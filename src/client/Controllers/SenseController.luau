--!strict
--[[
	SenseController: draws what a Sense spell shows you (docs/SenseSight.md). The server decides
	what is there and sends it to you alone (remote SenseReveal from Cast/SenseSight); this only
	draws it, for `duration` seconds, then lets it fade. A new reveal of the same kind replaces
	the old one. Nobody else sees any of it.

		heat     warm bodies: an orange glow over each body, drawn on top of walls (AlwaysOnTop);
		         fires, lit lamps, hot things: orange spheres; cold things: pale blue spheres. The
		         world dims and greys a little while it lasts, so the warmth stands out.
		metal    metal parts and people wearing metal: a steel-white glow, on top of walls.
		ley      the seam along the ground in the line's domain colour (Beams between points laid
		         on the terrain), a faint column where a nexus is.
		space    Clairsentience: pale outlines of every body and door, gold ones for containers, on top
		         of walls; the world dims as for heat.
		tracks   footprints on the ground (not through walls), alternating left and right along the
		         way they went, fainter the older they are; people and beasts shaped differently.

	Everything is client-only: HandleAdornments, Attachments and Beams under the camera or on
	Terrain, never parts the server knows about. Cost: at most the server's caps (24 bodies, 40
	spots, 40 metal parts, 160 prints, 8 lines), one transparency update per thing at 30 Hz while
	something is showing, nothing at all otherwise.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Data = require(Shared.Magic.Data.SenseSight)

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local FADE_IN = 0.35
local FADE_OUT = 1.2
local UPDATE_HZ = 30
local LEY_STEP = 6 -- studs between the points a ley seam is laid on
local HEAT = Color3.fromRGB(255, 140, 60)
local HOT = Color3.fromRGB(255, 90, 40)
local COLD = Color3.fromRGB(130, 195, 255)
local STEEL = Color3.fromRGB(200, 222, 240)
local PERSON_PRINT = Color3.fromRGB(245, 232, 190)
local BEAST_PRINT = Color3.fromRGB(205, 232, 175)
local SPACE_BODY = Color3.fromRGB(190, 200, 255) -- Clairsentience (Space): bodies, doors, containers
local SPACE_DOOR = Color3.fromRGB(150, 160, 255)
local SPACE_BOX = Color3.fromRGB(255, 225, 150)

type Item = { inst: Instance, base: number }
type Reveal = { kind: string, started: number, ends: number, items: { Item }, owned: { Instance } }

local SenseController = {
	name = "SenseController",
	dependencies = {},
}

local active: { [string]: Reveal } = {}
local folder: Folder? = nil
local grade: ColorCorrectionEffect? = nil

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "SenseSight"
	made.Parent = workspace.CurrentCamera or workspace
	folder = made
	return made
end

local function setTransparency(inst: Instance, value: number)
	if inst:IsA("HandleAdornment") then
		inst.Transparency = value
	elseif inst:IsA("Beam") then
		inst.Transparency = NumberSequence.new(value)
	end
end

local function clear(kind: string)
	local r = active[kind]
	active[kind] = nil
	if r then
		for _, inst in r.owned do
			inst:Destroy()
		end
	end
end

-- ─── Builders ───────────────────────────────────────────────────────────────

local function rootOf(model: Instance): BasePart?
	if not model:IsA("Model") then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	return if root and root:IsA("BasePart") then root else nil
end

-- A glow over a whole body, following it (adorned to its root, sized from its bounding box).
local function bodyGlow(r: Reveal, model: Instance, color: Color3, base: number)
	local root = rootOf(model)
	if not root then
		return
	end
	local ok, cf, size = pcall(function()
		return (model :: Model):GetBoundingBox()
	end)
	if not ok then
		return
	end
	local box = Instance.new("BoxHandleAdornment")
	box.Adornee = root
	box.CFrame = root.CFrame:ToObjectSpace(cf)
	box.Size = Vector3.new(math.min(size.X, 12), math.min(size.Y, 14), math.min(size.Z, 12))
	box.Color3 = color
	box.AlwaysOnTop = true
	box.ZIndex = 1
	box.Transparency = 1
	box.Parent = folderOf()
	table.insert(r.items, { inst = box, base = base })
	table.insert(r.owned, box)
end

local function partGlow(r: Reveal, part: Instance, color: Color3, base: number)
	if not part:IsA("BasePart") then
		return
	end
	local box = Instance.new("BoxHandleAdornment")
	box.Adornee = part
	box.Size = part.Size
	box.Color3 = color
	box.AlwaysOnTop = true
	box.ZIndex = 0
	box.Transparency = 1
	box.Parent = folderOf()
	table.insert(r.items, { inst = box, base = base })
	table.insert(r.owned, box)
end

local function spot(r: Reveal, position: Vector3, strength: number, cold: boolean)
	local ball = Instance.new("SphereHandleAdornment")
	ball.Adornee = workspace.Terrain
	ball.CFrame = CFrame.new(position)
	ball.Radius = 0.8 + 1.6 * strength
	ball.Color3 = if cold then COLD else HEAT:Lerp(HOT, strength)
	ball.AlwaysOnTop = true
	ball.ZIndex = 1
	ball.Transparency = 1
	ball.Parent = folderOf()
	table.insert(r.items, { inst = ball, base = 0.55 - 0.25 * strength })
	table.insert(r.owned, ball)
end

local function groundY(x: number, z: number, fallback: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(Vector3.new(x, fallback + 200, z), Vector3.new(0, -500, 0), params)
	return if hit then hit.Position.Y else fallback
end

local function leySeam(r: Reveal, a: Vector3, b: Vector3, domain: string, centerY: number)
	local color = Theme.domainColor(domain)
	local length = (Vector2.new(b.X, b.Z) - Vector2.new(a.X, a.Z)).Magnitude
	local steps = math.max(1, math.ceil(length / LEY_STEP))
	local previous: Attachment? = nil
	for i = 0, steps do
		local t = i / steps
		local x, z = a.X + (b.X - a.X) * t, a.Z + (b.Z - a.Z) * t
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = Vector3.new(x, groundY(x, z, centerY) + 0.5, z)
		attachment.Parent = workspace.Terrain
		table.insert(r.owned, attachment)
		if previous then
			for layer = 1, 2 do
				local beam = Instance.new("Beam")
				beam.Attachment0 = previous
				beam.Attachment1 = attachment
				beam.Color = ColorSequence.new(color)
				beam.LightEmission = 1
				beam.LightInfluence = 0
				beam.FaceCamera = true
				beam.Segments = 1
				beam.Width0 = if layer == 1 then 1.2 else 3.5
				beam.Width1 = beam.Width0
				beam.Transparency = NumberSequence.new(1)
				beam.Parent = attachment
				table.insert(r.items, { inst = beam, base = if layer == 1 then 0.15 else 0.7 })
			end
		end
		previous = attachment
	end
end

local function nexusColumn(r: Reveal, position: Vector3, domain: string, strength: number, centerY: number)
	local y = groundY(position.X, position.Z, centerY)
	local column = Instance.new("CylinderHandleAdornment")
	column.Adornee = workspace.Terrain
	column.CFrame = CFrame.new(position.X, y + 20, position.Z) * CFrame.Angles(math.rad(90), 0, 0)
	column.Height = 40
	column.Radius = 1.5 + 2 * math.clamp(strength, 0, 1)
	column.Color3 = Theme.domainColor(domain)
	column.AlwaysOnTop = false
	column.Transparency = 1
	column.Parent = folderOf()
	table.insert(r.items, { inst = column, base = 0.6 })
	table.insert(r.owned, column)
end

local function footprint(r: Reveal, position: Vector3, heading: number, age: number, kind: string, side: number)
	local beast = kind == "beast"
	local mark = Instance.new("BoxHandleAdornment")
	mark.Adornee = workspace.Terrain
	mark.CFrame = CFrame.new(position + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, heading, 0) * CFrame.new(side * (if beast then 0.25 else 0.35), 0, 0)
	mark.Size = if beast then Vector3.new(0.55, 0.06, 0.55) else Vector3.new(0.45, 0.06, 0.95)
	mark.Color3 = if beast then BEAST_PRINT else PERSON_PRINT
	mark.AlwaysOnTop = false
	mark.Transparency = 1
	mark.Parent = folderOf()
	local fade = math.clamp(age / Data.tracks.keepSeconds, 0, 1)
	table.insert(r.items, { inst = mark, base = 0.2 + 0.65 * fade })
	table.insert(r.owned, mark)
end

-- ─── Reveal ─────────────────────────────────────────────────────────────────

local function list(value: any): { any }
	return if typeof(value) == "table" then value else {}
end

local function onReveal(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.kind) ~= "string" or not Data.kinds[payload.kind] then
		return
	end
	local kind = payload.kind
	clear(kind)
	local duration = if typeof(payload.duration) == "number" then math.clamp(payload.duration, 1, Data.duration.max) else 6
	local center = if typeof(payload.center) == "Vector3" then payload.center else Vector3.zero
	local now = os.clock()
	local r: Reveal = { kind = kind, started = now, ends = now + duration, items = {}, owned = {} }
	active[kind] = r

	if kind == "heat" then
		for _, model in list(payload.bodies) do
			if typeof(model) == "Instance" then
				bodyGlow(r, model, HEAT, 0.4)
			end
		end
		for _, s in list(payload.spots) do
			if typeof(s) == "table" and typeof(s.p) == "Vector3" then
				spot(r, s.p, math.clamp(tonumber(s.s) or 0.5, 0, 1), s.cold == true)
			end
		end
	elseif kind == "metal" then
		for _, part in list(payload.parts) do
			if typeof(part) == "Instance" then
				partGlow(r, part, STEEL, 0.5)
			end
		end
		for _, model in list(payload.bodies) do
			if typeof(model) == "Instance" then
				bodyGlow(r, model, STEEL, 0.55)
			end
		end
	elseif kind == "ley" then
		for _, line in list(payload.lines) do
			if typeof(line) == "table" and typeof(line.a) == "Vector3" and typeof(line.b) == "Vector3" then
				leySeam(r, line.a, line.b, tostring(line.d), center.Y)
			end
		end
		for _, n in list(payload.nexuses) do
			if typeof(n) == "table" and typeof(n.p) == "Vector3" then
				nexusColumn(r, n.p, tostring(n.d), tonumber(n.s) or 0.5, center.Y)
			end
		end
	elseif kind == "space" then
		-- Clairsentience: pale outlines of everything that fills the space, on top of walls.
		for _, model in list(payload.bodies) do
			if typeof(model) == "Instance" then
				bodyGlow(r, model, SPACE_BODY, 0.45)
			end
		end
		for _, part in list(payload.doors) do
			if typeof(part) == "Instance" then
				partGlow(r, part, SPACE_DOOR, 0.55)
			end
		end
		for _, part in list(payload.boxes) do
			if typeof(part) == "Instance" then
				partGlow(r, part, SPACE_BOX, 0.4)
			end
		end
	elseif kind == "tracks" then
		for index, p in list(payload.prints) do
			if typeof(p) == "table" and typeof(p.p) == "Vector3" then
				footprint(r, p.p, tonumber(p.h) or 0, tonumber(p.age) or 0, tostring(p.k), if index % 2 == 0 then 1 else -1)
			end
		end
	end
end

-- ─── Fading ─────────────────────────────────────────────────────────────────

local function update()
	local now = os.clock()
	local seeThrough = 0 -- how strongly heat or metal sight is on (dims the world)
	for kind, r in active do
		if now >= r.ends then
			clear(kind)
			continue
		end
		local alpha = math.min(1, (now - r.started) / FADE_IN, (r.ends - now) / FADE_OUT)
		for _, item in r.items do
			setTransparency(item.inst, 1 - (1 - item.base) * alpha)
		end
		if kind == "heat" or kind == "metal" or kind == "space" then
			seeThrough = math.max(seeThrough, alpha)
		end
	end
	local g = grade
	if g then
		g.Enabled = seeThrough > 0.01
		g.Saturation = -0.55 * seeThrough
		g.Brightness = -0.08 * seeThrough
		g.Contrast = 0.1 * seeThrough
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function SenseController.init(_self: any, _ctx: any) end

function SenseController.start(_self: any, _ctx: any)
	local g = Instance.new("ColorCorrectionEffect")
	g.Name = "SenseSight"
	g.Enabled = false
	g.Parent = Lighting
	grade = g

	Net.listen("SenseReveal", onReveal)

	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		if next(active) == nil then
			local gg = grade
			if gg and gg.Enabled then
				gg.Enabled = false
			end
			return
		end
		elapsed += dt
		if elapsed >= 1 / UPDATE_HZ then
			elapsed = 0
			update()
		end
	end)
end

return SenseController
