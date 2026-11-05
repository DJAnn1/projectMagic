--!strict
--[[
	Teleport and movement tools.

	tp <where> [target]      where: settlement | village | town | city | poi | shrine | school |
	                         awakening | ruin | mythic | biome | spawn | nexus | ley | coords |
	                         player | npc | random | up | down | cursor | bookmark
	    target depends on `where`: a name, an index ("tp village 3" = the third village), an id,
	    "x z" / "x y z" coordinates, a number of studs (up/down), or @cursor. Without a target:
	    the nearest one.
	tpsettlement / tppoi / tpnpc / tpplayer / tpbiome   the same with a dropdown for the panel
	bookmark <save|go|delete|list> [name]   persisted per admin (AdminData store)
	fly [on|off] [speed] · noclip [on|off] · walkspeed <n> · jumppower <n> · resetmovement
	    fly and noclip run on the admin's client (it owns its character's physics); the server
	    only grants them. Speeds are set on the server Humanoid.
]]

local Players = game:GetService("Players")

local Util = require(script.Parent.Parent.Util)
local WorldConfig = require(script.Parent.Parent.Parent.World.WorldConfig)

local GROUPS: { [string]: (string) -> boolean } = {
	shrine = function(t)
		return string.sub(t, 1, 7) == "shrine_"
	end,
	school = function(t)
		return t == "academy"
	end,
	awakening = function(t)
		return t == "singing_caverns" or t == "hollow_grove" or t == "sunken_shrine" or t == "quiet_place"
	end,
	ruin = function(t)
		return t == "ruined_library" or t == "dungeon" or t == "hermit_tower"
	end,
	mythic = function(t)
		return string.sub(t, 1, 7) == "mythic_"
	end,
}

local KINDS = {
	"settlement", "village", "town", "city", "poi", "shrine", "school", "awakening", "ruin", "mythic",
	"biome", "spawn", "nexus", "ley", "coords", "player", "npc", "random", "up", "down", "cursor", "bookmark",
}

return function(admin: any, deps: any)
	local world = deps.world
	local npcs = deps.npcs
	local bookmarks = deps.bookmarks
	local movement: { [Player]: { fly: boolean, noclip: boolean, flySpeed: number } } = {}

	local function here(player: Player): Vector3?
		local root = Util.rootOf(player)
		return if root then root.Position else nil
	end

	-- The nearest of a list of things with x/z, or the n-th (1-based) when `index` is given.
	local function pick(list: { any }, from: Vector3?, index: number?): any?
		if index then
			return list[index]
		end
		local best, bestD = nil, math.huge
		for _, item in list do
			local d = if from then (item.x - from.X) ^ 2 + (item.z - from.Z) ^ 2 else 0
			if d < bestD then
				best, bestD = item, d
			end
		end
		return best
	end

	local function byName(list: { any }, raw: string, nameOf: (any) -> string): any?
		local lower = string.lower(raw)
		for _, item in list do
			if string.lower(nameOf(item)) == lower then
				return item
			end
		end
		for _, item in list do
			if string.find(string.lower(nameOf(item)), lower, 1, true) then
				return item
			end
		end
		return nil
	end

	local function parseCoords(target: string?): Vector3?
		local nums = {}
		for n in string.gmatch(target or "", "-?%d+%.?%d*") do
			table.insert(nums, tonumber(n))
		end
		if #nums == 2 then
			return Vector3.new(nums[1], 0, nums[2])
		elseif #nums == 3 then
			return Vector3.new(nums[1], nums[2], nums[3])
		end
		return nil
	end

	-- Resolves a destination. Returns (position, snapToGround, label) or (nil, false, error).
	local function resolve(ctx: any, where: string, target: string?): (Vector3?, boolean, string)
		local player: Player = ctx.player
		local from = here(player)
		local index = tonumber(target or "")
		local placement = world:placement()

		if where == "settlement" or where == "village" or where == "town" or where == "city" then
			local list = {}
			for _, s in placement.settlements do
				if where == "settlement" or s.size == where then
					table.insert(list, s)
				end
			end
			local s = if target and not index then byName(list, target, function(x)
				return x.name
			end) else pick(list, from, index)
			if not s then
				return nil, false, "no such " .. where .. " (" .. #list .. " exist)"
			end
			return Vector3.new(s.x, 0, s.z), true, s.name
		elseif where == "poi" or GROUPS[where] then
			local list = {}
			for _, poi in placement.pois do
				if where == "poi" or GROUPS[where](poi.type) then
					table.insert(list, poi)
				end
			end
			local poi = if target and not index then (placement.byId[target] or byName(list, target, function(x)
				return x.id .. " " .. x.type
			end)) else pick(list, from, index)
			if not poi then
				return nil, false, "no such " .. where .. " (" .. #list .. " exist)"
			end
			return Vector3.new(poi.x, 0, poi.z), true, poi.id .. " (" .. poi.type .. ")"
		elseif where == "biome" then
			if not target then
				return nil, false, "tp biome <biome id>"
			end
			local best, bestD = nil, math.huge
			for _, cell in world:index().cells do
				if cell.sample.biome == target or string.find(cell.sample.biome, string.lower(target), 1, true) then
					local d = if from then (cell.x - from.X) ^ 2 + (cell.z - from.Z) ^ 2 else 0
					if d < bestD then
						best, bestD = cell, d
					end
				end
			end
			if not best then
				return nil, false, "no " .. target .. " on this world's coarse grid"
			end
			return Vector3.new(best.x, 0, best.z), true, "nearest " .. best.sample.biome
		elseif where == "spawn" then
			local spawn = workspace:FindFirstChild("WorldSpawn")
			if not spawn or not spawn:IsA("BasePart") then
				return nil, false, "no world spawn yet"
			end
			return spawn.Position + Vector3.new(0, 3, 0), false, "world spawn"
		elseif where == "nexus" then
			local list = world:nexuses()
			local nexus = if target and not index then byName(list, target, function(x)
				return x.domain .. " " .. x.id
			end) else pick(list, from, index)
			if not nexus then
				return nil, false, "no such nexus (" .. #list .. " exist)"
			end
			return Vector3.new(nexus.x, 0, nexus.z), true, string.format("nexus %s (%s, strength %.2f)", nexus.id, nexus.domain, nexus.strength)
		elseif where == "ley" then
			local lines = world:magicMap().lines
			if #lines == 0 then
				return nil, false, "no ley lines"
			end
			local line = if index then lines[index] else nil
			if line then
				return Vector3.new((line.a.x + line.b.x) / 2, 0, (line.a.z + line.b.z) / 2), true, "ley line " .. index .. " midpoint (" .. line.domain .. ")"
			end
			-- Nearest point on any line.
			local best, bestD, label = Vector3.zero, math.huge, ""
			local p = from or Vector3.zero
			for i, l in lines do
				local ax, az, bx, bz = l.a.x, l.a.z, l.b.x, l.b.z
				local dx, dz = bx - ax, bz - az
				local t = math.clamp(((p.X - ax) * dx + (p.Z - az) * dz) / math.max(dx * dx + dz * dz, 1), 0, 1)
				local q = Vector3.new(ax + dx * t, 0, az + dz * t)
				local d = (q - Vector3.new(p.X, 0, p.Z)).Magnitude
				if d < bestD then
					best, bestD, label = q, d, "ley line " .. i .. " (" .. l.domain .. ")"
				end
			end
			return best, true, label
		elseif where == "coords" then
			local v = parseCoords(target)
			if not v then
				return nil, false, "tp coords <x z> or <x y z>"
			end
			return v, v.Y == 0, "coordinates"
		elseif where == "player" then
			local lower = string.lower(target or "")
			for _, other in Players:GetPlayers() do
				if string.lower(other.Name) == lower or string.lower(other.DisplayName) == lower or string.find(string.lower(other.Name), lower, 1, true) then
					local root = Util.rootOf(other)
					if root and other ~= player then
						return root.Position + Vector3.new(3, 0, 0), false, other.Name
					end
				end
			end
			return nil, false, "no other player '" .. tostring(target) .. "'"
		elseif where == "npc" then
			local npc = npcs:isReady() and npcs:find(target, player)
			if not npc then
				return nil, false, "no NPC '" .. tostring(target) .. "'"
			end
			return npcs:positionOf(npc) + Vector3.new(4, 4, 0), false, npc.name .. " (" .. npc.id .. ")"
		elseif where == "random" then
			local rng = Random.new()
			local half = WorldConfig.WORLD_SIZE / 2 * 0.8
			return Vector3.new(rng:NextNumber(-half, half), 0, rng:NextNumber(-half, half)), true, "somewhere random"
		elseif where == "up" or where == "down" then
			local n = tonumber(target or "") or 50
			if not from then
				return nil, false, "no character"
			end
			return from + Vector3.new(0, if where == "up" then n else -n, 0), false, where .. " " .. n
		elseif where == "cursor" then
			local v = parseCoords(target)
			if not v then
				return nil, false, "tp cursor needs @cursor (the panel fills it in)"
			end
			return v + Vector3.new(0, 4, 0), false, "cursor"
		elseif where == "bookmark" then
			local list = bookmarks.list(player)
			local entry = list[target or ""]
			if not entry then
				for name, value in list do
					if string.find(string.lower(name), string.lower(target or ""), 1, true) then
						entry, target = value, name
					end
				end
			end
			if not entry then
				return nil, false, "no bookmark '" .. tostring(target) .. "'"
			end
			return Vector3.new(entry.x, entry.y, entry.z), false, "bookmark " .. tostring(target)
		end
		return nil, false, "unknown destination " .. where
	end

	local function go(ctx: any, where: string, target: string?): string
		local position, snap, label = resolve(ctx, where, target)
		if not position then
			return label
		end
		local ok, message = Util.teleport(ctx.player, world, position, snap)
		return if ok then label .. ": " .. message else message
	end

	admin:Register({
		name = "tp", aliases = { "teleport", "goto" }, category = "Teleport",
		description = "Teleport anywhere. e.g. tp village 3 · tp shrine · tp biome tundra · tp coords 120 -400 · tp up 100 · tp cursor @cursor",
		args = {
			{ name = "where", type = "enum", options = KINDS },
			{ name = "target", type = "text", optional = true, hint = "name, index, id, coords, studs or @cursor" },
		},
		handler = function(ctx, a)
			return go(ctx, a.where, a.target)
		end,
	})

	admin:Register({
		name = "tpsettlement", category = "Teleport", description = "Teleport to a settlement",
		args = { { name = "settlement", type = "settlement" } },
		handler = function(ctx, a)
			return go(ctx, "settlement", a.settlement.name)
		end,
	})

	admin:Register({
		name = "tppoi", category = "Teleport", description = "Teleport to any point of interest (hidden and mythic sites included)",
		args = { { name = "poi", type = "poi" } },
		handler = function(ctx, a)
			return go(ctx, "poi", a.poi.id)
		end,
	})

	admin:Register({
		name = "tpbiome", category = "Teleport", description = "Teleport to the nearest area of a biome",
		args = { { name = "biome", type = "biome" } },
		handler = function(ctx, a)
			return go(ctx, "biome", a.biome)
		end,
	})

	admin:Register({
		name = "tpnpc", category = "Teleport", description = "Teleport to an NPC",
		args = { { name = "npc", type = "npc" } },
		handler = function(ctx, a)
			return go(ctx, "npc", a.npc.id)
		end,
	})

	admin:Register({
		name = "tpplayer", category = "Teleport", description = "Teleport to another player, or bring them to you",
		args = { { name = "player", type = "player" }, { name = "mode", type = "enum", options = { "to", "bring" }, default = "to" } },
		handler = function(ctx, a)
			local other: Player = a.player
			if other == ctx.player then
				return "that's you"
			end
			if a.mode == "bring" then
				local p = here(ctx.player)
				if not p then
					return "no character"
				end
				local ok, message = Util.teleport(other, world, p + Vector3.new(3, 0, 0), false)
				return if ok then "brought " .. other.Name else message
			end
			return go(ctx, "player", other.Name)
		end,
	})

	admin:Register({
		name = "tpcursor", category = "Teleport", description = "Teleport to where you click (the panel fills @cursor)",
		args = { { name = "at", type = "vector3", hint = "@cursor" } },
		handler = function(ctx, a)
			local _, message = Util.teleport(ctx.player, world, a.at + Vector3.new(0, 4, 0), false)
			return message
		end,
	})

	admin:Register({
		name = "bookmark", aliases = { "bm" }, category = "Teleport",
		description = "Save, go to, delete or list your position bookmarks (kept between sessions)",
		args = {
			{ name = "action", type = "enum", options = { "save", "go", "delete", "list" }, default = "list" },
			{ name = "name", type = "text", optional = true },
		},
		handler = function(ctx, a)
			local player: Player = ctx.player
			if a.action == "list" then
				local lines = {}
				for name, at in bookmarks.list(player) do
					table.insert(lines, string.format("%s  %s", name, Util.fmt(Vector3.new(at.x, at.y, at.z))))
				end
				table.sort(lines)
				return if #lines > 0 then table.concat(lines, "\n") else "(no bookmarks; bookmark save <name>)"
			end
			if not a.name then
				return "bookmark " .. a.action .. " needs a name"
			end
			local name = string.sub(a.name, 1, 40)
			if a.action == "save" then
				local p = here(player)
				if not p then
					return "no character"
				end
				local ok = bookmarks.set(player, name, { x = math.floor(p.X), y = math.floor(p.Y), z = math.floor(p.Z), at = os.time() })
				return if ok then "saved " .. name .. " at " .. Util.fmt(p) else "saved for this session (store write failed)"
			elseif a.action == "delete" then
				bookmarks.set(player, name, nil)
				return "deleted " .. name
			end
			return go(ctx, "bookmark", name)
		end,
	})

	-- ─── Movement ───────────────────────────────────────────────────────────

	local function stateOf(player: Player)
		local s = movement[player]
		if not s then
			s = { fly = false, noclip = false, flySpeed = 80 }
			movement[player] = s
		end
		return s
	end
	Players.PlayerRemoving:Connect(function(player)
		movement[player] = nil
	end)

	admin:Register({
		name = "fly", category = "Movement", description = "Toggle flying (WASD + Space/Ctrl, camera-relative)",
		args = {
			{ name = "on", type = "boolean", optional = true },
			{ name = "speed", type = "number", min = 10, max = 1000, optional = true, slider = true },
		},
		handler = function(ctx, a)
			local s = stateOf(ctx.player)
			s.fly = if a.on == nil then not s.fly else a.on
			s.flySpeed = a.speed or s.flySpeed
			return { text = string.format("fly %s (speed %d)", if s.fly then "on" else "off", s.flySpeed), data = { kind = "movement", fly = s.fly, flySpeed = s.flySpeed, noclip = s.noclip } }
		end,
	})

	admin:Register({
		name = "noclip", category = "Movement", description = "Toggle walking through walls and terrain",
		args = { { name = "on", type = "boolean", optional = true } },
		handler = function(ctx, a)
			local s = stateOf(ctx.player)
			s.noclip = if a.on == nil then not s.noclip else a.on
			return { text = "noclip " .. (if s.noclip then "on" else "off"), data = { kind = "movement", fly = s.fly, flySpeed = s.flySpeed, noclip = s.noclip } }
		end,
	})

	admin:Register({
		name = "walkspeed", aliases = { "speed" }, category = "Movement", description = "Set your walk speed (16 = normal)",
		args = { { name = "speed", type = "number", min = 0, max = 500, default = 16, slider = true } },
		handler = function(ctx, a)
			local humanoid = Util.humanoidOf(ctx.player)
			if not humanoid then
				return "no character"
			end
			humanoid.WalkSpeed = a.speed
			return "walk speed " .. a.speed
		end,
	})

	admin:Register({
		name = "jumppower", aliases = { "jump" }, category = "Movement", description = "Set your jump power (50 = normal)",
		args = { { name = "power", type = "number", min = 0, max = 1000, default = 50, slider = true } },
		handler = function(ctx, a)
			local humanoid = Util.humanoidOf(ctx.player)
			if not humanoid then
				return "no character"
			end
			humanoid.UseJumpPower = true
			humanoid.JumpPower = a.power
			return "jump power " .. a.power
		end,
	})

	admin:Register({
		name = "resetmovement", category = "Movement", description = "Fly and noclip off, normal walk speed and jump",
		handler = function(ctx)
			local s = stateOf(ctx.player)
			s.fly, s.noclip = false, false
			local humanoid = Util.humanoidOf(ctx.player)
			if humanoid then
				humanoid.WalkSpeed = 16
				humanoid.UseJumpPower = true
				humanoid.JumpPower = 50
			end
			return { text = "movement reset", data = { kind = "movement", fly = false, flySpeed = s.flySpeed, noclip = false } }
		end,
	})
end
