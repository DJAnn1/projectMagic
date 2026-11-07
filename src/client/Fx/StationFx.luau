--!strict
--[[
	StationFx: stations that visibly change while someone uses them, drawn on this client from the
	attributes ActivityService sets (Shared/Life/Data/StationTypes.ATTR). docs/Activities.md §2, §4.

		anvil   a blade on the anvil that lengthens with the work and cools when it's done; sparks on
		        every blow (ActivityController calls strike() when the smith's hammer lands)
		forge   the coals flare, embers rise, smoke leaves the stack
		hearth  a fire in the hearth, a pot over it, warm light, smoke from the chimney
		desk    an open book and a lit candle that flickers
		altar   faint motes of light over the altar while someone prays

	DISTANCE  near (FULL_RANGE): everything. Far (SMOKE_RANGE): only chimney and forge smoke, so a town
	          seen from a hill shows which hearths and forges are going. Further: nothing.
	BUDGETS   lights, emitters and smoke columns are capped, nearest first. Reduced effects halves them.

		StationFx.track(part) · untrack(part)
		StationFx.step(cameraPosition, now, quality)   ~5 Hz
		StationFx.strike(stationId)
		StationFx.partFor(stationId) -> BasePart?
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local StationTypes = require(Shared.Life.Data.StationTypes)
local ActivityLibrary = require(Shared.Life.Data.ActivityLibrary)

local KenneyTextures = require(script.Parent.KenneyTextures)

local A = StationTypes.ATTR
local rgb = Color3.fromRGB
local FULL_RANGE = 120
local SMOKE_RANGE = 700
local CAPS = { lights = 8, emitters = 24, smoke = 14 }

type Look = { parts: { BasePart }, emitters: { [string]: ParticleEmitter }, lights: { PointLight }, data: { [string]: any } }

type Entry = {
	part: BasePart,
	kind: string,
	id: string,
	building: Model?,
	look: Look?,
	smoke: ParticleEmitter?,
	smokeAnchor: Attachment?,
	boosted: { [PointLight]: number }?,
	noSmoke: boolean?, -- no chimney or stack found: don't look again
}

local entries: { [BasePart]: Entry } = {}
local byId: { [string]: Entry } = {}

local StationFx = {}

local folder: Folder? = nil
local function fxFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "StationFx"
	f.Parent = workspace
	folder = f
	return f
end

local function buildingOf(part: BasePart): Model?
	local node: Instance? = part.Parent
	while node and node ~= workspace do
		if node:IsA("Model") and node:GetAttribute("LotId") then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function newPart(look: Look, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	if shape then
		p.Shape = shape
	end
	p.Parent = fxFolder()
	table.insert(look.parts, p)
	return p
end

local function newEmitter(look: Look, name: string, parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.LightInfluence = 0
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	look.emitters[name] = e
	return e
end

local function newLight(look: Look, parent: Instance, color: Color3, range: number, brightness: number): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
	table.insert(look.lights, l)
	return l
end

-- The side of a station people work from: towards its first use point, else the building's middle.
local function workSide(e: Entry): Vector3
	local point = e.part:FindFirstChild("UsePoint1")
	local toward = if point and point:IsA("Attachment") then point.WorldPosition elseif e.building then e.building:GetPivot().Position else e.part.Position + e.part.CFrame.LookVector
	local d = Vector3.new(toward.X - e.part.Position.X, 0, toward.Z - e.part.Position.Z)
	return if d.Magnitude > 0.01 then d.Unit else e.part.CFrame.LookVector
end

local function topOf(part: BasePart): Vector3
	return part.Position + Vector3.new(0, part.Size.Y / 2, 0)
end

local function findNear(model: Model?, names: { string }, near: Vector3, reach: number): BasePart?
	if not model then
		return nil
	end
	local best, bestD = nil :: BasePart?, reach
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and table.find(names, d.Name) then
			local dist = Vector3.new(d.Position.X - near.X, 0, d.Position.Z - near.Z).Magnitude
			if dist < bestD then
				best, bestD = d, dist
			end
		end
	end
	return best
end

-- ─── Looks ──────────────────────────────────────────────────────────────────

local builders: { [string]: (Entry, Look) -> () } = {}

builders.anvil = function(e, look)
	local top = topOf(e.part)
	local blade = newPart(look, Vector3.new(0.5, 0.12, 0.5), CFrame.new(top + Vector3.new(0, 0.06, 0)) * e.part.CFrame.Rotation, rgb(255, 140, 50), Enum.Material.Neon)
	look.data.blade = blade
	local a = Instance.new("Attachment")
	a.Parent = blade
	newEmitter(look, "Sparks", a, {
		Texture = KenneyTextures.spark_05, Color = ColorSequence.new(rgb(255, 230, 160), rgb(255, 120, 40)),
		Size = NumberSequence.new(0.35, 0.05), Lifetime = NumberRange.new(0.25, 0.5), Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(75, 75), Acceleration = Vector3.new(0, -40, 0), LightEmission = 1, Rate = 0,
	})
end

builders.forge = function(e, look)
	local coals = findNear(e.building, { "Coals" }, e.part.Position, 4)
	local over = if coals then topOf(coals) else topOf(e.part)
	local anchor = newPart(look, Vector3.new(2.6, 0.2, 2.6), CFrame.new(over), rgb(0, 0, 0), Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	local a = Instance.new("Attachment")
	a.Parent = anchor
	newEmitter(look, "Embers", a, {
		Texture = KenneyTextures.spark_01, Color = ColorSequence.new(rgb(255, 190, 90), rgb(255, 90, 30)),
		Size = NumberSequence.new(0.18, 0.02), Lifetime = NumberRange.new(1, 2), Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(20, 20), Acceleration = Vector3.new(0, 2, 0), LightEmission = 1, Rate = 14,
	})
	if coals then
		local light = coals:FindFirstChildOfClass("PointLight")
		if light then
			e.boosted = { [light] = light.Brightness }
			light.Brightness = light.Brightness * 2.2
		end
		look.data.coals = coals
		look.data.coalColor = coals.Color
		coals.Color = rgb(255, 160, 60)
	end
end

builders.hearth = function(e, look)
	local side = workSide(e)
	local face = e.part.Position + side * (e.part.Size.X / 2 + 0.35) - Vector3.new(0, e.part.Size.Y / 2 - 0.4, 0)
	local base = newPart(look, Vector3.new(0.6, 0.2, 1.4), CFrame.lookAt(face, face + side), rgb(40, 30, 26), Enum.Material.Slate)
	local a = Instance.new("Attachment")
	a.Position = Vector3.new(0, 0.2, 0)
	a.Parent = base
	newEmitter(look, "Fire", a, {
		Texture = KenneyTextures.flame_02, Color = ColorSequence.new(rgb(255, 210, 120), rgb(255, 90, 30)),
		Size = NumberSequence.new(0.9, 0.1), Lifetime = NumberRange.new(0.4, 0.7), Speed = NumberRange.new(1, 2),
		Acceleration = Vector3.new(0, 3, 0), LightEmission = 1, Rate = 22, Transparency = NumberSequence.new(0.1, 1),
	})
	newLight(look, base, rgb(255, 150, 70), 14, 1.8)
	local pot = newPart(look, Vector3.new(0.9, 1, 1), CFrame.new(face + Vector3.new(0, 0.9, 0)) * CFrame.Angles(0, 0, math.rad(90)), rgb(46, 46, 50), Enum.Material.Metal, Enum.PartType.Cylinder)
	local steam = Instance.new("Attachment")
	steam.Position = Vector3.new(0.5, 0, 0)
	steam.Parent = pot
	newEmitter(look, "Steam", steam, {
		Texture = KenneyTextures.smoke_04, Color = ColorSequence.new(rgb(240, 240, 240)), Size = NumberSequence.new(0.4, 1.4),
		Lifetime = NumberRange.new(1, 1.8), Speed = NumberRange.new(1, 2), Transparency = NumberSequence.new(0.6, 1),
		LightInfluence = 1, Rate = 5, EmissionDirection = Enum.NormalId.Right,
	})
end

builders.desk = function(e, look)
	local top = topOf(e.part)
	local rot = e.part.CFrame.Rotation
	local side = workSide(e)
	-- The book faces the reader: open, two pages.
	local bookAt = CFrame.lookAt(top + Vector3.new(0, 0.05, 0), top + Vector3.new(0, 0.05, 0) + side)
	newPart(look, Vector3.new(0.7, 0.06, 0.9), bookAt * CFrame.new(-0.36, 0, 0) * CFrame.Angles(0, 0, math.rad(6)), rgb(244, 236, 214), Enum.Material.SmoothPlastic)
	newPart(look, Vector3.new(0.7, 0.06, 0.9), bookAt * CFrame.new(0.36, 0, 0) * CFrame.Angles(0, 0, math.rad(-6)), rgb(244, 236, 214), Enum.Material.SmoothPlastic)
	newPart(look, Vector3.new(1.5, 0.04, 1), bookAt * CFrame.new(0, -0.04, 0), rgb(110, 40, 36), Enum.Material.Fabric)
	local candleAt = CFrame.new(top) * rot * CFrame.new(0, 0.3, -1.1)
	newPart(look, Vector3.new(0.6, 0.22, 0.22), candleAt * CFrame.Angles(0, 0, math.rad(90)), rgb(240, 232, 210), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	local flame = newPart(look, Vector3.new(0.12, 0.22, 0.12), candleAt * CFrame.new(0, 0.42, 0), rgb(255, 200, 110), Enum.Material.Neon, Enum.PartType.Ball)
	look.data.flame = flame
	look.data.candleLight = newLight(look, flame, rgb(255, 190, 110), 9, 0.9)
end

builders.altar = function(e, look)
	local top = topOf(e.part)
	local anchor = newPart(look, Vector3.new(2, 0.2, 2), CFrame.new(top + Vector3.new(0, 0.3, 0)), rgb(0, 0, 0), Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	local a = Instance.new("Attachment")
	a.Parent = anchor
	newEmitter(look, "Motes", a, {
		Texture = KenneyTextures.light_01, Color = ColorSequence.new(rgb(255, 240, 200)), Size = NumberSequence.new(0.25, 0),
		Lifetime = NumberRange.new(2, 3.5), Speed = NumberRange.new(0.3, 0.8), SpreadAngle = Vector2.new(180, 180),
		LightEmission = 1, Rate = 6, Transparency = NumberSequence.new(0.2, 1),
	})
end

local function dropLook(e: Entry)
	local look = e.look
	if not look then
		return
	end
	for _, p in look.parts do
		p:Destroy()
	end
	if e.boosted then
		for light, brightness in e.boosted do
			light.Brightness = brightness
		end
		e.boosted = nil
	end
	local coals = look.data.coals
	if coals and look.data.coalColor then
		coals.Color = look.data.coalColor
	end
	e.look = nil
end

local function smokeSource(e: Entry): Vector3?
	if e.kind == "forge" then
		local stack = findNear(e.building, { "ForgeStack" }, e.part.Position, 3)
		return if stack then topOf(stack) else nil
	elseif e.kind == "hearth" then
		local cap = findNear(e.building, { "ChimneyCap" }, e.part.Position, 6)
		return if cap then topOf(cap) else nil
	end
	return nil
end

local function dropSmoke(e: Entry)
	if e.smokeAnchor then
		local p = e.smokeAnchor.Parent
		if p then
			p:Destroy()
		end
	end
	e.smoke, e.smokeAnchor = nil, nil
end

local function makeSmoke(e: Entry): boolean
	local at = smokeSource(e)
	if not at then
		return false
	end
	local p = Instance.new("Part")
	p.Size = Vector3.new(1, 1, 1)
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide, p.CanTouch, p.CanQuery = false, false, false
	p.CFrame = CFrame.new(at + Vector3.new(0, 0.5, 0))
	p.Parent = fxFolder()
	local a = Instance.new("Attachment")
	a.Parent = p
	local s = Instance.new("ParticleEmitter")
	s.Texture = KenneyTextures.smoke_07
	s.Color = ColorSequence.new(rgb(150, 146, 140), rgb(200, 198, 194))
	s.Size = NumberSequence.new(1.2, 6)
	s.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	s.Lifetime = NumberRange.new(5, 8)
	s.Speed = NumberRange.new(2.5, 4)
	s.Acceleration = Vector3.new(1.2, 0.6, 0.4)
	s.SpreadAngle = Vector2.new(8, 8)
	s.RotSpeed = NumberRange.new(-20, 20)
	s.Rate = if e.kind == "forge" then 3 else 2
	s.LightInfluence = 1
	s.Parent = a
	e.smoke, e.smokeAnchor = s, a
	return true
end

-- ─── Tracking ───────────────────────────────────────────────────────────────

function StationFx.track(part: Instance)
	if not part:IsA("BasePart") or entries[part] then
		return
	end
	local kind = part:GetAttribute(A.kind)
	local id = part:GetAttribute(A.id)
	if typeof(kind) ~= "string" or typeof(id) ~= "string" or not StationTypes.types[kind] then
		return
	end
	local e: Entry = { part = part, kind = kind, id = id, building = buildingOf(part), look = nil, smoke = nil, smokeAnchor = nil, boosted = nil, noSmoke = nil }
	entries[part] = e
	byId[id] = e
end

function StationFx.untrack(part: Instance)
	local e = entries[part :: BasePart]
	if not e then
		return
	end
	dropLook(e)
	dropSmoke(e)
	entries[part :: BasePart] = nil
	if byId[e.id] == e then
		byId[e.id] = nil
	end
end

function StationFx.partFor(id: string): BasePart?
	local e = byId[id]
	return e and e.part
end

function StationFx.strike(id: string)
	local e = byId[id]
	local look = e and e.look
	local sparks = look and look.emitters.Sparks
	if sparks then
		sparks:Emit(14)
	end
end

local function progressOf(e: Entry, now: number): number
	local index, start, duration = StationTypes.decodeWork(e.part:GetAttribute(A.work))
	if not index or not ActivityLibrary.byIndex[index] then
		return 0
	end
	local elapsed = math.max(0, now - start)
	return (elapsed % duration) / duration
end

-- quality: 1 normal, 0.5 reduced (mobile, reduced effects).
function StationFx.step(camera: Vector3, now: number, quality: number)
	local near: { { e: Entry, d: number } } = {}
	local far: { { e: Entry, d: number } } = {}
	for part, e in entries do
		if not part.Parent then
			StationFx.untrack(part)
			continue
		end
		local active = part:GetAttribute(A.active) == true
		local d = (part.Position - camera).Magnitude
		if active and d <= FULL_RANGE and builders[e.kind] then
			table.insert(near, { e = e, d = d })
		elseif e.look then
			dropLook(e)
		end
		if active and d <= SMOKE_RANGE and (e.kind == "forge" or e.kind == "hearth") then
			table.insert(far, { e = e, d = d })
		elseif e.smoke then
			dropSmoke(e)
		end
	end
	table.sort(near, function(a, b)
		return a.d < b.d
	end)
	table.sort(far, function(a, b)
		return a.d < b.d
	end)
	local lights, emitters = 0, 0
	local maxLights, maxEmitters = math.floor(CAPS.lights * quality), math.floor(CAPS.emitters * quality)
	for _, item in near do
		local e = item.e
		if not e.look then
			if emitters >= maxEmitters then
				continue
			end
			local look: Look = { parts = {}, emitters = {}, lights = {}, data = {} }
			e.look = look
			builders[e.kind](e, look)
		end
		local look = e.look :: Look
		for _ in look.emitters do
			emitters += 1
		end
		for _, l in look.lights do
			lights += 1
			l.Enabled = lights <= maxLights
		end
		-- Per-kind live changes.
		if e.kind == "anvil" then
			local p = progressOf(e, now)
			local blade: BasePart? = look.data.blade
			if blade then
				local len = 0.5 + 2.2 * p
				blade.Size = Vector3.new(len, 0.12, 0.42)
				local done = p > 0.85
				blade.Material = if done then Enum.Material.Metal else Enum.Material.Neon
				blade.Color = if done then rgb(120, 120, 128) else rgb(255, 120 + math.floor(80 * p), 50)
			end
		elseif e.kind == "desk" then
			local light: PointLight? = look.data.candleLight
			if light then
				light.Brightness = 0.8 + math.noise(now * 3, e.part.Position.X) * 0.35
			end
		end
	end
	local maxSmoke = math.floor(CAPS.smoke * quality)
	for i, item in far do
		local e = item.e
		if i <= maxSmoke then
			if not e.smoke and not e.noSmoke and not makeSmoke(e) then
				e.noSmoke = true
			end
		elseif e.smoke then
			dropSmoke(e)
		end
	end
end

function StationFx.counts(): (number, number)
	local looks, smokes = 0, 0
	for _, e in entries do
		if e.look then
			looks += 1
		end
		if e.smoke then
			smokes += 1
		end
	end
	return looks, smokes
end

return StationFx
