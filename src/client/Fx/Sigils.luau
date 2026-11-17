--!strict
--[[
	Sigils: the drawn circles of magic (docs/Smoothness.md, stage 2; data in Shared/Magic/Data/Sigils).

	A sigil is a flat, invisible Part carrying a SurfaceGui. The drawing is crisp lines, rings, dots
	and numerals (Frames, UIStroke, TextLabels), not a particle, so it stays sharp at any size and
	glows under Bloom (SurfaceGui Brightness above 1, LightInfluence 0). Each domain has its own
	pattern family; the property's category adds a motif round the edge; the verb sets how it
	turns and breathes; the caster's tier adds rings, a band, an inner ring and a crown; the
	caster's spell hand seeds the variations.

		Sigils.available(position) -> boolean        under the live cap and within range of the camera
		Sigils.create(spec, cframe, diameter, opts?) -> Handle?
			cframe: the disc's centre; its UpVector is the way the drawing faces
			opts.doubleSided: also drawn on the back (discs standing at the hand)
			opts.grow: seconds to grow from opts.from (diameter) to `diameter`
		Sigils.place(h, cframe)        Sigils.follow(h, fn)   fn() -> CFrame? each frame (nil = fade)
		Sigils.target(h, diameter)     snaps toward a new size (charge stages)
		Sigils.grow(h, diameter, seconds)
		Sigils.burst(h, diameter?)     release: snaps out (to `diameter` or burstMult x) and fades
		Sigils.fade(h, seconds?)       cancel: fades where it is
		Sigils.stamp(spec, position, normal, diameter, hold?)   a mark where a spell landed
		Sigils.seedFor(userId?, hand?, domain) -> number

	Finished drawings go back to a small pool keyed by what they look like, so a mage casting the
	same spell again reuses theirs. Nothing here touches gameplay. With Reduce spell effects the
	detail is capped (Data caps.reducedMaxTier) and stamps for small hits are skipped by callers.

	Unverified Roblox behaviour (docs/Smoothness.md): children of a rotated Frame turning with it
	inside a SurfaceGui; Brightness > 1 glowing under the project's Bloom; the cost of many
	SurfaceGuis at once (hence the live cap).
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Data = require(Shared.Magic.Data.Sigils)
local Registry = require(Shared.Magic.Registry)

local FxLayers = require(script.Parent.FxLayers)

export type Spec = {
	domain: string,
	property: string?,
	verb: string?,
	tier: number,
	seed: number,
	style: FxLayers.Style,
	reduced: boolean?,
}

type Element = { inst: Instance, prop: string, base: number }
type Layer = { frame: Frame, speed: number } -- speed: degrees a second

type Drawing = {
	key: string,
	part: Part,
	guis: { SurfaceGui },
	elements: { Element },
	layers: { Layer },
}

type Anim = {
	t0: number,
	duration: number,
	fromSize: number,
	toSize: number,
	fromAlpha: number,
	toAlpha: number,
	finish: boolean, -- recycle when done
}

export type Handle = {
	drawing: Drawing,
	cframe: CFrame,
	size: number,
	target: number,
	alpha: number,
	shownAlpha: number,
	pulse: number,
	born: number,
	follow: (() -> CFrame?)?,
	anim: Anim?,
	dead: boolean,
}

local CAN = Data.caps.canvas
local K = 0.9 -- the drawing's outer radius as a share of the canvas (the crown sits outside)

local Sigils = {}

local live: { Handle } = {}
local pool: { Drawing } = {}
local folder: Folder? = nil
local stepping: RBXScriptConnection? = nil

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "SigilFx"
	made.Parent = workspace
	folder = made
	return made
end

-- ─── Seeds ──────────────────────────────────────────────────────────────────

-- A stable number from a string (djb2), the same on every client.
local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

function Sigils.seedFor(userId: number?, hand: any, domain: string): number
	local h = hand
	local handPart = if typeof(h) == "table"
		then string.format("%s|%s|%s|%s", tostring(h.rune), tostring(h.shape), tostring(h.spin), tostring(h.speed))
		else "plain"
	return hash(string.format("%s:%s:%s", tostring(userId or "npc"), domain, handPart))
end

-- ─── Drawing primitives (unit coordinates: centre 0,0, edge radius 1, y down) ─

type Canvas = { parent: Frame, elements: { Element }, weight: number }

local function at(x: number, y: number): UDim2
	return UDim2.fromScale(0.5 + x * K / 2, 0.5 + y * K / 2)
end

local function track(c: Canvas, inst: Instance, prop: string, base: number)
	table.insert(c.elements, { inst = inst, prop = prop, base = base })
end

local function line(c: Canvas, x0: number, y0: number, x1: number, y1: number, thick: number, color: Color3, alpha: number)
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-4 then
		return
	end
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = at((x0 + x1) / 2, (y0 + y1) / 2)
	f.Size = UDim2.new(len * K / 2, 0, 0, math.max(1, thick * c.weight))
	f.Rotation = math.deg(math.atan2(dy, dx))
	f.BackgroundColor3 = color
	f.BackgroundTransparency = alpha
	f.BorderSizePixel = 0
	f.Parent = c.parent
	track(c, f, "BackgroundTransparency", alpha)
end

local function polyline(c: Canvas, points: { Vector2 }, thick: number, color: Color3, alpha: number, closed: boolean?)
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		line(c, a.X, a.Y, b.X, b.Y, thick, color, alpha)
	end
	if closed and #points > 2 then
		local a, b = points[#points], points[1]
		line(c, a.X, a.Y, b.X, b.Y, thick, color, alpha)
	end
end

local function ring(c: Canvas, r: number, thick: number, color: Color3, alpha: number, cx: number?, cy: number?)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = at(cx or 0, cy or 0)
	f.Size = UDim2.fromScale(r * K, r * K)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(1, thick * c.weight)
	stroke.Color = color
	stroke.Transparency = alpha
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = f
	f.Parent = c.parent
	track(c, stroke, "Transparency", alpha)
end

local function dot(c: Canvas, x: number, y: number, r: number, color: Color3, alpha: number)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = at(x, y)
	f.Size = UDim2.fromScale(r * K, r * K)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = alpha
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	f.Parent = c.parent
	track(c, f, "BackgroundTransparency", alpha)
end

local function text(c: Canvas, str: string, x: number, y: number, size: number, rotation: number, color: Color3, alpha: number)
	local t = Instance.new("TextLabel")
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = at(x, y)
	t.Size = UDim2.fromScale(size * K, size * K * 0.6)
	t.Rotation = rotation
	t.BackgroundTransparency = 1
	t.Text = str
	t.Font = Enum.Font.Antique
	t.TextScaled = true
	t.TextColor3 = color
	t.TextTransparency = alpha
	t.Parent = c.parent
	track(c, t, "TextTransparency", alpha)
end

local function polar(r: number, a: number): Vector2
	return Vector2.new(math.cos(a) * r, math.sin(a) * r)
end

local function regular(c: Canvas, n: number, r: number, rot: number, thick: number, color: Color3, alpha: number)
	local pts = {}
	for i = 0, n - 1 do
		table.insert(pts, polar(r, rot + i / n * math.pi * 2))
	end
	polyline(c, pts, thick, color, alpha, true)
end

local function starShape(c: Canvas, n: number, rOut: number, rIn: number, rot: number, thick: number, color: Color3, alpha: number)
	local pts = {}
	for i = 0, n * 2 - 1 do
		table.insert(pts, polar(if i % 2 == 0 then rOut else rIn, rot + i / (n * 2) * math.pi * 2))
	end
	polyline(c, pts, thick, color, alpha, true)
end

-- ─── Patterns (inner drawings, within radius ~0.8) ──────────────────────────

type Colors = { main: Color3, second: Color3, accent: Color3, bright: Color3 }

local patterns: { [string]: (Canvas, Random, Colors) -> () } = {}

-- Energy: forked lightning running out from the centre.
patterns.lattice = function(c, rng, col)
	local arms = rng:NextInteger(6, 9)
	for i = 1, arms do
		local a = (i - 1) / arms * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
		local pts = { polar(0.12, a) }
		local r = 0.12
		while r < 0.8 do
			r += rng:NextNumber(0.08, 0.13)
			local p = polar(math.min(r, 0.82), a + rng:NextNumber(-0.16, 0.16))
			table.insert(pts, p)
			if rng:NextNumber() < 0.4 and r < 0.65 then
				local side = if rng:NextNumber() < 0.5 then -1 else 1
				local b = math.atan2(p.Y, p.X) + side * rng:NextNumber(0.35, 0.6)
				local q = p + Vector2.new(math.cos(b), math.sin(b)) * rng:NextNumber(0.12, 0.2)
				line(c, p.X, p.Y, q.X, q.Y, 3, col.second, 0.15)
			end
		end
		polyline(c, pts, 5, col.main, 0)
	end
end

-- Earth: hex stone plates with fault lines across them.
patterns.plates = function(c, rng, col)
	local s = 0.27
	local h = s * math.sqrt(3)
	for q = -4, 4 do
		for r = -4, 4 do
			local x = s * 1.5 * q
			local y = h * (r + q / 2)
			if x * x + y * y < 0.62 then
				for e = 0, 2 do
					local a0 = e / 6 * math.pi * 2
					local a1 = (e + 1) / 6 * math.pi * 2
					line(c, x + math.cos(a0) * s, y + math.sin(a0) * s, x + math.cos(a1) * s, y + math.sin(a1) * s, 4, col.main, 0.1)
				end
			end
		end
	end
	for _ = 1, 2 do
		local a = rng:NextNumber(0, math.pi * 2)
		local pts = {}
		for t = -1, 1, 0.25 do
			table.insert(pts, Vector2.new(math.cos(a), math.sin(a)) * t * 0.8 + polar(rng:NextNumber(0, 0.06), rng:NextNumber(0, math.pi * 2)))
		end
		polyline(c, pts, 7, col.bright, 0)
	end
end

-- Water: ripples from two sources and one wave ring.
patterns.ripples = function(c, rng, col)
	for _, r in { 0.2, 0.38, 0.56, 0.74 } do
		ring(c, r, 4, col.main, 0.05)
	end
	local ox, oy = rng:NextNumber(-0.3, 0.3), rng:NextNumber(-0.3, 0.3)
	for _, r in { 0.12, 0.24, 0.34 } do
		ring(c, r, 3, col.second, 0.3, ox, oy)
	end
	local k = rng:NextInteger(6, 10)
	local pts = {}
	for i = 0, 40 do
		local a = i / 40 * math.pi * 2
		table.insert(pts, polar(0.66 + 0.04 * math.sin(a * k), a))
	end
	polyline(c, pts, 4, col.bright, 0)
end

-- Air: spiral arms with feathers along them.
patterns.spiral = function(c, rng, col)
	local arms = rng:NextInteger(3, 5)
	local twist = rng:NextNumber(1.8, 2.6) * math.pi
	for i = 1, arms do
		local a0 = (i - 1) / arms * math.pi * 2
		local pts = {}
		for j = 0, 16 do
			local t = j / 16
			table.insert(pts, polar(0.08 + 0.74 * t ^ 1.15, a0 + t * twist))
		end
		polyline(c, pts, 5, col.main, 0)
		for j = 4, 15, 3 do
			local p = pts[j]
			local a = math.atan2(p.Y, p.X) + 1.2
			local q = p + Vector2.new(math.cos(a), math.sin(a)) * 0.1
			line(c, p.X, p.Y, q.X, q.Y, 3, col.second, 0.2)
		end
	end
end

-- Life: a rosette of petals round a small ring.
patterns.rosette = function(c, rng, col)
	local n = rng:NextInteger(6, 10)
	local rot = rng:NextNumber(0, math.pi)
	for i = 1, n do
		local a = rot + (i - 1) / n * math.pi * 2
		local dir = Vector2.new(math.cos(a), math.sin(a))
		local perp = Vector2.new(-dir.Y, dir.X)
		local left, right = {}, {}
		for j = 0, 6 do
			local t = j / 6
			local rr = 0.16 + 0.58 * t
			local w = 0.15 * math.sin(math.pi * t)
			table.insert(left, dir * rr + perp * w)
			table.insert(right, dir * rr - perp * w)
		end
		polyline(c, left, 4, col.main, 0)
		polyline(c, right, 4, col.main, 0)
	end
	ring(c, 0.15, 4, col.second, 0.1)
end

-- Mind: nested turning polygons round an iris.
patterns.iris = function(c, rng, col)
	local radii = { 0.78, 0.6, 0.44 }
	for i, r in radii do
		regular(c, rng:NextInteger(3, 6), r, rng:NextNumber(0, math.pi), 4, if i == 2 then col.second else col.main, 0.05)
	end
	for i = 0, 23 do
		local a = i / 24 * math.pi * 2
		local p, q = polar(0.14, a), polar(0.28, a)
		line(c, p.X, p.Y, q.X, q.Y, 2, col.bright, 0.2)
	end
end

-- Spirit: spokes ending in small glyphs.
patterns.glyphs = function(c, rng, col)
	local n = rng:NextInteger(8, 12)
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2
		local p, q = polar(0.22, a), polar(0.6, a)
		line(c, p.X, p.Y, q.X, q.Y, 4, col.main, 0)
		-- A glyph: two or three strokes in a small box at the spoke's end.
		local centre = polar(0.7, a)
		for _ = 1, rng:NextInteger(2, 3) do
			local u = centre + Vector2.new(rng:NextNumber(-0.06, 0.06), rng:NextNumber(-0.06, 0.06))
			local v = centre + Vector2.new(rng:NextNumber(-0.06, 0.06), rng:NextNumber(-0.06, 0.06))
			line(c, u.X, u.Y, v.X, v.Y, 3, col.second, 0)
		end
	end
	ring(c, 0.44, 3, col.main, 0.25)
end

-- Void: a cracked web: jittered spokes joined at jittered rings.
patterns.web = function(c, rng, col)
	local n = rng:NextInteger(9, 13)
	local levels = { 0.2, 0.34, 0.48, 0.63, 0.78 }
	local angles: { number } = {}
	for i = 1, n do
		angles[i] = (i - 1) / n * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local p, q = polar(0.1, angles[i]), polar(0.84, angles[i] + rng:NextNumber(-0.05, 0.05))
		line(c, p.X, p.Y, q.X, q.Y, 3, col.main, 0)
	end
	for _, level in levels do
		local pts = {}
		for i = 1, n do
			table.insert(pts, polar(level * rng:NextNumber(0.9, 1.08), angles[i]))
		end
		polyline(c, pts, 3, col.main, 0.1, true)
	end
end

-- Space: stars joined into constellations, and two orbits.
patterns.constellation = function(c, rng, col)
	local stars: { Vector2 } = {}
	for _ = 1, rng:NextInteger(14, 20) do
		local p = polar(math.sqrt(rng:NextNumber(0.03, 0.6)), rng:NextNumber(0, math.pi * 2))
		table.insert(stars, p)
		dot(c, p.X, p.Y, rng:NextNumber(0.018, 0.035), col.bright, 0)
	end
	for i, p in stars do
		local best, bestD = 0, math.huge
		for j, q in stars do
			local d = (p - q).Magnitude
			if j > i and d < bestD then
				best, bestD = j, d
			end
		end
		if best > 0 then
			local q = stars[best]
			line(c, p.X, p.Y, q.X, q.Y, 2, col.second, 0.15)
		end
	end
	for k = 1, 2 do
		local rot = rng:NextNumber(0, math.pi)
		local a, b = 0.78, 0.78 * rng:NextNumber(0.35, 0.6)
		local pts = {}
		for i = 0, 28 do
			local t = i / 28 * math.pi * 2
			local x, y = math.cos(t) * a, math.sin(t) * b
			table.insert(pts, Vector2.new(x * math.cos(rot) - y * math.sin(rot), x * math.sin(rot) + y * math.cos(rot)))
		end
		polyline(c, pts, 3, if k == 1 then col.main else col.second, 0.1)
	end
end

-- Time: a dial with ticks, numerals and two hands.
local NUMERALS = { "XII", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI" }
patterns.dial = function(c, rng, col)
	ring(c, 0.73, 4, col.main, 0)
	for i = 0, 59 do
		local a = i / 60 * math.pi * 2 - math.pi / 2
		local long = i % 5 == 0
		local p, q = polar(if long then 0.6 else 0.66, a), polar(0.72, a)
		line(c, p.X, p.Y, q.X, q.Y, if long then 4 else 2, col.main, if long then 0 else 0.3)
	end
	for i, numeral in NUMERALS do
		local a = (i - 1) / 12 * math.pi * 2 - math.pi / 2
		local p = polar(0.5, a)
		text(c, numeral, p.X, p.Y, 0.11, math.deg(a) + 90, col.bright, 0)
	end
	for _, len in { 0.28, 0.42 } do
		local a = rng:NextNumber(0, math.pi * 2)
		local q = polar(len, a)
		line(c, 0, 0, q.X, q.Y, 5, col.second, 0)
	end
end

-- Gravity: rings crowding toward the centre, and curving spokes drawn in.
patterns.well = function(c, rng, col)
	for k = 1, 7 do
		ring(c, 0.8 * (k / 7) ^ 1.7, if k == 7 then 5 else 3, col.main, 0.05 + (7 - k) * 0.04)
	end
	local n = rng:NextInteger(7, 10)
	for i = 1, n do
		local a0 = (i - 1) / n * math.pi * 2
		local pts = {}
		for j = 0, 8 do
			local t = j / 8
			table.insert(pts, polar(0.8 - 0.7 * t, a0 + t * t * 0.9))
		end
		polyline(c, pts, 3, col.second, 0.15)
	end
end

-- Reality: a triangle tiling clipped to the circle, with two heavy hexagons laid over it.
patterns.tessellation = function(c, rng, col)
	local s = 0.27 * math.sin(math.pi / 3)
	local R = 0.8
	for dir = 0, 2 do
		local a = dir / 3 * math.pi + rng:NextNumber(-0.02, 0.02)
		local d = Vector2.new(math.cos(a), math.sin(a))
		local n = Vector2.new(-d.Y, d.X)
		for k = -3, 3 do
			local off = k * s
			if math.abs(off) < R then
				local half = math.sqrt(R * R - off * off)
				local p, q = n * off - d * half, n * off + d * half
				line(c, p.X, p.Y, q.X, q.Y, 3, col.main, 0.1)
			end
		end
	end
	regular(c, 6, rng:NextNumber(0.4, 0.6), rng:NextNumber(0, math.pi), 6, col.bright, 0)
	regular(c, 6, rng:NextNumber(0.2, 0.32), rng:NextNumber(0, math.pi), 5, col.second, 0)
end

-- ─── Bands, motifs, cores ───────────────────────────────────────────────────

local bands: { [string]: (Canvas, Random, Colors) -> () } = {}
bands.ring = function(c, _rng, col)
	ring(c, 0.92, 8, col.main, 0)
end
bands.ticks = function(c, _rng, col)
	ring(c, 0.97, 3, col.main, 0.1)
	for i = 0, 35 do
		local a = i / 36 * math.pi * 2
		local p, q = polar(0.88, a), polar(0.95, a)
		line(c, p.X, p.Y, q.X, q.Y, 3, col.second, 0)
	end
end
bands.runes = function(c, rng, col)
	ring(c, 0.86, 3, col.main, 0)
	ring(c, 0.98, 3, col.main, 0)
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		local centre = polar(0.92, a)
		for _ = 1, 2 do
			local u = centre + polar(rng:NextNumber(0, 0.035), rng:NextNumber(0, math.pi * 2))
			local v = centre + polar(rng:NextNumber(0, 0.035), rng:NextNumber(0, math.pi * 2))
			line(c, u.X, u.Y, v.X, v.Y, 3, col.second, 0)
		end
	end
end
bands.beads = function(c, _rng, col)
	ring(c, 0.92, 2, col.main, 0.2)
	for i = 0, 23 do
		local p = polar(0.92, i / 24 * math.pi * 2)
		dot(c, p.X, p.Y, 0.025, col.second, 0)
	end
end

local motifs: { [string]: (Canvas, Vector2, number, Color3) -> () } = {}
motifs.spikes = function(c, p, a, color)
	local q = p + Vector2.new(math.cos(a), math.sin(a)) * 0.07
	line(c, p.X, p.Y, q.X, q.Y, 3, color, 0)
end
motifs.notches = function(c, p, a, color)
	local t = Vector2.new(-math.sin(a), math.cos(a)) * 0.025
	line(c, p.X - t.X, p.Y - t.Y, p.X + t.X, p.Y + t.Y, 6, color, 0)
end
motifs.waves = function(c, p, a, color)
	local t = Vector2.new(-math.sin(a), math.cos(a)) * 0.03
	local o = Vector2.new(math.cos(a), math.sin(a)) * 0.02
	local m = p + o
	line(c, p.X - t.X, p.Y - t.Y, m.X, m.Y, 3, color, 0)
	line(c, m.X, m.Y, p.X + t.X, p.Y + t.Y, 3, color, 0)
end
motifs.chevrons = function(c, p, a, color)
	local t = Vector2.new(-math.sin(a), math.cos(a)) * 0.03
	local tip = p + Vector2.new(math.cos(a), math.sin(a)) * 0.04
	line(c, p.X - t.X, p.Y - t.Y, tip.X, tip.Y, 3, color, 0)
	line(c, p.X + t.X, p.Y + t.Y, tip.X, tip.Y, 3, color, 0)
end
motifs.dots = function(c, p, _a, color)
	dot(c, p.X, p.Y, 0.02, color, 0)
end
motifs.crosses = function(c, p, a, color)
	local u = Vector2.new(math.cos(a), math.sin(a)) * 0.03
	local t = Vector2.new(-u.Y, u.X)
	line(c, p.X - u.X, p.Y - u.Y, p.X + u.X, p.Y + u.Y, 3, color, 0)
	line(c, p.X - t.X, p.Y - t.Y, p.X + t.X, p.Y + t.Y, 3, color, 0)
end
motifs.petals = function(c, p, a, color)
	local u = Vector2.new(math.cos(a), math.sin(a)) * 0.04
	local t = Vector2.new(-u.Y, u.X) * 0.4
	local tip = p + u
	line(c, p.X, p.Y, tip.X + t.X, tip.Y + t.Y, 3, color, 0)
	line(c, p.X, p.Y, tip.X - t.X, tip.Y - t.Y, 3, color, 0)
end
motifs.hooks = function(c, p, a, color)
	local u = Vector2.new(math.cos(a), math.sin(a)) * 0.05
	local t = Vector2.new(-u.Y, u.X) * 0.6
	local q = p + u
	line(c, p.X, p.Y, q.X, q.Y, 3, color, 0)
	line(c, q.X, q.Y, q.X + t.X, q.Y + t.Y, 3, color, 0)
end

local cores: { [string]: (Canvas, Random, Colors) -> () } = {}
cores.star = function(c, rng, col)
	starShape(c, rng:NextInteger(5, 8), 0.16, 0.07, rng:NextNumber(0, math.pi), 4, col.bright, 0)
	dot(c, 0, 0, 0.04, col.bright, 0)
end
cores.disc = function(c, _rng, col)
	dot(c, 0, 0, 0.1, col.bright, 0.05)
	ring(c, 0.15, 3, col.main, 0)
end
cores.eye = function(c, _rng, col)
	local top, bottom = {}, {}
	for i = 0, 8 do
		local t = i / 8
		local x = -0.2 + 0.4 * t
		local y = 0.09 * math.sin(math.pi * t)
		table.insert(top, Vector2.new(x, -y))
		table.insert(bottom, Vector2.new(x, y))
	end
	polyline(c, top, 4, col.bright, 0)
	polyline(c, bottom, 4, col.bright, 0)
	dot(c, 0, 0, 0.05, col.bright, 0)
end
cores.void = function(c, _rng, col)
	dot(c, 0, 0, 0.16, Color3.fromRGB(8, 4, 14), 0.05)
	ring(c, 0.17, 3, col.main, 0)
end
cores.none = function(_c, _rng, _col) end

-- ─── Building a drawing ─────────────────────────────────────────────────────

local function keyOf(spec: Spec, tier: number, doubleSided: boolean): string
	return string.format("%s|%s|%d|%d|%s", spec.domain, tostring(spec.property), tier, spec.seed, if doubleSided then "2" else "1")
end

local function newLayer(parent: Frame, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function build(spec: Spec, tier: number, doubleSided: boolean): Drawing
	local family = Data.families[spec.domain] or Data.families.energy
	local motion = Data.motions[spec.verb or ""] or Data.defaultMotion
	local d = Data.detail
	local rng = Random.new(spec.seed)
	local style = spec.style
	local col: Colors = {
		main = style.primary,
		second = style.secondary,
		accent = style.accent,
		bright = FxLayers.whiten(style.primary, 0.55),
	}
	local spinDir = if rng:NextNumber() < 0.5 then -1 else 1
	local baseSpeed = family.spin * motion.spin * spinDir * 360

	local part = Instance.new("Part")
	part.Name = "Sigil"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(4, 0.05, 4)
	part.Parent = folderOf()

	local art = Instance.new("Frame")
	art.Name = "Art"
	art.Size = UDim2.fromScale(1, 1)
	art.BackgroundTransparency = 1
	art.BorderSizePixel = 0
	local elements: { Element } = {}
	local layerDefs: { { name: string, speed: number } } = {}
	local function canvasFor(name: string, speed: number): Canvas
		local frame = newLayer(art, name)
		table.insert(layerDefs, { name = name, speed = speed })
		return { parent = frame, elements = elements, weight = family.weight }
	end

	patterns[family.pattern](canvasFor("Pattern", baseSpeed), rng, col)
	if tier >= d.motifAt and spec.property then
		local property = Registry.properties[spec.property]
		local motif = property and Data.motifByCategory[(property :: any).category]
		local draw = motif and motifs[motif]
		if draw then
			local c = canvasFor("Motif", baseSpeed)
			for i = 0, 11 do
				local a = i / 12 * math.pi * 2 + math.pi / 12
				draw(c, polar(0.82, a), a, col.accent)
			end
		end
	end
	if tier >= d.bandAt then
		bands[family.band](canvasFor("Band", -baseSpeed * 0.5), rng, col)
	elseif tier >= d.ringAt then
		ring(canvasFor("Band", 0), 0.95, 4, col.main, 0.15)
	end
	if tier >= d.innerRingAt then
		local c = canvasFor("Inner", -baseSpeed * 1.4)
		ring(c, 0.3, 3, col.second, 0.1)
		for i = 0, 5 do
			local p = polar(0.3, i / 6 * math.pi * 2)
			dot(c, p.X, p.Y, 0.025, col.second, 0)
		end
	end
	if tier >= d.crownAt then
		local c = canvasFor("Crown", baseSpeed * 0.3)
		for i = 0, 11 do
			local p = polar(1.07, i / 12 * math.pi * 2)
			dot(c, p.X, p.Y, 0.025, col.accent, 0)
		end
	end
	cores[family.core](canvasFor("Core", 0), rng, col)

	local guis: { SurfaceGui } = {}
	local faces = if doubleSided then { Enum.NormalId.Top, Enum.NormalId.Bottom } else { Enum.NormalId.Top }
	for i, face in faces do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		gui.CanvasSize = Vector2.new(CAN, CAN)
		gui.LightInfluence = 0
		gui.Brightness = Data.caps.brightness
		gui.AlwaysOnTop = false
		gui.MaxDistance = Data.caps.range + 40
		gui.ResetOnSpawn = false
		local content = if i == 1 then art else art:Clone()
		content.Parent = gui
		gui.Parent = part
		table.insert(guis, gui)
	end

	-- Layers and elements of every face (a cloned back face has its own instances).
	local layers: { Layer } = {}
	local allElements: { Element } = {}
	for i, gui in guis do
		local content = gui:FindFirstChild("Art") :: Frame
		for _, def in layerDefs do
			local frame = content:FindFirstChild(def.name) :: Frame?
			if frame then
				-- The back face is seen mirrored: turn it the other way so both read the same.
				table.insert(layers, { frame = frame, speed = if i == 1 then def.speed else -def.speed })
			end
		end
		if i == 1 then
			for _, e in elements do
				table.insert(allElements, e)
			end
		end
	end
	if #guis > 1 then
		-- Re-find the cloned elements by walking the back face in the same order as the front.
		local front = (guis[1]:FindFirstChild("Art") :: Frame):GetDescendants()
		local back = (guis[2]:FindFirstChild("Art") :: Frame):GetDescendants()
		local index: { [Instance]: number } = {}
		for n, inst in front do
			index[inst] = n
		end
		for _, e in elements do
			local n = index[e.inst]
			local twin = n and back[n]
			if twin then
				table.insert(allElements, { inst = twin, prop = e.prop, base = e.base })
			end
		end
	end

	return { key = keyOf(spec, tier, doubleSided), part = part, guis = guis, elements = allElements, layers = layers }
end

local function setAlpha(drawing: Drawing, alpha: number)
	local keep = 1 - math.clamp(alpha, 0, 1)
	for _, e in drawing.elements do
		(e.inst :: any)[e.prop] = 1 - (1 - e.base) * keep
	end
end

local function retire(drawing: Drawing)
	drawing.part.CFrame = CFrame.new(0, -50000, 0)
	setAlpha(drawing, 1)
	table.insert(pool, drawing)
	while #pool > Data.caps.pool do
		local old = table.remove(pool, 1)
		if old then
			old.part:Destroy()
		end
	end
end

local function take(spec: Spec, tier: number, doubleSided: boolean): Drawing
	local key = keyOf(spec, tier, doubleSided)
	for i, drawing in pool do
		if drawing.key == key then
			table.remove(pool, i)
			return drawing
		end
	end
	return build(spec, tier, doubleSided)
end

-- ─── Running ────────────────────────────────────────────────────────────────

local function ease(t: number): number
	return 1 - (1 - t) ^ 3
end

local function step(dt: number)
	local now = os.clock()
	for i = #live, 1, -1 do
		local h = live[i]
		local drawing = h.drawing
		local follow = h.follow
		if follow and not (h.anim and h.anim.finish) then
			local ok, cf = pcall(follow)
			if ok and cf then
				h.cframe = cf
			else
				h.follow = nil
				Sigils.fade(h)
			end
		end
		local anim = h.anim
		local size = h.size
		if anim then
			local t = math.clamp((now - anim.t0) / anim.duration, 0, 1)
			local e = ease(t)
			size = anim.fromSize + (anim.toSize - anim.fromSize) * e
			h.alpha = anim.fromAlpha + (anim.toAlpha - anim.fromAlpha) * t
			if t >= 1 then
				h.anim = nil
				if anim.finish then
					h.dead = true
					table.remove(live, i)
					retire(drawing)
					continue
				end
				h.target = size
			end
		else
			size += (h.target - size) * math.min(1, dt * Data.timing.snap)
		end
		h.size = size
		local breath = if h.pulse > 0 then 1 + h.pulse * math.sin((now - h.born) * 3.2) else 1
		local shown = math.max(0.05, size * breath)
		drawing.part.Size = Vector3.new(shown, 0.05, shown)
		drawing.part.CFrame = h.cframe
		if math.abs(h.alpha - h.shownAlpha) > 0.01 then
			h.shownAlpha = h.alpha
			setAlpha(drawing, h.alpha)
		end
		for _, layer in drawing.layers do
			if layer.speed ~= 0 then
				layer.frame.Rotation = (layer.frame.Rotation + layer.speed * dt) % 360
			end
		end
	end
	if #live == 0 then
		local c = stepping
		if c then
			c:Disconnect()
			stepping = nil
		end
	end
end

local function ensureStepping()
	if not stepping then
		stepping = RunService.RenderStepped:Connect(step)
	end
end

-- ─── Public ─────────────────────────────────────────────────────────────────

function Sigils.available(position: Vector3): boolean
	if #live >= Data.caps.live then
		return false
	end
	local camera = workspace.CurrentCamera
	return camera == nil or (camera.CFrame.Position - position).Magnitude <= Data.caps.range
end

function Sigils.create(spec: Spec, cframe: CFrame, diameter: number, opts: { doubleSided: boolean?, grow: number?, from: number? }?): Handle?
	if not Sigils.available(cframe.Position) then
		return nil
	end
	local o = opts or {}
	local tier = math.clamp(math.floor(spec.tier), 0, 8)
	if spec.reduced then
		tier = math.min(tier, Data.detail.reducedMaxTier)
	end
	local ok, drawing = pcall(take, spec, tier, o.doubleSided == true)
	if not ok then
		warn("[Sigils] couldn't draw " .. spec.domain .. ": " .. tostring(drawing))
		return nil
	end
	local motion = Data.motions[spec.verb or ""] or Data.defaultMotion
	local start = o.from or (if motion.draw == "in" then diameter * 1.6 else diameter * 0.2)
	local h: Handle = {
		drawing = drawing,
		cframe = cframe,
		size = start,
		target = diameter,
		alpha = 1,
		shownAlpha = -1,
		pulse = if spec.reduced then 0 else motion.pulse,
		born = os.clock(),
		follow = nil,
		anim = {
			t0 = os.clock(),
			duration = o.grow or 0.18,
			fromSize = start,
			toSize = diameter,
			fromAlpha = 1,
			toAlpha = 0,
			finish = false,
		},
		dead = false,
	}
	table.insert(live, h)
	ensureStepping()
	step(0)
	return h
end

function Sigils.place(h: Handle, cframe: CFrame)
	h.cframe = cframe
end

function Sigils.follow(h: Handle, fn: () -> CFrame?)
	h.follow = fn
end

function Sigils.target(h: Handle, diameter: number)
	if not h.dead and not h.anim then
		h.target = diameter
	end
end

function Sigils.grow(h: Handle, diameter: number, seconds: number)
	if h.dead then
		return
	end
	h.anim = {
		t0 = os.clock(),
		duration = math.max(0.05, seconds),
		fromSize = h.size,
		toSize = diameter,
		fromAlpha = h.alpha,
		toAlpha = 0,
		finish = false,
	}
end

function Sigils.burst(h: Handle, diameter: number?)
	if h.dead then
		return
	end
	local S = Data.size
	h.follow = nil
	h.pulse = 0
	h.anim = {
		t0 = os.clock(),
		duration = S.burstTime + S.burstFade,
		fromSize = h.size,
		toSize = math.max(diameter or 0, h.size * S.burstMult),
		fromAlpha = h.alpha,
		toAlpha = 1,
		finish = true,
	}
end

function Sigils.fade(h: Handle, seconds: number?)
	if h.dead then
		return
	end
	h.follow = nil
	h.anim = {
		t0 = os.clock(),
		duration = seconds or Data.timing.cancelFade,
		fromSize = h.size,
		toSize = h.size * 0.7,
		fromAlpha = h.alpha,
		toAlpha = 1,
		finish = true,
	}
end

-- How far above the ground at `position` a lying sigil should sit: above the grass blades on grass
-- terrain (they'd cover a flush drawing), flush everywhere else. `material` skips the raycast.
local liftParams = RaycastParams.new()
liftParams.FilterType = Enum.RaycastFilterType.Include
function Sigils.groundLift(position: Vector3, material: Enum.Material?): number
	local L = Data.lift
	local mat = material
	if not mat then
		liftParams.FilterDescendantsInstances = { workspace.Terrain }
		local hit = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -5, 0), liftParams)
		mat = if hit then hit.Material else nil
	end
	if mat and table.find(L.grassMaterials, mat.Name) then
		local ok, grass = pcall(function()
			return workspace.Terrain.GrassLength
		end)
		return (if ok and typeof(grass) == "number" then grass else 0.7) + L.aboveGrass
	end
	return L.base
end

-- A mark where a spell landed: it snaps open, holds, then fades.
function Sigils.stamp(spec: Spec, position: Vector3, normal: Vector3, diameter: number, hold: number?)
	local S, T = Data.size, Data.timing
	local d = math.clamp(diameter, S.stampMin, S.stampMax)
	local up = if normal.Magnitude > 0.1 then normal.Unit else Vector3.yAxis
	local look = if math.abs(up.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
	local right = look:Cross(up).Unit
	local cf = CFrame.fromMatrix(position + up * Sigils.groundLift(position), right, up) -- UpVector = the surface normal
	local h = Sigils.create(spec, cf, d, { grow = T.stampGrow, from = d * 0.3 })
	if not h then
		return
	end
	task.delay(T.stampGrow + (hold or T.stampHold), function()
		Sigils.fade(h, T.stampFade)
	end)
end

-- For specs and tooling: every family's pattern, band and core can be drawn.
function Sigils.knows(pattern: string, band: string, core: string): boolean
	return patterns[pattern] ~= nil and bands[band] ~= nil and cores[core] ~= nil
end

return Sigils
