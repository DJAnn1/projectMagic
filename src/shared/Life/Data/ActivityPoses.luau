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

	-- ── Stage 2 (2026-11-07): the other trades, everyday life, hobbies, the other domains ──
	-- Ground-sitting poses use body "sit" with `lower` and no station: the legs go straight out (hips +90)
	-- and the body drops about a stud onto the ground where they stand.
	gather = { -- crouched, one hand reaching into the plants, the basket in the other
		joints = { [RS] = { 70, 0, -5 }, [LS] = { 30, 0, 10 }, [NECK] = { -35, 0, 0 }, [ROOT] = { -25, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 20, shape = "sine" },
			{ joint = RS, axis = "y", amp = 12, shape = "circle" },
		},
		period = 2.4, body = "crouch", lower = 0.9, variants = THREE, simple = { RS },
	},
	grind = { -- pestle going round in a mortar at chest height
		joints = { [RS] = { 50, 0, -15 }, [LS] = { 42, 0, 15 }, [NECK] = { -25, 0, 0 }, [ROOT] = { -8, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 14, shape = "circle" },
			{ joint = RS, axis = "x", amp = 6, shape = "sine" },
		},
		period = 1.2, variants = TWO, simple = { RS },
	},
	lantern = { -- a lamp held out ahead, looking along the street
		joints = { [RS] = { 85, 0, -8 }, [NECK] = { 6, 0, 0 } },
		motion = { { joint = NECK, axis = "y", amp = 22, shape = "sine" } },
		period = 6, variants = TWO, simple = {},
	},
	bless = { -- both arms raised and open, face lifted
		joints = { [RS] = { 128, 0, 20 }, [LS] = { 128, 0, -20 }, [NECK] = { 14, 0, 0 } },
		motion = {
			{ joint = RS, axis = "z", amp = 10, shape = "sine" },
			{ joint = LS, axis = "z", amp = -10, shape = "sine" },
			{ joint = NECK, axis = "x", amp = 4, shape = "sine", phase = 0.25 },
		},
		period = 4, variants = TWO, simple = { RS, LS },
	},
	skyread = { -- one hand up feeling the wind, head turning across the sky
		joints = { [RS] = { 158, 0, 10 }, [LS] = { 20, 0, 0 }, [NECK] = { 24, 0, 0 } },
		motion = {
			{ joint = NECK, axis = "y", amp = 24, shape = "sine" },
			{ joint = RS, axis = "z", amp = 12, shape = "sine", phase = 0.3 },
		},
		period = 5, variants = TWO, simple = {},
	},
	write = { -- hunched, the writing hand moving in short strokes
		joints = { [RS] = { 58, 0, -12 }, [LS] = { 45, 0, 14 }, [NECK] = { -34, 0, 0 }, [ROOT] = { -16, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 9, shape = "sine" },
			{ joint = RS, axis = "x", amp = 4, shape = "sine", phase = 0.5 },
		},
		period = 1.3, variants = TWO, simple = { RS },
	},
	hawk = { -- calling out wares: one arm sweeping over the goods, head turning to passers-by
		joints = { [RS] = { 65, 0, -28 }, [LS] = { 18, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 30, shape = "sine" },
			{ joint = RS, axis = "x", amp = 15, shape = "sine", phase = 0.25 },
			{ joint = NECK, axis = "y", amp = 16, shape = "sine", phase = 0.5 },
		},
		period = 3, variants = THREE, simple = { RS },
	},
	aim = { -- bow held out in the left hand, the right drawing back and loosing
		joints = { [LS] = { 90, 0, 0 }, [RS] = { 90, 0, -30 }, [NECK] = { 0, -10, 0 } },
		motion = { { joint = RS, axis = "z", amp = 22, shape = "strike" } },
		period = 4.5, variants = TWO, simple = { RS },
	},
	chat = { -- talking with the hands, a mug in the other
		joints = { [RS] = { 35, 0, -15 }, [LS] = { 30, 0, 10 } },
		motion = {
			{ joint = RS, axis = "x", amp = 25, shape = "sine" },
			{ joint = RS, axis = "y", amp = 15, shape = "circle" },
			{ joint = NECK, axis = "y", amp = 10, shape = "sine", phase = 0.4 },
			{ joint = ROOT, axis = "y", amp = 5, shape = "sine" },
		},
		period = 2.8, variants = THREE, simple = { RS },
	},
	lecture = { -- pointing at something, book open in the other hand
		joints = { [RS] = { 82, 0, -20 }, [LS] = { 42, 0, 15 } },
		motion = {
			{ joint = RS, axis = "y", amp = 25, shape = "sine" },
			{ joint = NECK, axis = "y", amp = 20, shape = "sine", phase = 0.5 },
		},
		period = 4.5, variants = TWO, simple = { RS },
	},
	sit_listen = { -- a child sitting on the ground at lessons, slate on their lap, a hand up now and then
		joints = { [RH] = { 90, 0, 0 }, [LH] = { 90, 0, 0 }, [LS] = { 35, 0, 10 }, [RS] = { 20, 0, 0 }, [NECK] = { 4, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 130, shape = "strike" },
			{ joint = NECK, axis = "y", amp = 8, shape = "sine" },
		},
		period = 9, body = "sit", lower = 1, variants = THREE, simple = {},
	},
	toss = { -- throwing a ball up and catching it
		joints = { [RS] = { 60, 0, -10 }, [LS] = { 60, 0, 10 }, [NECK] = { 10, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 40, shape = "strike" },
			{ joint = LS, axis = "x", amp = 40, shape = "strike" },
			{ joint = NECK, axis = "x", amp = 18, shape = "sine" },
		},
		period = 1.6, variants = TWO, simple = { RS, LS },
	},
	rest_sit = { -- sitting on the ground leaning back on their hands
		joints = { [RH] = { 90, 0, 8 }, [LH] = { 90, 0, -8 }, [RS] = { -30, 0, 15 }, [LS] = { -30, 0, -15 }, [NECK] = { 10, 0, 0 }, [ROOT] = { 8, 0, 0 } },
		motion = { { joint = NECK, axis = "y", amp = 15, shape = "sine" } },
		period = 8, body = "sit", lower = 1, variants = TWO, simple = {},
	},
	fold = { -- standing with arms folded, weight shifting
		joints = { [RS] = { 80, 0, -45 }, [LS] = { 75, 0, 45 } },
		motion = {
			{ joint = ROOT, axis = "z", amp = 3, shape = "sine" },
			{ joint = NECK, axis = "y", amp = 18, shape = "sine", phase = 0.3 },
		},
		period = 6, variants = THREE, simple = {},
	},
	stroll = { -- hands clasped behind the back, looking about
		joints = { [RS] = { -25, 0, 8 }, [LS] = { -25, 0, -8 } },
		motion = { { joint = NECK, axis = "y", amp = 14, shape = "sine" } },
		period = 6, variants = TWO, simple = {},
	},
	cower = { -- crouched low, arms over the head, trembling
		joints = { [RS] = { 115, 0, -35 }, [LS] = { 115, 0, 35 }, [NECK] = { -35, 0, 0 }, [ROOT] = { -25, 0, 0 } },
		motion = { { joint = ROOT, axis = "z", amp = 2, shape = "sine" } },
		period = 0.5, body = "crouch", lower = 1.2, variants = TWO, simple = {},
	},
	whittle = { -- sitting, knife paring at a block on the knee
		joints = { [RH] = { 90, 0, 0 }, [LH] = { 90, 0, 0 }, [RS] = { 55, 0, -20 }, [LS] = { 50, 0, 20 }, [NECK] = { -30, 0, 0 }, [ROOT] = { -10, 0, 0 } },
		motion = { { joint = RS, axis = "x", amp = 14, shape = "strike" } },
		period = 0.9, body = "sit", lower = 1, variants = TWO, simple = { RS },
	},
	scrub = { -- kneeling, scrubbing in hard circles
		joints = { [RH] = { -88, 0, 0 }, [LH] = { -88, 0, 0 }, [RS] = { 70, 0, -5 }, [LS] = { 40, 0, 15 }, [NECK] = { -30, 0, 0 }, [ROOT] = { -30, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 25, shape = "circle" },
			{ joint = RS, axis = "x", amp = 10, shape = "sine" },
		},
		period = 1.1, body = "kneel", lower = 1.05, variants = TWO, simple = { RS },
	},
	stack = { -- crouched, setting one stone carefully on another
		joints = { [RS] = { 60, 0, -10 }, [LS] = { 60, 0, 10 }, [NECK] = { -25, 0, 0 }, [ROOT] = { -15, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 25, shape = "sine" },
			{ joint = LS, axis = "x", amp = 25, shape = "sine" },
		},
		period = 3, body = "crouch", lower = 0.9, variants = TWO, simple = {},
	},
	feed = { -- bent over, scattering crumbs
		joints = { [RS] = { 45, 0, -10 }, [LS] = { 30, 0, 10 }, [NECK] = { -25, 0, 0 }, [ROOT] = { -10, 0, 0 } },
		motion = { { joint = RS, axis = "x", amp = 35, shape = "strike" } },
		period = 2.6, variants = TWO, simple = { RS },
	},
	argue = { -- both arms going, shouting at the water
		joints = { [RS] = { 60, 0, -20 }, [LS] = { 50, 0, 20 }, [NECK] = { 10, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 40, shape = "sine" },
			{ joint = LS, axis = "x", amp = 30, shape = "sine", phase = 0.5 },
			{ joint = NECK, axis = "x", amp = 8, shape = "sine" },
		},
		period = 2, variants = THREE, simple = { RS, LS },
	},
	inspect = { -- something held up close, turned over, looked at
		joints = { [RS] = { 55, 0, -15 }, [LS] = { 45, 0, 15 }, [NECK] = { -18, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 18, shape = "sine" },
			{ joint = NECK, axis = "y", amp = 12, shape = "sine", phase = 0.3 },
		},
		period = 3.6, variants = THREE, simple = { RS },
	},
	water = { -- tipping a watering can over pots
		joints = { [RS] = { 45, 0, -5 }, [NECK] = { -25, 0, 0 }, [ROOT] = { -10, 0, 0 } },
		motion = { { joint = RS, axis = "x", amp = 18, shape = "sine" } },
		period = 3, variants = TWO, simple = { RS },
	},
	meditate = { -- sitting cross-legged, hands on the knees, very still
		joints = { [RH] = { 90, 0, 25 }, [LH] = { 90, 0, -25 }, [RS] = { 20, 0, -15 }, [LS] = { 20, 0, 15 }, [NECK] = { -6, 0, 0 } },
		motion = { { joint = NECK, axis = "x", amp = 3, shape = "sine" } },
		period = 5, body = "sit", lower = 1, variants = TWO, simple = {},
	},
	cast_lift = { -- both palms up, raising something from the ground
		joints = { [RS] = { 100, 0, -20 }, [LS] = { 100, 0, 20 }, [NECK] = { 15, 0, 0 } },
		motion = {
			{ joint = RS, axis = "x", amp = 10, shape = "sine" },
			{ joint = LS, axis = "x", amp = 10, shape = "sine", phase = 0.5 },
		},
		period = 4, variants = TWO, simple = {},
	},
	cast_ring = { -- arms held apart, holding two things at a distance
		joints = { [RS] = { 75, 0, 30 }, [LS] = { 75, 0, -30 }, [NECK] = { -10, 0, 0 } },
		motion = {
			{ joint = RS, axis = "y", amp = 10, shape = "sine" },
			{ joint = LS, axis = "y", amp = -10, shape = "sine" },
		},
		period = 3, variants = TWO, simple = {},
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
	-- Stage 2 slots (2026-11-07), all waiting for a clip.
	gather = "", -- 2.4 s loop: crouched, reaching into plants
	grind = "", -- 1.2 s loop: pestle circling in a mortar
	lantern = "", -- 6 s loop over the walk: lantern held out, looking along the street
	bless = "", -- 4 s loop: arms raised and open
	skyread = "", -- 5 s loop: hand raised to the wind, head turning
	write = "", -- 1.3 s loop: hunched, writing
	hawk = "", -- 3 s loop: calling out, arm sweeping over goods
	aim = "", -- 4.5 s: bow drawn and loosed
	chat = "", -- 2.8 s loop: talking with the hands
	lecture = "", -- 4.5 s loop: pointing, book in hand
	sit_listen = "", -- 9 s loop: sitting on the ground, hand up now and then
	toss = "", -- 1.6 s loop: ball thrown up and caught
	rest_sit = "", -- 8 s loop: sitting back on the hands
	fold = "", -- 6 s loop: arms folded, weight shifting
	stroll = "", -- 6 s loop over the walk: hands behind the back
	cower = "", -- 0.5 s loop: crouched, arms over the head, trembling
	whittle = "", -- 0.9 s loop: sitting, paring wood
	scrub = "", -- 1.1 s loop: kneeling, scrubbing
	stack = "", -- 3 s loop: crouched, placing stones
	feed = "", -- 2.6 s loop: scattering crumbs
	argue = "", -- 2 s loop: shouting, both arms going
	inspect = "", -- 3.6 s loop: turning something over in the hands
	water = "", -- 3 s loop: tipping a watering can
	meditate = "", -- 5 s loop: sitting cross-legged, still
	cast_lift = "", -- 4 s loop: palms up, lifting
	cast_ring = "", -- 3 s loop: arms apart, holding two things
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
