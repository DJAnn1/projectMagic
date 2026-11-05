--!strict
--[[
	MemoryService: episodic memory. What happened, with whom, when, and how much it mattered.

	A memory: { t (game days), kind, subject (npc id or "u:<userId>"), valence -1..1,
	intensity 0..1, secondhand, from (who told them), note }.

	BOUNDED   at most CAP memories per NPC; adding past the cap drops the weakest
	MERGING   the same kind about the same subject within a game hour stacks (intensity adds)
	DECAY     strength = intensity x 0.5 ^ (age / halfLife)
	            halfLife: 4 days positive, 6 days negative (bad things linger)
	            x (0.7 + neuroticism) for negative memories
	            x quirk multipliers (grudge keepers x3 on negative, the forgiving x0.4, ...)
	OPINION   of a subject = Σ valence x strength over their memories of them, clamped -1..1
	GOSSIP    socialising NPCs pass on their strongest memory about a THIRD party the listener
	          hasn't heard: secondhand intensity = original x 0.6 x listener's trust in the
	          speaker x both gossip multipliers. Secondhand memories don't spread further than
	          one more hop (intensity keeps shrinking), so rumours fade with distance.

	Kinds and their default valence live in KINDS; the text is DialogueEngine's job.
]]

local Quirks = require(script.Parent.Data.Quirks)

export type Memory = {
	t: number,
	kind: string,
	subject: string,
	valence: number,
	intensity: number,
	secondhand: boolean,
	from: string?,
	note: string?,
	shared: { [string]: boolean }?, -- listeners it was already told to
}

local CAP = 24
local MERGE_WINDOW = 1 / 24 -- one game hour
local POSITIVE_HALF_LIFE = 4
local NEGATIVE_HALF_LIFE = 6

local MemoryService = {}

-- kind -> default valence (positive good, negative bad) and whether it's worth gossiping about.
MemoryService.KINDS = {
	attacked_me = { valence = -0.9, gossip = true },
	attacked_someone = { valence = -0.6, gossip = true },
	healed_me = { valence = 0.7, gossip = true },
	helped_me = { valence = 0.5, gossip = true },
	taught_me = { valence = 0.6, gossip = true },
	talked_kindly = { valence = 0.2, gossip = false },
	talked_rudely = { valence = -0.3, gossip = true },
	chatted = { valence = 0.1, gossip = false },
	saw_magic = { valence = 0.2, gossip = true },
	saw_harmful_magic = { valence = -0.4, gossip = true },
	saw_mythic_magic = { valence = 0.5, gossip = true },
	duel_won = { valence = 0.3, gossip = true },
	duel_lost = { valence = -0.5, gossip = true },
	backlash = { valence = -0.6, gossip = true },
	disaster = { valence = -0.7, gossip = true },
	became_student = { valence = 0.5, gossip = true },
	school_founded = { valence = 0.6, gossip = true },
	went_rogue = { valence = -0.8, gossip = true },
	awakened = { valence = 0.8, gossip = true },
	invention = { valence = 0.6, gossip = true },
	-- Quest endings (QuestDirector via NPCService.questBond; Data/QuestTemplates `memory`).
	saved_me = { valence = 0.9, gossip = true },
	protected_me = { valence = 0.7, gossip = true },
	impressed_me = { valence = 0.5, gossip = true },
	beat_me_fairly = { valence = 0.2, gossip = true },
	beat_me = { valence = 0.1, gossip = true },
	cheated_me = { valence = -0.6, gossip = true },
	failed_me = { valence = -0.5, gossip = true },
	owes_me = { valence = 0.4, gossip = false },
	used_me = { valence = -0.6, gossip = true },
	betrayed_me = { valence = -0.9, gossip = true },
	spared_me = { valence = 0.6, gossip = true },
	harmed_town = { valence = -0.7, gossip = true },
} :: { [string]: { valence: number, gossip: boolean } }

local function halfLife(npc: any, valence: number): number
	local base = if valence < 0 then NEGATIVE_HALF_LIFE * (0.7 + (npc.traits.neuroticism or 0.5)) else POSITIVE_HALF_LIFE
	for _, q in npc.quirks do
		local e = Quirks.defs[q].effects
		base *= (if valence < 0 then e.negativeHalfLife else e.positiveHalfLife) or 1
	end
	return base
end

local function gossipMult(npc: any): number
	local m = 0.5 + (npc.traits.extraversion or 0.5)
	for _, q in npc.quirks do
		m *= Quirks.defs[q].effects.gossipMult or 1
	end
	return m
end

function MemoryService.strength(npc: any, m: Memory, now: number): number
	local age = math.max(0, now - m.t)
	return m.intensity * 0.5 ^ (age / halfLife(npc, m.valence))
end

function MemoryService.add(npc: any, kind: string, subject: string, now: number, opts: { intensity: number?, valence: number?, note: string?, secondhand: boolean?, from: string? }?): Memory
	local o = opts or {}
	npc.memories = npc.memories or {}
	local list: { Memory } = npc.memories
	local valence = o.valence or (MemoryService.KINDS[kind] and MemoryService.KINDS[kind].valence) or 0
	-- Neurotic minds feel bad things harder.
	local intensity = math.clamp((o.intensity or 0.5) * (if valence < 0 then 0.7 + (npc.traits.neuroticism or 0.5) * 0.6 else 1), 0.01, 1)
	for _, m in list do
		if m.kind == kind and m.subject == subject and now - m.t <= MERGE_WINDOW and m.secondhand == (o.secondhand == true) then
			m.intensity = math.min(1, m.intensity + intensity * 0.5)
			m.t = now
			return m
		end
	end
	local memory: Memory = {
		t = now,
		kind = kind,
		subject = subject,
		valence = valence,
		intensity = intensity,
		secondhand = o.secondhand == true,
		from = o.from,
		note = o.note,
	}
	table.insert(list, memory)
	if #list > CAP then
		MemoryService.prune(npc, now)
	end
	return memory
end

-- Drops forgotten memories, then the weakest beyond the cap.
function MemoryService.prune(npc: any, now: number)
	local list: { Memory } = npc.memories or {}
	table.sort(list, function(a, b)
		return MemoryService.strength(npc, a, now) > MemoryService.strength(npc, b, now)
	end)
	for i = #list, 1, -1 do
		if i > CAP or MemoryService.strength(npc, list[i], now) < 0.02 then
			table.remove(list, i)
		end
	end
end

-- -1..1: how this NPC feels about a subject, from what they remember of them.
function MemoryService.opinion(npc: any, subject: string, now: number): number
	local sum = 0
	for _, m in (npc.memories or {}) :: { Memory } do
		if m.subject == subject then
			sum += m.valence * MemoryService.strength(npc, m, now)
		end
	end
	return math.clamp(sum, -1, 1)
end

-- Strongest memories first (optionally only about one subject).
function MemoryService.top(npc: any, count: number, now: number, subject: string?): { Memory }
	local list: { Memory } = {}
	for _, m in (npc.memories or {}) :: { Memory } do
		if not subject or m.subject == subject then
			table.insert(list, m)
		end
	end
	table.sort(list, function(a, b)
		return MemoryService.strength(npc, a, now) > MemoryService.strength(npc, b, now)
	end)
	while #list > count do
		table.remove(list)
	end
	return list
end

--[[
	The speaker tells the listener about someone else. Returns the new secondhand memory, or nil.
	`trust` is the listener's trust in the speaker (0..1).
]]
function MemoryService.gossip(speaker: any, listener: any, now: number, trust: number): Memory?
	local best: Memory? = nil
	local bestStrength = 0.08
	for _, m in (speaker.memories or {}) :: { Memory } do
		local kind = MemoryService.KINDS[m.kind]
		if kind and kind.gossip and m.subject ~= listener.id and not (m.shared and m.shared[listener.id]) then
			local s = MemoryService.strength(speaker, m, now)
			if s > bestStrength then
				best, bestStrength = m, s
			end
		end
	end
	if not best then
		return nil
	end
	best.shared = best.shared or {}
	best.shared[listener.id] = true
	local intensity = bestStrength * 0.6 * math.clamp(trust, 0, 1) * math.sqrt(gossipMult(speaker) * gossipMult(listener))
	if intensity < 0.03 then
		return nil
	end
	return MemoryService.add(listener, best.kind, best.subject, now, {
		intensity = intensity,
		valence = best.valence,
		secondhand = true,
		from = speaker.id,
		note = best.note,
	})
end

return MemoryService
