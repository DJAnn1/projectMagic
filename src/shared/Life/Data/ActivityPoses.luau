--!strict
--[[
	ActivityPoses: how a body looks while doing something, with no animation asset at all
	(docs/Activities.md §3), plus the labelled animation slots that replace a pose when filled.

	SLOTS  AnimationIds by name. The server's NPC/Data/Activities.Clips is this same table, so one id
	       here reaches every NPC. An activity names a slot in `clip`; while the slot is empty the
	       procedural pose plays instead. R6 only (CombatAnimations.rigType).

	A POSE FAMILY (procedural; the client's Fx/ActivityPoser plays it on the R6 joints)
		joints   R6 joint -> { x, y, z } degrees: the resting shape of the pose, in the PARENT part's
		         axes (the torso for limbs and neck, the root for RootJoint). +x lifts an arm or leg
		         forward, +z swings it out to the right, -x on the neck bows the head, -x on the root
		         leans the body forward. The rotation is applied as yaw (y) after pitch (x) and roll (z).
		motion   rhythmic parts: { joint, axis, amp (degrees), shape, phase (0..1)? }
		         shape "sine" swings ±amp; "strike" rises slowly through amp and drops fast (a tool
		         landing at the end of each period); "circle" is a sine a quarter period behind
		period   seconds per beat. Strikes land once per period (sparks are timed to it).
		body     nil (standing) | "sit" | "lie" | "kneel" | "crouch": the body's place. "sit" and "lie"
		         use the station's BodyCFrame when it has one (a chair, a bed); otherwise in place.
		lower    studs the body drops for "kneel" and "crouch"
		variants { { speed, amp, mirror? } }: a person keeps one (seeded), so two smiths don't move in
		         step. mirror swaps left and right.
		simple   the reduced loop at medium distance: only these joints move
]]

export type Motion = { joint: string, axis: string, amp: number, shape: string, phase: number? }
export type Variant = { speed: number, amp: number, mirror: boolean? }
export type Pose = {
	joints: { [string]: { number } },
	motion: { Motion },
	period: number,
	body: string?,
	lower: number?,
	variants: { Variant },
	simple: { string },
}

local RS, LS, RH, LH, NECK, ROOT = "Right Shoulder", "Left Shoulder", "Right Hip", "Left Hip", "Neck", "RootJoint"

local TWO: { Variant } = { { speed = 1, amp = 1 }, { speed = 0.86, amp = 1.12 } }
local THREE: { Variant } = { { speed = 1, amp = 1 }, { speed = 0.9, amp = 1.1, mirror = true }, { speed = 1.12, amp = 0.9 } }

local poses: { [string]: Pose } = {
	hammer = {
		joints = { [RS] = { 40, 0, 0 }, [LS] = { 55, 0, -15 }, [NECK] = { -18, 0, 0 }, [ROOT] = { -8, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 105, shape = "strike" },
			{ joint = ROOT, axis = "x", amp = -6, shape = "strike" },
		},
		period = 1.1, variants = THREE, simple = { RS },
	},
	stir = {
		joints = { [RS] = { 50, 0, -10 }, [LS] = { 30, 0, 0 }, [NECK] = { -20, 0, 0 }, [ROOT] = { -12, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 12, shape = "sine" },
			{ joint = RS, axis = "y", amp = 18, shape = "circle" },
			{ joint = ROOT, axis = "y", amp = 4, shape = "sine" },
		},
		period = 2.2, variants = TWO, simple = { RS },
	},
	dig = {
		joints = { [RS] = { 45, 0, 0 }, [LS] = { 45, 0, 0 }, [NECK] = { -15, 0, 0 }, [ROOT] = { -10, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 70, shape = "strike" },
			{ joint = LS, axis = "x", amp = 70, shape = "strike" },
			{ joint = ROOT, axis = "x", amp = -10, shape = "strike" },
		},
		period = 1.8, variants = TWO, simple = { RS, LS },
	},
	sweep = {
		joints = { [RS] = { 35, 0, 0 }, [LS] = { 45, 0, 0 }, [NECK] = { -20, 0, 0 }, [ROOT] = { -10, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 38, shape = "sine" },
			{ joint = LS, axis = "y", amp = 38, shape = "sine" },
			{ joint = ROOT, axis = "y", amp = 12, shape = "sine" },
		},
		period = 1.6, variants = THREE, simple = { RS, LS },
	},
	chop = {
		joints = { [RS] = { 60, 0, 10 }, [LS] = { 60, 0, -10 }, [NECK] = { -10, 0, 0 }, [ROOT] = { -4, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 115, shape = "strike" },
			{ joint = LS, axis = "x", amp = 115, shape = "strike" },
			{ joint = ROOT, axis = "x", amp = -16, shape = "strike" },
		},
		period = 1.7, variants = TWO, simple = { RS, LS },
	},
	read = {
		joints = { [RS] = { 55, 0, -12 }, [LS] = { 45, 0, 12 }, [NECK] = { -32, 0, 0 }, [ROOT] = { -16, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 6, shape = "sine" },
			{ joint = NECK, axis = "y", amp = 7, shape = "sine", phase = 0.3 },
		},
		period = 3.4, variants = TWO, simple = {},
	},
	sleep = {
		joints = { [RS] = { 0, 0, 8 }, [LS] = { 0, 0, -8 }, [NECK] = { 0, 0, 0 } },
		motion = { { joint = NECK, axis = "x", amp = 2, shape = "sine" } },
		period = 4.2, body = "lie", variants = TWO, simple = {},
	},
	eat = {
		joints = { [RH] = { 90, 0, 0 }, [LH] = { 90, 0, 0 }, [RS] = { 40, 0, -10 }, [LS] = { 40, 0, 10 }, [NECK] = { -8, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 55, shape = "sine" },
			{ joint = LS, axis = "x", amp = 30, shape = "sine", phase = 0.5 },
			{ joint = NECK, axis = "x", amp = 6, shape = "sine" },
		},
		period = 4, body = "sit", variants = THREE, simple = { RS },
	},
	patrol = {
		joints = { [RS] = { 18, 0, 0 } },
		motion = { { joint = NECK, axis = "y", amp = 32, shape = "sine" } },
		period = 7, variants = TWO, simple = {},
	},
	fish = {
		joints = { [RS] = { 48, 0, 0 }, [LS] = { 40, 0, -20 }, [NECK] = { -6, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 6, shape = "sine" },
			{ joint = LS, axis = "y", amp = 10, shape = "circle" },
		},
		period = 3, variants = TWO, simple = {},
	},
	pray = {
		joints = { [RH] = { -88, 0, 0 }, [LH] = { -88, 0, 0 }, [RS] = { 72, 0, -28 }, [LS] = { 72, 0, 28 }, [NECK] = { -28, 0, 0 } },
		motion = { { joint = NECK, axis = "x", amp = 3, shape = "sine" } },
		period = 5, body = "kneel", lower = 1.05, variants = TWO, simple = {},
	},
	cast_hold = {
		joints = { [RS] = { 68, 0, -24 }, [LS] = { 68, 0, 24 }, [NECK] = { -14, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 6, shape = "sine" },
			{ joint = LS, axis = "x", amp = 6, shape = "sine", phase = 0.5 },
		},
		period = 2.6, variants = TWO, simple = {},
	},
	cast_shape = {
		joints = { [RH] = { 70, 0, 0 }, [LH] = { 70, 0, 0 }, [RS] = { 55, 0, -12 }, [LS] = { 55, 0, 12 }, [NECK] = { -30, 0, 0 }, [ROOT] = { -12, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 14, shape = "sine" },
			{ joint = LS, axis = "y", amp = 14, shape = "sine", phase = 0.5 },
		},
		period = 2.4, body = "crouch", lower = 0.9, variants = TWO, simple = {},
	},
	cast_pour = {
		joints = { [RS] = { 62, 0, -10 }, [LS] = { 62, 0, 10 }, [NECK] = { -22, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 28, shape = "sine" },
			{ joint = LS, axis = "y", amp = 28, shape = "sine" },
			{ joint = NECK, axis = "y", amp = 18, shape = "sine" },
		},
		period = 3.2, variants = TWO, simple = { RS, LS },
	},
}

local ActivityPoses = {}

ActivityPoses.poses = poses

-- Animation slots. Empty = the procedural pose plays. The owner's own clips (2026-11-05) first.
ActivityPoses.slots = table.freeze({
	hammer = "rbxassetid://83054299922044",
	dig = "rbxassetid://102462779862982",
	hold = "rbxassetid://115233860888201",
	point = "rbxassetid://75385791730022",
	sit = "rbxassetid://123240149331173",
	-- Conversation (NPCAnimator). Empty: the head turns and bobs instead.
	talk = "", -- 3-4 s loop: standing, gesturing with one hand while speaking
	listen = "", -- 3-4 s loop: standing, shifting weight, a small nod
	-- Activity slots waiting for a clip (ActivityPoses.poses plays meanwhile).
	stir = "", -- 2 s loop: bent at a hearth, right arm stirring in circles
	sweep = "", -- 1.6 s loop: broom swept side to side, body twisting with it
	chop = "", -- 1.7 s: two-handed overhead axe swing landing at the end
	read = "", -- 4 s loop: hunched over a desk, small head and hand movements
	sleep = "", -- 4 s loop: lying on the back, slow breathing
	eat = "", -- 4 s loop: seated, lifting food and drink in turns
	patrol = "", -- 7 s loop over the walk: spear upright, looking left and right
	fish = "", -- 3 s loop: rod held out, small twitches
	pray = "", -- 5 s loop: kneeling, hands together, head bowed
	cast_hold = "", -- 2.6 s loop: palms cupped around something in front
	cast_shape = "", -- 2.4 s loop: crouched, hands shaping something on the ground
	cast_pour = "", -- 3.2 s loop: both arms guiding something side to side
	-- Still Roblox's defaults.
	wave = "rbxassetid://128777973",
	cheer = "rbxassetid://129423030",
	laugh = "rbxassetid://129423131",
	dance = "rbxassetid://182435998",
}) :: { [string]: string }

function ActivityPoses.hasClip(slot: string?): boolean
	if not slot then
		return false
	end
	local id = ActivityPoses.slots[slot]
	return id ~= nil and id ~= ""
end

-- 0..1 (strike) or -1..1 (sine, circle) for a motion at time t (seconds) with a period.
function ActivityPoses.wave(shape: string, t: number, period: number, phase: number?): number
	local u = (t / period + (phase or 0)) % 1
	if shape == "strike" then
		-- Rise for 70% of the beat, then drop: 0 at the moment of impact (u wraps to 0).
		return if u < 0.7 then u / 0.7 else 1 - (u - 0.7) / 0.3
	elseif shape == "circle" then
		return math.cos(u * 2 * math.pi)
	end
	return math.sin(u * 2 * math.pi)
end

-- How many strikes have landed between two times (sparks on the anvil, chips from the block).
function ActivityPoses.strikesBetween(t0: number, t1: number, period: number): number
	if t1 <= t0 or period <= 0 then
		return 0
	end
	return math.floor(t1 / period) - math.floor(t0 / period)
end

return ActivityPoses
