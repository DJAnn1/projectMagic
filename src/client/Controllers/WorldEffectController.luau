--!strict
--[[
	WorldEffectController: applies the server's WorldEffect cues on this client.

		knockback        push from Force / waves (clamped: a bad packet can't fling the player)
		weapon           Fx/WeaponFx: arrows, bolts and knives in flight, stuck where they land
		spell            Fx/SpellFx.spell: begin (skipped while CastClient predicts our own cast),
		                 launch (a projectile flying the server path), resolve (impact), chain (arcs)
		hit, heal        Fx/CombatFeedback: damage numbers, hit markers, hurt flash, hit-stop
		statusTag        Fx/CombatFeedback: the status word over whoever it landed on
		field, field_end persistent zone rings
		wave, tsunami    rolling water / spray along the front
		quake, tremor    camera shake + dust (shake respects Reduce motion / Reduce spell effects)
		reaction, steam, conduction, smoke, firestorm, blizzard, crush, shear   InteractionMatrix results
		backlash         a burst at the caster; our own backlash also shakes the camera
		status           our own status overlays (blind, slowed time, silence, burning...)
		                 (+ knockdown: our character falls for the duration, then gets up)
		combo, combo_ready   Fx/ComboFx: a two-player combo erupting, and the "finish it here" ring
		gravity, gravity_pull  Fx/GravityFx: grips, wells, singularities, shields, slams; a well dragging you
		time             Fx/TimeFx: afterimages, recalls, a stopped world, wounds, foreseen spells
		surge            Fx/SurgeFx: transforming, the finisher, a relic waking
		event, event_end world events (no visuals yet)
	Everything visual is pooled and LOD-scaled inside SpellFx; a failing handler is logged, never
	allowed to break the listener.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local SpellFx = require(script.Parent.Parent:WaitForChild("Fx").SpellFx)
local FxPool = require(script.Parent.Parent.Fx.FxPool)
local CombatFeedback = require(script.Parent.Parent.Fx.CombatFeedback)
local WeaponFx = require(script.Parent.Parent.Fx.WeaponFx)
local DashFx = require(script.Parent.Parent.Fx.DashFx)
local ComboFx = require(script.Parent.Parent.Fx.ComboFx)
local GravityFx = require(script.Parent.Parent.Fx.GravityFx)
local TimeFx = require(script.Parent.Parent.Fx.TimeFx)
local SurgeFx = require(script.Parent.Parent.Fx.SurgeFx)
local Audio = require(script.Parent.Parent:WaitForChild("Audio").Audio)

local MAX_KNOCKBACK = 250 -- studs/s; above CastTuning.force.maxSpeed so legitimate pushes pass whole

local WorldEffectController = {
	name = "WorldEffectController",
	dependencies = { "CastClient" },
}

local log: any = nil
local castClient: any = nil

local function knockback(velocity: any)
	if typeof(velocity) ~= "Vector3" or velocity.Magnitude ~= velocity.Magnitude then
		return
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	-- Anchor Weight (a Gravity spell): nothing pushes you around.
	if humanoid and humanoid:GetAttribute("Status_gravity_heavy") ~= nil then
		return
	end
	if root and root:IsA("BasePart") then
		local clamped = if velocity.Magnitude > MAX_KNOCKBACK then velocity.Unit * MAX_KNOCKBACK else velocity
		root.AssemblyLinearVelocity += clamped
	end
end

-- Knocked down (HitReactions): your character falls and gets up when the status ends. The
-- server already stops walking (WalkSpeed 0); this is the fall itself, which only the owning
-- client can do to a player character.
local downToken = 0
local function knockdown(active: boolean, duration: any)
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	downToken += 1
	local token = downToken
	if active then
		humanoid.PlatformStand = true
		local root = humanoid.RootPart
		Audio.play("combat.knockdown", { position = if root then root.Position else nil })
		local seconds = if typeof(duration) == "number" then math.clamp(duration, 0.2, 5) else 1.6
		task.delay(seconds, function()
			if token == downToken and humanoid.Parent then
				humanoid.PlatformStand = false
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	else
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local REACTIONS: { [string]: boolean } = {
	steam = true, conduction = true, smoke = true, firestorm = true, blizzard = true, crush = true, shear = true, tremor = true,
}

local function handle(effect: { [string]: any })
	local kind = effect.kind
	if kind == "knockback" then
		knockback(effect.velocity)
	elseif kind == "spell" then
		if effect.stage == "begin" and castClient:isPredicting(effect.caster) then
			return
		end
		SpellFx.spell(effect)
	elseif kind == "weapon" then
		WeaponFx.cue(effect)
	elseif kind == "dash" then
		DashFx.cue(effect)
	elseif kind == "sound" then
		-- The admin command `sound <role>`: audition a library sound here (a one-shot; long
		-- music and ambience play for up to 12 s, then stop).
		if typeof(effect.role) == "string" then
			Audio.play(effect.role, { vary = false })
		end
	elseif kind == "surge" then
		SurgeFx.cue(effect)
	elseif kind == "time" then
		TimeFx.cue(effect)
	elseif kind == "gravity" then
		GravityFx.cue(effect)
	elseif kind == "gravity_pull" then
		GravityFx.pull(effect)
	elseif kind == "field" then
		SpellFx.field(effect)
		if effect.field == "gravity" then
			GravityFx.fieldPulse(effect)
		end
	elseif kind == "field_end" then
		SpellFx.fieldEnd(effect)
	elseif kind == "wave" then
		SpellFx.wave(effect)
	elseif kind == "tsunami" then
		SpellFx.tsunami(effect)
	elseif kind == "quake" then
		SpellFx.quake(effect)
	elseif kind == "reaction" then
		SpellFx.reaction(effect.result, effect)
	elseif REACTIONS[kind] then
		SpellFx.reaction(kind, effect)
	elseif kind == "backlash" then
		SpellFx.backlash(effect)
	elseif kind == "status" then
		SpellFx.status(effect)
		if effect.status == "knockdown" then
			knockdown(effect.active == true, effect.duration)
		end
	elseif kind == "hit" then
		CombatFeedback.hit(effect)
	elseif kind == "heal" then
		CombatFeedback.heal(effect)
	elseif kind == "statusTag" then
		CombatFeedback.statusTag(effect)
	elseif kind == "combo" then
		ComboFx.play(effect)
	elseif kind == "combo_ready" then
		ComboFx.ready(effect)
	end
end

function WorldEffectController.init(_self: any, ctx: any)
	log = ctx.log
	castClient = ctx.get("CastClient")
	-- Lower-end devices keep fewer effects alive at once.
	FxPool.setScale(SpellFx.quality())
	CombatFeedback.setShake(SpellFx.shake)
end

function WorldEffectController.start(_self: any, _ctx: any)
	Net.listen("WorldEffect", function(effect)
		if typeof(effect) ~= "table" then
			return
		end
		local ok, err = pcall(handle, effect)
		if not ok then
			log:throttled("fx:" .. tostring(effect.kind), 30, "Warn", "fx_failed", { kind = effect.kind, err = err })
		end
	end)
end

return WorldEffectController
