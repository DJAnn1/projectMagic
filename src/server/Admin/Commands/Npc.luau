--!strict
--[[
	NPC tools (NPCService's admin API) and population control.
	NPC arguments take an id, (part of) a name, "nearest", or "@selected" (the panel's inspector).

	npc · npcinspect · npcs · npcday · npclod · npcawaken · npctalk
	npcspawn [occupation] [seed] [at] [spec]   spec: "openness=0.9 pride=0.2 quirks=lucky_coin,grudge_keeper
	                                           metallurgy=70 name=Ada_Stone age=30"
	npcdelete · npckill · npcheal · npcfreeze [on|off] · npctier <0|1|2|auto>
	navaudit <settlement>: every building's path tested piece by piece (the sealed-rooms hunt)
	npcneed · npctrait · npcmastery · npcrel · npcbond · npcdo · npcgossip · npcambition
	population <multiplier> · npcrebuild · npclist [settlement] [occupation] [domain] [minMastery]
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Server = script.Parent.Parent.Parent
local NpcData = require(Server.NPC.Data.NpcData)
local Quirks = require(Server.NPC.Data.Quirks)
local NPCLOD = require(Server.NPC.NPCLOD)
local NpcLooks = require(Server.NPC.NpcLooks)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)
local WorldClock = require(Server.NPC.WorldClock)
local Util = require(script.Parent.Parent.Util)
local Navigation = require(Server.NPC.NavigationService)
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local TOPICS = { "greet", "self", "magic", "rumor", "work", "learn", "farewell", "ambient" }

return function(admin: any, deps: any)
	local npcs = deps.npcs
	local world = deps.world

	local function npcArg(optional: boolean?): any
		return { name = "npc", type = "npc", default = if optional then "nearest" else nil, hint = "id, name, nearest or @selected" }
	end

	admin:Register({
		name = "npc", category = "NPCs", description = "Describe an NPC: identity, needs, scores, memories, relationships, magic",
		args = { npcArg(true) },
		handler = function(_, a)
			return npcs:describe(a.npc)
		end,
	})

	admin:Register({
		name = "npclook", category = "NPCs", description = "What an NPC wears (hair, headwear, beard, scarf) and their body scale (NPC/NpcLooks)",
		args = { npcArg(true) },
		handler = function(_, a)
			local npc = a.npc
			local appearance = npc.appearance or {}
			return string.format("%s (%s, %s %s, %s hair, %s, %s): %s", npc.name, tostring(npc.ageBand), tostring(npc.culture), tostring(npc.occupation),
				tostring(appearance.hair), tostring(appearance.build), tostring(appearance.feature), NpcLooks.describe(NpcLooks.choose(npc)))
		end,
	})

	admin:Register({
		name = "npcinspect", category = "NPCs", description = "Open an NPC in the panel's inspector (click an NPC with the Inspector tab open)",
		args = { npcArg(true) },
		handler = function(_, a)
			return { text = "inspecting " .. a.npc.name, data = { kind = "npcinspect", npc = npcs:inspect(a.npc) } }
		end,
	})

	-- The panel inspector's 1 s refresh: hidden, so it doesn't fill the audit log.
	admin:Register({
		name = "__npcinspect", hidden = true, category = "NPCs", description = "inspector refresh",
		args = { npcArg(true) },
		handler = function(_, a)
			return { text = "", data = { kind = "npcinspect", npc = npcs:inspect(a.npc) } }
		end,
	})

	admin:Register({
		name = "npcs", category = "Population", description = "Settlements, populations and LOD tiers",
		handler = function()
			if not npcs:isReady() then
				return "NPCs aren't ready"
			end
			local stats = npcs:stats()
			local total = #npcs:all()
			local lines = { string.format("%s%s | %d NPCs in %d towns, boot %d ms, time x%g", WorldClock.stamp(), if WorldClock.isAltered() then " (altered)" else "", total, #npcs:towns(), stats.bootMs, WorldClock.scale()) }
			for _, town in npcs:towns() do
				local t = { 0, 0, 0 }
				local out, rogue = 0, 0
				for _, npc in town.npcs do
					t[(npc.tier or 2) + 1] += 1
					out += if npc.knockedOut then 1 else 0
					rogue += if npc.magic.rogue then 1 else 0
				end
				local dangers = {}
				for _, kind in town.dangers do
					table.insert(dangers, kind)
				end
				table.insert(lines, string.format("%s %s (%s %s) pop %d  T0 %d T1 %d T2 %d  out %d rogue %d%s", town.id, town.settlement.name, town.settlement.culture, town.settlement.size,
					#town.npcs, t[1], t[2], t[3], out, rogue, if #dangers > 0 then "  DANGER " .. table.concat(dangers, ",") else ""))
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "npcday", category = "NPCs", description = "A deterministic 24-hour trace of an NPC's day",
		args = { npcArg(true) },
		handler = function(_, a)
			return npcs:dayTrace(a.npc)
		end,
	})

	admin:Register({
		name = "npcmove", category = "NPCs", description = "An NPC's movement report: state, agent size, speed, network owner, recent history, and the totals",
		args = { npcArg(true) },
		handler = function(_, a)
			return npcs:navReport(a.npc)
		end,
	})

	-- ─── navaudit: why are rooms sealed? (Shine Pass, 2026-11-10) ──────────────
	-- Splits the walk into a building into pieces and tests each with an ordinary villager's agent,
	-- so one run says WHICH piece fails and on WHICH building types, instead of guessing.
	local auditRay = RaycastParams.new()
	auditRay.FilterType = Enum.RaycastFilterType.Exclude

	local function auditExclude(): { Instance }
		local list: { Instance } = {}
		local folder = workspace:FindFirstChild("NPCs")
		if folder then
			table.insert(list, folder)
		end
		for _, p in Players:GetPlayers() do
			if p.Character then
				table.insert(list, p.Character)
			end
		end
		auditRay.FilterDescendantsInstances = list
		return list
	end

	-- What's under a point: (its height above what was hit, the hit part's name), or nil when nothing is within 14 studs.
	local function under(pos: Vector3): (number?, string?)
		local hit = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -16, 0), auditRay)
		if not hit then
			return nil, nil
		end
		return pos.Y - hit.Position.Y, hit.Instance.Name
	end

	local function grounded(pos: Vector3): Vector3
		local gap = under(pos)
		return if gap then pos - Vector3.new(0, gap - 0.5, 0) else pos
	end

	local function canWalkAway(params: any, pos: Vector3): boolean
		for _, dir in Navigation.PROBE_DIRECTIONS do
			if Navigation.TryPath(params, pos, pos + dir * 4) then
				return true
			end
		end
		return false
	end

	-- Solid parts crowding a standing spot within the agent's radius (body height, above the floor).
	-- The box turns with the building: a world-aligned box over-counted in rotated lots (a turned bed's
	-- world bounds are far bigger than the bed).
	local function crowding(pos: Vector3, radius: number, exclude: { Instance }, turn: CFrame): (number, string)
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Exclude
		overlap.FilterDescendantsInstances = exclude
		local feet = grounded(pos)
		local box = CFrame.new(feet + Vector3.new(0, 2.75, 0)) * turn
		local names: { string } = {}
		local n = 0
		for _, part in workspace:GetPartBoundsInBox(box, Vector3.new(radius * 2, 4.5, radius * 2), overlap) do
			if part.CanCollide then
				n += 1
				if #names < 3 and not table.find(names, part.Name) then
					table.insert(names, part.Name)
				end
			end
		end
		return n, table.concat(names, ",")
	end

	local function mark(ok: boolean): string
		return if ok then "✓" else "✗"
	end

	local function gapText(g: number?, on: string?): string
		return if g then string.format("%+.1f on %s", g, on or "?") else "nothing below"
	end

	admin:Register({
		name = "navaudit", category = "NPCs",
		description = "Test every building in a town for NPC paths, piece by piece (outside → door → through → room → home spot), with link-end heights and furniture crowding the home spot. Takes a few seconds; rows also go to the Output as nav_audit",
		args = { { name = "settlement", type = "settlement" } },
		handler = function(_, a)
			local params = Navigation.auditParams()
			local radius: number = params.AgentRadius
			local exclude = auditExclude()
			local rows: { string } = {}
			local byType: { [string]: { n: number, full: number } } = {}
			local fails: { [string]: number } = { out = 0, door = 0, room = 0, home = 0, homeFree = 0, full = 0, grounded = 0 }
			local total = 0
			for _, model in CollectionService:GetTagged("Building") do
				if not (model:IsA("Model") and model:IsDescendantOf(workspace) and model:GetAttribute("SettlementId") == a.settlement.id) then
					continue
				end
				local primary = model.PrimaryPart
				if not primary then
					continue
				end
				local entrance = primary:FindFirstChild("Entrance")
				local linkA = primary:FindFirstChild("PathLink1A")
				local linkB = primary:FindFirstChild("PathLink1B")
				local home = primary:FindFirstChild("NPCHome") or primary:FindFirstChild("NPCWork") or primary:FindFirstChild("NPCSeat1")
				if not (entrance and linkA and linkB and home and entrance:IsA("Attachment") and linkA:IsA("Attachment")
					and linkB:IsA("Attachment") and home:IsA("Attachment")) then
					continue -- not a building people go into
				end
				total += 1
				local kind = tostring(model:GetAttribute("BuildingType"))
				local lot = tostring(model:GetAttribute("LotId"))
				local ePos, aPos, bPos, hPos = grounded(entrance.WorldPosition), linkA.WorldPosition, linkB.WorldPosition, home.WorldPosition
				local out = Navigation.TryPath(params, ePos, aPos)
				local door, via = Navigation.TryPath(params, aPos, bPos)
				local room = canWalkAway(params, bPos)
				local toHome = Navigation.TryPath(params, bPos, hPos)
				local homeFree = canWalkAway(params, hPos)
				local full = Navigation.TryPath(params, ePos, hPos)
				local fullGrounded = full or Navigation.TryPath(params, ePos, grounded(hPos))
				local gapA, onA = under(aPos)
				local gapB, onB = under(bPos)
				local gapH = under(hPos)
				local lotFrame = model:GetAttribute("LotCFrame")
				local turn = if typeof(lotFrame) == "CFrame" then lotFrame.Rotation else CFrame.identity
				local crowd, crowdNames = crowding(hPos, radius, exclude, turn)
				local results: { [string]: boolean } = { out = out, door = door, room = room, home = toHome, homeFree = homeFree, full = full, grounded = fullGrounded }
				for key, ok in results do
					if not ok then
						fails[key] += 1
					end
				end
				local t = byType[kind] or { n = 0, full = 0 }
				t.n += 1
				t.full += if full then 1 else 0
				byType[kind] = t
				local shortLot = string.gsub(lot, "^.*_", "")
				table.insert(rows, string.format(
					"%s %s %s | out %s door %s%s room %s home %s homeFree %s grounded %s | link out %s, in %s | home spot %s above floor, %d solid within %.2g (%s)",
					mark(full), shortLot, kind, mark(out), mark(door), if door and not via then "(no link)" else "",
					mark(room), mark(toHome), mark(homeFree), mark(fullGrounded),
					gapText(gapA, onA), gapText(gapB, onB), if gapH then string.format("%.1f", gapH) else "?", crowd, radius, crowdNames))
				if deps.log then
					deps.log:info("nav_audit", {
						lot = lot, kind = kind, full = full, out = out, door = door, viaLink = via, room = room, home = toHome,
						homeFree = homeFree, grounded = fullGrounded, gapOut = gapA, onOut = onA, gapIn = gapB, onIn = onB,
						homeAbove = gapH, crowd = crowd, crowdBy = crowdNames,
					})
				end
				task.wait()
			end
			table.sort(rows)
			local types: { string } = {}
			for kind, t in byType do
				table.insert(types, string.format("%s %d/%d", kind, t.full, t.n))
			end
			table.sort(types)
			if deps.log then
				deps.log:info("nav_audit_summary", {
					settlement = a.settlement.id, buildings = total, failOut = fails.out, failDoor = fails.door, failRoom = fails.room,
					failHome = fails.home, failHomeFree = fails.homeFree, failFull = fails.full, failGrounded = fails.grounded,
				})
			end
			return string.format(
				"%d buildings, agent radius %.2g. Walk in reaches home: %s\nfailed: outside→door %d · through the door %d · room sealed %d · door→home %d · home spot boxed in %d · whole walk %d (%d even with the home spot on the floor)\n%s",
				total, radius, table.concat(types, " · "), fails.out, fails.door, fails.room, fails.home, fails.homeFree, fails.full, fails.grounded,
				table.concat(rows, "\n"))
		end,
	})

	admin:Register({
		name = "npclod", category = "Population", description = "LOD tiers, rig pool, path cache and brain cost",
		handler = function()
			local stats = npcs:stats()
			local a, b, c = NPCLOD.counts(npcs:towns())
			local available, built = NPCLOD.poolStats()
			local paths = NPCLOD.pathStats()
			local ticks = math.max(stats.brainTicks, 1)
			return string.format("T0 %d/%d  T1 %d/%d  T2 %d\nrigs %d built, %d pooled\npaths computed %d, cache hits %d, failed %d, queued %d\nbrain %.3f ms per tick (%d ticks)  T2 batch %d NPCs in %.1f ms%s",
				a, NPCLOD.limits.maxT0, b, NPCLOD.limits.maxT1, c, built, available, paths.computed, paths.cacheHits, paths.failed, paths.queued,
				stats.brainMs / ticks, stats.brainTicks, stats.t2Count, stats.t2Ms, if stats.parallel then " (parallel)" else "")
		end,
	})

	admin:Register({
		name = "npcawaken", category = "NPCs", description = "Wake an NPC's hidden mythic gift (no NPC: list who has one)",
		args = { { name = "npc", type = "npc", optional = true } },
		handler = function(_, a)
			if not a.npc then
				local lines = {}
				for _, npc in npcs:all() do
					if npc.magic.hiddenMythic then
						table.insert(lines, string.format("%s %s: hidden %s", npc.id, npc.name, npc.magic.hiddenMythic))
					end
				end
				return if #lines > 0 then table.concat(lines, "\n") else "(no hidden mythic NPCs)"
			end
			return if npcs:awaken(a.npc, "admin") then a.npc.name .. " awakened to " .. a.npc.magic.awakened.domain else a.npc.name .. " has no hidden gift"
		end,
	})

	admin:Register({
		name = "npctalk", category = "NPCs", description = "What an NPC would say to you (no distance check, no side effects)",
		args = { npcArg(true), { name = "topic", type = "enum", options = TOPICS, default = "greet" } },
		handler = function(ctx, a)
			return npcs:sample(a.npc, ctx.player, a.topic)
		end,
	})

	-- "openness=0.9 quirks=a,b metallurgy=70 name=Ada_Stone age=30"
	local function parseSpec(spec: string?): ({ [string]: any }?, string?)
		local opts: { [string]: any } = { traits = {}, mastery = {} }
		-- Commas inside a value (quirks=a,b) become ';' so tokens split on spaces only.
		for _, token in Util.splitList((string.gsub(spec or "", ",", ";"))) do
			local key, value = string.match(token, "^([%w_]+)=(.+)$")
			if not key or not value then
				return nil, "bad spec token '" .. token .. "' (use key=value)"
			end
			key = string.lower(key)
			if key == "quirks" then
				opts.quirks = {}
				for _, q in string.split(value, ";") do
					if not Quirks.defs[q] then
						return nil, "no quirk " .. q
					end
					table.insert(opts.quirks, q)
				end
			elseif key == "name" then
				opts.name = string.gsub(value, "_", " ")
			elseif key == "age" then
				opts.age = math.clamp(tonumber(value) or 30, 6, 95)
			elseif table.find(NpcData.bigFive, key) or table.find(NpcData.custom, key) then
				opts.traits[key] = math.clamp(tonumber(value) or 0.5, 0, 1)
			elseif Registry.branches[key] then
				opts.mastery[key] = math.clamp(tonumber(value) or 30, 0, 100)
			else
				return nil, "unknown spec key '" .. key .. "' (a trait, quirks, a branch id, name or age)"
			end
		end
		return opts, nil
	end

	admin:Register({
		name = "npcspawn", category = "NPCs", description = "Spawn an NPC at a point, optionally with an occupation, a seed and a spec (traits, quirks, mastery)",
		args = {
			{ name = "occupation", type = "occupation", optional = true },
			{ name = "seed", type = "integer", min = 1, max = 2 ^ 31 - 2, optional = true, hint = "a different person per seed" },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: 8 studs ahead)" },
			{ name = "spec", type = "text", optional = true, hint = "openness=0.9 quirks=lucky_coin metallurgy=70 name=Ada_Stone" },
		},
		handler = function(ctx, a)
			local at: Vector3? = a.at or Util.ahead(ctx.player, world, 8)
			if not at then
				return "no character"
			end
			local opts, err = parseSpec(a.spec)
			if not opts then
				return err or "bad spec"
			end
			opts.occupation, opts.seed = a.occupation, a.seed
			local npc, why = npcs:spawn(at, opts)
			if not npc then
				return why or "spawn failed"
			end
			return { text = string.format("spawned %s (%s, %s, %d) at %s", npc.name, npc.id, npc.occupationName, npc.age, Util.fmt(at)), data = { kind = "select", npcId = npc.id } }
		end,
	})

	admin:Register({
		name = "npcdelete", category = "NPCs", description = "Remove an NPC from this server (generated ones return on restart)",
		args = { npcArg() },
		handler = function(_, a)
			npcs:remove(a.npc)
			return "removed " .. a.npc.name
		end,
	})

	admin:Register({
		name = "npckill", category = "NPCs", description = "Knock an NPC out (six game hours, then they wake at home)",
		args = { npcArg() },
		handler = function(_, a)
			npcs:knockout(a.npc)
			return a.npc.name .. " is knocked out"
		end,
	})

	admin:Register({
		name = "npcheal", category = "NPCs", description = "Wake, heal and fully satisfy an NPC",
		args = { npcArg() },
		handler = function(_, a)
			npcs:heal(a.npc)
			return a.npc.name .. " healed"
		end,
	})

	admin:Register({
		name = "npcfreeze", category = "NPCs", description = "Freeze an NPC in place (no thinking, no moving)",
		args = { npcArg(), { name = "on", type = "boolean", optional = true } },
		handler = function(_, a)
			local frozen = if a.on == nil then not a.npc.frozen else a.on
			npcs:setFrozen(a.npc, frozen)
			return a.npc.name .. (if frozen then " frozen" else " unfrozen")
		end,
	})

	admin:Register({
		name = "npctier", category = "NPCs", description = "Force an NPC's LOD tier (0 full rig, 1 anchored rig, 2 data) or back to auto",
		args = { npcArg(), { name = "tier", type = "enum", options = { "0", "1", "2", "auto" } } },
		handler = function(_, a)
			npcs:forceTier(a.npc, if a.tier == "auto" then nil else tonumber(a.tier))
			return a.npc.name .. " tier " .. a.tier .. " (applies on the next LOD pass, 0.5 s)"
		end,
	})

	admin:Register({
		name = "npcneed", category = "NPCs", description = "Set one of an NPC's needs (0 desperate .. 1 satisfied)",
		args = { npcArg(), { name = "need", type = "need" }, { name = "value", type = "number", min = 0, max = 1, slider = true } },
		handler = function(_, a)
			npcs:setNeed(a.npc, a.need, a.value)
			return string.format("%s %s = %.2f (re-deciding)", a.npc.name, a.need, a.value)
		end,
	})

	admin:Register({
		name = "npctrait", category = "NPCs", description = "Set a personality trait (brain recompiled)",
		args = { npcArg(), { name = "trait", type = "trait" }, { name = "value", type = "number", min = 0, max = 1, slider = true } },
		handler = function(_, a)
			npcs:setTrait(a.npc, a.trait, a.value)
			return string.format("%s %s = %.2f", a.npc.name, a.trait, a.value)
		end,
	})

	admin:Register({
		name = "npcmastery", category = "NPCs", description = "Set an NPC's mastery in a branch (0 = forget it)",
		args = { npcArg(), { name = "branch", type = "branch" }, { name = "value", type = "number", min = 0, max = 100, slider = true } },
		handler = function(_, a)
			npcs:setMastery(a.npc, a.branch, a.value)
			return string.format("%s %s mastery %.0f (tier %d)", a.npc.name, a.branch, a.value, NPCMagicLife.tierOf(a.npc, a.branch))
		end,
	})

	admin:Register({
		name = "npcrel", category = "NPCs", description = "Set how an NPC feels about you or another NPC",
		args = {
			npcArg(),
			{ name = "about", type = "string", hint = "me, or an NPC id/name" },
			{ name = "affinity", type = "number", min = -1, max = 1, slider = true },
			{ name = "trust", type = "number", min = 0, max = 1, default = 0.5, slider = true },
		},
		handler = function(ctx, a)
			if string.lower(a.about) == "me" then
				npcs:setRelation(a.npc, "u:" .. ctx.player.UserId, a.affinity, a.trust, ctx.player)
				return string.format("%s's view of you: affinity %.2f trust %.2f", a.npc.name, a.affinity, a.trust)
			end
			local other = npcs:find(a.about, ctx.player)
			if not other then
				return "no NPC '" .. a.about .. "'"
			end
			npcs:setRelation(a.npc, other.id, a.affinity, a.trust, nil)
			return string.format("%s's view of %s: affinity %.2f trust %.2f", a.npc.name, other.name, a.affinity, a.trust)
		end,
	})

	admin:Register({
		name = "npcbond", category = "NPCs", description = "Make an NPC your teacher or your apprentice (or clear it)",
		args = { npcArg(), { name = "bond", type = "enum", options = { "teacher", "apprentice", "none" } } },
		handler = function(ctx, a)
			npcs:setBond(a.npc, ctx.player, a.bond)
			return if a.bond == "teacher" then a.npc.name .. " will teach you (try npcdo teachme)"
				elseif a.bond == "apprentice" then a.npc.name .. " is your apprentice: their study goes x1.5 in every domain"
				else "bond cleared"
		end,
	})

	admin:Register({
		name = "npcdo", category = "NPCs", description = "Force an action: any brain action, or home, flee, duel, teachme",
		args = { npcArg(), { name = "action", type = "npcaction" }, { name = "minutes", type = "number", min = 5, max = 1440, default = 60, hint = "game minutes" } },
		handler = function(ctx, a)
			return npcs:forceAction(a.npc, a.action, a.minutes, ctx.player)
		end,
	})

	admin:Register({
		name = "npcgossip", category = "NPCs", description = "The NPC gossips with up to five nearby townsfolk now",
		args = { npcArg() },
		handler = function(_, a)
			return string.format("%s gossiped; %d heard something new", a.npc.name, npcs:gossip(a.npc))
		end,
	})

	admin:Register({
		name = "npcambition", category = "NPCs", description = "Set an NPC's life ambition (and its branch)",
		args = { npcArg(), { name = "ambition", type = "ambition" }, { name = "branch", type = "branch", optional = true } },
		handler = function(_, a)
			if not npcs:setAmbition(a.npc, a.ambition, a.branch) then
				return "no ambition " .. a.ambition
			end
			return a.npc.name .. ": " .. a.npc.ambition.text
		end,
	})

	-- ─── Population ─────────────────────────────────────────────────────────

	admin:Register({
		name = "population", category = "Population", description = "Set the NPC population multiplier (0.25-3) and regenerate every NPC",
		args = { { name = "multiplier", type = "number", min = 0.25, max = 3, slider = true } },
		handler = function(_, a)
			FeatureFlags.set("npc_population_mult", a.multiplier)
			return npcs:rebuild()
		end,
	})

	admin:Register({
		name = "npcrebuild", category = "Population", description = "Save, then regenerate every NPC from the seed",
		handler = function()
			return npcs:rebuild()
		end,
	})

	admin:Register({
		name = "npclist", category = "Population", description = "List NPCs, filtered (each row has a tp button in the panel)",
		args = {
			{ name = "settlement", type = "settlement", optional = true },
			{ name = "occupation", type = "occupation", optional = true },
			{ name = "domain", type = "domain", optional = true },
			{ name = "minMastery", type = "number", min = 0, max = 100, default = 0 },
		},
		handler = function(_, a)
			if not npcs:isReady() then
				return "NPCs aren't ready"
			end
			local rows = {}
			for _, npc in npcs:all() do
				if a.settlement and npc.settlementId ~= a.settlement.id then
					continue
				end
				if a.occupation and npc.occupation ~= a.occupation then
					continue
				end
				if a.domain and not table.find(npc.profile.manifest, a.domain) then
					continue
				end
				local best, mastery, tier = NPCMagicLife.best(npc)
				if mastery < a.minMastery then
					continue
				end
				table.insert(rows, {
					id = npc.id,
					name = npc.name,
					town = npc.settlementName,
					occupation = npc.occupationName,
					domains = table.concat(npc.profile.manifest, "/"),
					best = if best then Registry.branches[best].name else "-",
					mastery = math.floor(mastery),
					tier = tier,
					lod = npc.tier or 2,
				})
			end
			table.sort(rows, function(x, y)
				return x.mastery > y.mastery
			end)
			return { text = string.format("%d NPCs", #rows), data = { kind = "npclist", rows = rows } }
		end,
	})
end
