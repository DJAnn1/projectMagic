--!strict
--[[
	QuestFactory: turns a template + a situation into a concrete quest (docs/Quests.md §2).

		QuestFactory.build(template, situation, ctx) -> (QuestState?, reason?)
		QuestFactory.text(quest, s) -> string           fills {slot} placeholders
		QuestFactory.fill(quest, s) -> string           same, for ids ("treatise:{branch}")

	SLOTS
		from = "<fact>"     a situation fact (npcId, poiId, settlementId, otherSettlementId, branch,
		                    domain, ...), or "here" (the situation's position)
		pick = "<picker>"   colleague:<occ,occ>          an NPC of that occupation in the situation's town
		                    colleagueIn:<slot>:<occ,..>  the same, in another settlement slot's town
		                    anywhere:<occ>               the nearest of that occupation
		                    worriedOne                   someone close to the situation's NPC
		                    elder:<domain>               the old NPC with the most affinity for it
		                    settlementCenter[:<slot>]    a town's centre
		                    nearPoi:<type,type>          the nearest VISIBLE POI of those types
		                    npcHome:<slot> / npcWork:<slot>   where that NPC lives / works
		                    mythicSubBranch:<domain>     the first sub-branch of a mythic domain
		                    mentor                       the town's most skilled NPC mage (teaching
		                                                 trades first); the same person every time
		                    aroundTown:<min>:<max>       a seeded dry spot that far from the town centre
		                    tagged:<Tag>                 the nearest instance with that CollectionService
		                                                 tag within 250 studs (PracticeYard)
		                    domainProperty:<domain>      a seeded property of the domain's root branch
		                    oneOf:<a,b,c>                a seeded word from the list (text slots)
		Placeholders inside picks ("elder:{mythic}") use slots resolved earlier.
	DISPLAY: npc slots show as the NPC's name ({giver}); every other slot also gets {<slot>_name}
	(settlement, POI, branch, domain names). Derived: {<branch>_parent} for branch slots and
	{<domain>_moment} (the world event a mythic site opens on) for domain slots.

	Deterministic: every choice is seeded from (worldSeed, quest id, "quest"), so the same
	situation always makes the same quest. A required slot that can't be filled refuses the build.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local CollectionService = game:GetService("CollectionService")

local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)
local NPCMagicLife = require(script.Parent.Parent.NPC.NPCMagicLife)

local QuestTypes = require(script.Parent.QuestTypes)

type Template = QuestTypes.Template
type Situation = QuestTypes.Situation
type QuestState = QuestTypes.QuestState

export type BuildContext = {
	world: any, -- WorldStateService
	npcs: any, -- NPCService
	worldSeed: number,
	userId: number?, -- personal quests
	position: Vector3?, -- the player's position (nearest-pickers)
}

local MOMENTS: { [string]: string } = { time = "eclipse", gravity = "starfall", reality = "magic_storm" }
-- Trades that teach: a mentor is picked among these first (then any mage).
local TEACHING = { scholar = 3, tidepriest = 3, healer = 2, weathercaller = 2, herbalist = 1, smith = 1 }
local TAG_NAMES: { [string]: string } = { PracticeYard = "the practice yard" }

local POI_NAMES: { [string]: string } = {
	mine = "the mine", dungeon = "the old delve", ruined_library = "the ruined library", academy = "the academy",
	hermit_tower = "the hermit's tower", quiet_place = "the Quiet Place", sunken_shrine = "the Sunken Shrine",
	hollow_grove = "the Hollow Grove", shrine_life = "the shrine of Life", shrine_spirit = "the shrine of Spirit",
}

local QuestFactory = {}

local function settlementById(world: any, id: any): any?
	for _, s in world:placement().settlements do
		if s.id == id then
			return s
		end
	end
	return nil
end

local function vec(world: any, x: number, z: number): { number }
	local ok, y = pcall(world.surfaceHeight, world, x, z)
	return { x, if ok and typeof(y) == "number" then y + 3 else 3, z }
end

local function split(list: string): { string }
	local out = {}
	for item in string.gmatch(list, "[^,]+") do
		table.insert(out, item)
	end
	return out
end

-- NPCs of `occupations` in a settlement, sorted by id (seeded pick among them).
local function npcsIn(npcs: any, settlementId: string, occupations: { string }?): { any }
	local out = {}
	for _, town in npcs:towns() do
		if town.id == settlementId then
			for _, npc in town.npcs do
				if not npc.knockedOut and (not occupations or table.find(occupations, npc.occupation)) then
					table.insert(out, npc)
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- Fills {placeholders} from a lookup function; unknown keys are left as they are.
local function substitute(s: string, lookup: (string) -> string?): string
	return (string.gsub(s, "{([%w_]+)}", function(key)
		return lookup(key) or ("{" .. key .. "}")
	end))
end

type Resolved = { value: any, name: string?, npc: any? }

local function resolveSlot(spec: QuestTypes.SlotSpec, situation: Situation, slots: { [string]: Resolved }, ctx: BuildContext, rng: Random): Resolved?
	local world, npcs = ctx.world, ctx.npcs
	local facts = situation.facts

	if spec.from then
		if spec.from == "here" then
			return { value = vec(world, situation.x, situation.z), name = "the site" }
		end
		local v = facts[spec.from]
		if v == nil then
			return nil
		end
		if spec.kind == "npc" then
			local npc = npcs:get(v)
			return if npc then { value = npc.id, name = npc.name, npc = npc } else nil
		elseif spec.kind == "settlement" then
			local s = settlementById(world, v)
			return if s then { value = s.id, name = s.name } else nil
		elseif spec.kind == "position" then
			for _, poi in world:placement().pois do
				if poi.id == v then
					return { value = vec(world, poi.x, poi.z), name = POI_NAMES[poi.type] or poi.name or "the place" }
				end
			end
			return nil
		elseif spec.kind == "branch" then
			local def = Registry.branches[v]
			return if def then { value = v, name = def.name } else nil
		elseif spec.kind == "domain" then
			local def = Registry.domains[v]
			return if def then { value = v, name = def.name } else nil
		end
		return { value = v, name = tostring(v) }
	end

	local pick = spec.pick
	if not pick then
		return nil
	end
	-- Placeholders from slots already resolved.
	pick = substitute(pick, function(key)
		local r = slots[key]
		return if r and typeof(r.value) == "string" then r.value else nil
	end)
	local kind, rest = string.match(pick, "^([%a]+):?(.*)$")
	local here = Vector3.new(situation.x, 0, situation.z)

	if kind == "colleague" then
		local list = npcsIn(npcs, situation.settlementId or "", split(rest))
		local npc = list[rng:NextInteger(1, math.max(1, #list))]
		return if npc then { value = npc.id, name = npc.name, npc = npc } else nil
	elseif kind == "colleagueIn" then
		local slotName, occs = string.match(rest, "^([%w_]+):(.+)$")
		local town = slotName and slots[slotName]
		if not town then
			return nil
		end
		local list = npcsIn(npcs, town.value, split(occs :: string))
		local npc = list[rng:NextInteger(1, math.max(1, #list))]
		return if npc then { value = npc.id, name = npc.name, npc = npc } else nil
	elseif kind == "anywhere" then
		local occs = split(rest)
		local best, bestD = nil, math.huge
		local from = ctx.position or here
		for _, npc in npcs:all() do
			if not npc.knockedOut and table.find(occs, npc.occupation) then
				local d = (Vector3.new(npc.position.X, 0, npc.position.Z) - Vector3.new(from.X, 0, from.Z)).Magnitude
				if d < bestD then
					best, bestD = npc, d
				end
			end
		end
		return if best then { value = best.id, name = best.name, npc = best } else nil
	elseif kind == "worriedOne" then
		local subject = npcs:get(facts.npcId)
		if not subject then
			return nil
		end
		-- Household first (a parent, a sibling), then anyone working the same trade.
		for _, npc in npcsIn(npcs, subject.settlementId) do
			if npc ~= subject and npc.household == subject.household and npc.ageBand ~= "child" then
				return { value = npc.id, name = npc.name, npc = npc }
			end
		end
		for _, npc in npcsIn(npcs, subject.settlementId, { subject.occupation, "scholar", "healer" }) do
			if npc ~= subject then
				return { value = npc.id, name = npc.name, npc = npc }
			end
		end
		return nil
	elseif kind == "elder" then
		local domain = rest
		local best, bestScore = nil, -math.huge
		for _, npc in npcs:all() do
			if not npc.knockedOut and npc.age >= 55 and npc.magic and npc.magic.caster then
				local a = npc.magic.caster.affinities[domain] or 0
				local d = (npc.position - Vector3.new(situation.x, npc.position.Y, situation.z)).Magnitude
				local score = a * 2 + npc.age / 100 - d / 3000
				if score > bestScore then
					best, bestScore = npc, score
				end
			end
		end
		return if best then { value = best.id, name = best.name, npc = best } else nil
	elseif kind == "settlementCenter" then
		local s = if rest ~= "" then (slots[rest] and settlementById(world, slots[rest].value)) else settlementById(world, situation.settlementId)
		return if s then { value = vec(world, s.x, s.z), name = s.name } else nil
	elseif kind == "nearPoi" then
		local types = split(rest)
		local best, bestD = nil, math.huge
		for _, poi in world:placement().pois do
			-- Hidden POIs (mythic sites) are never quest targets: their places are secrets.
			if table.find(types, poi.type) and not poi.hidden then
				local d = (poi.x - situation.x) ^ 2 + (poi.z - situation.z) ^ 2
				if d < bestD then
					best, bestD = poi, d
				end
			end
		end
		return if best then { value = vec(world, best.x, best.z), name = POI_NAMES[best.type] or best.name or "the place" } else nil
	elseif kind == "npcHome" or kind == "npcWork" then
		local r = slots[rest]
		local npc = r and r.npc
		if not npc then
			return nil
		end
		local spot = if kind == "npcHome" then (npc.spots and npc.spots.home) else (npc.spots and npc.spots.work)
		local p: Vector3 = if typeof(spot) == "Vector3" then spot else npc.position
		return { value = { p.X, p.Y + 3, p.Z }, name = if kind == "npcHome" then npc.name .. "'s home" else npc.name .. "'s workshop" }
	elseif kind == "mentor" then
		local best, bestScore = nil, -math.huge
		for _, npc in npcsIn(npcs, situation.settlementId or "") do
			if npc.magic and npc.ageBand ~= "child" then
				local _, _, tier = NPCMagicLife.best(npc)
				local score = tier * 10 + (TEACHING[npc.occupation] or 0)
				if tier >= 1 and score > bestScore then -- npcsIn is sorted by id: ties keep the first
					best, bestScore = npc, score
				end
			end
		end
		return if best then { value = best.id, name = best.name, npc = best } else nil
	elseif kind == "aroundTown" then
		local lo, hi = string.match(rest, "^(%d+):(%d+)$")
		local s = settlementById(world, situation.settlementId)
		if not s or not lo or not hi then
			return nil
		end
		local angle = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(tonumber(lo) :: number, tonumber(hi) :: number)
		local ok, px, h, pz = pcall(world.findDryLand, world, s.x + math.cos(angle) * r, s.z + math.sin(angle) * r, 40)
		if not ok or typeof(px) ~= "number" then
			return nil
		end
		return { value = { px, h + 3, pz }, name = "outside " .. s.name }
	elseif kind == "tagged" then
		local best, bestD = nil :: Vector3?, 250 * 250
		for _, inst in CollectionService:GetTagged(rest) do
			local p: Vector3? = if inst:IsA("Model") then inst:GetPivot().Position elseif inst:IsA("BasePart") then inst.Position else nil
			if p then
				local d = (p.X - situation.x) ^ 2 + (p.Z - situation.z) ^ 2
				if d < bestD then
					best, bestD = p, d
				end
			end
		end
		return if best then { value = { best.X, best.Y + 3, best.Z }, name = TAG_NAMES[rest] or "the place" } else nil
	elseif kind == "domainProperty" then
		local root = Registry.branches[rest]
		if not root or #root.ownProperties == 0 then
			return nil
		end
		local list = table.clone(root.ownProperties)
		table.sort(list)
		local id = list[rng:NextInteger(1, #list)]
		local def = Registry.properties[id]
		return { value = id, name = if def then string.lower(def.name) else id }
	elseif kind == "oneOf" then
		local list = split(rest)
		if #list == 0 then
			return nil
		end
		local word = list[rng:NextInteger(1, #list)]
		return { value = word, name = word }
	elseif kind == "mythicSubBranch" then
		local children = {}
		for _, id in Registry.branchIds do
			if Registry.branches[id].parent == rest then
				table.insert(children, id)
			end
		end
		table.sort(children)
		local id = children[1]
		return if id then { value = id, name = Registry.branches[id].name } else nil
	end
	return nil
end

function QuestFactory.build(template: Template, situation: Situation, ctx: BuildContext): (QuestState?, string?)
	local id = template.id .. "|" .. situation.id .. "|" .. (if ctx.userId then tostring(ctx.userId) else "shared")
	local rng = Seed.random(ctx.worldSeed, id, "quest")
	local resolved: { [string]: Resolved } = {}

	-- Resolve in passes: picks may depend on other slots ("colleagueIn:other:..", "elder:{mythic}").
	local pending: { string } = {}
	for name in template.slots do
		table.insert(pending, name)
	end
	table.sort(pending)
	for _ = 1, 4 do
		local left = {}
		for _, name in pending do
			local r = resolveSlot(template.slots[name], situation, resolved, ctx, rng)
			if r then
				resolved[name] = r
			else
				table.insert(left, name)
			end
		end
		pending = left
		if #pending == 0 then
			break
		end
	end
	for _, name in pending do
		if not template.slots[name].optional then
			return nil, "slot " .. name .. " unresolved"
		end
	end

	local slots: { [string]: any } = {}
	local names: { [string]: string } = {}
	for name, r in resolved do
		slots[name] = r.value
		local kind = template.slots[name].kind
		if kind == "npc" then
			names[name] = r.name or "someone"
		else
			names[name .. "_name"] = r.name or tostring(r.value)
		end
		if kind == "branch" then
			local def = Registry.branches[r.value]
			slots[name .. "_parent"] = def and def.parent or r.value
		elseif kind == "domain" then
			slots[name .. "_moment"] = MOMENTS[r.value] or "magic_storm"
		end
	end
	for k, v in situation.facts do
		if names[k] == nil and slots[k] == nil and (typeof(v) == "string" or typeof(v) == "number") then
			slots[k] = v -- facts usable in text, e.g. {goal_text} via goalText -> slot
		end
	end

	local quest: QuestState = {
		id = id,
		template = template.id,
		situation = situation.id,
		scope = template.scope,
		owner = ctx.userId,
		seed = rng:NextInteger(1, 2 ^ 30),
		slots = slots,
		names = names,
		stage = template.stages[1].id,
		option = nil,
		progress = {},
		carried = {},
		creative = {},
		status = "offered",
		offeredAt = os.time(),
		startedAt = nil,
		deadline = nil,
		stageDeadline = nil,
		outcome = nil,
		firedComplications = {},
		contributors = if template.scope == "shared" then {} else nil,
		tracked = false,
	}
	return quest, nil
end

local function lookup(quest: QuestState, key: string): string?
	local n = quest.names[key]
	if n then
		return n
	end
	local v = quest.slots[key]
	if typeof(v) == "string" or typeof(v) == "number" then
		return tostring(v)
	end
	return nil
end

-- Player-facing text: {giver} -> "Hedda Ashhand", {town_name} -> "Emberfall".
function QuestFactory.text(quest: QuestState, s: string): string
	return substitute(s, function(key)
		return lookup(quest, key)
	end)
end

-- Ids and keys: {branch} -> "alloycraft" (slot values before display names).
function QuestFactory.fill(quest: QuestState, s: string): string
	return substitute(s, function(key)
		local v = quest.slots[key]
		if typeof(v) == "string" or typeof(v) == "number" then
			return tostring(v)
		end
		return quest.names[key]
	end)
end

-- A position slot as a Vector3 (nil when the slot is missing or not a position).
function QuestFactory.position(quest: QuestState, slot: string?): Vector3?
	local v = slot and quest.slots[slot]
	if typeof(v) == "table" and typeof(v[1]) == "number" then
		return Vector3.new(v[1], v[2], v[3])
	end
	return nil
end

QuestFactory.MOMENTS = MOMENTS

return QuestFactory
