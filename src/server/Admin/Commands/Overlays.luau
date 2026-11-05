--!strict
--[[
	Debug overlays. The server samples the data (only admins ever receive it: some of it, like
	ley lines and hidden sites, is secret) and the admin's client draws it with local parts.

	overlay <layer> [on|off] [radius]
	  density      ambient magic density heatmap (0 .. 3)
	  resonance    the dominant domain's resonance per cell
	  ley          ley lines and nexus points (whole map)
	  stress       tectonic stress heatmap
	  water        generated water depth below sea level
	  biomes       biome borders
	  chunks       chunk borders (built chunks solid, unbuilt dashed)
	  settlements  settlement outlines and district anchors (whole map)
	  npclod       NPC positions coloured by LOD tier (the panel refreshes it every 2 s)
	  lots         settlement layouts: lot outlines coloured by building type (solid = built,
	               faint = planned), street centre lines, the plaza, failed lots as red markers
	  clear        removes every layer
	Grids are at most 33 x 33 samples around you, so a large radius means coarser cells.
]]

local Util = require(script.Parent.Parent.Util)
local Server = script.Parent.Parent.Parent
local WorldGen = require(Server.World.WorldGen)
local WorldConfig = require(Server.World.WorldConfig)

local LAYERS = { "density", "resonance", "ley", "stress", "water", "biomes", "chunks", "settlements", "npclod", "lots", "clear" }
local GRID = 33

return function(admin: any, deps: any)
	local world = deps.world
	local npcs = deps.npcs
	local settlements = deps.settlements

	-- Samples fn(x, z) on a grid around `center`. Returns (cells, step).
	local function grid(center: Vector3, radius: number, fn: (number, number) -> any): ({ any }, number)
		local step = math.max(8, math.ceil(radius * 2 / (GRID - 1)))
		local cells = {}
		for dz = -radius, radius, step do
			for dx = -radius, radius, step do
				local x, z = center.X + dx, center.Z + dz
				table.insert(cells, { x = x, z = z, y = world:surfaceHeight(x, z), v = fn(x, z) })
			end
		end
		return cells, step
	end

	local function dominant(resonance: { [string]: number }): (string, number)
		local best, bestV = "none", -math.huge
		for d, v in resonance do
			if v > bestV then
				best, bestV = d, v
			end
		end
		return best, bestV
	end

	local function build(layer: string, center: Vector3, radius: number): ({ [string]: any }?, string)
		if layer == "density" then
			local cells, step = grid(center, radius, function(x, z)
				return world:densityAt(x, z)
			end)
			return { cells = cells, step = step, min = 0, max = 3 }, "density heatmap (blue 0 → red 3)"
		elseif layer == "resonance" then
			local map = world:magicMap()
			local cells, step = grid(center, radius, function(x, z)
				local d = dominant(map:resonanceAt(x, z))
				return d
			end)
			return { cells = cells, step = step }, "dominant resonance per cell (colour = domain)"
		elseif layer == "stress" then
			local cells, step = grid(center, radius, function(x, z)
				return world:stressAt(x, z)
			end)
			return { cells = cells, step = step, min = 0, max = 1 }, "tectonic stress (blue low → red high)"
		elseif layer == "water" then
			local gen = world:gen()
			local cells, step = grid(center, radius, function(x, z)
				return math.max(0, WorldConfig.SEA_LEVEL - gen:height(x, z))
			end)
			for _, c in cells do
				c.y = math.max(c.y, WorldConfig.SEA_LEVEL)
			end
			return { cells = cells, step = step, min = 0, max = 60 }, "generated water depth (light → deep)"
		elseif layer == "biomes" then
			local gen = world:gen()
			local cells, step = grid(center, radius, function(x, z)
				return gen:sample(x, z).biome
			end)
			return { cells = cells, step = step }, "biome borders"
		elseif layer == "ley" then
			local nexuses, lines = {}, {}
			for _, n in world:nexuses() do
				table.insert(nexuses, { x = n.x, z = n.z, y = world:surfaceHeight(n.x, n.z), domain = n.domain, strength = n.strength, id = n.id })
			end
			for _, l in world:magicMap().lines do
				table.insert(lines, { ax = l.a.x, az = l.a.z, ay = world:surfaceHeight(l.a.x, l.a.z), bx = l.b.x, bz = l.b.z, by = world:surfaceHeight(l.b.x, l.b.z), domain = l.domain })
			end
			return { nexuses = nexuses, lines = lines }, string.format("%d nexuses, %d ley lines (whole map)", #nexuses, #lines)
		elseif layer == "chunks" then
			local size = WorldConfig.CHUNK_SIZE
			local chunks = {}
			local ccx, ccz = WorldGen.chunkOf(center.X, center.Z)
			local reach = math.ceil(radius / size)
			local n = WorldGen.chunkCount()
			for cz = ccz - reach, ccz + reach do
				for cx = ccx - reach, ccx + reach do
					if cx >= 0 and cz >= 0 and cx < n and cz < n then
						local ox, oz = WorldGen.chunkOrigin(cx, cz)
						table.insert(chunks, { cx = cx, cz = cz, x = ox, z = oz, y = world:surfaceHeight(ox + size / 2, oz + size / 2), built = world:isChunkBuilt(ox + 1, oz + 1) })
					end
				end
			end
			return { chunks = chunks, size = size }, string.format("%d chunks of %d studs", #chunks, size)
		elseif layer == "settlements" then
			local towns = if npcs:isReady() then npcs:townOutlines() else {}
			return { towns = towns }, string.format("%d settlements with district anchors", #towns)
		elseif layer == "lots" then
			local towns = settlements:overlayData(center, radius)
			local lots, failed = 0, 0
			for _, t in towns do
				lots += #t.lots
				failed += #t.failures
			end
			return { towns = towns }, string.format("%d settlements in range: %d lots, %d failed (red)", #towns, lots, failed)
		elseif layer == "npclod" then
			if not npcs:isReady() then
				return nil, "NPCs aren't ready"
			end
			local points = npcs:lodPoints(center, radius)
			return { points = points, live = true }, string.format("%d NPCs (green T0, yellow T1, grey T2, blue frozen)", #points)
		end
		return nil, "unknown layer " .. layer
	end

	local args = {
		{ name = "layer", type = "enum", options = LAYERS },
		{ name = "on", type = "boolean", default = true },
		{ name = "radius", type = "number", min = 64, max = 2048, default = 384, slider = true },
	}

	local function handler(ctx: any, a: any): any
		if a.layer == "clear" or not a.on then
			return { text = if a.layer == "clear" then "overlays cleared" else a.layer .. " off", data = { kind = "overlay", layer = a.layer, on = false } }
		end
		local root = Util.rootOf(ctx.player)
		if not root then
			return "no character"
		end
		local data, text = build(a.layer, root.Position, a.radius)
		if not data then
			return text
		end
		data.kind, data.layer, data.on, data.radius = "overlay", a.layer, true, a.radius
		return { text = text, data = data }
	end

	admin:Register({
		name = "overlay", category = "Overlays", description = "Toggle a debug overlay drawn only on your screen",
		args = args,
		handler = handler,
	})
	-- The panel's live refresh (npclod every 2 s): hidden, so it doesn't fill the audit log.
	admin:Register({ name = "__overlay", hidden = true, category = "Overlays", description = "live overlay refresh", args = args, handler = handler })
end
