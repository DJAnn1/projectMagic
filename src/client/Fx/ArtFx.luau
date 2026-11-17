--!strict
--[[
	ArtFx: what every domain's spell module draws with (Fx/EnergyFx, Fx/EarthFx...), and the lasting
	bodies they leave (Server/Magic/Cast/ArtRuntime: parts tagged "ArtBody", attribute ArtLook).

	Helpers: part, seq, emitter, burst, fadeOut, rootOf, flatDisc, bolt (jagged lightning), sound.
	Bodies: a domain module registers builders by look (ArtFx.register); while the server's part exists
	its Visual is drawn and stepped every frame:
		fixed     the root never moves (rings, fences, mirrors)
		ownPlace  the builder's update places it (v.extra.at: the shadow puppet stands behind you)
		follower  (an ObjectValue "Model" on the part) drawn at that body's root, smoothly
		else      eased toward the server's part (a drifting ball, a rolling boulder)
	Reduce spell effects thins particles (ArtFx.rate).
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)
local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)

local TEX = DomainFx.textures
local UP = Vector3.new(0, 1, 0)

local ArtFx = {}

ArtFx.TAG = "ArtBody"
ArtFx.textures = TEX

local rng = Random.new()

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function rate(n: number): number
	return if reduced() then n * 0.35 else n
end

local function holder(): Instance
	return workspace:FindFirstChild("MagicFx") or workspace
end

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = "EnergyFx"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Size = Vector3.one * 0.4
	for k, v in props do
		(p :: any)[k] = v
	end
	if not props.Parent then
		p.Parent = holder()
	end
	return p
end

local function seq(...: number): NumberSequence
	return FxLayers.seq(...)
end

-- A plain (unpooled) emitter: bodies own theirs and are destroyed with them.
local function emitter(parent: Instance, spec: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = spec.texture or TEX.sparkles
	e.Color = spec.color or ColorSequence.new(Color3.new(1, 1, 1))
	e.Size = spec.size or seq(0, 1, 1, 0)
	e.Transparency = spec.transparency or seq(0, 0, 1, 1)
	e.Lifetime = spec.lifetime or NumberRange.new(0.5, 1)
	e.Speed = spec.speed or NumberRange.new(0)
	local spread = spec.spread or 0
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = spec.rotSpeed or NumberRange.new(-40, 40)
	e.Acceleration = spec.acceleration or Vector3.zero
	e.Drag = spec.drag or 0
	e.LightEmission = spec.emission or 1
	e.LightInfluence = 0
	e.Shape = spec.shape or Enum.ParticleEmitterShape.Box
	e.ShapeStyle = spec.style or Enum.ParticleEmitterShapeStyle.Volume
	e.EmissionDirection = spec.direction or Enum.NormalId.Top
	e.Rate = rate(spec.rate or 10)
	e.LockedToPart = spec.locked == true
	e.ZOffset = spec.zOffset or 0
	e.Parent = parent
	return e
end

local function burst(position: Vector3, spec: { [string]: any }, count: number, life: number?)
	local p = part({ Transparency = 1, Size = spec.box or Vector3.one, CFrame = CFrame.new(position) })
	local e = emitter(p, spec)
	e.Rate = 0
	e:Emit(math.max(1, math.floor(rate(count))))
	Debris:AddItem(p, life or 2)
end

local function fadeOut(p: BasePart, seconds: number, grow: Vector3?)
	local goal: { [string]: any } = { Transparency = 1 }
	if grow then
		goal.Size = grow
	end
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	Debris:AddItem(p, seconds + 0.05)
end

local function rootOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function flatDisc(center: Vector3, radius: number, color: Color3, transparency: number, material: Enum.Material?): Part
	return part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, radius * 2, radius * 2),
		CFrame = CFrame.new(center + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Transparency = transparency,
		Material = material or Enum.Material.Neon,
	})
end

-- A jagged bolt of lightning between two points, gone in a blink.
local function bolt(a: Vector3, b: Vector3, color: Color3, width: number, life: number)
	local d = b - a
	local length = d.Magnitude
	if length < 0.2 then
		return
	end
	local n = math.clamp(math.floor(length / 3), 3, 12)
	local side = d:Cross(UP)
	side = if side.Magnitude > 0.01 then side.Unit else Vector3.new(1, 0, 0)
	local up2 = side:Cross(d.Unit)
	local prev = a
	for i = 1, n do
		local t = i / n
		local point = a + d * t
		if i < n then
			local jitter = length * 0.06
			point += side * rng:NextNumber(-jitter, jitter) + up2 * rng:NextNumber(-jitter, jitter)
		end
		local seg = point - prev
		local p = part({
			Size = Vector3.new(width, width, seg.Magnitude),
			CFrame = CFrame.lookAt(prev + seg / 2, point),
			Color = color,
		})
		fadeOut(p, life)
		prev = point
	end
	FxLayers.light(a:Lerp(b, 0.5), color, 3, math.clamp(length, 8, 24), life + 0.1, 0.5)
end

local function sound(position: Vector3, domain: string, property: string, which: string, volume: number?)
	local look = DomainFx.look(domain, property)
	local s = (look.sounds :: any)[which]
	if s then
		FxLayers.sound(position, s, volume or 0.7)
	end
end

-- ─── Bodies ─────────────────────────────────────────────────────────────────

export type Visual = {
	part: BasePart, -- the server's body part
	root: Part, -- our own, moved every frame
	model: Model?, -- a follower's body
	look: string,
	extra: { [string]: any }, -- state a look keeps between frames
	owned: { Instance }, -- everything it made, destroyed with it
	update: ((Visual, number) -> ())?,
	fixed: boolean?, -- the root never moves
	ownPlace: boolean?, -- the update places it (v.extra.at)
}

local function own<T>(v: Visual, inst: T): T
	table.insert(v.owned, inst :: any)
	return inst
end

local visuals: { [BasePart]: Visual } = {}

local function anchorPart(at: CFrame): Part
	return part({ Transparency = 1, Size = Vector3.one, CFrame = at })
end

local function linked(bodyPart: BasePart, name: string): Instance?
	local v = bodyPart:FindFirstChild(name)
	return if v and v:IsA("ObjectValue") then v.Value else nil
end

local function limb(model: Model, names: { string }): BasePart?
	for _, n in names do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local BUILD: { [string]: (Visual) -> () } = {}

-- A domain's builders, by look (the server's ArtLook).
function ArtFx.register(builders: { [string]: (Visual) -> () })
	for look, fn in builders do
		BUILD[look] = fn
	end
end

local function cleanup(v: Visual)
	v.root:Destroy()
	for _, inst in v.owned do
		inst:Destroy()
	end
	table.clear(v.owned)
end

local function build(bodyPart: Instance)
	if not bodyPart:IsA("BasePart") or visuals[bodyPart] then
		return
	end
	local look = bodyPart:GetAttribute("ArtLook")
	local builder = if typeof(look) == "string" then BUILD[look] else nil
	if not builder then
		return
	end
	local model = linked(bodyPart, "Model")
	local v: Visual = {
		part = bodyPart,
		root = anchorPart(bodyPart.CFrame),
		model = if model and model:IsA("Model") then model else nil,
		look = look :: string,
		extra = {},
		owned = {},
	}
	visuals[bodyPart] = v
	local ok, err = pcall(builder, v)
	if not ok then
		warn("[ArtFx] " .. tostring(look) .. ": " .. tostring(err))
	end
end

local function unbuild(bodyPart: Instance)
	local v = if bodyPart:IsA("BasePart") then visuals[bodyPart :: BasePart] else nil
	if v then
		visuals[bodyPart :: BasePart] = nil
		cleanup(v)
	end
end

local function step(dt: number)
	for bodyPart, v in visuals do
		if not bodyPart.Parent then
			visuals[bodyPart] = nil
			cleanup(v)
			continue
		end
		-- Followers stand where their body is now; free bodies ease toward the server's part.
		local root = v.model and rootOf(v.model)
		if v.ownPlace and not v.fixed then
			-- Its own place (the update eases it there); the root rides along.
			v.root.CFrame = CFrame.new(v.extra.at or (if root then root.Position else bodyPart.Position))
		elseif root and not v.fixed then
			v.root.CFrame = CFrame.new(root.Position)
		elseif not v.fixed then
			v.root.CFrame = v.root.CFrame:Lerp(CFrame.new(bodyPart.Position), math.clamp(dt * 10, 0, 1))
		end
		if v.update then
			local ok, err = pcall(v.update, v, dt)
			if not ok then
				v.update = nil
				warn("[ArtFx] " .. v.look .. ": " .. tostring(err))
			end
		end
	end
end

-- ─── Bolt bodies (SpellFx.launch) ───────────────────────────────────────────

-- A route's own bolt look (Data/EffectLibrary `look`), by name. fn(anchor, coreSize) -> (stop?, weave?)
type FlightFn = (Part, number) -> ((() -> ())?, number?)
local FLIGHTS: { [string]: FlightFn } = {}

function ArtFx.registerFlights(looks: { [string]: FlightFn })
	for look, fn in looks do
		FLIGHTS[look] = fn
	end
end

-- Dresses a flying bolt in its route's look. Returns a stop function (called when it lands) and,
-- for a winding flight, how far it weaves.
function ArtFx.flight(look: string, anchor: Part, coreSize: number): ((() -> ())?, number?)
	local fn = FLIGHTS[look]
	if not fn then
		return nil, nil
	end
	local ok, stop, weave = pcall(fn, anchor, coreSize)
	if not ok then
		warn("[ArtFx] flight " .. look .. ": " .. tostring(stop))
		return nil, nil
	end
	return stop, weave
end

function ArtFx.start()
	for _, p in CollectionService:GetTagged(ArtFx.TAG) do
		task.spawn(build, p)
	end
	CollectionService:GetInstanceAddedSignal(ArtFx.TAG):Connect(function(p)
		-- Attributes and links arrive with the part; give them a frame in case they lag.
		task.defer(build, p)
	end)
	CollectionService:GetInstanceRemovedSignal(ArtFx.TAG):Connect(unbuild)
	RunService.RenderStepped:Connect(step)
end

ArtFx.reduced = reduced
ArtFx.rate = rate
ArtFx.holder = holder
ArtFx.part = part
ArtFx.seq = seq
ArtFx.emitter = emitter
ArtFx.burst = burst
ArtFx.fadeOut = fadeOut
ArtFx.rootOf = rootOf
ArtFx.flatDisc = flatDisc
ArtFx.bolt = bolt
ArtFx.sound = sound
ArtFx.own = own
ArtFx.anchorPart = anchorPart
ArtFx.linked = linked
ArtFx.limb = limb

return ArtFx
