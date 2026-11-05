--!strict
--[[
	FxPool: reuse instead of Instance.new for every spell. Creating and destroying emitters is
	the main client cost of magic-heavy scenes, so everything visual comes from here:

		FxPool.anchor(cframe, size?) -> Part?     an invisible, non-colliding, non-queryable anchor
		                                          part (with an Attachment child "A")
		FxPool.emitter(parent) -> ParticleEmitter?
		FxPool.beam(parent) -> Beam?    FxPool.trail(parent) -> Trail?    FxPool.light(parent) -> PointLight?
		FxPool.release(anchor)          returns the anchor AND everything parented to it
		FxPool.releaseAfter(anchor, seconds)

	Caps (live at once, scaled down on low-end devices by SpellFx): beyond them acquire returns
	nil and the effect is simply skipped, so a crowded fight degrades instead of stuttering.
	Everything lives in workspace.MagicFx, created by this client, so none of it replicates.
	Released objects are hidden (Enabled false / Parent pool folder) and reset on next use.
]]

local MAX_ANCHORS = 160
local MAX_EMITTERS = 280
local MAX_BEAMS = 40
local MAX_TRAILS = 40
local MAX_LIGHTS = 14 -- PointLights are the costliest thing here: a hard global budget

local FxPool = {}

local root = Instance.new("Folder")
root.Name = "MagicFx"
root.Parent = workspace
local spare = Instance.new("Folder") -- unparented: pooled objects sit here, outside the world
spare.Name = "Pool"

local free: { [string]: { Instance } } = { anchor = {}, emitter = {}, beam = {}, trail = {}, light = {} }
local live: { [string]: number } = { anchor = 0, emitter = 0, beam = 0, trail = 0, light = 0 }
local caps: { [string]: number } = { anchor = MAX_ANCHORS, emitter = MAX_EMITTERS, beam = MAX_BEAMS, trail = MAX_TRAILS, light = MAX_LIGHTS }
local scale = 1

-- Low-end devices get proportionally smaller caps.
function FxPool.setScale(s: number)
	scale = math.clamp(s, 0.2, 1)
end

local function take(kind: string, make: () -> Instance): Instance?
	if live[kind] >= math.max(4, math.floor(caps[kind] * scale)) then
		return nil
	end
	live[kind] += 1
	local list = free[kind]
	local item = table.remove(list)
	return item or make()
end

local function give(kind: string, item: Instance)
	live[kind] = math.max(0, live[kind] - 1)
	item.Parent = spare
	table.insert(free[kind], item)
end

function FxPool.anchor(cframe: CFrame, size: Vector3?): Part?
	local part = take("anchor", function(): Instance
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Transparency = 1
		p.Material = Enum.Material.SmoothPlastic
		local a = Instance.new("Attachment")
		a.Name = "A"
		a.Parent = p
		return p
	end) :: Part?
	if not part then
		return nil
	end
	-- Full reset: a recycled anchor may have been a Neon bolt core or a flash sphere.
	part.Size = size or Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = cframe
	part.Transparency = 1
	part.Shape = Enum.PartType.Block
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.new(1, 1, 1);
	(part:FindFirstChild("A") :: Attachment).Position = Vector3.zero -- projectiles offset it
	part:SetAttribute("Fx", true)
	part.Parent = root
	return part
end

function FxPool.emitter(parent: Instance): ParticleEmitter?
	local e = take("emitter", function(): Instance
		return Instance.new("ParticleEmitter")
	end) :: ParticleEmitter?
	if not e then
		return nil
	end
	e.Enabled = false
	e:Clear()
	-- Reset what layers set beyond SpellFx.configure (flat ground marks, inward charge-ups).
	e.Orientation = Enum.ParticleOrientation.FacingCamera
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.LockedToPart = false
	e.Acceleration = Vector3.zero
	e.Drag = 0
	e.VelocityInheritance = 0
	e.Brightness = 1
	e.EmissionDirection = Enum.NormalId.Top
	e.Rate = 0
	e.Parent = parent
	return e
end

function FxPool.beam(parent: Instance): Beam?
	local b = take("beam", function(): Instance
		return Instance.new("Beam")
	end) :: Beam?
	if b then
		-- Reset what only some users set (lightning brightens and stretches its textures).
		b.Brightness = 1
		b.ZOffset = 0
		b.Texture = ""
		b.TextureMode = Enum.TextureMode.Wrap
		b.TextureLength = 1
		b.TextureSpeed = 0
		b.CurveSize0, b.CurveSize1 = 0, 0
		b.Enabled = true
		b.Parent = parent
	end
	return b
end

function FxPool.trail(parent: Instance): Trail?
	local t = take("trail", function(): Instance
		return Instance.new("Trail")
	end) :: Trail?
	if t then
		t.Texture = ""
		t.TextureMode = Enum.TextureMode.Stretch
		t.TextureLength = 1
		t.Brightness = 1
		t.Enabled = true
		t.Parent = parent
	end
	return t
end

-- A PointLight under `parent`, or nil when the light budget is spent (the effect goes unlit).
function FxPool.light(parent: Instance): PointLight?
	local l = take("light", function(): Instance
		local light = Instance.new("PointLight")
		light.Shadows = false
		return light
	end) :: PointLight?
	if l then
		l.Enabled = true
		l.Brightness = 0
		l.Parent = parent
	end
	return l
end

-- Returns an anchor and every pooled thing under it.
function FxPool.release(anchor: Part)
	if not anchor:GetAttribute("Fx") then
		return
	end
	anchor:SetAttribute("Fx", nil)
	for _, child in anchor:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child.Enabled = false
			give("emitter", child)
		elseif child:IsA("Beam") then
			child.Enabled = false
			give("beam", child)
		elseif child:IsA("Trail") then
			child.Enabled = false
			give("trail", child)
		elseif child:IsA("PointLight") then
			child.Enabled = false
			give("light", child)
		elseif child:IsA("Attachment") and child.Name ~= "A" then
			child:Destroy() -- extra attachments (beam ends) aren't pooled
		end
	end
	give("anchor", anchor)
end

function FxPool.releaseAfter(anchor: Part, seconds: number)
	task.delay(seconds, function()
		FxPool.release(anchor)
	end)
end

function FxPool.stats(): { [string]: number }
	return table.clone(live)
end

return FxPool
