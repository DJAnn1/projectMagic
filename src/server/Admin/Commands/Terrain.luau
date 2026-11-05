--!strict
--[[
	Terrain tools. Every edit goes through WorldStateService:edit, so it is PERSISTENT: saved per
	chunk, replayed on every server and after restarts, exactly like a quake's fault. Undo with
	regenchunk (back to the generated state).

	terrain carve  [radius] [at]               a ball of air
	terrain raise  [radius] [at] [material]    a mound on the surface
	terrain flood  [radius] [at]               water into the air above the surface (not into rock)
	terrain smooth [radius] [at] [material]    levels to the area's average height (radius <= 32)
	deltas <show|clear> [at]                   a chunk's saved edits; clear deletes them for everyone
	                                           (the terrain stays until the chunk is rebuilt)
]]

local Util = require(script.Parent.Parent.Util)
local Server = script.Parent.Parent.Parent
local WorldGen = require(Server.World.WorldGen)
local TerrainDeform = require(Server.World.TerrainDeform)

local MATERIALS = { "Ground", "Grass", "Rock", "Sand", "Mud", "Snow", "Basalt", "Sandstone", "Slate", "Limestone", "Ice", "Salt" }
local SMOOTH_STEP = 4

return function(admin: any, deps: any)
	local world = deps.world

	local function surface(x: number, z: number): number
		local h = TerrainDeform.surfaceAt(world, x, z)
		return h
	end

	admin:Register({
		name = "terrain", category = "Terrain", description = "Carve, raise, flood or smooth terrain at a point (persistent edits)",
		args = {
			{ name = "tool", type = "enum", options = { "carve", "raise", "flood", "smooth" } },
			{ name = "radius", type = "number", min = 2, max = 64, default = 12, slider = true },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: 20 studs ahead)" },
			{ name = "material", type = "enum", options = MATERIALS, default = "Ground" },
		},
		handler = function(ctx, a)
			local at: Vector3? = a.at or Util.ahead(ctx.player, world, 20)
			if not at then
				return "no character"
			end
			local r: number = a.radius
			local ground = surface(at.X, at.Z)
			local ops: { any } = {}
			if a.tool == "carve" then
				table.insert(ops, { k = "ball", m = "Air", x = at.X, y = at.Y, z = at.Z, r = r })
			elseif a.tool == "raise" then
				table.insert(ops, { k = "ball", m = a.material, x = at.X, y = ground, z = at.Z, r = r })
			elseif a.tool == "flood" then
				table.insert(ops, { k = "replace", m = "Water", f = "Air", x = at.X, y = ground + r / 2, z = at.Z, sx = r * 2, sy = r, sz = r * 2 })
			else
				if r > 32 then
					return "smooth radius is at most 32"
				end
				local heights, sum, count = {}, 0, 0
				local lo, hi = math.huge, -math.huge
				for dx = -r, r, SMOOTH_STEP do
					for dz = -r, r, SMOOTH_STEP do
						if dx * dx + dz * dz <= r * r then
							local h = surface(at.X + dx, at.Z + dz)
							table.insert(heights, { dx, dz })
							sum += h
							count += 1
							lo, hi = math.min(lo, h), math.max(hi, h)
						end
					end
				end
				local level = sum / math.max(count, 1)
				for _, cell in heights do
					local x, z = at.X + cell[1], at.Z + cell[2]
					local above = hi + 4 - level
					local below = level - (lo - 4)
					table.insert(ops, { k = "block", m = "Air", x = x, y = level + above / 2, z = z, sx = SMOOTH_STEP, sy = above, sz = SMOOTH_STEP })
					table.insert(ops, { k = "block", m = a.material, x = x, y = level - below / 2, z = z, sx = SMOOTH_STEP, sy = below, sz = SMOOTH_STEP })
				end
			end
			world:edit("admin:" .. a.tool, ops)
			return string.format("%s r%d at %s (%d op%s, saved)", a.tool, r, Util.fmt(at), #ops, if #ops == 1 then "" else "s")
		end,
	})

	admin:Register({
		name = "deltas", category = "Terrain", description = "Show or delete a chunk's saved terrain edits",
		args = {
			{ name = "action", type = "enum", options = { "show", "clear" }, default = "show" },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: you)" },
		},
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			local at: Vector3? = a.at or (root and root.Position)
			if not at then
				return "no character"
			end
			local cx, cz = WorldGen.chunkOf(at.X, at.Z)
			if a.action == "clear" then
				return string.format("chunk %d,%d: %d saved edits deleted (regenchunk to rebuild its terrain)", cx, cz, world:clearChunkDeltas(cx, cz))
			end
			local saved, pending = world:chunkDeltas(cx, cz)
			local lines = { string.format("chunk %d,%d: %d saved, %d not yet flushed", cx, cz, #saved, #pending) }
			for i = math.max(1, #saved - 9), #saved do
				local op = saved[i]
				table.insert(lines, string.format("  %s %s %s at (%d,%d,%d)%s %s", op.i, op.k, op.m, op.x, op.y, op.z,
					if op.r then " r" .. op.r else string.format(" %dx%dx%d", op.sx or 0, op.sy or 0, op.sz or 0), os.date("!%m-%d %H:%M", op.t)))
			end
			return table.concat(lines, "\n")
		end,
	})
end
