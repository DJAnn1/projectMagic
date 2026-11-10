--!strict
--[[
	CastPoses: how a body casts, by what the spell does (docs/CastPoses.md). The owner, 2026-11-10:
	"the different types of spells should have different animations".

	Each kind (Data/RouteSummaries kinds, the same ones Read the cast uses) has two procedural poses
	in the ActivityPoses format (Fx/ActivityPoser plays them on R6 joints, REPLACING the CastSpell
	clip on the joints they name, so the two don't stack):
		gather   held while charging (and the wind-up of a quick cast)
		release  the moment of casting; the controller blends gather into release, holds, fades out
	Angles are degrees in the parent part's axes: +x lifts an arm forward (-x swings it back), +z
	swings the RIGHT arm out to the side (-z for the left arm out), -x on the neck bows the head,
	-x on the root leans the body forward, y turns. Legs (hips) are never posed, so walking keeps going, and so
	nothing crouches either (a lowered torso on straight legs would sink them into the ground):
	low and heavy is a forward lean.

	`twoHanded` kinds use both arms, so the form's adjustment moves both.

	MODES (Magic/SpellHand.modeFor, by form) shift the whole pose after the kind's:
		hand       touch, projectile, beam, chain: as written
		overhead   burst, summon: arms raised by `arm` degrees
		ground     aura, wall, zone, pillar, ritual: arms lowered and a lean toward the ground

	CLIPS: an uploaded R6 clip per kind would replace these (not wired yet; docs/CastPoses.md).
]]

local ActivityPoses = require(game:GetService("ReplicatedStorage").Shared.Life.Data.ActivityPoses)

type Pose = ActivityPoses.Pose

local RS, LS, NECK, ROOT = "Right Shoulder", "Left Shoulder", "Neck", "RootJoint"
local ONE = { { speed = 1, amp = 1 } }

local function pose(joints: { [string]: { number } }, motion: { ActivityPoses.Motion }?, period: number?, lower: number?): Pose
	return {
		joints = joints,
		motion = motion or {},
		period = period or 1,
		lower = lower,
		body = if lower and lower > 0 then "crouch" else nil,
		variants = ONE,
		simple = { RS },
	}
end

export type KindPoses = { gather: Pose, release: Pose, twoHanded: boolean }
export type Mode = { arm: number, lean: number, lower: number }

local kinds: { [string]: KindPoses } = {
	-- Drawn back and turned, the off hand aiming; then a hard thrust.
	attack = {
		twoHanded = false,
		gather = pose({ [RS] = { -30, 0, 25 }, [LS] = { 55, 0, -10 }, [NECK] = { 0, 15, 0 }, [ROOT] = { 0, -20, 0 } },
			{ { joint = RS, axis = "x", amp = 4, shape = "sine" } }, 0.3),
		release = pose({ [RS] = { 100, 0, 0 }, [LS] = { 15, 0, -15 }, [NECK] = { 0, 0, 0 }, [ROOT] = { -8, 15, 0 } }),
	},
	-- Both hands cupped in front, breathing; then lifted and offered.
	heal = {
		twoHanded = true,
		gather = pose({ [RS] = { 65, 0, -25 }, [LS] = { 65, 0, 25 }, [NECK] = { -15, 0, 0 } },
			{ { joint = RS, axis = "x", amp = 6, shape = "sine" }, { joint = LS, axis = "x", amp = 6, shape = "sine" } }, 1.6),
		release = pose({ [RS] = { 115, 0, -15 }, [LS] = { 115, 0, 15 }, [NECK] = { 10, 0, 0 } }),
	},
	-- Arms crossed in front, braced low; then palms pushed out.
	protect = {
		twoHanded = true,
		gather = pose({ [RS] = { 80, 0, -45 }, [LS] = { 80, 0, 45 }, [NECK] = { -8, 0, 0 }, [ROOT] = { -6, 0, 0 } }),
		release = pose({ [RS] = { 90, 0, -8 }, [LS] = { 90, 0, 8 }, [NECK] = { -4, 0, 0 }, [ROOT] = { -4, 0, 0 } }),
	},
	-- Hands low and open; then flung up.
	boost = {
		twoHanded = true,
		gather = pose({ [RS] = { 35, 0, 10 }, [LS] = { 35, 0, -10 }, [NECK] = { 8, 0, 0 } },
			{ { joint = NECK, axis = "x", amp = 4, shape = "sine" } }, 1.2),
		release = pose({ [RS] = { 165, 0, 15 }, [LS] = { 165, 0, -15 }, [NECK] = { 15, 0, 0 } }),
	},
	-- Both arms out, straining, a tremor; then the grip closes and the body leans in.
	control = {
		twoHanded = true,
		gather = pose({ [RS] = { 85, 0, 5 }, [LS] = { 85, 0, -5 }, [NECK] = { -5, 0, 0 } },
			{ { joint = RS, axis = "x", amp = 3, shape = "sine" }, { joint = LS, axis = "x", amp = 3, shape = "sine", phase = 0.5 } }, 0.45),
		release = pose({ [RS] = { 95, 0, -15 }, [LS] = { 95, 0, 15 }, [ROOT] = { -10, 0, 0 } }),
	},
	-- Arm wound out to the side, leaning; then swept across.
	move = {
		twoHanded = false,
		gather = pose({ [RS] = { 25, 0, 50 }, [LS] = { 20, 0, -20 }, [ROOT] = { -12, -10, 0 } }),
		release = pose({ [RS] = { 90, 0, -30 }, [LS] = { -10, 0, -25 }, [ROOT] = { -18, 20, 0 } }),
	},
	-- Bent low over the ground, both hands down toward it; then a heavy push down.
	land = {
		twoHanded = true,
		gather = pose({ [RS] = { 20, 0, 20 }, [LS] = { 20, 0, -20 }, [NECK] = { -15, 0, 0 }, [ROOT] = { -22, 0, 0 } }),
		release = pose({ [RS] = { 35, 0, 5 }, [LS] = { 35, 0, -5 }, [NECK] = { -25, 0, 0 }, [ROOT] = { -38, 0, 0 } }),
	},
	-- A hand at the temple, head turning slowly as if listening; then the palm sweeps outward.
	sense = {
		twoHanded = false,
		gather = pose({ [RS] = { 150, 0, -45 }, [NECK] = { -8, 0, 0 } },
			{ { joint = NECK, axis = "y", amp = 14, shape = "sine" } }, 3),
		release = pose({ [RS] = { 90, 0, 35 }, [NECK] = { 0, 20, 0 } }),
	},
	utility = {
		twoHanded = false,
		gather = pose({ [RS] = { 55, 0, 5 }, [NECK] = { -5, 0, 0 } }),
		release = pose({ [RS] = { 85, 0, 0 } }),
	},
	-- A spell with no real effect: a limp, uncertain gesture.
	none = {
		twoHanded = false,
		gather = pose({ [RS] = { 40, 0, 0 }, [NECK] = { -12, 0, 0 } }),
		release = pose({ [RS] = { 60, 0, 0 }, [NECK] = { -8, 0, 0 } }),
	},
}

return table.freeze({
	kinds = kinds,
	fallback = "utility",
	modes = table.freeze({
		hand = { arm = 0, lean = 0, lower = 0 },
		overhead = { arm = 65, lean = 5, lower = 0 },
		ground = { arm = -40, lean = -15, lower = 0 },
	}) :: { [string]: Mode },

	fadeIn = 0.2, -- seconds for the gather pose to come in when a charge starts
	-- Casting, as shares of the cast state's duration: gather -> release by `reachAt`, held to `holdTo`,
	-- then faded out by the end (plus `tail` seconds after).
	reachAt = 0.3,
	holdTo = 0.7,
	tail = 0.15,
	range = 120, -- studs from the camera
})
