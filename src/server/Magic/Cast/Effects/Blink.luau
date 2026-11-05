--!strict
--[[
	Blink: Space magic that moves bodies through space.

		redirect   the caster steps to the aim point (Blink)
		transfer   the target is pulled to stand in front of the caster (Displace); a harmful act,
		           so other players only with pvp_enabled
	The destination is always ON something: a downward ray finds the surface, and a clearance box
	the size of a character must be empty, so nobody is ever placed inside a wall or the ground.
	Range and line of sight were already validated by CastService.
	A backfire throws the caster a short distance in a random direction.
]]

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)

local CLEARANCE = Vector3.new(3, 5, 3)

local Blink = {}

-- A standing spot at (or just above) a point, or nil when there's no room.
local function standAt(point: Vector3, ignore: { Instance }): CFrame?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -20, 0), params)
	if not hit then
		return nil
	end
	local stand = CFrame.new(hit.Position + Vector3.new(0, CLEARANCE.Y / 2 + 0.5, 0))
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = ignore
	for _, part in workspace:GetPartBoundsInBox(stand, CLEARANCE, overlap) do
		if part.CanCollide then
			return nil
		end
	end
	return stand
end

local function facing(stand: CFrame, toward: Vector3): CFrame
	local flat = Vector3.new(toward.X - stand.Position.X, 0, toward.Z - stand.Position.Z)
	return if flat.Magnitude > 0.1 then CFrame.lookAt(stand.Position, stand.Position + flat) else stand
end

function Blink.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local verb = ctx.stats.recipe.verb
	if ctx.backfire then
		local angle = ctx.rng:NextNumber() * math.pi * 2
		local stand = standAt(ctx.origin + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 10, { ctx.character })
		if stand then
			ctx.character:PivotTo(stand)
		end
		return { effective = false, hits = 0, note = "Space slips; you land somewhere you didn't choose." }
	end

	if verb == "transfer" then
		local target: Targeting.Hit? = if ctx.target then Targeting.characterOf(ctx.target) else Targeting.select(ctx, 1)[1]
		if not target or not Targeting.canHarm(ctx.player, target.model) then
			return { effective = false, hits = 0, note = "Nothing there you can move." }
		end
		local front = ctx.origin + ctx.root.CFrame.LookVector * 5
		local stand = standAt(front, { ctx.character, target.model })
		if not stand then
			return { effective = false, hits = 0, note = "No room in front of you." }
		end
		target.model:PivotTo(facing(stand, ctx.origin))
		return { effective = true, hits = 1 }
	end

	local stand = standAt(ctx.point, { ctx.character })
	if not stand then
		return { effective = false, hits = 0, note = "No room there." }
	end
	ctx.character:PivotTo(facing(stand, stand.Position + (ctx.point - ctx.origin)))
	return { effective = true, hits = 0 }
end

return Blink
