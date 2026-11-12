--!strict
--[[
	Reach: how far a player is from something they want to use. One rule for the client's pick
	(InteractClickController), the server's check (Interact/PromptRouter, InteractionService,
	ContainerService), so the two can never disagree about whether a thing is in reach.

		Reach.holderOf(prompt)            -> (point, holder)  where the prompt is, and what it's on
		Reach.toPart(part, from)          -> studs from `from` to the nearest point of the part's box
		Reach.toPrompt(prompt, from)      -> studs from `from` to the nearest surface of the prompt's holder
		Reach.SLACK                       studs the server allows past MaxActivationDistance (latency)

	WHY THE SURFACE  Measuring to a part's centre made a wide chest or a long door fail from one
	side and pass from another, and a model's pivot can sit anywhere. The nearest point of the
	part's bounding box is the same from every angle.
]]

local Reach = {}

Reach.SLACK = 3

-- Where the prompt is (its world point) and the instance it belongs to (part or model).
function Reach.holderOf(prompt: ProximityPrompt): (Vector3?, Instance?)
	local holder = prompt.Parent
	if holder and holder:IsA("Attachment") then
		local part = holder.Parent
		return holder.WorldPosition, if part and part:IsA("BasePart") then part else holder
	elseif holder and holder:IsA("BasePart") then
		return holder.Position, holder
	elseif holder and holder:IsA("Model") then
		return holder:GetPivot().Position, holder
	end
	return nil, nil
end

-- Distance from a point to the nearest point of an oriented box (0 inside it).
local function toBox(cf: CFrame, size: Vector3, from: Vector3): number
	local localPoint = cf:PointToObjectSpace(from)
	local half = size / 2
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (localPoint - clamped).Magnitude
end

function Reach.toPart(part: BasePart, from: Vector3): number
	return toBox(part.CFrame, part.Size, from)
end

function Reach.toPrompt(prompt: ProximityPrompt, from: Vector3): number
	local point, holder = Reach.holderOf(prompt)
	if not point or not holder then
		return math.huge
	end
	if holder:IsA("BasePart") then
		return toBox(holder.CFrame, holder.Size, from)
	elseif holder:IsA("Model") then
		local cf, size = holder:GetBoundingBox()
		return toBox(cf, size, from)
	end
	return (point - from).Magnitude
end

return Reach
