--!strict
--[[
	LocalShots: the caster's own bolt leaves their hand on the release frame (docs/Smoothness.md,
	stage 1). Without this, a bolt appears only when the server's "launch" cue comes back, a round
	trip after the hand has already thrown (100-200 ms on a live server), and from the chest.

	Purely cosmetic. The server still decides everything: SpellFx.launch hands its launch cue to the
	bolt already flying (which eases onto the server's path), the server's impact cue decides where
	it bursts and whom it hit, and a cast the server refuses or turns into a backfire fades out
	(SpellFx.dropLocal). Other players see exactly what they saw before.

		LocalShots.fire(args) -> handle?
			args.recipe, args.stats   the spell and its previewed stats (MagicStateController:preview)
			args.held                 seconds the charge was held (equip mode), or nil
			args.point, args.target   the aim sent with the cast
		LocalShots.drop(handle)       the cast was refused

	Flag: local_shots_enabled (replicated). Off: bolts wait for the server as before.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local FeatureFlags = require(Shared.Core.FeatureFlags)
local ShotPlan = require(Shared.Magic.ShotPlan)

local SpellFx = require(script.Parent.SpellFx)

local HAND_DROP = 1.05 -- studs from the arm's centre to the palm (R6 arms are 2 long)
local WINDOW_BASE = 0.6 -- seconds a local bolt waits for the server's launch, plus the ping below
local WINDOW_PER_PING = 3
local WINDOW_MAX = 2

local LocalShots = {}

export type FireArgs = {
	recipe: any,
	stats: any,
	held: number?,
	point: Vector3,
	target: Model?,
}

-- The casting hand: the palm end of the right arm (R6), else the right hand (R15), else the chest.
local function handOf(character: Model, root: BasePart): Vector3
	local arm = character:FindFirstChild("Right Arm")
	if arm and arm:IsA("BasePart") then
		return (arm.CFrame * CFrame.new(0, -HAND_DROP, 0)).Position
	end
	local hand = character:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		return hand.Position
	end
	return root.Position + Vector3.new(0, 1.5, 0)
end

function LocalShots.enabled(): boolean
	return FeatureFlags.get("local_shots_enabled") ~= false
end

function LocalShots.fire(args: FireArgs): string?
	if not LocalShots.enabled() then
		return nil
	end
	local player = Players.LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return nil
	end
	local plan = ShotPlan.of(args.recipe, args.stats, {
		held = args.held,
		hasTarget = args.target ~= nil,
		shapes = FeatureFlags.get("spell_shapes_enabled") ~= false,
	})
	if not plan then
		return nil
	end
	-- Where the server will aim (CastService currentPoint): a picked target's body, else the point.
	local point = args.point
	local targetRoot = args.target and args.target:FindFirstChild("HumanoidRootPart")
	if targetRoot and targetRoot:IsA("BasePart") then
		point = targetRoot.Position
	end
	local origin = handOf(character, root)
	local velocity = ShotPlan.velocity(plan, origin, point, root.CFrame.LookVector)
	local okPing, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local window = math.min(WINDOW_MAX, WINDOW_BASE + (if okPing and typeof(ping) == "number" then ping else 0.1) * WINDOW_PER_PING)
	return SpellFx.launchLocal({
		stage = "launch",
		domain = plan.domain,
		property = args.recipe.property,
		verb = args.recipe.verb,
		form = "projectile",
		power = args.recipe.power,
		masteryTier = args.stats.masteryTier,
		harmful = args.stats.harmful,
		origin = origin,
		point = point,
		velocity = velocity,
		gravity = plan.gravity,
		hitRadius = plan.radius,
		homing = if plan.homing then args.target else nil,
		turnRate = plan.turnRate,
		lifetime = plan.lifetime,
		look = plan.look,
		lod = 2,
		window = window,
	})
end

function LocalShots.drop(handle: string?)
	SpellFx.dropLocal(handle)
end

return LocalShots
