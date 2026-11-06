--!strict
--[[
	CombatAnimations: every combat animation and every action state, as data. docs/Combat.md §11.

	ANIMATIONS   asset id, priority, looped, fades, base speed, approxLength (seconds; used for
	             marker fallbacks while a track's real Length is still 0), and the named
	             keyframe markers we expect. Each marker has `at`, the fraction of the clip where
	             it should be. When the clip has no such marker (or it never fires), the
	             controller fires it at `at` instead, so gameplay timing never depends on an
	             animator having added the marker.
	STATES       what a body is doing. The SERVER decides the state (character attributes, see
	             ActionRules); animations only follow it. Per state:
	               animation        played on entry (optional)
	               loop             looped after the entry animation ends (or at once if no entry)
	               duration         default seconds before it ends (0 = until changed)
	               next             the state it falls into when its duration ends (default idle)
	               scaleToDuration  speed the entry animation so its "Release" marker (or its end)
	                                lands exactly when the state's duration ends (cast times)
	               holdAt           freeze the entry clip at this marker (a held pose); a
	                                following state with the same clip resumes from there
	               allows          actions possible while in it (move, cast, slash, block, dash, equip)
	               interruptedBy    states that may replace it (nil = any). "Forced" sets
	                                (knockdowns) ignore this.
	DOMAINS      per-domain speed and weight multipliers (earth heavier and slower, air quicker).

	The animations must be owned by the account or group that owns the place, or they play in
	Studio and silently fail in live servers. They are R6 (rigType below).
]]

export type Priority = "Core" | "Idle" | "Movement" | "Action" | "Action2" | "Action3" | "Action4"

export type MarkerDef = {
	name: string,
	at: number, -- fraction of the clip (0..1) for the fallback
}

export type AnimationDef = {
	id: number,
	priority: Priority,
	looped: boolean,
	fadeIn: number,
	fadeOut: number,
	speed: number,
	approxLength: number,
	markers: { MarkerDef },
}

export type StateDef = {
	animation: string?,
	loop: string?,
	duration: number,
	next: string?,
	scaleToDuration: boolean?,
	holdAt: string?, -- freeze the entry clip at this marker (charging's wind-up pose)
	allows: { [string]: boolean },
	interruptedBy: { [string]: boolean }?,
}

export type DomainStyle = { speed: number, weight: number }

local function set(list: { string }): { [string]: boolean }
	local out = {}
	for _, v in list do
		out[v] = true
	end
	return out
end

local CombatAnimations = {}

CombatAnimations.actions = { "move", "cast", "slash", "block", "dash", "equip" }

-- The rig every clip here was authored for. Players (Game Settings › Avatar › Avatar Type) and
-- NPC rigs (NPCLOD) must use it: R6 clips can't move an R15 body, and the reverse.
CombatAnimations.rigType = "R6" :: "R6" | "R15"

--[[
	Locomotion overrides for Roblox's default Animate script (the LocalScript in every character):
	Animate child name → clip name in `animations`. The client swaps the Animation ids under those
	children on spawn. Empty since 2026-11-05: walking uses Roblox's default walk, and the Run
	clip plays only while the running toggle is on (Controllers/MovementClient). Put a walk clip
	here (walk = "Walk") once there is one.
]]
CombatAnimations.locomotion = {} :: { [string]: string }

CombatAnimations.animations = {
	BlockStart = {
		id = 115334865008883, priority = "Action2", looped = false, fadeIn = 0.06, fadeOut = 0.1,
		speed = 1, approxLength = 0.3, markers = { { name = "ParryOpen", at = 0.15 } },
	},
	Block = {
		-- Re-uploaded by the place owner (2026-11-05). The older 128098131606169 and 111952812431898
		-- weren't usable by this place.
		id = 97111944327100, priority = "Action", looped = true, fadeIn = 0.1, fadeOut = 0.15,
		speed = 1, approxLength = 1, markers = {},
	},
	BlockHit = {
		id = 112849868505263, priority = "Action3", looped = false, fadeIn = 0.03, fadeOut = 0.1,
		speed = 1, approxLength = 0.35, markers = {},
	},
	Equip = {
		id = 89289769245430, priority = "Action", looped = false, fadeIn = 0.1, fadeOut = 0.15,
		speed = 1, approxLength = 0.45, markers = { { name = "Attuned", at = 0.6 } },
	},
	Hold = {
		id = 108827586483203, priority = "Action", looped = true, fadeIn = 0.15, fadeOut = 0.2,
		speed = 1, approxLength = 1.5, markers = {},
	},
	Slash1 = {
		id = 138752334774532, priority = "Action2", looped = false, fadeIn = 0.05, fadeOut = 0.12,
		speed = 1, approxLength = 0.5, markers = { { name = "HitFrame", at = 0.4 }, { name = "ComboOpen", at = 0.7 } },
	},
	Slash2 = {
		id = 113754806600593, priority = "Action2", looped = false, fadeIn = 0.05, fadeOut = 0.12,
		speed = 1, approxLength = 0.55, markers = { { name = "HitFrame", at = 0.45 }, { name = "ComboOpen", at = 0.75 } },
	},
	-- The owner's real Run clip (2026-11-05); it used to share Slash1's id.
	Run = {
		id = 136370984503271, priority = "Movement", looped = true, fadeIn = 0.2, fadeOut = 0.2,
		speed = 1, approxLength = 0.8, markers = {},
	},
	Dash = {
		id = 103931697209739, priority = "Action3", looped = false, fadeIn = 0.04, fadeOut = 0.12,
		speed = 1, approxLength = 0.4, markers = { { name = "DashEnd", at = 0.85 } },
	},
	CastSpell = {
		id = 135616983966337, priority = "Action2", looped = false, fadeIn = 0.08, fadeOut = 0.15,
		speed = 1, approxLength = 0.8, markers = { { name = "Release", at = 0.65 } },
	},
} :: { [string]: AnimationDef }

local EVERYTHING = set(CombatAnimations.actions)

CombatAnimations.states = {
	idle = { duration = 0, allows = EVERYTHING },
	equipping = {
		animation = "Equip", duration = 0.45, next = "holding",
		allows = set({ "move" }),
		interruptedBy = set({ "idle", "staggered", "dashing", "equipping" }),
	},
	holding = { loop = "Hold", duration = 0, allows = EVERYTHING },
	charging = {
		-- The CastSpell wind-up, frozen at its "Release" pose while the charge builds (holdAt).
		-- The release (casting) resumes the same clip from there instead of restarting it.
		animation = "CastSpell", holdAt = "Release", duration = 6, next = "holding",
		allows = set({ "move", "cast", "block", "dash" }),
	},
	channeling = {
		-- A channelled spell pouring out while the button is held (Casting.md §8).
		loop = "Hold", duration = 0, next = "holding",
		allows = set({ "move" }),
		interruptedBy = set({ "idle", "staggered", "dashing", "holding", "casting", "channeling" }),
	},
	casting = {
		animation = "CastSpell", duration = 0.8, scaleToDuration = true,
		allows = set({ "move" }),
		interruptedBy = set({ "idle", "staggered", "dashing", "casting" }),
	},
	slashing = {
		-- Spellblade (Data/MeleeTuning): Slash1, or Slash2 as the variant. A swing can be cancelled
		-- into a block, a dash, the next slash or a cast (the finisher); its pending hits then stop.
		animation = "Slash1", duration = 0.5,
		allows = set({ "move", "slash", "block", "dash", "cast" }),
		interruptedBy = set({ "idle", "staggered", "dashing", "blocking", "slashing", "casting" }),
	},
	blocking = { animation = "BlockStart", loop = "Block", duration = 0, allows = set({ "move", "block" }) },
	dashing = {
		animation = "Dash", duration = 0.4,
		allows = {},
		interruptedBy = set({ "idle", "staggered" }),
	},
	staggered = {
		-- No clip of its own: combat tracks stop and the knockdown fall (WorldEffectController /
		-- PlatformStand) shows instead.
		duration = 2, allows = {}, interruptedBy = set({ "idle" }),
	},
} :: { [string]: StateDef }

CombatAnimations.domains = {
	energy = { speed = 1.1, weight = 1 },
	earth = { speed = 0.88, weight = 1 },
	water = { speed = 0.95, weight = 1 },
	air = { speed = 1.15, weight = 0.9 },
	life = { speed = 1, weight = 1 },
	mind = { speed = 1.05, weight = 0.9 },
	spirit = { speed = 0.95, weight = 0.95 },
	void = { speed = 0.9, weight = 1 },
	space = { speed = 1.1, weight = 1 },
	time = { speed = 0.8, weight = 1 },
	gravity = { speed = 0.78, weight = 1 },
	reality = { speed = 0.9, weight = 1 },
} :: { [string]: DomainStyle }

-- Speed scaling never goes past these (a 0.1 s cast would otherwise play at 8x).
CombatAnimations.minSpeed = 0.35
CombatAnimations.maxSpeed = 2.5

-- Pairs of animation names that share an asset id (reported once at boot, client and server).
CombatAnimations.duplicates = (function(): { { a: string, b: string, id: number } }
	local seen: { [number]: string } = {}
	local names: { string } = {}
	for name in CombatAnimations.animations do
		table.insert(names, name)
	end
	table.sort(names) -- stable report order
	local out = {}
	for _, name in names do
		local id = CombatAnimations.animations[name].id
		local other = seen[id]
		if other then
			table.insert(out, { a = other, b = name, id = id })
		else
			seen[id] = name
		end
	end
	return out
end)()

return CombatAnimations
