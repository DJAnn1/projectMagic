--!strict
--[[
	Targeting: who a spell's form reaches. Characters are any Model with a living Humanoid and a
	HumanoidRootPart: players and NPCs alike (accessories and limbs resolve up to their model).

		Targeting.select(ctx, maxTargets?) -> { Hit }   by form (see FORM RULES below)
		Targeting.inRadius(center, radius, max, exclude?) -> { Hit }   nearest first
		Targeting.inCone(origin, direction, reach, degrees, max, exclude?) -> { Hit }
		Targeting.alongLine(from, to, max, ignore) -> { Hit }          thin ray, walls stop it
		Targeting.alongBeam(from, to, radius, max, ignore) -> { Hit }  thick sweep, walls stop it
		Targeting.canHarm(caster, model) -> boolean      Cast/PvpRules; never the caster (backfires excepted)
		Targeting.canHelp(caster, model) -> boolean      heals and buffs: not across a duel
		Targeting.lineOfSight(from, to, ignore, tolerance) -> (clear, hitPosition?)
		Targeting.occluded(from, to, target) -> boolean   a solid wall between two points

	FORM RULES (numbers in Data/CombatTuning)
		delivered   a projectile flight already decided who it struck (Cast/Delivery): those
		touch       the explicit target if within reach, else the nearest character in a cone in
		            front of the caster (coneDegrees, reach = stats.range + reachSlack)
		projectile  (no flight: budget fallback) the first character on the line; piercing: more
		beam        a thick sweep (beam.radius) from the caster's chest to the point; walls stop it
		chain       the beam's first hit, then hops to the nearest unhit character within
		            jumpBase + jumpPerPower x P that it can see
		aura        everyone within `area` of the caster
		other       everyone within `area` of the point (burst, zone, wall, pillar, summon, ritual);
		            with area.occlusion a wall between the centre and a target shields it

	Cost: one spatial query (GetPartBoundsInRadius, capped at 300 parts) or a few casts, plus one
	occlusion ray per area target (at most maxAreaTargets = 24).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Aim = require(Shared.Magic.Aim)
local CastTypes = require(script.Parent.CastTypes)
local PvpRules = require(script.Parent.PvpRules)
local C = require(script.Parent.Parent.Data.CombatTuning)

export type Hit = CastTypes.Hit

local MAX_QUERY_PARTS = 300

local Targeting = {}

-- The character an instance belongs to (or is), if it's alive.
function Targeting.characterOf(instance: Instance?): Hit?
	if not instance then
		return nil
	end
	local model: Model? = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and root and root:IsA("BasePart") then
			if humanoid.Health <= 0 then
				return nil
			end
			return { model = model, humanoid = humanoid, root = root, distance = 0 }
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- Other players follow PvpRules (duels, party, pvp_enabled). NPCs always can be. Never yourself.
function Targeting.canHarm(caster: Player, model: Model): boolean
	if model == caster.Character then
		return false
	end
	local victim = Players:GetPlayerFromCharacter(model)
	if victim then
		return PvpRules.allowed(caster.UserId, victim.UserId)
	end
	return true
end

-- May this caster heal or buff that character? Anyone, unless a duel keeps them apart.
function Targeting.canHelp(caster: Player, model: Model): boolean
	local target = Players:GetPlayerFromCharacter(model)
	return target == nil or PvpRules.canHelp(caster.UserId, target.UserId)
end

local function isSolid(instance: Instance): boolean
	return instance:IsA("Terrain") or (instance:IsA("BasePart") and instance.CanCollide)
end

-- Characters within `radius` of `center`, nearest first, at most `max`.
function Targeting.inRadius(center: Vector3, radius: number, max: number, exclude: { [Model]: boolean }?): { Hit }
	local params = OverlapParams.new()
	params.MaxParts = MAX_QUERY_PARTS
	local seen: { [Model]: boolean } = {}
	local hits: { Hit } = {}
	for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
		local hit = Targeting.characterOf(part)
		if hit and not seen[hit.model] and not (exclude and exclude[hit.model]) then
			seen[hit.model] = true
			hit.distance = (hit.root.Position - center).Magnitude
			table.insert(hits, hit)
		end
	end
	table.sort(hits, function(a, b)
		return a.distance < b.distance
	end)
	while #hits > max do
		table.remove(hits)
	end
	return hits
end

-- Characters within `reach` of `origin` and `degrees` of `direction` (flattened), nearest first.
function Targeting.inCone(origin: Vector3, direction: Vector3, reach: number, degrees: number, max: number, exclude: { [Model]: boolean }?): { Hit }
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return Targeting.inRadius(origin, reach, max, exclude)
	end
	flat = flat.Unit
	local minDot = math.cos(math.rad(degrees))
	local hits: { Hit } = {}
	for _, hit in Targeting.inRadius(origin, reach, max * 4 + 4, exclude) do
		local to = hit.root.Position - origin
		local toFlat = Vector3.new(to.X, 0, to.Z)
		-- Someone standing inside you (or right on top) is always in the cone.
		if toFlat.Magnitude < 1.5 or toFlat.Unit:Dot(flat) >= minDot then
			table.insert(hits, hit)
			if #hits >= max then
				break
			end
		end
	end
	return hits
end

-- Characters along a thin line, in order, at most `max`. Terrain and other solid parts stop it.
function Targeting.alongLine(from: Vector3, to: Vector3, max: number, ignore: { Instance }): { Hit }
	return Targeting.alongBeam(from, to, 0, max, ignore)
end

-- Characters along a thick line (a sphere of `radius` swept from -> to), in order, at most `max`.
-- radius 0 is a plain raycast. Solid non-character parts and terrain stop the sweep.
function Targeting.alongBeam(from: Vector3, to: Vector3, radius: number, max: number, ignore: { Instance }): { Hit }
	local hits: { Hit } = {}
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = table.clone(ignore)
	local origin = from
	for _ = 1, max + 8 do -- a few extra steps for non-solid parts we pass through
		local remaining = to - origin
		if #hits >= max or remaining.Magnitude < 0.5 then
			break
		end
		params.FilterDescendantsInstances = excluded
		local result = if radius > 0
			then workspace:Spherecast(origin, radius, remaining, params)
			else workspace:Raycast(origin, remaining, params)
		if not result then
			break
		end
		local hit = Targeting.characterOf(result.Instance)
		if hit then
			hit.distance = (result.Position - from).Magnitude
			table.insert(hits, hit)
			table.insert(excluded, hit.model)
		elseif isSolid(result.Instance) then
			break -- a wall stops the spell
		else
			table.insert(excluded, result.Instance)
		end
		-- Continue from where the sweep stopped (never backwards, never stuck in place).
		local advanced = (result.Position - origin):Dot(remaining.Unit)
		origin += remaining.Unit * math.max(0.1, advanced)
	end
	return hits
end

-- Clear when nothing solid (other than characters and `ignore`) blocks the line short of `to`.
-- Characters and non-colliding parts don't block sight. Shared with the client's reticle
-- (Shared/Magic/Aim), so "no line of sight" there means the same as here.
function Targeting.lineOfSight(from: Vector3, to: Vector3, ignore: { Instance }, tolerance: number): (boolean, Vector3?)
	return Aim.lineOfSight(from, to, ignore, tolerance)
end

-- True when a solid wall stands between `from` and the target's root.
function Targeting.occluded(from: Vector3, hit: Hit, ignore: { Instance }): boolean
	local list = table.clone(ignore)
	table.insert(list, hit.model)
	local clear = Targeting.lineOfSight(from, hit.root.Position, list, 1)
	return not clear
end

local function chainJump(power: number): number
	return Aim.chainJump(power)
end

function Targeting.select(ctx: CastTypes.EffectContext, maxTargets: number?): { Hit }
	local stats = ctx.stats
	local form = stats.recipe.form
	local max = math.max(1, maxTargets or stats.maxTargets)
	local caster = ctx.character

	if ctx.backfire then
		return { { model = caster, humanoid = caster:FindFirstChildOfClass("Humanoid") :: Humanoid, root = ctx.root, distance = 0 } }
	end

	-- A projectile flight already decided who it struck.
	local delivered = ctx.delivered
	if delivered then
		local alive: { Hit } = {}
		for _, h in delivered do
			if h.humanoid.Health > 0 and h.model.Parent and #alive < max then
				table.insert(alive, h)
			end
		end
		return alive
	end

	local chest = ctx.origin + Vector3.new(0, 1.5, 0)
	if form == "touch" then
		local reach = stats.range + C.touch.reachSlack
		if ctx.target then
			local hit = Targeting.characterOf(ctx.target)
			if hit and hit.model ~= caster and (hit.root.Position - ctx.origin).Magnitude <= reach + 3 then
				return { hit }
			end
		end
		local direction = ctx.point - ctx.origin
		if direction.Magnitude < 0.5 then
			direction = ctx.root.CFrame.LookVector
		end
		return Targeting.inCone(ctx.origin, direction, reach, C.touch.coneDegrees, 1, { [caster] = true })
	elseif form == "projectile" or form == "beam" or form == "chain" then
		local lineMax = if form == "beam" then max elseif stats.flags.piercing then max else 1
		local radius = if form == "beam" then C.beam.radius + C.beam.radiusPerPower * stats.recipe.power else C.beam.radius
		local direction = ctx.point - chest
		local to = if direction.Magnitude > 0.1 then ctx.point + direction.Unit * 2 else ctx.point
		local hits = Targeting.alongBeam(chest, to, radius, lineMax, { caster })
		if #hits == 0 and ctx.target then
			-- The point is on the target but the sweep grazed past it: count the target.
			local hit = Targeting.characterOf(ctx.target)
			if hit and hit.model ~= caster and (hit.root.Position - ctx.point).Magnitude <= 6 then
				hits = { hit }
			end
		end
		if form == "chain" and #hits > 0 then
			local hitSet: { [Model]: boolean } = { [caster] = true }
			for _, h in hits do
				hitSet[h.model] = true
			end
			local jump = chainJump(stats.recipe.power)
			local last = hits[#hits]
			while #hits < max do
				local nextHit: Hit? = nil
				for _, candidate in Targeting.inRadius(last.root.Position, jump, 4, hitSet) do
					if not C.chain.needsSight or not Targeting.occluded(last.root.Position, candidate, { last.model }) then
						nextHit = candidate
						break
					end
				end
				if not nextHit then
					break
				end
				last = nextHit
				hitSet[last.model] = true
				table.insert(hits, last)
			end
		end
		return hits
	end

	local center = if form == "aura" then ctx.origin else ctx.point
	local hits = Targeting.inRadius(center, stats.area, max, { [caster] = true })
	if C.area.occlusion and form ~= "aura" then
		local eye = center + Vector3.new(0, C.area.lift, 0)
		local visible: { Hit } = {}
		for _, hit in hits do
			if not Targeting.occluded(eye, hit, { caster }) then
				table.insert(visible, hit)
			end
		end
		return visible
	end
	return hits
end

-- Exposed for Delivery and the specs.
Targeting.chainJump = chainJump

return Targeting
