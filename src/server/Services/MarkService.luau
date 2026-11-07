--!strict
--[[
	MarkService: the magic you use most slowly marks your body (docs/MagicMarks.md). Rules:
	Shared/Magic/MarkRules. Content: Shared/Magic/Data/Marks. Drawing: Client/Fx/MarkFx.

	COUNTING  Every working spell you cast (SpellResolved, effective, not borrowed) adds a point to
	          its domain, at most one cast per castGap seconds and dayCap points per domain per real
	          day. A hybrid splits its point. What you stop using fades a little every day.
	SHOWING   MarkRules.evaluate: enough points AND a real share of your magic, at most maxMarks.
	          The result goes on your character as the attribute "MagicMarks" ("energy:2,water:1")
	          plus the tag "MagicMarked"; every client draws it. Nothing else is sent.
	TELLING   A first-person Journal line when a mark appears, grows or fades. NPCs notice it
	          themselves (AmbientLifeService, Data/MarkLines). No toast, card or meter.
	PERK      Cast/Resistances reads the attribute: resistPerStage to your own domain per stage.
	QUIRK     GreetingRules: strange marks make nervous people a little warier; footprints and
	          particles on every client.
	NPCS      NPC mages carry marks from their own best mastery tier (MarkRules.npcStage), through
	          NPCLOD's marks provider, so the old smith's black arms are part of the world too.

	Saved in PlayerData.marks (reconcile fills old saves), under progressKey like the rest of the
	player save, so progress resets and erasure already cover it. No remotes.

	Flag: magic_marks_enabled. Admin: marks, markset, markclear, npcmarks.
	Log: marks_changed (a player's marks moved), marks_ready.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Registry = require(Shared.Magic.Registry)
local MarkRules = require(Shared.Magic.MarkRules)
local MarkData = require(Shared.Magic.Data.Marks)

local Server = script.Parent.Parent
local NPCLOD = require(Server.NPC.NPCLOD)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)

local T = MarkData.tuning
local TAG = "MagicMarked"
local ATTRIBUTE = "MagicMarks"

local MarkService = {
	name = "MarkService",
	dependencies = { "AdminService", "JournalService", "NPCService", "PlayerDataService" },
}

local log: any = nil
local journal: any = nil
local npcs: any = nil
local playerData: any = nil

local lastCounted: { [Player]: number } = {}

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("magic_marks_enabled") == true
end

local function today(): number
	return MarkRules.dayOf(os.time())
end

-- The saved record, made whole (old saves, bad edits).
local function recordOf(player: Player): MarkRules.Record?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local r = state.data.marks
	if typeof(r) ~= "table" then
		r = MarkRules.newRecord()
		state.data.marks = r
	end
	r.points = if typeof(r.points) == "table" then r.points else {}
	r.dayPoints = if typeof(r.dayPoints) == "table" then r.dayPoints else {}
	r.shown = if typeof(r.shown) == "table" then r.shown else {}
	r.day = tonumber(r.day) or 0
	r.decayDay = tonumber(r.decayDay) or 0
	return r :: MarkRules.Record
end

-- Puts the marks on a character model (or takes them off).
local function applyTo(model: Model?, raw: string?)
	if not model then
		return
	end
	model:SetAttribute(ATTRIBUTE, raw)
	if raw then
		CollectionService:AddTag(model, TAG)
	else
		CollectionService:RemoveTag(model, TAG)
	end
end

local function show(player: Player)
	local record = recordOf(player)
	local raw = if enabled() and record then MarkRules.encode(record.shown) else nil
	applyTo(player.Character, raw)
end

-- Re-evaluates a player's marks; writes the Journal for anything that changed.
local function refresh(player: Player, quiet: boolean?)
	local record = recordOf(player)
	if not record then
		return
	end
	local new = MarkRules.evaluate(record)
	local changes = MarkRules.changes(record.shown, new)
	if #changes == 0 then
		return
	end
	record.shown = new
	for _, change in changes do
		local line = MarkRules.journalLine(change.domain, change.from, change.to)
		if line and not quiet then
			journal:log(player, "mark", line, { domain = change.domain, stage = change.to })
		end
		log:info("marks_changed", {
			userId = player.UserId,
			domain = change.domain,
			from = change.from,
			to = change.to,
			points = math.floor(record.points[change.domain] or 0),
		})
	end
	show(player)
end

-- An NPC's marks: their strongest branch's domain, at the stage their tier has reached.
local function npcMarks(npc: any): string?
	if not enabled() or typeof(npc) ~= "table" or typeof(npc.magic) ~= "table" then
		return nil
	end
	local branchId, _, tier = NPCMagicLife.best(npc)
	local def = branchId and Registry.branches[branchId]
	local domain = def and def.domains[1]
	local stage = MarkRules.npcStage(tier)
	if not domain or stage <= 0 then
		return nil
	end
	return MarkRules.encode({ [domain] = stage })
end

-- Every NPC body in the world, marked again (the flag changed, or an admin asked).
local function remarkNpcs()
	for _, town in npcs:towns() do
		for _, npc in town.npcs do
			if npc.rig then
				NPCLOD.applyMarks(npc.rig.model, npc)
			end
		end
	end
end

-- ─── Events ─────────────────────────────────────────────────────────────────

local function onSpell(payload: any)
	if not enabled() or not payload.effective or payload.borrowed or payload.backfired then
		return
	end
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	if not player then
		return
	end
	local now = os.clock()
	if now - (lastCounted[player] or -math.huge) < T.castGap then
		return
	end
	local record = recordOf(player)
	if not record then
		return
	end
	lastCounted[player] = now
	local day = today()
	MarkRules.decay(record, day)
	if MarkRules.addCast(record, payload.domains or {}, day) > 0 then
		refresh(player)
	end
end

local function onLoaded(player: Player)
	local record = recordOf(player)
	if not record then
		return
	end
	-- Time away fades what you'd built; the Journal says so if a mark slipped while you were gone.
	MarkRules.decay(record, today())
	if enabled() then
		refresh(player)
	end
	show(player)
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function status(player: Player): string
	local record = recordOf(player)
	if not record then
		return "no data for them yet"
	end
	local total = 0
	for _, points in record.points do
		total += points
	end
	local domains: { string } = {}
	for domain in record.points do
		table.insert(domains, domain)
	end
	table.sort(domains, function(a, b)
		return (record.points[a] or 0) > (record.points[b] or 0)
	end)
	local lines = {
		string.format(
			"%s: shown %s, flag %s, stages at %s points, share %.0f%% to gain / %.0f%% to keep",
			player.Name, MarkRules.encode(record.shown) or "none", tostring(enabled()),
			table.concat(T.stages, "/"), T.share * 100, T.keepShare * 100
		),
	}
	for _, domain in domains do
		local points = record.points[domain] or 0
		table.insert(lines, string.format(
			"  %s: %.0f points (%.0f%%), %.0f today of %d, stage %d",
			domain, points, if total > 0 then points / total * 100 else 0,
			if record.day == today() then record.dayPoints[domain] or 0 else 0, T.dayCap,
			record.shown[domain] or 0
		))
	end
	if #domains == 0 then
		table.insert(lines, "  no points yet: cast spells that work")
	end
	return table.concat(lines, "\n")
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "marks",
		category = "Spells",
		description = "Magic Marks: a player's points per domain, shares, today's cap and the marks on their body",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			return status(a.player)
		end,
	})
	admin:Register({
		name = "markset",
		category = "Spells",
		description = "Give a player exactly enough points in a domain for a mark stage (0 removes that domain's points). Journal lines fire as in play",
		args = {
			{ name = "domain", type = "domain" },
			{ name = "stage", type = "number" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local record = recordOf(a.player)
			if not record then
				return "no data for them yet"
			end
			local domain = if typeof(a.domain) == "table" then a.domain.id else tostring(a.domain)
			if not MarkData.domains[domain] then
				return "no such domain: " .. domain
			end
			local stage = math.clamp(math.floor(tonumber(a.stage) or 0), 0, #T.stages)
			record.points[domain] = if stage == 0 then nil else T.stages[stage]
			-- Enough share to show: this domain outweighs the rest put together.
			if stage > 0 then
				local others = 0
				for other, points in record.points do
					if other ~= domain then
						others += points
					end
				end
				record.points[domain] = math.max(T.stages[stage], others * 2)
			end
			refresh(a.player)
			return status(a.player)
		end,
	})
	admin:Register({
		name = "markclear",
		category = "Spells",
		description = "Erase a player's Magic Marks: points, today's cap and the marks on their body",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local state = playerData:get(a.player)
			if not state then
				return "no data for them yet"
			end
			state.data.marks = MarkRules.newRecord()
			show(a.player)
			return "cleared"
		end,
	})
	admin:Register({
		name = "npcmarks",
		category = "NPCs",
		description = "How many NPCs carry Magic Marks, by stage and domain (all towns), and re-mark every NPC body",
		args = {},
		handler = function(_ctx: any, _a: any)
			remarkNpcs()
			local byStage = { 0, 0, 0 }
			local byDomain: { [string]: number } = {}
			local total = 0
			for _, town in npcs:towns() do
				for _, npc in town.npcs do
					total += 1
					local raw = npcMarks(npc)
					local mark = MarkRules.decode(raw)[1]
					if mark then
						byStage[mark.stage] += 1
						byDomain[mark.domain] = (byDomain[mark.domain] or 0) + 1
					end
				end
			end
			local parts: { string } = {}
			for domain, count in byDomain do
				table.insert(parts, domain .. " " .. count)
			end
			table.sort(parts)
			return string.format(
				"%d NPCs: stage 1 %d, stage 2 %d, stage 3 %d (tiers %s)\n  %s",
				total, byStage[1], byStage[2], byStage[3], table.concat(T.npcTiers, "/"),
				if #parts > 0 then table.concat(parts, ", ") else "none"
			)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function MarkService.init(_self: any, ctx: any)
	log = ctx.log
	journal = ctx.get("JournalService")
	npcs = ctx.get("NPCService")
	playerData = ctx.get("PlayerDataService")
	NPCLOD.setMarksProvider(npcMarks)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	ctx.bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		onLoaded(payload.player)
	end)
	ctx.bus:subscribe(Topics.FlagChanged, function(payload: any)
		if payload.name == "magic_marks_enabled" then
			for _, player in Players:GetPlayers() do
				if enabled() then
					refresh(player, true)
				end
				show(player)
			end
			remarkNpcs()
		end
	end)
	registerAdmin(ctx.get("AdminService"))
end

function MarkService.start(_self: any, _ctx: any)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			show(player)
		end)
		if player.Character then
			show(player)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastCounted[player] = nil
	end)
	-- A server that runs past midnight still fades what isn't being used.
	task.spawn(function()
		local day = today()
		while true do
			task.wait(600)
			if today() ~= day then
				day = today()
				for _, player in Players:GetPlayers() do
					local record = recordOf(player)
					if record then
						MarkRules.decay(record, day)
						if enabled() then
							refresh(player)
						end
					end
				end
			end
		end
	end)
	log:info("marks_ready", { domains = #Registry.domainIds, stages = table.concat(T.stages, "/") })
end

return MarkService
