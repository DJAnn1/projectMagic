--!strict
--[[
	ActivityProps: the tools in NPCs' hands, drawn on this client only (docs/Activities.md §2).

	Built from Shared/Life/Data/HeldProps: a Model named after the prop in ReplicatedStorage.Assets.Props
	if one exists, otherwise the plain-Part fallback. Welded to an R6 arm, massless, no collisions, not
	queryable, so nothing a tool touches is affected. Pooled per prop id: putting a hammer away and picking
	one up again reuses the same parts.

		ActivityProps.attach(model, propId, hand) -> Held?     hand "right" | "left"
		ActivityProps.detach(held)
		ActivityProps.tipOf(held) -> Vector3?                   the working end, in the world
		ActivityProps.count() -> number                         props out right now (the budget)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeldProps = require(Shared.Life.Data.HeldProps)

local POOL_PER_ID = 12

export type Held = { id: string, holder: Model, arm: BasePart, tip: Attachment, weld: Weld }

local pools: { [string]: { Model } } = {}
local out = 0

local ActivityProps = {}

local function plain(def: HeldProps.Prop): Model
	local holder = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "Grip"
	root.Size = Vector3.new(0.1, 0.1, 0.1)
	root.Transparency = 1
	root.CFrame = CFrame.new()
	holder.PrimaryPart = root
	root.Parent = holder
	for i, p in def.parts do
		local part = Instance.new("Part")
		part.Name = "Piece" .. i
		part.Size = p.size
		part.Color = p.color
		part.Material = p.material
		if p.shape == "ball" then
			part.Shape = Enum.PartType.Ball
		elseif p.shape == "cylinder" then
			part.Shape = Enum.PartType.Cylinder
		end
		local a = p.angles or Vector3.zero
		-- Offsets are from the arm's centre; the grip part stands at the arm's centre too.
		part.CFrame = CFrame.new(p.offset) * CFrame.Angles(math.rad(a.X), math.rad(a.Y), math.rad(a.Z))
		part.Parent = holder
	end
	return holder
end

local function fromAsset(def: HeldProps.Prop, id: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild(HeldProps.MODEL_FOLDER)
	local source = folder and folder:FindFirstChild(id)
	if not source or not source:IsA("Model") or not source.PrimaryPart then
		return nil
	end
	local copy = source:Clone()
	-- The model's PrimaryPart goes at `grip` from the arm centre: wrap it so the holder's origin is the
	-- arm centre like the fallback's.
	local holder = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "Grip"
	root.Size = Vector3.new(0.1, 0.1, 0.1)
	root.Transparency = 1
	root.CFrame = CFrame.new()
	holder.PrimaryPart = root
	root.Parent = holder
	copy:PivotTo(CFrame.new(def.grip))
	for _, d in copy:GetDescendants() do
		if d:IsA("BasePart") then
			d.Parent = holder
		end
	end
	copy:Destroy()
	return holder
end

local function build(id: string): Model?
	local def = HeldProps.get(id)
	if not def then
		return nil
	end
	local holder = fromAsset(def, id) or plain(def)
	holder.Name = "HeldProp_" .. id
	local root = holder.PrimaryPart :: BasePart
	for _, d in holder:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			d.CastShadow = false
			if d ~= root then
				local w = Instance.new("WeldConstraint")
				w.Part0 = root
				w.Part1 = d
				w.Parent = d
			end
		end
	end
	local tip = Instance.new("Attachment")
	tip.Name = "Tip"
	tip.Position = def.tip
	tip.Parent = root
	holder:SetAttribute("PropId", id)
	return holder
end

function ActivityProps.attach(model: Model, id: string, hand: string): Held?
	local arm = model:FindFirstChild(if hand == "left" then "Left Arm" else "Right Arm")
	if not arm or not arm:IsA("BasePart") then
		return nil
	end
	local pool = pools[id]
	local holder = if pool and #pool > 0 then table.remove(pool) else build(id)
	if not holder then
		return nil
	end
	local root = holder.PrimaryPart :: BasePart
	-- Offsets are from the arm's centre and the tools are symmetric, so either hand uses them as they are.
	root.CFrame = arm.CFrame
	local weld = Instance.new("Weld")
	weld.Part0 = arm
	weld.Part1 = root
	weld.Parent = root
	holder.Parent = model
	out += 1
	return { id = id, holder = holder, arm = arm, tip = root:FindFirstChild("Tip") :: Attachment, weld = weld }
end

function ActivityProps.detach(held: Held?)
	if not held then
		return
	end
	held.weld:Destroy()
	held.holder.Parent = nil
	out = math.max(0, out - 1)
	local pool = pools[held.id]
	if not pool then
		pool = {}
		pools[held.id] = pool
	end
	if #pool < POOL_PER_ID then
		table.insert(pool, held.holder)
	else
		held.holder:Destroy()
	end
end

function ActivityProps.tipOf(held: Held?): Vector3?
	if not held or not held.tip.Parent then
		return nil
	end
	return held.tip.WorldPosition
end

function ActivityProps.count(): number
	return out
end

return ActivityProps
