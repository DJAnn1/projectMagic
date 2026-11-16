--!strict
--[[
	AgendaService: the world acts without you (docs/LivingHistory.md §5 and §8, Living History
	stage 4a). The plan for each game day is Agendas/AgendaRules: the same on every server, from the
	world seed alone. What happens on this server when one comes due:

	SIEGE      A player within liveReach of the town: it plays out live. A band of the nearest haunt's
	           Wildborn rises past the town's edge and makes for the plaza (WildbornService.band); the
	           town's people shelter (NPCService.setDanger), its guards and hunters turn out against
	           every raider they see (NPCCombat.onWitness), someone shouts. Band dead before its hours
	           are up: the town held. Otherwise it falls. Nobody near: the seeded outcome.
	FALLEN     Its people stay sheltering, nobody repairs anything (TownRepairService.holdTown), the
	           buildings round the plaza are scorched (when a player first comes near, so they're
	           there to scorch), dark smoke rises over it, and Wildborn hold the plaza (an occupation
	           band, raised when a player comes near). Kill them all: it's retaken, repairs start.
	           Unattended it frees itself on its seeded retake day. A new server knows which towns are
	           already fallen from the last lookBack days of plans (AgendaRules.fallen).
	RAID       A player near at night: a building on the town's edge catches fire (FireSim) and someone
	           shouts who did it. Unattended: only news.
	ALLIANCE, TRADE   news only (stage 4b may make them show).
	NEWS       Ask anyone for rumours: the nearest recent outcome within newsReach you haven't heard,
	           with a direction (NPCService rumour hook), and a quiet Journal line.
	CHRONICLE  Live outcomes only (an unattended one would be written by every server): a siege
	           broken, a town fallen, a town retaken (Topics.DeedDone).
	OVERRIDES  Live outcomes hold on this server only, as the owner chose (per server).

	Flag agendas_enabled. Admin: agendas [day], agendanow <kind>, townfall, townretake.
	Log: agenda_started, agenda_resolved, town_fell, town_retaken, agenda_news.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local OmenRules = require(Shared.Magic.OmenRules)

local Server = script.Parent.Parent
local Rules = require(Server.Agendas.AgendaRules)
local Data = require(Server.Agendas.Data.Agendas)
local WorldClock = require(Server.NPC.WorldClock)
local NPCCombat = require(Server.NPC.NPCCombat)
local FireSim = require(Server.Magic.Cast.FireSim)

local T = Rules.Tuning

local AgendaService = {
	name = "AgendaService",
	dependencies = {
		"AdminService",
		"AmbientLifeService",
		"JournalService",
		"NPCService",
		"TownRepairService",
		"WildbornService",
		"WorldService",
		"WorldStateService",
	},
}

type Siege = { agenda: Rules.Agenda, band: string, risen: boolean, subjects: { string } }
type Fallen = {
	agenda: string,
	theme: string,
	retake: number,
	band: string,
	risen: boolean,
	scorched: boolean,
	smoke: BasePart?,
	subjects: { string },
}

local log: any = nil
local bus: any = nil
local npcs: any = nil
local ambient: any = nil
local journal: any = nil
local repair: any = nil
local wildborn: any = nil
local world: any = nil
local worldService: any = nil

local ready = false
local plans: { [number]: { Rules.Agenda } } = {}
local started: { [string]: boolean } = {}
local overrides: { [string]: string } = {} -- agenda id -> what really happened here (live)
local retakenAt: { [string]: number } = {} -- fall agenda id -> game time it was freed (live or admin)
local sieges: { [string]: Siege } = {}
local fallen: { [string]: Fallen } = {}
local heard: { [Player]: { [string]: boolean } } = {}
local folder: Folder? = nil
local adminCount = 0
local raiderIds: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local raiderCount = 0

local function enabled(): boolean
	return FeatureFlags.get("agendas_enabled") == true
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function townList(): { Rules.Town }
	local out: { Rules.Town } = {}
	for _, town in npcs:towns() do
		local relations = if town.settlement and town.settlement.relations then town.settlement.relations else {}
		table.insert(out, { id = town.id, x = town.x, z = town.z, radius = town.radius, relations = relations })
	end
	return out
end

local function hauntList(): { Rules.Haunt }
	local out: { Rules.Haunt } = {}
	for _, h in wildborn:haunts() do
		table.insert(out, { theme = h.theme, x = h.x, z = h.z })
	end
	return out
end

local function planFor(day: number): { Rules.Agenda }
	local plan = plans[day]
	if not plan then
		plan = Rules.plan(worldService:getSeed(), day, townList(), hauntList())
		plans[day] = plan
		-- Keep the cache small.
		for d in plans do
			if d < day - T.lookBack - 2 then
				plans[d] = nil
			end
		end
	end
	return plan
end

local function townById(id: string?): any?
	if not id then
		return nil
	end
	for _, town in npcs:towns() do
		if town.id == id then
			return town
		end
	end
	return nil
end

local function nameOf(id: string?): string
	local town = townById(id)
	return if town and town.settlement and town.settlement.name then tostring(town.settlement.name) else "a town"
end

local function rootOf(player: Player): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function playersNear(at: Vector3, radius: number): { Player }
	local out: { Player } = {}
	for _, player in Players:GetPlayers() do
		local p = rootOf(player)
		if p and flat(p, at) <= radius then
			table.insert(out, player)
		end
	end
	return out
end

local function centreOf(town: any): Vector3
	return Vector3.new(town.x, world:surfaceHeight(town.x, town.z), town.z)
end

local function deed(kind: string, town: any, by: { Player }?)
	if not bus then
		return
	end
	local ids: { number }? = nil
	if by and #by > 0 then
		ids = {}
		for _, p in by do
			table.insert(ids :: { number }, p.UserId)
		end
	end
	bus:publish(Topics.DeedDone, { kind = kind, x = town.x, z = town.z, by = ids, what = nameOf(town.id) })
end

-- Someone in `town` near `at` shouts a line from `category`.
local function shout(town: any, at: Vector3, category: string, vars: { [string]: string })
	local best, bestD = nil, 120
	for _, npc in town.npcs do
		if npc.rig and not npc.knockedOut and npc.action ~= "sleep" then
			local d = flat(npc.position, at)
			if d < bestD then
				best, bestD = npc, d
			end
		end
	end
	if best then
		local line = ambient:lineFor(best, nil, { category }, Data.lines, vars)
		if line then
			npcs:speak(best, line, 90)
		end
	end
end

-- Guards and hunters near any living member of a band turn on it.
local function turnOut(town: any, bandId: string, subjects: { string })
	local exists, _, models = wildborn:bandStatus(bandId)
	if not exists then
		return
	end
	for _, model in models do
		local id = raiderIds[model]
		if not id then
			raiderCount += 1
			id = raiderCount
			raiderIds[model] = id
		end
		local subject = "wb:" .. bandId .. ":" .. id
		if not table.find(subjects, subject) then
			table.insert(subjects, subject)
			NPCCombat.setExternalTarget(subject, function(): (Model?, BasePart?)
				local root = model:FindFirstChild("HumanoidRootPart")
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if model.Parent and humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
					return model, root
				end
				return nil, nil
			end)
		end
		local root = model:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			for _, npc in town.npcs do
				if (npc.occupation == "guard" or npc.occupation == "hunter") and npc.rig and not npc.knockedOut and flat(npc.position, root.Position) <= 110 then
					NPCCombat.onWitness(npc, subject)
				end
			end
		end
	end
end

local function forgetSubjects(subjects: { string })
	for _, subject in subjects do
		NPCCombat.setExternalTarget(subject, nil)
	end
	table.clear(subjects)
end

-- ─── Fallen towns ───────────────────────────────────────────────────────────

local function makeSmoke(town: any): BasePart
	local part = Instance.new("Part")
	part.Name = "FallenSmoke_" .. town.id
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(12, 1, 12)
	part.Position = centreOf(town) + Vector3.new(0, 12, 0)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(40, 36, 34), Color3.fromRGB(90, 86, 82))
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 10), NumberSequenceKeypoint.new(1, 40) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	smoke.Lifetime = NumberRange.new(14, 20)
	smoke.Rate = 4
	smoke.Speed = NumberRange.new(9, 14)
	smoke.SpreadAngle = Vector2.new(12, 12)
	smoke.Acceleration = Vector3.new(2, 1, 0)
	smoke.LightInfluence = 1
	smoke.Parent = part
	part.Parent = folder
	return part
end

local function fall(town: any, agendaId: string, theme: string, retake: number, live: boolean)
	if fallen[town.id] then
		return
	end
	local f: Fallen = {
		agenda = agendaId, theme = theme, retake = retake, band = "occupy:" .. town.id .. ":" .. agendaId,
		risen = false, scorched = false, smoke = makeSmoke(town), subjects = {},
	}
	fallen[town.id] = f
	repair:holdTown(town.id, true)
	npcs:setDanger(town.id, "fallen:" .. agendaId, "siege", 0.7)
	log:info("town_fell", { town = town.id, agenda = agendaId, theme = theme, live = live, retake = math.floor(retake * 10) / 10 })
end

local function free(town: any, how: string, by: { Player }?)
	local f = fallen[town.id]
	if not f then
		return
	end
	fallen[town.id] = nil
	retakenAt[f.agenda] = WorldClock.now()
	forgetSubjects(f.subjects)
	wildborn:dropBand(f.band)
	if f.smoke then
		f.smoke:Destroy()
	end
	repair:holdTown(town.id, false)
	npcs:setDanger(town.id, "fallen:" .. f.agenda, "siege", nil)
	if how == "retaken" then
		deed("town_retaken", town, by)
	end
	log:info("town_retaken", { town = town.id, agenda = f.agenda, how = how, by = if by and by[1] then by[1].UserId else nil })
end

local function keepFallen(town: any, f: Fallen, now: number)
	if now >= f.retake then
		free(town, "time", nil)
		return
	end
	local centre = centreOf(town)
	local near = playersNear(centre, T.liveReach)
	if #near == 0 then
		return
	end
	if not f.scorched then
		local n = repair:scorch(centre, town.radius * 0.6, 40)
		f.scorched = n > 0
	end
	local exists, alive = wildborn:bandStatus(f.band)
	if not exists and not f.risen then
		f.risen = wildborn:band(f.band, f.theme, centre, centre, T.occupation)
	elseif f.risen and (not exists or alive == 0) then
		if exists then
			free(town, "retaken", playersNear(centre, 250))
		else
			f.risen = false -- the band went with nobody near: it holds the plaza again next time
		end
		return
	end
	turnOut(town, f.band, f.subjects)
end

-- ─── Starting and resolving ─────────────────────────────────────────────────

local function resolve(agenda: Rules.Agenda, outcome: string, live: boolean)
	overrides[agenda.id] = if live then outcome else overrides[agenda.id]
	log:info("agenda_resolved", { id = agenda.id, kind = agenda.kind, town = agenda.town, outcome = outcome, live = live })
end

local function edgePoint(town: any, theme: string?): Vector3
	local towards: Vector3? = nil
	if theme then
		local best, bestD = nil, math.huge
		for _, h in wildborn:haunts() do
			local d = (h.x - town.x) ^ 2 + (h.z - town.z) ^ 2
			if h.theme == theme and d < bestD then
				best, bestD = h, d
			end
		end
		if best then
			towards = Vector3.new(best.x - town.x, 0, best.z - town.z)
		end
	end
	local dir = if towards and towards.Magnitude > 1 then towards.Unit else Vector3.new(1, 0, 0)
	local reach = town.radius + T.edge
	local x, z = town.x + dir.X * reach, town.z + dir.Z * reach
	return Vector3.new(x, world:surfaceHeight(x, z), z)
end

local function edgeBuildingPart(town: any): BasePart?
	local centre = Vector3.new(town.x, 0, town.z)
	local best: Model?, bestD = nil, -1
	for _, model in CollectionService:GetTagged("Structure") do
		if model:IsA("Model") and model:GetAttribute("SettlementId") == town.id then
			local d = flat(model:GetPivot().Position, centre)
			if d > bestD then
				best, bestD = model, d
			end
		end
	end
	if not best then
		return nil
	end
	for _, part in best:GetDescendants() do
		if part:IsA("BasePart") and ((part:GetAttribute("Flammability") :: number?) or 0) > 0 then
			return part
		end
	end
	return nil
end

local function start(agenda: Rules.Agenda)
	started[agenda.id] = true
	local town = townById(agenda.town)
	if not town then
		return
	end
	local centre = centreOf(town)
	local live = #playersNear(centre, T.liveReach) > 0
	log:info("agenda_started", { id = agenda.id, kind = agenda.kind, town = agenda.town, other = agenda.other, live = live })
	if agenda.kind == "siege" then
		if fallen[town.id] then
			return -- already theirs
		end
		if live then
			local band = "siege:" .. agenda.id
			local from = edgePoint(town, agenda.theme)
			local count = T.band[1] + (#agenda.id % (T.band[2] - T.band[1] + 1))
			if wildborn:band(band, agenda.theme or "fire", from, centre, count) then
				sieges[agenda.id] = { agenda = agenda, band = band, risen = true, subjects = {} }
				npcs:setDanger(town.id, "siege:" .. agenda.id, "siege", 0.5)
				shout(town, from, "shout_siege", { dir = OmenRules.bearing(town.x, town.z, from.X, from.Z) })
				return
			end
		end
		resolve(agenda, agenda.outcome, false)
		if agenda.outcome == "fell" then
			fall(town, agenda.id, agenda.theme or "fire", agenda.retake or (agenda.day + T.retakeDays[2]), false)
		end
	elseif agenda.kind == "raid" then
		local hour = WorldClock.hour()
		if live and (hour >= 20 or hour < 5) then
			local part = edgeBuildingPart(town)
			if part then
				FireSim.ignitePart(part, 0.8)
				shout(town, part.Position, "shout_raid", { other = nameOf(agenda.other) })
				resolve(agenda, "burned", true)
				return
			end
		end
		resolve(agenda, agenda.outcome, false)
	else
		resolve(agenda, agenda.outcome, false)
	end
end

local function stepSiege(id: string, siege: Siege, now: number)
	local agenda = siege.agenda
	local town = townById(agenda.town)
	if not town then
		sieges[id] = nil
		return
	end
	local exists, alive = wildborn:bandStatus(siege.band)
	local over = now >= agenda.at + agenda.hours / 24
	local function finish(outcome: string, live: boolean)
		sieges[id] = nil
		forgetSubjects(siege.subjects)
		npcs:setDanger(town.id, "siege:" .. agenda.id, "siege", nil)
		resolve(agenda, outcome, live)
	end
	if exists and alive == 0 then
		finish("held", true)
		deed("siege_broken", town, playersNear(centreOf(town), T.liveReach))
	elseif not exists then
		-- Everyone left: what was always going to happen, happens.
		finish(agenda.outcome, false)
		if agenda.outcome == "fell" then
			fall(town, agenda.id, agenda.theme or "fire", agenda.retake or (agenda.day + T.retakeDays[2]), false)
		end
	elseif over then
		wildborn:dropBand(siege.band)
		finish("fell", true)
		fall(town, agenda.id, agenda.theme or "fire", agenda.retake or (agenda.day + T.retakeDays[2]), true)
		deed("town_fell", town, nil)
	else
		turnOut(town, siege.band, siege.subjects)
	end
end

local function tick()
	if not enabled() or not ready then
		return
	end
	local now = WorldClock.now()
	local today = math.floor(now)
	for day = today - 1, today do
		for _, agenda in planFor(day) do
			if not started[agenda.id] and now >= agenda.at and now < agenda.at + agenda.hours / 24 then
				start(agenda)
			end
		end
	end
	for id, siege in sieges do
		stepSiege(id, siege, now)
	end
	for townId, f in fallen do
		local town = townById(townId)
		if town then
			keepFallen(town, f, now)
		end
	end
end

-- ─── News ───────────────────────────────────────────────────────────────────

type News = { id: string, outcome: string, town: string, other: string?, at: number }

local function recentNews(now: number): { News }
	local out: { News } = {}
	local today = math.floor(now)
	for day = today - T.newsKeep, today do
		for _, agenda in planFor(day) do
			local done = agenda.at + agenda.hours / 24
			if done <= now then
				local outcome = overrides[agenda.id] or agenda.outcome
				table.insert(out, { id = agenda.id, outcome = outcome, town = agenda.town, other = agenda.other, at = done })
				if agenda.kind == "siege" and outcome == "fell" then
					local freedAt = retakenAt[agenda.id] or (if agenda.retake and not overrides[agenda.id] then agenda.retake else nil)
					if freedAt and freedAt <= now then
						table.insert(out, { id = agenda.id .. ":retaken", outcome = "retaken", town = agenda.town, at = freedAt })
					end
				end
			end
		end
	end
	return out
end

local function rumorHook(player: Player, npc: any): string?
	if not enabled() or not ready or typeof(npc.position) ~= "Vector3" then
		return nil
	end
	local mine = heard[player] or {}
	heard[player] = mine
	local best: News?, bestD = nil, T.newsReach
	for _, news in recentNews(WorldClock.now()) do
		local town = townById(news.town)
		if town and not mine[news.id] then
			local d = flat(npc.position, Vector3.new(town.x, 0, town.z))
			if d <= bestD and npc.settlementId ~= news.town then
				best, bestD = news, d
			end
		end
	end
	if not best then
		return nil
	end
	local town = townById(best.town)
	if not town then
		return nil
	end
	local vars = {
		town = nameOf(best.town),
		other = nameOf(best.other),
		dir = OmenRules.bearing(npc.position.X, npc.position.Z, town.x, town.z),
	}
	local text = ambient:lineFor(npc, player, { "news_" .. best.outcome }, Data.lines, vars)
	if not text then
		return nil
	end
	mine[best.id] = true
	local line = Data.journal[best.outcome]
	if line then
		journal:log(player, "rumor", (string.gsub(line, "{(%w+)}", function(k)
			return vars[k] or ""
		end)), { quiet = true })
	end
	log:info("agenda_news", { userId = player.UserId, npc = npc.id, news = best.id, outcome = best.outcome })
	return text
end

-- For OmenService: sieges starting within `within` real seconds, as { id, x, z, startsAt (unix) }.
function AgendaService.upcoming(_self: any, within: number): { { id: string, x: number, z: number, startsAt: number } }
	local out = {}
	if not enabled() or not ready then
		return out
	end
	local now = WorldClock.now()
	local perDay = WorldClock.daySeconds() / math.max(WorldClock.scale(), 1e-3)
	for day = math.floor(now), math.floor(now) + 1 do
		for _, agenda in planFor(day) do
			local inSeconds = (agenda.at - now) * perDay
			if agenda.kind == "siege" and not started[agenda.id] and inSeconds > 0 and inSeconds <= within then
				local town = townById(agenda.town)
				if town then
					table.insert(out, { id = agenda.id, x = town.x, z = town.z, startsAt = os.time() + inSeconds })
				end
			end
		end
	end
	return out
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function nearestTown(player: Player): any?
	local at = rootOf(player)
	if not at then
		return nil
	end
	local best, bestD = nil, math.huge
	for _, town in npcs:towns() do
		local d = flat(at, Vector3.new(town.x, 0, town.z))
		if d < bestD then
			best, bestD = town, d
		end
	end
	return best
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "agendas",
		category = "World",
		description = "The world's own business: a game day's agendas (0 = today, -1 yesterday, 1 tomorrow) with their seeded and real outcomes, sieges running and fallen towns",
		args = { { name = "day", type = "integer", min = -10, max = 10, default = 0 } },
		handler = function(_ctx: any, a: any)
			local now = WorldClock.now()
			local day = math.floor(now) + a.day
			local lines = { string.format("on=%s · ready=%s · game day %d (now %s)", tostring(enabled()), tostring(ready), day, WorldClock.stamp()) }
			for _, agenda in planFor(day) do
				table.insert(lines, string.format("%s: %s %s%s at %02d:%02d for %dh · seeded %s%s%s", agenda.id, agenda.kind, nameOf(agenda.town),
					if agenda.other then " ← " .. nameOf(agenda.other) else "", math.floor((agenda.at - day) * 24) % 24, math.floor(((agenda.at - day) * 24 % 1) * 60),
					agenda.hours, agenda.outcome, if overrides[agenda.id] then " · here " .. overrides[agenda.id] else "", if started[agenda.id] then " · started" else ""))
			end
			if #lines == 1 then
				table.insert(lines, "(nothing that day)")
			end
			for id, siege in sieges do
				local _, alive = wildborn:bandStatus(siege.band)
				table.insert(lines, string.format("siege running %s: %d Wildborn left", id, alive))
			end
			for townId, f in fallen do
				local _, alive = wildborn:bandStatus(f.band)
				table.insert(lines, string.format("fallen %s (%s) until day %.1f · occupiers %d", nameOf(townId), f.theme, f.retake, alive))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "agendanow",
		category = "World",
		description = "Start an agenda at the nearest town right now, live if you're within reach: siege (Wildborn march on it), raid (a fire at its edge, at night only), alliance, trade",
		args = { { name = "kind", type = "enum", options = { "siege", "raid", "alliance", "trade" } } },
		handler = function(ctx: any, a: any)
			local town = nearestTown(ctx.player)
			if not town then
				return "no towns"
			end
			adminCount += 1
			local theme = "fire"
			local haunt = Rules.nearestHaunt({ id = town.id, x = town.x, z = town.z, radius = town.radius, relations = {} }, hauntList())
			if haunt then
				theme = haunt.theme
			end
			local other: string? = nil
			for _, t in npcs:towns() do
				if t.id ~= town.id then
					other = t.id
					break
				end
			end
			local now = WorldClock.now()
			local agenda: Rules.Agenda = {
				id = string.format("admin_%s_%d", a.kind, adminCount), day = math.floor(now), kind = a.kind, town = town.id,
				other = if a.kind == "raid" or a.kind == "alliance" then other else nil, theme = theme, at = now,
				hours = T.lasts[a.kind], outcome = if a.kind == "siege" then "fell" elseif a.kind == "raid" then "burned" elseif a.kind == "alliance" then "sworn" else "boom",
				retake = math.floor(now) + T.retakeDays[1],
			}
			start(agenda)
			return string.format("%s at %s (%s)", a.kind, nameOf(town.id), if sieges[agenda.id] then "live: Wildborn coming" else "resolved: " .. (overrides[agenda.id] or agenda.outcome))
		end,
	})
	admin:Register({
		name = "townfall",
		category = "World",
		description = "The nearest town falls to the Wildborn right now (this server): its people shelter, repairs stop, smoke, occupiers at the plaza when you come near",
		args = {},
		handler = function(ctx: any, _a: any)
			local town = nearestTown(ctx.player)
			if not town then
				return "no towns"
			end
			local haunt = Rules.nearestHaunt({ id = town.id, x = town.x, z = town.z, radius = town.radius, relations = {} }, hauntList())
			adminCount += 1
			fall(town, "admin_fall_" .. adminCount, if haunt then haunt.theme else "fire", WorldClock.now() + T.retakeDays[1], true)
			return nameOf(town.id) .. " has fallen"
		end,
	})
	admin:Register({
		name = "townretake",
		category = "World",
		description = "The nearest fallen town is free again right now, as if its occupiers were gone (no Chronicle deed)",
		args = {},
		handler = function(ctx: any, _a: any)
			local town = nearestTown(ctx.player)
			if not town or not fallen[town.id] then
				return "the nearest town isn't fallen"
			end
			free(town, "admin", nil)
			return nameOf(town.id) .. " is free"
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function AgendaService.init(_self: any, ctx: any)
	log = ctx.log
	bus = ctx.bus
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	journal = ctx.get("JournalService")
	repair = ctx.get("TownRepairService")
	wildborn = ctx.get("WildbornService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
	npcs:setRumorHook(rumorHook)
	Players.PlayerRemoving:Connect(function(player)
		heard[player] = nil
	end)
end

function AgendaService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Agendas"
	parent.Parent = workspace
	folder = parent
	task.spawn(function()
		world:awaitReady()
		while not npcs:isReady() do
			task.wait(2)
		end
		-- Haunts are planned in the background: the plans depend on them.
		local waited = 0
		while #wildborn:haunts() == 0 and waited < 60 do
			task.wait(2)
			waited += 2
		end
		local now = WorldClock.now()
		local known = Rules.fallen(worldService:getSeed(), now, townList(), hauntList())
		local count = 0
		for townId, f in known do
			local town = townById(townId)
			if town then
				fall(town, f.agenda, f.theme, f.retake, false)
				count += 1
			end
		end
		-- What already ended before this server is history, not something to start.
		for day = math.floor(now) - 1, math.floor(now) do
			for _, agenda in planFor(day) do
				if now >= agenda.at + agenda.hours / 24 then
					started[agenda.id] = true
				end
			end
		end
		ready = true
		log:info("agendas_ready", { fallen = count, today = #planFor(math.floor(now)), haunts = #wildborn:haunts() })
		while true do
			task.wait(5)
			local ok, err = pcall(tick)
			if not ok then
				log:warn("agenda_tick_failed", { err = tostring(err) })
			end
		end
	end)
end

return AgendaService
