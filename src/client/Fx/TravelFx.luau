--!strict
--[[
	TravelFx: what Domain Travel looks like (docs/Travel.md), on anyone riding, for everyone to see. Driven
	by the character attribute TravelStyle: a board under your feet if the style has one, and motes
	streaming off you, in the domain's colour.

	Reduce spell effects keeps the board and drops the motes. Colour comes from Theme.domainColor, so the
	colour-safe and high-contrast palettes apply; the style's name is shown in words on the rider's panel.
	Budget: at most one part and one emitter per rider, removed when they stop.
]]

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local T = require(Shared.Magic.Data.TravelTuning)

local TravelFx = {}

local active: { [Model]: { Instance } } = {}

function TravelFx.clear(character: Model)
	local list = active[character]
	if list then
		active[character] = nil
		for _, item in list do
			item:Destroy()
		end
	end
end

function TravelFx.apply(character: Model, domain: string)
	TravelFx.clear(character)
	local style = T.styles[domain]
	local root = character:FindFirstChild("HumanoidRootPart")
	if not style or not root or not root:IsA("BasePart") then
		return
	end
	local color = Theme.domainColor(domain)
	local list: { Instance } = {}

	local board = style.board
	if board then
		local part = Instance.new("Part")
		part.Name = "TravelBoard"
		part.Size = board.size
		part.Material = board.material
		part.Color = color
		part.Transparency = board.transparency or 0
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = false
		part.CFrame = root.CFrame * CFrame.new(0, -3.2, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
		part.Parent = character
		table.insert(list, part)
	end

	if not Theme.settings.reducedEffects then
		local motes = Instance.new("ParticleEmitter")
		motes.Name = "TravelMotes"
		motes.Color = ColorSequence.new(color)
		motes.LightEmission = 0.6
		motes.Rate = style.motes
		motes.Lifetime = NumberRange.new(0.3, 0.8)
		motes.Speed = NumberRange.new(1, 4)
		motes.SpreadAngle = Vector2.new(40, 40)
		motes.EmissionDirection = Enum.NormalId.Bottom
		motes.Size = NumberSequence.new(0.7, 0)
		motes.Parent = root
		table.insert(list, motes)
	end
	active[character] = list
end

return TravelFx
