--!strict
--[[
	DialogueEngine: what an NPC says, generated from who they are and what they remember.
	Template + grammar (Data/DialogueGrammar); no network, no model, always available.

	1. CONTEXT   context(npc, listener, env) gathers the variables: name, occupation, ambition,
	             goal, family bond, magic (best branch, tier, focus, technique, school, mentor,
	             rival), a hint of hidden mythic potential, mood, the relationship band toward
	             the listener, a grievance if the listener hurt them, and a RUMOUR built from
	             their strongest gossip-worthy memory (MemoryService).
	2. EXPAND    line(npc, topic, ctx, turn): pick a variant of the topic's rule whose `when`
	             conditions hold (weighted, seeded by npc+listener+topic+turn), expand <rules>
	             and {vars} recursively.
	3. STYLE     personality shapes the delivery: introverts stop at the first sentence; anxious
	             people hedge; funny people tack on a joke; quirks surface their own lines.

	Mood (mood()): anxious when unsafe, angry or grieving after strong recent negative memories
	(pride/low agreeableness tip toward anger), tired/hungry from low needs, cheerful when needs
	are met and recent memories are good, content otherwise.

	OPTIONAL MODEL (LLM) HOOK. DialogueEngine.renderer = function(ctx, baseline) -> string? can
	rewrite the baseline line (an external model via HttpService). NPCService only calls it when
	the `npc_llm_dialogue` flag is on, with a 2 s budget, caches per (npc, topic, context hash), and
	ALWAYS passes the result through TextService filtering for the listening player. Any failure
	or timeout falls back to the grammar line. Never send player-typed text or personal data to
	it: the context is game state only.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Grammar = require(script.Parent.Data.DialogueGrammar)
local NpcData = require(script.Parent.Data.NpcData)
local Quirks = require(script.Parent.Data.Quirks)
local MemoryService = require(script.Parent.MemoryService)
local RelationshipGraph = require(script.Parent.RelationshipGraph)

export type Context = {
	vars: { [string]: string },
	mood: string,
	rel: string,
	traits: { [string]: number },
	listener: string,
}

export type Env = {
	now: number, -- game days
	hour: number,
	nameOf: (id: string) -> string,
	eventHook: string?,
	reputation: number?, -- player's standing in this settlement (-1..1)
	teach: { branch: string, canTeach: boolean, noGap: boolean }?,
}

local DialogueEngine = {}

DialogueEngine.renderer = nil :: ((Context, string) -> string?)?

local OCCUPATION_VERB: { [string]: string } = {
	smith = "in tools", miner = "in ore", builder = "standing", farmer = "fed", herbalist = "in remedies", healer = "alive",
	lamplighter = "lit", tidepriest = "on the sea's good side", fisher = "in fish", weathercaller = "out of the worst storms",
	guard = "safe", scholar = "remembering", merchant = "supplied", innkeeper = "fed and watered", hunter = "in meat",
	child = "noisy", retired = "honest",
}

local MEMORY_PHRASES: { [string]: string } = {
	attacked_me = "{s} attacked me. In broad daylight.",
	attacked_someone = "{s} has been hurting people.",
	healed_me = "{s} healed me when nobody else would.",
	helped_me = "{s} helped me out of a real bind.",
	taught_me = "{s} taught me something worth knowing.",
	talked_rudely = "{s} has a nasty tongue on them.",
	saw_magic = "{s} was doing some impressive magic the other day.",
	saw_harmful_magic = "{s} was throwing dangerous magic around near town.",
	saw_mythic_magic = "{s} did something with magic that shouldn't be possible.",
	duel_won = "{s} won a duel. Not cleanly, the way I heard it.",
	duel_lost = "{s} lost a duel and hasn't shown their face since.",
	backlash = "{s} got burned by their own spell.",
	disaster = "{s} brought disaster down near here.",
	school_founded = "{s} has founded a school.",
	went_rogue = "{s} left town. Forbidden magic, they say.",
	awakened = "{s} awakened to something rare. Something old.",
	invention = "{s} invented a technique of their own.",
}

-- ─── Mood ───────────────────────────────────────────────────────────────────

function DialogueEngine.mood(npc: any, now: number): (string, number)
	local needs = npc.needs or {}
	local recent = 0
	local worst: any = nil
	for _, m in (npc.memories or {}) :: { any } do
		if now - m.t < 1 then
			local s = MemoryService.strength(npc, m, now)
			recent += m.valence * s
			if m.valence < 0 and (not worst or m.valence * s < worst.score) then
				worst = { kind = m.kind, score = m.valence * s }
			end
		end
	end
	local avg = 0
	for _, v in needs do
		avg += v
	end
	avg /= 6
	local value = math.clamp(avg - 0.5 + recent * 0.5, -1, 1)
	if (needs.safety or 1) < 0.4 then
		return "anxious", value
	end
	if worst and worst.score < -0.35 then
		local fiery = (npc.traits.pride or 0.5) > 0.6 or (npc.traits.agreeableness or 0.5) < 0.35
		return if fiery or worst.kind == "attacked_me" then "angry" else "grieving", value
	end
	if (needs.rest or 1) < 0.25 then
		return "tired", value
	end
	if (needs.food or 1) < 0.25 then
		return "hungry", value
	end
	if avg > 0.7 and recent > 0.1 then
		return "cheerful", value
	end
	return "content", value
end

-- ─── Relationship band ──────────────────────────────────────────────────────

function DialogueEngine.band(npc: any, listener: string, now: number, extra: number?): (string, number)
	local edge = RelationshipGraph.peek(npc.id, listener)
	local opinion = (if edge then edge.affinity * 0.6 else 0) + MemoryService.opinion(npc, listener, now) * 0.8 + (extra or 0)
	local band = if opinion <= -0.5 then "hostile"
		elseif opinion <= -0.15 then "wary"
		elseif not edge and math.abs(opinion) < 0.15 then "stranger"
		elseif opinion < 0.35 then "acquaintance"
		elseif opinion < 0.7 then "friend"
		else "close"
	return band, opinion
end

-- ─── Context ────────────────────────────────────────────────────────────────

local function article(word: string): string
	return (if string.match(string.lower(word), "^[aeiou]") then "an " else "a ") .. word
end

function DialogueEngine.context(npc: any, listener: string, env: Env): Context
	local vars: { [string]: string } = {}
	local occ = NpcData.occupations[npc.occupation]
	vars.name = npc.name
	vars.first = string.match(npc.name, "^(%S+)") or npc.name
	vars.player = env.nameOf(listener)
	vars.place = npc.settlementName
	vars.occupation = string.lower(occ.name)
	vars.occupation_a = article(string.lower(occ.name))
	vars.occupation_cap = occ.name
	vars.occupation_verb = OCCUPATION_VERB[npc.occupation] or "going"
	vars.ambition = npc.ambition.text
	vars.goal = npc.goal.text
	vars.age = tostring(npc.age)
	vars.district = occ.district
	if env.hour < 11 then
		vars.morning = "1"
	elseif env.hour >= 18 then
		vars.evening = "1"
	end
	if npc.ageBand == "elder" then
		vars.elder = "1"
	end
	for _, q in npc.quirks do
		if Quirks.defs[q].effects.noMagicWeekday == 2 then
			vars.tuesday_quirk = "1"
		end
	end

	-- Family: the strongest bond.
	for _, rel in RelationshipGraph.top(npc.id, 6) do
		local bond = rel.edge.bond
		if bond == "spouse" or bond == "sibling" or bond == "parent" or bond == "child" then
			vars.bond_word = if bond == "child" then "parent" elseif bond == "parent" then "child" else bond
			vars.bond_name = env.nameOf(rel.id)
			break
		end
	end

	-- Magic.
	local magic = npc.magic
	if magic then
		local best, mastery = nil, -1
		for id, m in magic.mastery do
			if m > mastery then
				best, mastery = id, m
			end
		end
		if best then
			local tier = MagicCore.tierForMastery(mastery)
			vars.best_branch = Registry.branches[best].name
			vars.tier_name = MagicCore.tierDef(math.max(tier, 1)).name
			vars[if tier <= 2 then "low_tier" elseif tier <= 5 then "mid_tier" else "high_tier"] = "1"
		end
		if npc.profile.manifest[1] then
			vars.domain = Registry.domains[npc.profile.manifest[1]].name
		end
		if magic.focus then
			vars.focus = Registry.branches[magic.focus].name
		end
		if magic.techniques[1] then
			vars.technique = magic.techniques[1].name
		end
		vars.school = magic.school
		if magic.mentor then
			vars.mentor = env.nameOf(magic.mentor)
		end
		if magic.rival then
			vars.rival = env.nameOf(magic.rival)
			vars.rival_word = if (npc.traits.humor or 0.5) > 0.6 then "dear friend" else "rival"
		end
		-- Hidden mythic potential leaks as a feeling the curious notice (they don't know what it is).
		if magic.hiddenMythic and (npc.traits.curiosity or 0.5) > 0.5 then
			vars.hidden_stirring = "1"
		end
	end

	-- Teaching offer (computed by NPCService against the player's progression).
	if env.teach then
		vars.teach_branch = Registry.branches[env.teach.branch] and Registry.branches[env.teach.branch].name or env.teach.branch
		if env.teach.canTeach then
			vars.can_teach = "1"
		end
		if env.teach.noGap then
			vars.no_gap = "1"
		end
	end

	-- Grievance and rumours.
	for _, m in MemoryService.top(npc, 3, env.now, listener) do
		if m.kind == "attacked_me" or m.kind == "talked_rudely" then
			vars.grievance = "1"
		end
	end
	for _, m in MemoryService.top(npc, 8, env.now) do
		local phrase = MEMORY_PHRASES[m.kind]
		if phrase and m.subject ~= listener and not vars.rumor then
			local subject = if m.subject == npc.id then "I" else env.nameOf(m.subject)
			if subject ~= "I" then
				vars.rumor = (string.gsub(phrase, "{s}", subject))
				vars.rumor_short = subject
			end
		end
	end
	vars.event_hook = env.eventHook

	local mood = DialogueEngine.mood(npc, env.now)
	local rel = DialogueEngine.band(npc, listener, env.now, env.reputation)
	return { vars = vars, mood = mood, rel = rel, traits = npc.traits, listener = listener }
end

-- ─── Expansion ──────────────────────────────────────────────────────────────

local function allowed(v: any, ctx: Context): boolean
	local w = v.when
	if not w then
		return true
	end
	if w.mood and not table.find(w.mood, ctx.mood) then
		return false
	end
	if w.rel and not table.find(w.rel, ctx.rel) then
		return false
	end
	for t, x in (w.above or {}) :: { [string]: number } do
		if (ctx.traits[t] or 0.5) <= x then
			return false
		end
	end
	for t, x in (w.below or {}) :: { [string]: number } do
		if (ctx.traits[t] or 0.5) >= x then
			return false
		end
	end
	for _, var in (w.has or {}) :: { string } do
		if not ctx.vars[var] then
			return false
		end
	end
	return true
end

local function expand(symbol: string, ctx: Context, rng: Random, depth: number): string
	local variants = Grammar[symbol]
	if not variants or depth > 5 then
		return ""
	end
	local pool, total = {}, 0
	for _, v in variants do
		if allowed(v, ctx) then
			table.insert(pool, v)
			total += v.w or 1
		end
	end
	if #pool == 0 then
		return ""
	end
	local roll = rng:NextNumber() * total
	local chosen = pool[#pool]
	for _, v in pool do
		roll -= v.w or 1
		if roll <= 0 then
			chosen = v
			break
		end
	end
	local text = string.gsub(chosen.text, "<([%w_]+)>", function(sub: string): string
		return expand(sub, ctx, rng, depth + 1)
	end)
	text = string.gsub(text, "{([%w_]+)}", function(var: string): string
		return ctx.vars[var] or ""
	end)
	return text
end

local function tidy(text: string): string
	local t = string.gsub(text, "%s+", " ")
	t = string.gsub(t, " ([%.,!%?])", "%1")
	t = string.match(t, "^%s*(.-)%s*$") or t
	return t
end

-- One line on a topic. `turn` varies repeated talks; the same inputs give the same line.
function DialogueEngine.line(npc: any, topic: string, ctx: Context, turn: number): string
	local rng = Random.new(Seed.derive(npc.seed, npc.id .. "|" .. ctx.listener, topic, turn))
	local text = tidy(expand(topic, ctx, rng, 0))
	local t = npc.traits

	-- Style: the taciturn stop at one sentence.
	if (t.extraversion or 0.5) < 0.3 then
		text = string.match(text, "^(.-[%.!%?])%s") or text
	end
	-- The anxious hedge.
	if (t.neuroticism or 0.5) > 0.7 and rng:NextNumber() < 0.3 and #text > 0 then
		text = expand("hedge", ctx, rng, 0) .. string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2)
	end
	-- The funny can't help themselves.
	if (t.humor or 0.5) > 0.7 and rng:NextNumber() < 0.35 then
		text ..= " " .. expand("joke", ctx, rng, 0)
	end
	-- Quirks surface.
	if rng:NextNumber() < 0.18 then
		local lines = {}
		for _, q in npc.quirks do
			for _, l in (Quirks.defs[q].effects.lines or {}) :: { string } do
				table.insert(lines, l)
			end
		end
		if #lines > 0 then
			local l = lines[rng:NextInteger(1, #lines)]
			text ..= " " .. string.gsub(l, "{domain}", ctx.vars.domain or "magic")
		end
	end
	text = tidy(text)
	return if text == "" then "..." else text
end

return DialogueEngine
