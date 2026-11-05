--!strict
--[[
	QuestTypes: the data schema of the quest system (docs/Quests.md §2). Types only.

	SITUATION   something quest-worthy in the simulation, found by Quests/SituationDetector:
	            a collapsed tunnel, a failing reservoir, an apprentice dabbling in Void...
	TEMPLATE    Quests/Data/QuestTemplates: what kind of story a situation can become, with
	            slots, stages, approach options, outcomes, failure, escalation and NPC solving
	QUEST       a template instantiated for a player (personal) or a server (shared), slots filled

	Text fields use {slot} placeholders, filled by QuestFactory.text from the quest's slots.
]]

-- ─── Situations ─────────────────────────────────────────────────────────────

export type Situation = {
	id: string, -- deterministic: "<kind>:<subject>" (the same situation is never detected twice)
	kind: string, -- see SituationDetector.KINDS
	x: number,
	z: number,
	settlementId: string?,
	severity: number, -- 0..1: how bad (pacing intensity, reward scale)
	facts: { [string]: any }, -- kind-specific: npcId, poiId, eventId, branch, domain, otherSettlementId...
	source: string, -- "world" | "npc" | "event" | "faction" | "player" | "mythic"
	forUserId: number?, -- player-specific situations (bounty, mythic notoriety, lore gaps)
	detectedAt: number, -- os.time()
	expiresAt: number,
	lastSeen: number?, -- os.time() of the last scan that found it (QuestDirector)
}

-- ─── Template schema ────────────────────────────────────────────────────────

-- Which spells count. Every listed field must match (unset = any).
export type CastMatch = {
	domains: { string }?,
	properties: { string }?,
	verbs: { string }?,
	forms: { string }?,
	routes: { string }?, -- EffectLibrary route ids (what the spell actually did)
	branches: { string }?, -- the recipe's branch or any ancestor
	harmful: boolean?,
	minPower: number?,
	maxPower: number?,
}

--[[
	One thing to do. `kind`:
		talk         talk to NPC `target`
		reach        be within `radius` of `at` (+ `seconds` of dwell)
		cast         spells matching `match` (or, creatively, whose interaction tags meet `needs`)
		             within `radius` of `at`; done at `amount` total recipe power (or `count` casts)
		subdue       bring NPC `target` to `share` health or knock them out (a duel never kills:
		             the NPC yields at the share)
		escort       NPC `target` follows you to `at`
		collect      pick up `item` at `at` (a quest-only item: never enters the economy)
		deliver      bring `item` to NPC `target`
		demonstrate  cast spells of `branch` near NPC `target`, `count` times, `spacingHours` apart
		wait         `hours` of game time pass
		witness      be within `radius` of `at` while world event `event` is active there
		pay          hand NPC `target` `amount` currency
		state        world predicate `predicate` holds (Objectives.predicates)
	`unseen = true` adds a constraint: being noticed by an awake NPC within noticeRadius (without
	a veil, blinding darkness, or night) fails the objective's option (it takes `onNoticed`).
]]
export type ObjectiveSpec = {
	id: string,
	kind: string,
	text: string,
	target: string?, -- slot name (an npc)
	at: string?, -- slot name (a position)
	radius: number?,
	seconds: number?,
	count: number?,
	amount: number?,
	share: number?,
	hours: number?,
	spacingHours: number?,
	item: string?,
	event: string?,
	branch: string?, -- slot name (a branch)
	predicate: string?,
	args: { [string]: any }?,
	match: CastMatch?,
	needs: { string }?, -- interaction tags that solve it (creative solutions)
	unseen: boolean?,
	anyEffect: boolean?, -- cast: counts even a cast that hit nothing (a show, not a result)
	onNoticed: string?, -- outcome id when noticed
	hidden: boolean?, -- not listed until done (discovered solutions)
}

-- What the player must have to SEE an option (anyone can still stumble into it).
export type Requirement = {
	domains: { string }?, -- any of these awakened
	minTier: number?, -- in the template's main branch slot, or best branch
	maxTier: number?, -- best branch at most this tier (beginner quests: hidden from veterans)
	lore: { string }?, -- all of these
	currency: number?,
	reputation: { [string]: number }?, -- faction id -> minimum standing
}

export type Option = {
	id: string,
	label: string,
	approach: string, -- "talk" | "force" | "magic" | "stealth" | "creative" | "wait" | "trade"
	requires: Requirement?,
	objectives: { ObjectiveSpec }, -- all must complete (in order when `ordered`)
	ordered: boolean?,
	outcome: string?, -- finishes the quest with this outcome
	next: string?, -- or advances to this stage id
}

export type Stage = {
	id: string,
	text: string,
	options: { Option },
	hours: number?, -- game hours before this stage fails (template failOutcome)
	failOnDeath: string?, -- outcome when the player dies during this stage (duels)
}

export type Rewards = {
	xp: { branch: string, amount: number }?, -- branch: a slot or a literal id; study XP
	lore: { string }?, -- may contain {slots}
	currency: number?,
	awakening: { domain: string, chance: number }?, -- an awakening roll (seeded per quest)
	relationship: number?, -- with the giver
	reputation: { [string]: number }?, -- faction id or "settlement" (the situation's) -> delta
	infamy: number?,
	bounty: { faction: string, amount: number }?,
	study: { kind: string, npc: string }?, -- ProgressionService:awardStudy from that NPC slot ("mentor"), in your best branch
}

export type Outcome = {
	text: string,
	success: boolean,
	rewards: Rewards?,
	world: { [string]: any }?, -- world consequences (QuestDirector.applyWorld): relief, event, relation...
	memory: string?, -- NPC memory kind the giver keeps of the player
	followUp: string?, -- a template that may grow from this ending
}

export type SlotSpec = {
	kind: string, -- "npc" | "position" | "settlement" | "branch" | "domain" | "faction" | "text" | "number"
	from: string?, -- a situation fact ("npcId", "poiId", ...) or "here"
	pick: string?, -- a QuestFactory picker ("giver", "colleague:<occupation>", "otherSettlement", ...)
	optional: boolean?,
}

export type Complication = {
	id: string,
	text: string,
	afterStage: string?, -- may fire once this stage is reached
	chance: number, -- per director check while eligible (scaled by pacing)
	effect: { [string]: any }, -- spawnHunters, startEvent, addObjective...
}

export type Template = {
	id: string,
	type: string, -- delivery | rescue | investigation | escort | duel | teaching | research |
	--              crisis | diplomacy | heist | mythic | hunt | atonement | hunted
	title: string,
	summary: string,
	giver: string?, -- slot of the NPC who asks
	scope: string, -- "personal" (one player, saved) | "shared" (everyone on the server helps)
	situations: { string },
	weight: number,
	domains: { string }, -- focus affinity: players leaning these domains see it more
	intensity: number, -- 0 calm .. 1 set piece (Director pacing)
	difficulty: { number }, -- {min, max} best-branch mastery tier it suits
	requires: Requirement?, -- to be offered at all
	slots: { [string]: SlotSpec },
	stages: { Stage },
	outcomes: { [string]: Outcome },
	failOutcome: string, -- on expiry or a failed stage timer
	expireHours: number, -- game hours from acceptance (and offers expire in offerHours)
	escalation: { afterHours: number, event: string?, text: string, outcome: string? }?,
	npcSolve: { chancePerHour: number, outcome: string }?,
	complications: { Complication }?,
	cooldownHours: number, -- before this template may be offered to the same player again
	protect: { string }?, -- npc slots that must not be knocked out (quest-warded against others)
	protectOutcome: string?, -- outcome when one is
	spawns: { [string]: { faction: string?, occupation: string?, near: string, fight: boolean? } }?, -- npcs made for the quest
	autoStart: boolean?, -- starts without being accepted (being hunted is not optional)
	beginner: boolean?, -- a first-hour quest: at most one beginner quest offered or active at once
	holds: { [string]: string }?, -- npc slot -> position slot: the NPC stays there while the quest runs
}

-- ─── Live quests ────────────────────────────────────────────────────────────

-- Slot values are JSON-safe: positions are { x, y, z } arrays.
export type QuestState = {
	id: string,
	template: string,
	situation: string,
	scope: string,
	owner: number?, -- personal: the player
	seed: number,
	slots: { [string]: any },
	names: { [string]: string }, -- display names per slot
	stage: string,
	option: string?, -- the option being pursued (nil: any)
	progress: { [string]: number }, -- "<option>/<objective>" -> progress
	carried: { [string]: boolean },
	creative: { string }, -- objectives solved by a creative cast
	status: string, -- "offered" | "active" | "completed" | "failed" | "expired" | "solved_by_others"
	offeredAt: number, -- os.time()
	startedAt: number?,
	deadline: number?, -- world clock (game days) when it fails
	stageDeadline: number?,
	outcome: string?,
	firedComplications: { string },
	contributors: { [string]: number }?, -- shared: userId -> contribution
	tracked: boolean?,
}

return {}
