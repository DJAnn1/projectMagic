--!strict
--[[
	FieldEffects: zones that change the rules inside them for a while. EffectRunner steps every
	field at field.tick (10 Hz); each step touches at most field.maxAssemblies assemblies AND
	spends that many tokens from the server parts budget (EffectBudget.takeParts), so many
	fields at once degrade gracefully instead of stalling the server.

	A field is a vertical cylinder (radius, height) at a point, or following a caster (aura forms).

	TIME      slow (time factor field.timeSlow) or haste (field.timeHaste)
	          - humanoids: the time_slow / time_haste status (WalkSpeed, NPC animation speed,
	            a client cue for the player's own camera/audio), refreshed while inside
	          - unanchored server-owned parts and projectiles: velocity scaled by the factor on
	            entry and restored on exit; gravity scaled by factor² with a VectorForce, so a
	            dropped crate falls in slow motion and resumes speed when it leaves
	GRAVITY   heavy (x field.gravityHeavy), light (x field.gravityLight) or inverted
	          (field.gravityInvert, deliberately weaker than normal gravity)
	          - a VectorForce on every assembly root inside, players included (constraints on a
	            character replicate and the owning client simulates them); above the field's
	            ceiling an inverted pull becomes weightless hover, so nothing is flung into the sky
	CURRENT   swimmers and floating parts get a VectorForce along the current's direction
	REALITY   rule edits on up to field.realityMaxParts parts, every original value kept in a
	          ledger and restored when the field ends or is dispelled:
	            slick       friction 0 (CustomPhysicalProperties)
	            intangible  CanCollide off + anchored + translucent (unanchored props only, so
	                        nothing falls through the world and floors never vanish)
	            transmute   material and colour swap
	          Never touches characters, Terrain, parts tagged NoMagicEdit, or anything inside a
	          model tagged Structure.

	Cleanup is total: every force, attachment and edited property is removed or restored by
	stop(), and EffectRunner calls stop() on expiry, dispel, and server shutdown.
]]

local CollectionService = game:GetService("CollectionService")

local Cast = script.Parent
local T = require(Cast.Parent.Data.CastTuning)
local C = require(Cast.Parent.Data.CombatTuning)
local EffectBudget = require(Cast.EffectBudget)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)

local FT = T.field
local FORCE_NAME = "MagicFieldForce"

export type Field = {
	kind: string, -- "time" | "gravity" | "current" | "reality"
	mode: string, -- time: slow|haste; gravity: heavy|light|invert; current: flow; reality: slick|intangible|transmute
	center: Vector3,
	follow: BasePart?,
	radius: number,
	height: number,
	direction: Vector3, -- current
	owner: number?,
	spare: Model?, -- the caster's character: heavy and light fields leave it alone
	crush: ((Targeting.Hit, number) -> ())?, -- heavy + harmful: damage(hit, falloff) every crush.interval
	crushClock: number,
	gravityMult: number?, -- multiples of normal gravity, by the caster's mastery (GravityRules.fieldMult)
	inside: { [BasePart]: { force: VectorForce?, attachment: Attachment?, scaled: boolean } },
	ledger: { [BasePart]: { [string]: any } },
	edited: boolean,
}

local FieldEffects = {}

local TRANSMUTE: { [Enum.Material]: Enum.Material } = {
	[Enum.Material.Wood] = Enum.Material.Slate,
	[Enum.Material.WoodPlanks] = Enum.Material.Marble,
	[Enum.Material.Slate] = Enum.Material.Glass,
	[Enum.Material.Glass] = Enum.Material.Ice,
	[Enum.Material.Ice] = Enum.Material.Wood,
	[Enum.Material.Plastic] = Enum.Material.Marble,
	[Enum.Material.SmoothPlastic] = Enum.Material.Neon,
	[Enum.Material.Metal] = Enum.Material.Glass,
}

export type FieldOptions = {
	follow: BasePart?,
	direction: Vector3?,
	owner: number?,
	spare: Model?,
	crush: ((Targeting.Hit, number) -> ())?,
	gravityMult: number?,
}

function FieldEffects.new(kind: string, mode: string, center: Vector3, radius: number, opts: FieldOptions): Field
	local r = math.clamp(radius, 4, FT.maxFieldRadius)
	return {
		kind = kind,
		mode = mode,
		center = center,
		follow = opts.follow,
		radius = r,
		height = r * 1.5,
		direction = opts.direction or Vector3.new(1, 0, 0),
		owner = opts.owner,
		spare = opts.spare,
		crush = opts.crush,
		crushClock = 0,
		gravityMult = opts.gravityMult,
		inside = {},
		ledger = {},
		edited = false,
	}
end

function FieldEffects.isMythic(kind: string): boolean
	return kind == "time" or kind == "gravity" or kind == "reality"
end

local function centerOf(field: Field): Vector3
	local follow = field.follow
	if follow and follow.Parent then
		field.center = follow.Position
	end
	return field.center
end

local function contains(field: Field, position: Vector3): boolean
	local c = field.center
	local flat = Vector3.new(position.X - c.X, 0, position.Z - c.Z)
	return flat.Magnitude <= field.radius and math.abs(position.Y - c.Y) <= field.height
end

local function serverOwned(root: BasePart): boolean
	local ok, owner = pcall(root.GetNetworkOwner, root)
	return ok and owner == nil
end

-- Assembly roots (and characters' HumanoidRootParts) inside the field, capped and budgeted.
local function gather(field: Field): ({ BasePart }, { [BasePart]: Targeting.Hit })
	local params = OverlapParams.new()
	params.MaxParts = FT.maxAssemblies * 4
	local roots: { BasePart } = {}
	local characters: { [BasePart]: Targeting.Hit } = {}
	local seen: { [BasePart]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(field.center, math.max(field.radius, field.height), params) do
		if #roots >= FT.maxAssemblies then
			break
		end
		local hit = Targeting.characterOf(part)
		local root = if hit then hit.root else (if part.Anchored then nil else part.AssemblyRootPart)
		if root and not seen[root] and contains(field, root.Position) then
			seen[root] = true
			table.insert(roots, root)
			if hit then
				characters[root] = hit
			end
		end
	end
	local granted = EffectBudget.takeParts(#roots)
	while #roots > granted do
		local dropped = table.remove(roots) :: BasePart
		characters[dropped] = nil
	end
	return roots, characters
end

local function setForce(field: Field, root: BasePart, force: Vector3)
	local entry = field.inside[root]
	if not entry then
		entry = { scaled = false }
		field.inside[root] = entry
	end
	if not entry.force then
		local attachment = Instance.new("Attachment")
		attachment.Name = FORCE_NAME
		attachment.Parent = root
		local vf = Instance.new("VectorForce")
		vf.Name = FORCE_NAME
		vf.RelativeTo = Enum.ActuatorRelativeTo.World
		vf.ApplyAtCenterOfMass = true
		vf.Attachment0 = attachment
		vf.Parent = root
		entry.force, entry.attachment = vf, attachment
	end
	(entry.force :: VectorForce).Force = force
end

local function release(field: Field, root: BasePart)
	local entry = field.inside[root]
	if not entry then
		return
	end
	field.inside[root] = nil
	if entry.force then
		entry.force:Destroy()
	end
	if entry.attachment then
		entry.attachment:Destroy()
	end
	-- Time fields give back the speed they took.
	if field.kind == "time" and entry.scaled and root.Parent and serverOwned(root) then
		local factor = if field.mode == "slow" then FT.timeSlow else FT.timeHaste
		root.AssemblyLinearVelocity /= factor
	end
end

-- ─── Kinds ──────────────────────────────────────────────────────────────────

local function stepTime(field: Field, roots: { BasePart }, characters: { [BasePart]: Targeting.Hit })
	local factor = if field.mode == "slow" then FT.timeSlow else FT.timeHaste
	local g = workspace.Gravity
	for _, root in roots do
		local hit = characters[root]
		if hit then
			StatusEffects.apply(hit.humanoid, if field.mode == "slow" then "time_slow" else "time_haste", { duration = 0.5, source = field.owner })
		elseif serverOwned(root) then
			local entry = field.inside[root]
			if not entry or not entry.scaled then
				root.AssemblyLinearVelocity *= factor
			end
			-- Gravity scaled by factor²: falls play out at the field's time rate.
			setForce(field, root, Vector3.new(0, root.AssemblyMass * g * (1 - factor * factor), 0))
			field.inside[root].scaled = true
		end
	end
end

local function gravityMultiplier(mode: string): number
	return if mode == "heavy" then FT.gravityHeavy elseif mode == "light" then FT.gravityLight else FT.gravityInvert
end

local function stepGravity(field: Field, roots: { BasePart }, characters: { [BasePart]: Targeting.Hit }, dt: number)
	local g = workspace.Gravity
	local mult = field.gravityMult or gravityMultiplier(field.mode)
	local ceiling = field.center.Y + field.height * 0.8
	local spare = if field.mode ~= "invert" then field.spare else nil
	-- Crushing: every crush.interval, everyone inside (but the caster) takes damage, most at the centre.
	local crush = field.crush
	if crush then
		field.crushClock += dt
		if field.crushClock >= C.crush.interval then
			field.crushClock = 0
			for root, hit in characters do
				if hit.model ~= spare then
					local d = Vector3.new(root.Position.X - field.center.X, 0, root.Position.Z - field.center.Z).Magnitude
					local t = math.clamp(d / field.radius, 0, 1)
					crush(hit, 1 - (1 - C.damage.areaFalloffMin) * t ^ C.damage.areaFalloffCurve)
				end
			end
		end
	end
	for _, root in roots do
		if spare and root:IsDescendantOf(spare) then
			if field.inside[root] then
				release(field, root)
			end
			continue -- your own field doesn't weigh on you
		end
		local m = mult
		if field.mode == "invert" and root.Position.Y >= ceiling then
			m = 0 -- hover at the ceiling instead of flying away
			if serverOwned(root) then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, v.Y * 0.5, v.Z)
			end
		end
		-- Net acceleration = m * g downward: add (1 - m) * g upward against normal gravity.
		setForce(field, root, Vector3.new(0, root.AssemblyMass * g * (1 - m), 0))
	end
end

local function stepCurrent(field: Field, roots: { BasePart }, characters: { [BasePart]: Targeting.Hit })
	for _, root in roots do
		local hit = characters[root]
		local inWater = if hit
			then hit.humanoid:GetState() == Enum.HumanoidStateType.Swimming
			else root.Position.Y <= field.center.Y + 2
		if inWater then
			setForce(field, root, field.direction * root.AssemblyMass * FT.currentSpeed)
		elseif field.inside[root] then
			release(field, root)
		end
	end
end

local function editable(part: BasePart): boolean
	if Targeting.characterOf(part) or CollectionService:HasTag(part, "NoMagicEdit") then
		return false
	end
	local ancestor = part:FindFirstAncestorWhichIsA("Model")
	while ancestor do
		if CollectionService:HasTag(ancestor, "Structure") or CollectionService:HasTag(ancestor, "NoMagicEdit") then
			return false
		end
		ancestor = ancestor:FindFirstAncestorWhichIsA("Model")
	end
	return part.Size.Magnitude < 200 -- never the baseplate or a whole cliff
end

-- Reality edits happen once, on the first step; the ledger restores them on stop.
local function applyReality(field: Field)
	field.edited = true
	local params = OverlapParams.new()
	params.MaxParts = FT.realityMaxParts * 4
	local candidates: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(field.center, field.radius, params) do
		if #candidates >= FT.realityMaxParts then
			break
		end
		if not part:IsA("Terrain") and editable(part) and (field.mode ~= "intangible" or not part.Anchored) then
			table.insert(candidates, part)
		end
	end
	local granted = EffectBudget.takeParts(#candidates)
	for i = 1, granted do
		local part = candidates[i]
		if field.mode == "slick" then
			field.ledger[part] = { CustomPhysicalProperties = part.CustomPhysicalProperties }
			local current = part.CurrentPhysicalProperties
			part.CustomPhysicalProperties = PhysicalProperties.new(current.Density, 0, current.Elasticity, 100, current.ElasticityWeight)
		elseif field.mode == "intangible" then
			field.ledger[part] = { CanCollide = part.CanCollide, Anchored = part.Anchored, Transparency = part.Transparency }
			part.CanCollide = false
			part.Anchored = true
			part.Transparency = math.max(part.Transparency, 0.6)
		elseif field.mode == "transmute" then
			local target = TRANSMUTE[part.Material]
			if target then
				field.ledger[part] = { Material = part.Material, Color = part.Color }
				part.Material = target
				part.Color = part.Color:Lerp(Color3.new(1, 1, 1), 0.3)
			end
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

-- One step. Returns the number of things affected (for metrics).
function FieldEffects.step(field: Field, dt: number): number
	centerOf(field)
	if field.kind == "reality" then
		if not field.edited then
			applyReality(field)
		end
		local n = 0
		for _ in field.ledger do
			n += 1
		end
		return n
	end
	local roots, characters = gather(field)
	local present: { [BasePart]: boolean } = {}
	for _, root in roots do
		present[root] = true
	end
	-- Whatever left the field (or fell out of the budget this tick) is released.
	for root in field.inside do
		if not present[root] or not root.Parent then
			release(field, root)
		end
	end
	if field.kind == "time" then
		stepTime(field, roots, characters)
	elseif field.kind == "gravity" then
		stepGravity(field, roots, characters, dt)
	elseif field.kind == "current" then
		stepCurrent(field, roots, characters)
	end
	return #roots
end

function FieldEffects.stop(field: Field)
	for root in field.inside do
		release(field, root)
	end
	for part, values in field.ledger do
		if part.Parent then
			for property, value in values do
				(part :: any)[property] = value
			end
		end
	end
	table.clear(field.ledger)
end

return FieldEffects
