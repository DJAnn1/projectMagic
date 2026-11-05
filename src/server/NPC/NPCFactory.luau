--!strict
--[[
	NPCFactory: generates every NPC from (worldSeed, npcId). Deterministic: the same seed and id
	give the same person on every server, forever, so NPCs are regenerated, never saved.

	Each aspect draws from its own stream, Seed.random(worldSeed, npcId, "npc.<aspect>"), so
	retuning quirks never reshuffles anyone's name or personality.

		NPCFactory.populate(worldSeed, settlement, authored?) -> { Npc }   a settlement's residents
		NPCFactory.generate(worldSeed, settlement, slot, override?) -> Npc

	Ids: "<settlementId>#<slot>" (slot 1..population). Households are assigned per settlement
	(sizes 1-4: couples, parents with children, lone elders), which RelationshipGraph turns into
	family bonds. Age doesn't advance: a child stays a child (aging would need deaths and births).
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local Types = require(Shared.Magic.Types)
local Registry = require(Shared.Magic.Registry)

local Server = ServerScriptService.Server
local ProfileGenerator = require(Server.Magic.ProfileGenerator)
local InnateProfile = require(Server.Magic.InnateProfile)
local Settlements = require(Server.World.Settlements)
local NpcData = require(script.Parent.Data.NpcData)
local Quirks = require(script.Parent.Data.Quirks)

export type Ambition = { id: string, text: string, kind: string, branch: string? }

export type Npc = {
	id: string,
	seed: number,
	settlementId: string,
	settlementName: string,
	culture: string,
	size: string,
	slot: number,
	name: string,
	age: number,
	ageBand: string,
	appearance: { skin: Color3, shirt: Color3, trousers: Color3, hair: string, build: string, feature: string },
	occupation: string,
	formerOccupation: string?,
	socialClass: string, -- "low" | "middle" | "high"
	household: string,
	traits: { [string]: number },
	quirks: { string },
	values: { string },
	fears: { string },
	secret: { id: string, text: string }?,
	goal: { id: string, text: string },
	ambition: Ambition,
	profile: Types.InnateProfile,
	authored: string?,
}

export type Override = {
	key: string,
	name: string?,
	age: number?,
	occupation: string?,
	formerOccupation: string?,
	traits: { [string]: number }?,
	quirks: { string }?,
	ambition: string?,
	ambitionBranch: string?,
	domainBias: { [string]: number }?,
	minGift: string?,
	forceMythic: string?,
}

local NPCFactory = {}

local function rngFor(worldSeed: number, id: string, aspect: string): Random
	return Seed.random(worldSeed, id, "npc." .. aspect)
end

local function weightedPick(rng: Random, ids: { string }, weightOf: (string) -> number): string?
	local total = 0
	for _, id in ids do
		total += math.max(0, weightOf(id))
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for _, id in ids do
		roll -= math.max(0, weightOf(id))
		if roll <= 0 then
			return id
		end
	end
	return ids[#ids]
end

-- A soft bell curve on 0..1.
local function bell(rng: Random): number
	return (rng:NextNumber() + rng:NextNumber() + rng:NextNumber()) / 3
end

local function ageBandOf(age: number): { min: number, max: number, label: string, shift: { [string]: number } }
	for _, band in NpcData.ageBands do
		if age >= band.min and age <= band.max then
			return band
		end
	end
	return NpcData.ageBands[3]
end

local function drawAge(rng: Random): number
	local r = rng:NextNumber()
	if r < 0.15 then
		return rng:NextInteger(6, 13)
	elseif r < 0.35 then
		return rng:NextInteger(14, 24)
	elseif r < 0.8 then
		return rng:NextInteger(25, 54)
	end
	return rng:NextInteger(55, 88)
end

local function drawOccupation(rng: Random, age: number, culture: string, size: string): string
	if age <= 13 then
		return "child"
	end
	if age >= 60 and rng:NextNumber() < 0.5 then
		return "retired"
	end
	local pick = weightedPick(rng, NpcData.occupationIds, function(id)
		local occ = NpcData.occupations[id]
		if id == "child" or id == "retired" or age < occ.minAge or age > occ.maxAge then
			return 0
		end
		local w = (occ.cultures and occ.cultures[culture]) or 1
		if id == "scholar" and size == "village" then
			w *= 0.3
		elseif id == "farmer" and size == "city" then
			w *= 0.4
		end
		return w
	end)
	return pick or "builder"
end

local function drawName(rng: Random, culture: string): string
	local names = NpcData.names[culture] or NpcData.names.wayfarer
	local first = names.first[rng:NextInteger(1, #names.first)] .. names.firstEnd[rng:NextInteger(1, #names.firstEnd)]
	local family = names.family[rng:NextInteger(1, #names.family)]
	return first .. " " .. family
end

local function drawTraits(rng: Random, culture: string, age: number, overrides: { [string]: number }?): { [string]: number }
	local traits: { [string]: number } = {}
	for _, list in { NpcData.bigFive, NpcData.custom } do
		for _, t in list do
			traits[t] = bell(rng)
		end
	end
	for t, d in (NpcData.cultureShift[culture] or {}) :: { [string]: number } do
		traits[t] = (traits[t] or 0.5) + d
	end
	for t, d in ageBandOf(age).shift do
		traits[t] = (traits[t] or 0.5) + d
	end
	for t, v in (overrides or {}) :: { [string]: number } do
		traits[t] = v
	end
	for t, v in traits do
		traits[t] = math.clamp(v, 0.02, 0.98)
	end
	return traits
end

-- 2-4 quirks, weighted by trait affinity, never two that exclude each other.
local function drawQuirks(rng: Random, traits: { [string]: number }, forced: { string }?): { string }
	local chosen: { string } = table.clone(forced or {})
	local count = rng:NextInteger(2, 4)
	local function blocked(id: string): boolean
		if table.find(chosen, id) then
			return true
		end
		for _, other in chosen do
			local a, b = Quirks.defs[id], Quirks.defs[other]
			if (a.excludes and table.find(a.excludes, other)) or (b.excludes and table.find(b.excludes, id)) then
				return true
			end
		end
		return false
	end
	local guard = 0
	while #chosen < count and guard < 40 do
		guard += 1
		local id = weightedPick(rng, Quirks.ids, function(qid)
			if blocked(qid) then
				return 0
			end
			local w = 1
			for t, a in (Quirks.defs[qid].affinity or {}) :: { [string]: number } do
				w += a * ((traits[t] or 0.5) - 0.5) * 2
			end
			return math.max(0.05, w)
		end)
		if id then
			table.insert(chosen, id)
		end
	end
	return chosen
end

-- The branch an ambition points at: occupation's preferred branches first, then the NPC's best.
local function ambitionBranch(rng: Random, profile: Types.InnateProfile, occupation: string, forced: string?): string?
	if forced and Registry.branches[forced] then
		return forced
	end
	local candidates: { string } = {}
	for _, preferred in NpcData.occupations[occupation].branches do
		local def = Registry.branches[preferred]
		if def and table.find(profile.manifest, def.domains[1]) then
			table.insert(candidates, preferred)
		end
	end
	if #candidates == 0 then
		for _, d in profile.manifest do
			for _, child in Registry.branches[d].children do
				table.insert(candidates, child)
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

function NPCFactory.generate(worldSeed: number, settlement: Settlements.Settlement, slot: number, override: Override?): Npc
	local id = settlement.id .. "#" .. slot
	local o: Override = override or ({} :: any)
	local culture = settlement.culture

	local ageRng = rngFor(worldSeed, id, "age")
	local age = o.age or drawAge(ageRng)
	local occupation = o.occupation or drawOccupation(rngFor(worldSeed, id, "occupation"), age, culture, settlement.size)
	local occ = NpcData.occupations[occupation]
	local traits = drawTraits(rngFor(worldSeed, id, "traits"), culture, age, o.traits)
	local quirkRng = rngFor(worldSeed, id, "quirks")
	local quirks = drawQuirks(quirkRng, traits, o.quirks)
	for _, q in quirks do
		for t, d in (Quirks.defs[q].effects.trait or {}) :: { [string]: number } do
			traits[t] = math.clamp((traits[t] or 0.5) + d, 0.02, 0.98)
		end
	end

	-- Magic: the same generator as players, biased by culture esteem and profession.
	local bias: { [string]: number } = {}
	for d, esteem in Settlements.cultures[culture].values do
		bias[d] = esteem * esteem
	end
	for d, w in occ.domains do
		bias[d] = (bias[d] or 1) * w
	end
	if o.formerOccupation then
		for d, w in NpcData.occupations[o.formerOccupation].domains do
			bias[d] = (bias[d] or 1) * w
		end
	end
	for d, w in (o.domainBias or {}) :: { [string]: number } do
		bias[d] = w
	end
	local profile = ProfileGenerator.generate(worldSeed, "npc:" .. id, {
		kind = "NPC",
		domainBias = bias,
		minGiftTier = o.minGift,
		forceMythic = o.forceMythic,
	})

	local appearanceRng = rngFor(worldSeed, id, "appearance")
	local primary = InnateProfile.signatureColors(profile).primary -- the signature stores hex strings
	local inner = rngFor(worldSeed, id, "inner")
	local values = {}
	while #values < 2 do
		local v = NpcData.values[inner:NextInteger(1, #NpcData.values)]
		if not table.find(values, v) then
			table.insert(values, v)
		end
	end
	local fears: { string } = { NpcData.fears[inner:NextInteger(1, #NpcData.fears)].id }
	for _, q in quirks do
		local fear = Quirks.defs[q].effects.fear
		if fear and not table.find(fears, fear) then
			table.insert(fears, fear)
		end
	end
	local secret = if inner:NextNumber() < 0.4 then NpcData.secrets[inner:NextInteger(1, #NpcData.secrets)] else nil
	local goal = NpcData.goals[inner:NextInteger(1, #NpcData.goals)]

	local ambitionDef = NpcData.ambitions[inner:NextInteger(1, #NpcData.ambitions)]
	if o.ambition then
		for _, a in NpcData.ambitions do
			if a.id == o.ambition then
				ambitionDef = a
			end
		end
	end
	local branch = ambitionBranch(inner, profile, o.formerOccupation or occupation, o.ambitionBranch)
	local ambitionText = string.gsub(ambitionDef.text, "{branch}", if branch then Registry.branches[branch].name else "their art")

	local class = if occupation == "merchant" or (occ.wealth >= 0.07 and inner:NextNumber() < 0.5) then "high"
		elseif occ.wealth <= 0.04 and inner:NextNumber() < 0.6 then "low"
		else "middle"

	return {
		id = id,
		seed = Seed.derive(worldSeed, id, "npc"),
		settlementId = settlement.id,
		settlementName = settlement.name,
		culture = culture,
		size = settlement.size,
		slot = slot,
		name = o.name or drawName(rngFor(worldSeed, id, "name"), culture),
		age = age,
		ageBand = ageBandOf(age).label,
		appearance = {
			skin = NpcData.skinTones[appearanceRng:NextInteger(1, #NpcData.skinTones)],
			shirt = primary:Lerp(Color3.fromRGB(110, 100, 90), 0.55), -- clothes echo their magic, muted
			trousers = Color3.fromRGB(appearanceRng:NextInteger(40, 90), appearanceRng:NextInteger(35, 80), appearanceRng:NextInteger(30, 70)),
			hair = NpcData.hair[appearanceRng:NextInteger(1, #NpcData.hair)],
			build = NpcData.builds[appearanceRng:NextInteger(1, #NpcData.builds)],
			feature = NpcData.features[appearanceRng:NextInteger(1, #NpcData.features)],
		},
		occupation = occupation,
		formerOccupation = o.formerOccupation,
		socialClass = class,
		household = "",
		traits = traits,
		quirks = quirks,
		values = values,
		fears = fears,
		secret = secret,
		goal = goal,
		ambition = { id = ambitionDef.id, text = ambitionText, kind = ambitionDef.kind, branch = branch },
		profile = profile,
		authored = if o.key then o.key else nil,
	}
end

--[[
	All residents of a settlement. `overrides` maps slot -> Override (authored NPCs); the slot
	keeps its id, so an authored NPC is still "<settlementId>#<slot>".
]]
function NPCFactory.populate(worldSeed: number, settlement: Settlements.Settlement, overrides: { [number]: Override }?): { Npc }
	local npcs: { Npc } = {}
	for slot = 1, settlement.population do
		table.insert(npcs, NPCFactory.generate(worldSeed, settlement, slot, overrides and overrides[slot]))
	end

	-- Households: adults found homes (1-2 adults), then children and elders join them.
	local rng = Seed.random(worldSeed, settlement.id, "npc.households")
	local homes: { { adults: number, members: { Npc } } } = {}
	local function newHome(npc: Npc)
		local home = { adults = if npc.ageBand == "child" then 0 else 1, members = { npc } }
		table.insert(homes, home)
		npc.household = settlement.id .. "/h" .. #homes
	end
	for _, npc in npcs do
		if npc.ageBand == "adult" or npc.ageBand == "young" then
			local joined = false
			for i, home in homes do
				if home.adults == 1 and #home.members == 1 and rng:NextNumber() < 0.45 then
					table.insert(home.members, npc)
					home.adults = 2
					npc.household = settlement.id .. "/h" .. i
					joined = true
					break
				end
			end
			if not joined then
				newHome(npc)
			end
		end
	end
	for _, npc in npcs do
		if npc.household == "" then
			-- Children and elders: join a home with room, else start one (an orphan or a lone elder).
			local placed = false
			for i, home in homes do
				if #home.members < 4 and home.adults > 0 and rng:NextNumber() < 0.6 then
					table.insert(home.members, npc)
					npc.household = settlement.id .. "/h" .. i
					placed = true
					break
				end
			end
			if not placed then
				newHome(npc)
			end
		end
	end
	return npcs
end

return NPCFactory
