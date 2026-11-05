--!strict
--[[
	AttuneGlowController: the glow in the hand of anyone holding a spell ready (equip mode,
	docs/Casting.md §6). Purely cosmetic and local: the server only sets the character attribute
	AttunedDomain (Services/AttunementService); every client draws the glow itself, in the
	caster's Signature colours (SpellFx.styleFor), so no effect instances replicate.

	PER GLOW   an Attachment on the right hand ("Right Arm" on R6, "RightHand" on R15), a small
	           PointLight and one ParticleEmitter (sparkles; fewer with Reduce spell effects).
	BUDGET     at most MAX_GLOWS at once, and only bodies within RANGE studs of the camera emit
	           (checked every CHECK seconds); the rest keep their glow parked (Enabled = false).
	BLADE      while the body is slashing (the spellblade), a trail from the palm past the fist
	           in the Signature colours: the edge of the attuned spell.
	CHARGING   (character attributes ChargeStart / ChargeStep, set by CastService; the stage is
	           worked out here from the server clock, so nothing replicates per stage) each stage
	           brightens the light and thickens the sparks, and a hum rises in pitch (only within
	           SOUND_RANGE). Overcharged: the glow shakes in the hand and the sparks crackle outward.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Charge = require(Shared.Magic.Charge)

local Client = script.Parent.Parent
local SpellFx = require(Client:WaitForChild("Fx").SpellFx)
local DomainFx = require(Client.Fx.DomainFx)

local MAX_GLOWS = 24
local RANGE = 150
local CHECK = 0.5
local SOUND_RANGE = 60
local SHAKE = 0.09 -- studs the overcharged glow jitters

local AttuneGlowController = {
	name = "AttuneGlowController",
	dependencies = { "MagicStateController" },
}

type Glow = {
	attachment: Attachment,
	light: PointLight,
	emitter: ParticleEmitter,
	hum: Sound,
	trail: Trail, -- the spellblade's edge, drawn only while slashing
	root: BasePart?,
	character: Model,
	base: CFrame, -- the attachment's resting place (the shake is around it)
	rate: number, -- the emitter's resting rate
	near: boolean,
}

local magic: any = nil
local glows: { [Model]: Glow } = {}
local count = 0

local function handOf(character: Model): BasePart?
	local hand = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
	return if hand and hand:IsA("BasePart") then hand else nil
end

local function removeGlow(character: Model)
	local glow = glows[character]
	if glow then
		glow.attachment:Destroy() -- takes the light and emitter with it
		glows[character] = nil
		count -= 1
	end
end

local function addGlow(player: Player, character: Model, domain: string)
	removeGlow(character)
	local hand = handOf(character)
	if not hand or count >= MAX_GLOWS then
		return
	end
	local style = SpellFx.styleFor(player.UserId, domain)
	local reduced = magic.settings:get().reducedEffects == true

	local attachment = Instance.new("Attachment")
	attachment.Name = "AttuneGlow"
	-- The palm: the grip attachment when the rig has one, else the bottom of the hand part.
	local grip = hand:FindFirstChild("RightGripAttachment")
	attachment.CFrame = if grip and grip:IsA("Attachment") then grip.CFrame else CFrame.new(0, -hand.Size.Y / 2, 0)
	attachment.Parent = hand

	local light = Instance.new("PointLight")
	light.Color = style.primary
	light.Brightness = 1.6
	light.Range = 7
	light.Shadows = false
	light.Parent = attachment

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = DomainFx.textures.sparkles
	emitter.Color = ColorSequence.new(style.primary, style.secondary)
	emitter.LightEmission = 0.8
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.Speed = NumberRange.new(0.5, 1.5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = if reduced then 6 else 18
	emitter.LockedToPart = true
	emitter.Parent = attachment

	-- The charge hum: a looped wind that rises in pitch per stage.
	local hum = Instance.new("Sound")
	hum.SoundId = DomainFx.sounds.wind
	hum.Looped = true
	hum.Volume = 0
	hum.RollOffMaxDistance = SOUND_RANGE
	hum.Parent = attachment

	-- The blade: a trail from the palm to a point past the fist, lit only mid-swing.
	local tip = Instance.new("Attachment")
	tip.Name = "BladeTip"
	tip.CFrame = attachment.CFrame * CFrame.new(0, -2.2, 0)
	tip.Parent = hand
	local trail = Instance.new("Trail")
	trail.Attachment0 = attachment
	trail.Attachment1 = tip
	trail.Color = ColorSequence.new(style.primary, style.secondary)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime = 0.18
	trail.LightEmission = 0.9
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = attachment
	attachment.Destroying:Connect(function()
		tip:Destroy()
	end)

	local root = character:FindFirstChild("HumanoidRootPart")
	glows[character] = {
		attachment = attachment,
		light = light,
		emitter = emitter,
		hum = hum,
		trail = trail,
		root = if root and root:IsA("BasePart") then root else nil,
		character = character,
		base = attachment.CFrame,
		rate = emitter.Rate,
		near = true,
	}
	count += 1
end

local function refresh(player: Player, character: Model)
	local domain = character:GetAttribute("AttunedDomain")
	if typeof(domain) == "string" and character.Parent then
		addGlow(player, character, domain)
	else
		removeGlow(character)
	end
end

local function watchCharacter(player: Player, character: Model)
	character:GetAttributeChangedSignal("AttunedDomain"):Connect(function()
		refresh(player, character)
	end)
	character.AncestryChanged:Connect(function()
		if not character.Parent then
			removeGlow(character)
		end
	end)
	-- The hand may stream in after the attribute: retry once it exists.
	task.spawn(function()
		character:WaitForChild(if character:FindFirstChild("Torso") then "Right Arm" else "RightHand", 10)
		refresh(player, character)
	end)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
	end)
	if player.Character then
		watchCharacter(player, player.Character)
	end
end

function AttuneGlowController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
end

function AttuneGlowController.start(_self: any, _ctx: any)
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	-- Only nearby glows emit and light.
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < CHECK then
			return
		end
		elapsed = 0
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local eye = camera.CFrame.Position
		for _, glow in glows do
			local near = glow.root ~= nil and (glow.root.Position - eye).Magnitude <= RANGE
			glow.near = near
			glow.emitter.Enabled = near
			glow.light.Enabled = near
		end
	end)

	-- Charging glows, every frame (only nearby ones that are charging do any work).
	RunService.RenderStepped:Connect(function()
		local t = workspace:GetServerTimeNow()
		for _, glow in glows do
			glow.trail.Enabled = glow.near and glow.character:GetAttribute("ActionState") == "slashing"
			local start = glow.character:GetAttribute("ChargeStart")
			local step = glow.character:GetAttribute("ChargeStep")
			if not glow.near or typeof(start) ~= "number" or typeof(step) ~= "number" then
				if glow.hum.Playing then
					glow.hum:Stop()
					glow.attachment.CFrame = glow.base
					glow.emitter.Rate = glow.rate
					glow.emitter.Speed = NumberRange.new(0.5, 1.5)
					glow.light.Brightness = 1.6
				end
				continue
			end
			-- step >= minStep, so passing it as the cast time gives the same stage the server counts.
			local index = Charge.stageIndex(t - start, step)
			local stage = Charge.stage(index)
			glow.light.Brightness = 1.6 + 0.9 * (index - 1)
			glow.emitter.Rate = glow.rate * (1 + 0.8 * (index - 1))
			if not glow.hum.Playing then
				glow.hum:Play()
			end
			glow.hum.Volume = 0.15 + 0.06 * index
			glow.hum.PlaybackSpeed = 0.7 + 0.25 * (index - 1)
			if stage.overcharge then
				local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * (SHAKE * 2)
				glow.attachment.CFrame = glow.base + jitter
				glow.emitter.Speed = NumberRange.new(3, 6)
			else
				glow.attachment.CFrame = glow.base
				glow.emitter.Speed = NumberRange.new(0.5, 1.5)
			end
		end
	end)
end

return AttuneGlowController
