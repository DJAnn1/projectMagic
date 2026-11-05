--!strict
--[[
	NPCBrain: utility AI. Every NPC has six needs; every few moments (by LOD tier) the brain
	drains them, then picks the action with the highest utility (UtilityScore) and keeps the full
	score breakdown for the inspector.

	compile(npc) precomputes everything that only changes when the NPC does (UtilityScore.Compiled):

	NEED WEIGHTS (how much each need matters to THIS person)
	    rest    1.0                               food    1.1
	    safety  1.6 x (0.6 + neuroticism)         social  0.8 x (0.4 + extraversion)
	    purpose 0.9 x (0.5 + 0.5 conscientiousness + 0.5 ambition)
	    wealth  0.7 x (0.5 + greed)
	NEED DRAIN multipliers
	    social  x (0.5 + extraversion)   purpose x (0.6 + 0.4 conscientiousness + 0.4 ambition)
	    wealth  x (0.6 + 0.8 greed)      then x every quirk's needDecay
	PERSONALITY affinity per action: 1 + Σ aff(action, trait) x (trait - 0.5) x 2, clamped
	QUIRK multiplier per action: Π quirk actionMult (a hobby quirk also makes "hobby" possible)
	AVAILABILITY: work needs a job (not child, retired or rogue); study/practice need magic;
	    teach needs a student; attend/play are for children; trade/help for adults; shelter only
	    ever scores under a threat
	Rogues lose "work" and lean toward practice and wandering.

	Interrupts (NPCService): a threat (attack, dangerous world event) drops safety and forces an
	immediate re-decision; the `danger` schedule block favours shelter, or help for professions
	that answer that event (water mages in a drought, healers in a plague).
]]

local NeedsActions = require(script.Parent.Data.NeedsActions)
local NpcData = require(script.Parent.Data.NpcData)
local Quirks = require(script.Parent.Data.Quirks)
local UtilityScore = require(script.Parent.UtilityScore)

local NPCBrain = {}

local DANGER_FITS: { [string]: number } = { shelter = 3, help = 1.4, worship = 1.2 }

local function personalityFor(npc: any, action: string): number
	local def = NeedsActions.actions[action]
	local m = 1
	for trait, aff in (def.traits or {}) :: { [string]: number } do
		m += aff * ((npc.traits[trait] or 0.5) - 0.5) * 2
	end
	return math.clamp(m, 0.25, 2.5)
end

local function available(npc: any): { string }
	local out: { string } = {}
	local child = npc.ageBand == "child"
	local magic = npc.magic
	local hasMagic = magic and next(magic.unlocked) ~= nil and npc.age >= 9
	local hasHobby = false
	for _, q in npc.quirks do
		if Quirks.defs[q].effects.hobby then
			hasHobby = true
		end
	end
	local rogue = magic and magic.rogue
	for _, id in NeedsActions.actionIds do
		local req = NeedsActions.actions[id].requires
		local ok = req == nil
			or (req == "work" and not child and npc.occupation ~= "retired" and not rogue)
			or (req == "magic" and hasMagic)
			or (req == "hobby" and hasHobby)
			or (req == "student" and magic ~= nil and #magic.students > 0)
			or (req == "child" and child)
			or (req == "adult" and not child)
			or req == "threat"
		if ok then
			table.insert(out, id)
		end
	end
	return out
end

function NPCBrain.compile(npc: any): UtilityScore.Compiled
	local t = npc.traits
	local weights = {
		rest = 1.0,
		food = 1.1,
		safety = 1.6 * (0.6 + (t.neuroticism or 0.5)),
		social = 0.8 * (0.4 + (t.extraversion or 0.5)),
		purpose = 0.9 * (0.5 + 0.5 * (t.conscientiousness or 0.5) + 0.5 * (t.ambition or 0.5)),
		wealth = 0.7 * (0.5 + (t.greed or 0.5)),
	}
	local occ = NpcData.occupations[npc.occupation]
	local gains: { [string]: { [string]: number } } = {}
	local fits: { [string]: { [string]: number } } = {}
	local personality: { [string]: number } = {}
	local quirk: { [string]: number } = {}
	local list = available(npc)
	for _, id in list do
		local def = NeedsActions.actions[id]
		local g = table.clone(def.satisfies)
		if id == "work" then
			g.wealth = occ.wealth
		end
		gains[id] = g
		local f = table.clone(def.blocks)
		f.danger = DANGER_FITS[id] or 0.3
		fits[id] = f
		personality[id] = personalityFor(npc, id)
		local q = 1
		for _, qid in npc.quirks do
			local mult = Quirks.defs[qid].effects.actionMult
			if mult and mult[id] then
				q *= mult[id]
			end
		end
		if npc.magic and npc.magic.rogue and (id == "practice" or id == "wander") then
			q *= 1.6
		end
		quirk[id] = q
	end
	return {
		seed = npc.seed % 2147483647,
		weights = weights,
		gains = gains,
		fits = fits,
		personality = personality,
		quirk = quirk,
		available = list,
	}
end

-- Drain multipliers per need for this person (personality x quirks).
function NPCBrain.drainOf(npc: any): { [string]: number }
	local t = npc.traits
	local d = {
		rest = 1,
		food = 1,
		safety = 1,
		social = 0.5 + (t.extraversion or 0.5),
		purpose = 0.6 + 0.4 * (t.conscientiousness or 0.5) + 0.4 * (t.ambition or 0.5),
		wealth = 0.6 + 0.8 * (t.greed or 0.5),
	}
	for _, q in npc.quirks do
		for need, m in (Quirks.defs[q].effects.needDecay or {}) :: { [string]: number } do
			d[need] = (d[need] or 1) * m
		end
	end
	return d
end

function NPCBrain.freshNeeds(seed: number): { [string]: number }
	local r = Random.new(seed)
	return {
		rest = 0.6 + r:NextNumber() * 0.3,
		food = 0.5 + r:NextNumber() * 0.4,
		safety = 1,
		social = 0.4 + r:NextNumber() * 0.4,
		purpose = 0.4 + r:NextNumber() * 0.4,
		wealth = 0.4 + r:NextNumber() * 0.4,
	}
end

-- Advances needs by `hours` of game time while doing `action`.
function NPCBrain.integrate(npc: any, hours: number, action: string)
	local needs = npc.needs
	local drain = npc.drain
	local gains = (npc.compiled.gains[action] or {}) :: { [string]: number }
	for _, need in NeedsActions.needs do
		local base = NeedsActions.decay[need]
		local level = needs[need] or 1
		if need == "safety" then
			level += (-base) * hours -- recovers on its own
		elseif not (need == "rest" and action == "sleep") then
			level -= base * (drain[need] or 1) * hours
		end
		level += (gains[need] or 0) * hours
		needs[need] = math.clamp(level, 0, 1)
	end
end

--[[
	Chooses the next action. Stores npc.action, npc.actionUntil (game days) and npc.lastScores
	(the top rows of the breakdown, for the inspector). Returns the chosen action.
]]
function NPCBrain.decide(npc: any, now: number, block: string, threat: boolean): string
	local hourIndex = math.floor(now * 24)
	local best, rows = UtilityScore.score(npc.compiled, npc.needs, block, npc.action, hourIndex, threat)
	npc.lastScores = { table.unpack(rows, 1, math.min(#rows, 8)) }
	npc.lastBlock = block
	npc.lastDecision = now
	if best ~= npc.action then
		npc.action = best
		npc.actionStarted = now
	end
	npc.actionUntil = now + NeedsActions.actions[best].minutes / 1440
	return best
end

-- Applies a choice made elsewhere (ParallelPool batch) the same way decide() does.
function NPCBrain.apply(npc: any, now: number, block: string, action: string)
	npc.lastBlock = block
	npc.lastDecision = now
	if action ~= npc.action then
		npc.action = action
		npc.actionStarted = now
	end
	npc.actionUntil = now + NeedsActions.actions[action].minutes / 1440
end

return NPCBrain
