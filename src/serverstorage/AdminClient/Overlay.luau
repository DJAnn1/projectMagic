--!strict
--[[
	Overlay: draws the admin panel's debug layers with LOCAL parts (created on this client only,
	so nobody else sees them and the server never pays for them). One folder per layer under
	workspace.AdminOverlay; applying a layer again replaces it.

		Overlay.apply(data)   data = the server's overlay payload (Admin/Commands/Overlays)
		Overlay.clear(layer?) one layer, or all of them
		Overlay.active()      { [layer] = radius } for live layers the panel refreshes
]]

local Overlay = {}

local root: Folder? = nil
local layers: { [string]: Folder } = {}
local live: { [string]: number } = {}

local DOMAIN_COLORS: { [string]: Color3 } = {
	energy = Color3.fromRGB(255, 140, 40), earth = Color3.fromRGB(150, 110, 70), water = Color3.fromRGB(60, 140, 255),
	air = Color3.fromRGB(200, 235, 255), life = Color3.fromRGB(80, 200, 90), mind = Color3.fromRGB(190, 120, 255),
	spirit = Color3.fromRGB(255, 240, 160), void = Color3.fromRGB(70, 40, 110), space = Color3.fromRGB(40, 60, 140),
	time = Color3.fromRGB(230, 200, 90), gravity = Color3.fromRGB(120, 90, 160), reality = Color3.fromRGB(255, 90, 200),
}
local TIER_COLORS = { [0] = Color3.fromRGB(80, 220, 120), [1] = Color3.fromRGB(240, 210, 70), [2] = Color3.fromRGB(150, 150, 150) }

local function folderFor(layer: string): Folder
	if not root or not root.Parent then
		local f = Instance.new("Folder")
		f.Name = "AdminOverlay"
		f.Parent = workspace
		root = f
	end
	local existing = layers[layer]
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = layer
	folder.Parent = root
	layers[layer] = folder
	return folder
end

local function part(parent: Instance, size: Vector3, cframe: CFrame, color: Color3, transparency: number, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Transparency = transparency
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function label(parent: BasePart, text: string)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 24)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 600
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.3
	t.Font = Enum.Font.Code
	t.TextScaled = true
	t.Text = text
	t.Parent = billboard
	billboard.Parent = parent
end

-- A straight bar between two points.
local function bar(parent: Instance, a: Vector3, b: Vector3, width: number, color: Color3, transparency: number)
	local length = (b - a).Magnitude
	if length < 0.1 then
		return
	end
	part(parent, Vector3.new(width, width, length), CFrame.lookAt((a + b) / 2, b), color, transparency)
end

-- Blue -> green -> red for 0..1.
local function heat(t: number): Color3
	local v = math.clamp(t, 0, 1)
	if v < 0.5 then
		return Color3.fromRGB(40, 90, 255):Lerp(Color3.fromRGB(60, 220, 90), v * 2)
	end
	return Color3.fromRGB(60, 220, 90):Lerp(Color3.fromRGB(255, 60, 40), (v - 0.5) * 2)
end

local function colorOf(name: string): Color3
	local known = DOMAIN_COLORS[name]
	if known then
		return known
	end
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 997
	end
	return Color3.fromHSV(h / 997, 0.65, 0.95)
end

local function drawGrid(folder: Folder, data: any, colorFor: (any) -> Color3)
	local step = data.step
	for _, c in data.cells do
		part(folder, Vector3.new(step * 0.92, 0.4, step * 0.92), CFrame.new(c.x, c.y + 1.5, c.z), colorFor(c.v), 0.55)
	end
end

local function drawBorders(folder: Folder, data: any)
	local cells = data.cells
	local n = math.floor(math.sqrt(#cells) + 0.5)
	local step = data.step
	for row = 0, n - 1 do
		for col = 0, n - 1 do
			local c = cells[row * n + col + 1]
			local right = if col < n - 1 then cells[row * n + col + 2] else nil
			local down = if row < n - 1 then cells[(row + 1) * n + col + 1] else nil
			if c and right and right.v ~= c.v then
				local x = (c.x + right.x) / 2
				part(folder, Vector3.new(0.6, 6, step), CFrame.new(x, math.max(c.y, right.y) + 3, c.z), colorOf(c.v), 0.3)
			end
			if c and down and down.v ~= c.v then
				local z = (c.z + down.z) / 2
				part(folder, Vector3.new(step, 6, 0.6), CFrame.new(c.x, math.max(c.y, down.y) + 3, z), colorOf(c.v), 0.3)
			end
		end
	end
end

function Overlay.apply(data: any)
	local layer: string = data.layer
	if not data.on then
		Overlay.clear(if layer == "clear" then nil else layer)
		return
	end
	local folder = folderFor(layer)
	if data.live then
		live[layer] = data.radius
	end
	if layer == "density" or layer == "stress" or layer == "water" then
		local lo, hi = data.min or 0, data.max or 1
		drawGrid(folder, data, function(v)
			return heat((v - lo) / math.max(hi - lo, 1e-6))
		end)
	elseif layer == "resonance" then
		drawGrid(folder, data, function(v)
			return colorOf(v)
		end)
	elseif layer == "biomes" then
		drawBorders(folder, data)
	elseif layer == "ley" then
		for _, n in data.nexuses do
			local p = part(folder, Vector3.one * (6 + n.strength * 10), CFrame.new(n.x, n.y + 12, n.z), colorOf(n.domain), 0.2, Enum.PartType.Ball)
			label(p, string.format("%s %s %.2f", n.id, n.domain, n.strength))
		end
		for _, l in data.lines do
			bar(folder, Vector3.new(l.ax, l.ay + 12, l.az), Vector3.new(l.bx, l.by + 12, l.bz), 1.5, colorOf(l.domain), 0.3)
		end
	elseif layer == "chunks" then
		local size = data.size
		for _, c in data.chunks do
			local color = if c.built then Color3.fromRGB(120, 200, 255) else Color3.fromRGB(255, 120, 120)
			local transparency = if c.built then 0.35 else 0.7
			local y = c.y + 4
			part(folder, Vector3.new(0.5, 8, size), CFrame.new(c.x, y, c.z + size / 2), color, transparency)
			part(folder, Vector3.new(size, 8, 0.5), CFrame.new(c.x + size / 2, y, c.z), color, transparency)
		end
	elseif layer == "settlements" then
		for _, town in data.towns do
			local segments = 32
			for i = 0, segments - 1 do
				local a0, a1 = i / segments * math.pi * 2, (i + 1) / segments * math.pi * 2
				local a = Vector3.new(town.x + math.cos(a0) * town.radius, town.y + 3, town.z + math.sin(a0) * town.radius)
				local b = Vector3.new(town.x + math.cos(a1) * town.radius, town.y + 3, town.z + math.sin(a1) * town.radius)
				bar(folder, a, b, 1, Color3.fromRGB(255, 200, 80), 0.3)
			end
			local centre = part(folder, Vector3.new(2, 2, 2), CFrame.new(town.x, town.y + 10, town.z), Color3.fromRGB(255, 200, 80), 0.1, Enum.PartType.Ball)
			label(centre, town.name .. " (" .. town.id .. ")")
			for _, d in town.districts do
				local marker = part(folder, Vector3.new(1, 8, 1), CFrame.new(d.x, d.y + 4, d.z), Color3.fromRGB(255, 255, 255), 0.4)
				label(marker, d.name)
			end
		end
	elseif layer == "lots" then
		local typeColors: { [string]: Color3 } = {
			house_small = Color3.fromRGB(120, 220, 120), house_medium = Color3.fromRGB(80, 190, 110), house_large = Color3.fromRGB(50, 150, 90),
			smithy = Color3.fromRGB(255, 130, 50), tavern = Color3.fromRGB(230, 180, 60), market_stall = Color3.fromRGB(240, 220, 120),
			well = Color3.fromRGB(80, 170, 255), shrine = Color3.fromRGB(200, 140, 255), watchtower = Color3.fromRGB(200, 200, 200),
			barn = Color3.fromRGB(170, 120, 80), magic_school = Color3.fromRGB(150, 100, 255),
		}
		for _, town in data.towns do
			local c = town.center
			local p = town.plaza
			for _, edge in { { -1, -1, 1, -1 }, { 1, -1, 1, 1 }, { 1, 1, -1, 1 }, { -1, 1, -1, -1 } } do
				bar(folder, Vector3.new(c.x + edge[1] * p, c.y + 1, c.z + edge[2] * p), Vector3.new(c.x + edge[3] * p, c.y + 1, c.z + edge[4] * p), 0.6, Color3.fromRGB(255, 255, 255), 0.2)
			end
			label(part(folder, Vector3.one * 2, CFrame.new(c.x, c.y + 14, c.z), Color3.fromRGB(255, 255, 255), 0.2, Enum.PartType.Ball), town.name)
			for _, road in town.roads do
				for i = 1, #road.points - 1 do
					local a, b = road.points[i], road.points[i + 1]
					bar(folder, Vector3.new(a.x, a.y + 1, a.z), Vector3.new(b.x, b.y + 1, b.z), if road.kind == "main" then 1.2 else 0.7, Color3.fromRGB(255, 200, 80), 0.25)
				end
			end
			for _, lot in town.lots do
				local color = typeColors[lot.type] or Color3.new(1, 1, 1)
				local transparency = if lot.built then 0.1 elseif lot.buildable then 0.35 else 0.6
				for i = 1, 4 do
					local a, b = lot.corners[i], lot.corners[i % 4 + 1]
					bar(folder, Vector3.new(a.x, a.y + 1.5, a.z), Vector3.new(b.x, b.y + 1.5, b.z), 0.5, color, transparency)
				end
				local marker = part(folder, Vector3.new(1, 3, 1), CFrame.new(lot.front.x, lot.front.y + 2, lot.front.z), color, transparency)
				label(marker, (lot.name or lot.type) .. (if lot.built then "" elseif lot.buildable then " (not built yet)" else " (planned)"))
			end
			for _, f in town.failures do
				local m = part(folder, Vector3.one * 3, CFrame.new(f.x, f.y + 6, f.z), Color3.fromRGB(255, 50, 50), 0.1, Enum.PartType.Ball)
				label(m, "FAILED " .. f.text)
			end
		end
	elseif layer == "npclod" then
		for _, p in data.points do
			local color = if p.frozen then Color3.fromRGB(80, 140, 255) else TIER_COLORS[p.tier] or Color3.new(1, 1, 1)
			part(folder, Vector3.one * (if p.forced then 3 else 2), CFrame.new(p.x, p.y + 8, p.z), color, 0.15, Enum.PartType.Ball)
		end
	end
end

function Overlay.clear(layer: string?)
	if layer then
		live[layer] = nil
		local folder = layers[layer]
		if folder then
			folder:Destroy()
			layers[layer] = nil
		end
		return
	end
	table.clear(live)
	for _, folder in layers do
		folder:Destroy()
	end
	table.clear(layers)
end

function Overlay.active(): { [string]: number }
	return live
end

return Overlay
