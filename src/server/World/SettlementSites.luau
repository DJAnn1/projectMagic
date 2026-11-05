--!strict
--[[
	SettlementSites: Step 1 of procedural settlements, choosing where exactly a settlement sits.

	POIPlacer picks WHICH coarse 128-stud cells get settlements (flat, dry, near the coast and
	moisture, 420+ studs apart, best N by score, seeded). Those picks become settlement ids that
	NPC towns and saves depend on, so they stay. This module then refines each pick: it scans
	the seeded height field (WorldGen:height, no raycasts, no terrain needed) around the pick and
	moves the centre to the best open, flat, dry spot within SEARCH studs.

	For each candidate centre on a 16-stud grid within SEARCH (about 110 candidates x 30 height
	samples, a few ms per settlement):
	    dry      every sample within the open radius stands SEA_LEVEL + MIN_DRY above sea
	    flat     height spread (max - min) within the open radius
	    slope    worst height step between neighbouring samples (cliffs disqualify)
	    score    = 4 x flatness + 1 x water nearby + 0.6 x ore nearby + 0.5 x forest/moisture
	               - 0.002 x distance moved (prefer staying near the coarse pick)
	Ties break by position, so the result is the same on every server.
]]

local C = require(script.Parent.WorldConfig)

local SEARCH = 96 -- how far the centre may move from the coarse pick
local GRID = 16 -- candidate spacing
local RING = 24 -- sample spacing inside the open radius
local MIN_DRY = 3
local MAX_STEP = 8 -- studs between samples RING apart (slope 1:3); more is a cliff
local FOREST = { deep_forest = 1, grasslands = 0.4, swamp = 0.5, tundra = 0.2 }

local SettlementSites = {}
-- The open radius scored for every site (tiers are assigned after placement, by rank).
SettlementSites.OPEN_RADIUS = 96

export type Site = {
	x: number,
	z: number,
	height: number,
	flatness: number, -- 0..1
	spread: number, -- studs of height variation within the open radius
	score: number,
	moved: number,
}

-- Heights on a square grid of `RING`-spaced samples within `radius` of (x, z).
local function samples(gen: any, x: number, z: number, radius: number): ({ { number } }, number)
	local rows: { { number } } = {}
	local n = math.floor(radius / RING)
	for j = -n, n do
		local row = {}
		for i = -n, n do
			if i * i + j * j <= n * n then
				row[i + n + 1] = gen:height(x + i * RING, z + j * RING)
			end
		end
		rows[j + n + 1] = row
	end
	return rows, n
end

-- Evaluates one candidate centre. Nil when it's wet or broken by a cliff.
function SettlementSites.evaluate(gen: any, index: any, x: number, z: number, radius: number): Site?
	local rows, n = samples(gen, x, z, radius)
	local lo, hi, sum, count = math.huge, -math.huge, 0, 0
	local worstStep = 0
	for j = 1, 2 * n + 1 do
		local row = rows[j]
		for i = 1, 2 * n + 1 do
			local h = row[i]
			if h then
				if h < C.SEA_LEVEL + MIN_DRY then
					return nil
				end
				lo, hi = math.min(lo, h), math.max(hi, h)
				sum += h
				count += 1
				local right, down = row[i + 1], rows[j + 1] and rows[j + 1][i]
				if right then
					worstStep = math.max(worstStep, math.abs(right - h))
				end
				if down then
					worstStep = math.max(worstStep, math.abs(down - h))
				end
			end
		end
	end
	if count == 0 or worstStep > MAX_STEP then
		return nil
	end
	local spread = hi - lo
	local flatness = math.clamp(1 - spread / 30, 0, 1)

	-- Resources around the site: water within 2.5 radii, ore and forest from the coarse index.
	local water = 0
	for a = 0, 7 do
		local angle = a / 8 * math.pi * 2
		local wx, wz = x + math.cos(angle) * radius * 2.5, z + math.sin(angle) * radius * 2.5
		if gen:height(wx, wz) < C.SEA_LEVEL then
			water = 1
			break
		end
	end
	local cell = index:cellAt(x, z)
	local ore = math.clamp(cell.ore or 0, 0, 1)
	local forest = (FOREST[cell.sample.biome] or 0) * 0.6 + math.clamp(cell.sample.moisture, 0, 1) * 0.4

	return {
		x = x,
		z = z,
		height = sum / count,
		flatness = flatness,
		spread = spread,
		score = 4 * flatness + water + 0.6 * ore + 0.5 * forest,
		moved = 0,
	}
end

-- The smaller open radius tried when nothing qualifies at the full one (tight coasts, hills).
SettlementSites.FALLBACK_RADIUS = 56

-- One scan at one open radius: the best valid site, or nil.
local function scan(gen: any, index: any, x: number, z: number, radius: number, yieldFn: (() -> ())?): Site?
	local best: Site? = nil
	local steps = math.floor(SEARCH / GRID)
	for dz = -steps, steps do
		for dx = -steps, steps do
			if dx * dx + dz * dz > steps * steps then
				continue
			end
			local cx, cz = x + dx * GRID, z + dz * GRID
			local site = SettlementSites.evaluate(gen, index, cx, cz, radius)
			if site then
				site.moved = math.sqrt((dx * GRID) ^ 2 + (dz * GRID) ^ 2)
				site.score -= 0.002 * site.moved
				if not best or site.score > best.score or (site.score == best.score and (cz * 100000 + cx) < (best.z * 100000 + best.x)) then
					best = site
				end
			end
		end
		if yieldFn then
			yieldFn()
		end
	end
	return best
end

--[[
	The best site within SEARCH studs of a coarse pick: first at the full open radius, then at
	FALLBACK_RADIUS. Nil when there is no dry, cliff-free ground near the pick at all; the caller
	then moves on to its next candidate cell rather than founding a town in the sea.
]]
function SettlementSites.refine(gen: any, index: any, x: number, z: number, radius: number, yieldFn: (() -> ())?): Site?
	return scan(gen, index, x, z, radius, yieldFn) or scan(gen, index, x, z, SettlementSites.FALLBACK_RADIUS, yieldFn)
end

return SettlementSites
