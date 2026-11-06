--!strict
--[[
	SurgeFx: what a Surge and a relic look like (docs/Moments.md). Cosmetic: the server decides everything.

		aura(character, domain)   an outline in the domain's colour, a light and rising motes, on anyone
		                          surging, for everyone to see. Reduce spell effects keeps the outline.
		cue "surge":
			start      a ring and a flash where you transformed, and a shake for you
			finisher   the blast, with its name over it
			borrow     a relic waking in your hand

	Colour comes from Theme.domainColor, so the colour-safe and high-contrast palettes apply, and the
	finisher's name says what it is in words.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)
local SpellFx = require(script.Parent.SpellFx)
local Audio = require(Client:WaitForChild("Audio").Audio)

local SurgeFx = {}

local auras: { [Model]: { Instance } } = {}

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = "SurgeFx"
	p.Shape = shape
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = workspace:FindFirstChild("MagicFx") or workspace
	return p
end

local function groundUnder(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(position + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), params)
	return if hit then hit.Position + Vector3.new(0, 0.2, 0) else position
end

local function ring(position: Vector3, from: number, to: number, seconds: number, color: Color3)
	local cframe = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	local disc = part(Enum.PartType.Cylinder, Vector3.new(0.3, from, from), cframe, color, 0.25)
	TweenService:Create(disc, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.1, to, to), Transparency = 1 }):Play()
	Debris:AddItem(disc, seconds + 0.1)
end

local function burst(position: Vector3, to: number, seconds: number, color: Color3)
	local ball = part(Enum.PartType.Ball, Vector3.new(4, 4, 4), CFrame.new(position), color, 0.15)
	TweenService:Create(ball, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(to, to, to), Transparency = 1 }):Play()
	Debris:AddItem(ball, seconds + 0.1)
end

local function label(position: Vector3, text: string, color: Color3)
	local anchor = part(Enum.PartType.Block, Vector3.new(0.1, 0.1, 0.1), CFrame.new(position + Vector3.new(0, 8, 0)), color, 1)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(420, 60)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 220
	gui.Adornee = anchor
	gui.Parent = anchor
	local words = Instance.new("TextLabel")
	words.BackgroundTransparency = 1
	words.Size = UDim2.fromScale(1, 1)
	words.FontFace = Theme.font.title
	words.TextScaled = true
	words.TextColor3 = color
	words.TextStrokeTransparency = 0.2
	words.Text = text
	words.Parent = gui
	TweenService:Create(words, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1.7)
end

local function isMine(casterId: any): boolean
	return casterId == Players.LocalPlayer.UserId
end

-- ─── The aura ───────────────────────────────────────────────────────────────

function SurgeFx.clearAura(character: Model)
	local list = auras[character]
	if list then
		auras[character] = nil
		for _, item in list do
			item:Destroy()
		end
	end
end

function SurgeFx.aura(character: Model, domain: string)
	SurgeFx.clearAura(character)
	local color = Theme.domainColor(domain)
	local list: { Instance } = {}

	local outline = Instance.new("Highlight")
	outline.Name = "SurgeOutline"
	outline.FillColor = color
	outline.FillTransparency = 0.72
	outline.OutlineColor = color
	outline.OutlineTransparency = 0
	outline.DepthMode = Enum.HighlightDepthMode.Occluded
	outline.Adornee = character
	outline.Parent = character
	table.insert(list, outline)

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and not reduced() then
		local light = Instance.new("PointLight")
		light.Name = "SurgeLight"
		light.Color = color
		light.Range = 18
		light.Brightness = 2.5
		light.Parent = root
		table.insert(list, light)

		local motes = Instance.new("ParticleEmitter")
		motes.Name = "SurgeMotes"
		motes.Color = ColorSequence.new(color)
		motes.LightEmission = 0.8
		motes.Rate = 28
		motes.Lifetime = NumberRange.new(0.5, 1.1)
		motes.Speed = NumberRange.new(4, 9)
		motes.SpreadAngle = Vector2.new(25, 25)
		motes.EmissionDirection = Enum.NormalId.Top
		motes.Size = NumberSequence.new(0.5, 0)
		motes.Parent = root
		table.insert(list, motes)
	end
	auras[character] = list
end

-- ─── Cues ───────────────────────────────────────────────────────────────────

function SurgeFx.cue(cue: { [string]: any })
	local position: Vector3 = cue.position
	local domain = if typeof(cue.domain) == "string" then cue.domain else "energy"
	local color = Theme.domainColor(domain)
	if cue.fx == "start" then
		ring(groundUnder(position), 2, 34, 0.5, color)
		if not reduced() then
			burst(position, 16, 0.4, color)
		end
		Audio.play("combat.knockdown", { position = position })
		if isMine(cue.caster) then
			SpellFx.shake(0.8, 0.4)
		end
	elseif cue.fx == "finisher" then
		local radius: number = if typeof(cue.radius) == "number" then cue.radius else 14
		ring(groundUnder(position), 2, radius * 2, 0.45, color)
		burst(position, radius * 2, 0.45, color)
		if typeof(cue.name) == "string" then
			label(position, cue.name, color)
		end
		Audio.play("combat.knockdown", { position = position })
		local camera = workspace.CurrentCamera
		if camera and (camera.CFrame.Position - position).Magnitude <= radius * 5 + 40 then
			SpellFx.shake(1.5, 0.5)
		end
	elseif cue.fx == "borrow" then
		ring(groundUnder(position), 2, 24, 0.6, color)
		if not reduced() then
			burst(position, 10, 0.5, color)
		end
	end
end

return SurgeFx
