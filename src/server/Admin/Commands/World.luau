--!strict
--[[
	World control.

	seed                                  the world seed, generation and epoch
	reseed <seed|random> RESEED           OWNER ONLY: a new world for every server (all close)
	regenworld RESEED                     OWNER ONLY: the same seed, a fresh generation (every
	                                      saved terrain edit, region and town record left behind)
	regenchunk [radius] [at]              chunks back to their generated state (this server builds
	                                      them again; the saved edits are deleted for everyone)
	regensettlements                      settlement state cleared and every NPC regenerated
	time <hour> · daylength <seconds> · timescale <x> · simdays <days>
	spawnpoi <type> [at] · spawnsettlement [size] [culture] [at]   runtime only (not saved)
	rep <settlement> <value> [player]     a player's standing with a settlement
	(event control: startevent / stopevent / events, registered by EventDirector)
]]

local Server = script.Parent.Parent.Parent
local Util = require(script.Parent.Parent.Util)
local AdminConfig = require(Server.Config.AdminConfig)
local WorldClock = require(Server.NPC.WorldClock)
local WorldGen = require(Server.World.WorldGen)
local POIRules = require(Server.World.POIRules)
local Settlements = require(Server.World.Settlements)
local FeatureFlags = require(game:GetService("ReplicatedStorage").Shared.Core.FeatureFlags)

return function(admin: any, deps: any)
	local world = deps.world
	local worldService = deps.worldService
	local npcs = deps.npcs
	local playerData = deps.playerData
	local spawned = 0

	local poiTypes = {}
	local ruleByType: { [string]: any } = {}
	for _, rule in POIRules do
		table.insert(poiTypes, rule.type)
		ruleByType[rule.type] = rule
	end
	table.sort(poiTypes)
	local cultures = {}
	for id in Settlements.cultures do
		table.insert(cultures, id)
	end
	table.sort(cultures)

	admin:Register({
		name = "seed", category = "World", description = "Show the world seed, generation and epoch",
		handler = function()
			return string.format("seed %d · generation %d · epoch %s · world day %d · game clock %s%s",
				worldService:getSeed(), worldService:getGeneration(), os.date("!%Y-%m-%d %H:%M", worldService:getEpoch()),
				worldService:getWorldDay(), WorldClock.stamp(), if WorldClock.isAltered() then " (this server's clock is altered)" else "")
		end,
	})

	admin:Register({
		name = "reseed", category = "World", ownerOnly = true,
		description = "OWNER ONLY. Change the world seed for EVERY server (they all close; players rejoin the new world). Irreversible.",
		args = {
			{ name = "seed", type = "string", hint = "a number 1..2147483646, or random" },
			{ name = "confirm", type = "enum", options = { "RESEED" }, hint = "type RESEED" },
		},
		handler = function(ctx, a)
			local seed = if string.lower(a.seed) == "random" then Random.new():NextInteger(1, 2 ^ 31 - 2) else tonumber(a.seed)
			if not seed then
				return "seed must be a number or random"
			end
			local _, message = worldService:reseed(seed, ctx.player.UserId, AdminConfig.OwnerUserId)
			return message
		end,
	})

	admin:Register({
		name = "regenworld", category = "World", ownerOnly = true,
		description = "OWNER ONLY. Regenerate the whole world from the SAME seed: every saved terrain edit, region and town record is left behind (every server closes).",
		args = { { name = "confirm", type = "enum", options = { "RESEED" }, hint = "type RESEED" } },
		handler = function(ctx)
			local _, message = worldService:reseed(worldService:getSeed(), ctx.player.UserId, AdminConfig.OwnerUserId)
			return message
		end,
	})

	admin:Register({
		name = "regenchunk", aliases = { "regenregion" }, category = "World",
		description = "Reset chunks to their generated state (radius 0 = just this chunk); deletes their saved edits for everyone",
		args = {
			{ name = "radius", type = "integer", min = 0, max = 3, default = 0, slider = true, hint = "in chunks" },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: you)" },
		},
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			local at: Vector3? = a.at or (root and root.Position)
			if not at then
				return "no character"
			end
			local ccx, ccz = WorldGen.chunkOf(at.X, at.Z)
			local n = WorldGen.chunkCount()
			local lines = {}
			for dz = -a.radius, a.radius do
				for dx = -a.radius, a.radius do
					local cx, cz = ccx + dx, ccz + dz
					if cx >= 0 and cz >= 0 and cx < n and cz < n then
						local _, message = world:resetChunk(cx, cz)
						table.insert(lines, message)
					end
				end
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "regensettlements", category = "World", description = "Clear every settlement's saved state and regenerate all NPCs",
		handler = function()
			world:clearSettlementState()
			return "settlement state cleared; " .. npcs:rebuild()
		end,
	})

	admin:Register({
		name = "time", aliases = { "settime" }, category = "World", description = "Jump this server's game clock forward to an hour of the day",
		args = { { name = "hour", type = "number", min = 0, max = 23.99, slider = true } },
		handler = function(_, a)
			WorldClock.setHour(a.hour)
			return "it is now " .. WorldClock.stamp() .. " on this server"
		end,
	})

	admin:Register({
		name = "daylength", category = "World", description = "Real seconds per game day (npc_day_seconds; default 1440)",
		args = { { name = "seconds", type = "number", min = 60, max = 86400 } },
		handler = function(_, a)
			local ok, why = FeatureFlags.set("npc_day_seconds", a.seconds)
			return if ok then string.format("a game day now lasts %d s (%.1f min)", a.seconds, a.seconds / 60) else "failed: " .. tostring(why)
		end,
	})

	admin:Register({
		name = "timescale", category = "World", description = "Game time speed on this server: 0 pauses NPC life, 1 normal, 5/20/100 to watch it fast",
		args = { { name = "scale", type = "number", min = 0, max = 1000, hint = "0, 1, 5, 20, 100" } },
		handler = function(_, a)
			WorldClock.setScale(a.scale)
			local perHour = WorldClock.secondsPerHour()
			return string.format("time x%g · a game hour now takes %s", a.scale, if perHour == math.huge then "forever (paused)" else string.format("%.1f s", perHour))
		end,
	})

	admin:Register({
		name = "simdays", category = "Population", description = "Simulate N in-game days instantly (needs, chapters of magical careers, recovery)",
		args = { { name = "days", type = "number", min = 0.05, max = 3650 } },
		handler = function(_, a)
			return npcs:simulateDays(a.days)
		end,
	})

	-- ─── Structures (runtime only) ──────────────────────────────────────────

	local function poiAt(ruleType: string, at: Vector3): any
		local rule = ruleByType[ruleType]
		spawned += 1
		return {
			id = string.format("%s_admin%d", ruleType, spawned),
			type = ruleType,
			x = at.X,
			z = at.Z,
			biome = world:gen():sample(at.X, at.Z).biome,
			radius = rule.radius,
			hidden = rule.hidden == true,
			grants = rule.grants or {},
			settlement = nil,
			hints = {},
		}
	end

	admin:Register({
		name = "spawnpoi", aliases = { "spawnsite" }, category = "World",
		description = "Place a point of interest (shrine, academy, awakening or MYTHIC site...) at a point. Works at once; not saved",
		args = {
			{ name = "type", type = "enum", options = poiTypes },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: 20 studs ahead)" },
		},
		handler = function(ctx, a)
			local at: Vector3? = a.at or Util.ahead(ctx.player, world, 20)
			if not at then
				return "no character"
			end
			local poi = poiAt(a.type, at)
			world:addPOI(poi)
			return string.format("placed %s (radius %d) at %s%s", poi.id, poi.radius, Util.fmt(at), if poi.hidden then " (hidden site)" else "")
		end,
	})

	admin:Register({
		name = "spawnsettlement", category = "World", description = "Found a settlement here, with generated residents. Not saved",
		args = {
			{ name = "size", type = "enum", options = { "village", "town", "city" }, default = "village" },
			{ name = "culture", type = "enum", options = cultures, optional = true },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: you)" },
		},
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			local at: Vector3? = a.at or (root and root.Position)
			if not at then
				return "no character"
			end
			local rng = Random.new()
			local poi = poiAt("settlement", at)
			local settlement: Settlements.Settlement = {
				id = poi.id,
				name = Settlements.makeName(rng),
				culture = a.culture or cultures[rng:NextInteger(1, #cultures)],
				size = a.size,
				x = at.X,
				z = at.Z,
				population = if a.size == "city" then 40 elseif a.size == "town" then 18 else 8,
				relations = {},
			}
			poi.settlement = settlement
			world:addPOI(poi)
			local count = if npcs:isReady() then npcs:addTown(settlement, poi.radius) else 0
			return string.format("founded %s (%s %s) with %d residents", settlement.name, settlement.size, settlement.culture, count)
		end,
	})

	-- ─── Reputation (the faction system that exists today) ──────────────────

	admin:Register({
		name = "rep", aliases = { "reputation" }, category = "Quests & factions",
		description = "Set a player's reputation with a settlement (crimes are negative, deeds positive)",
		args = {
			{ name = "settlement", type = "settlement" },
			{ name = "value", type = "number", min = -1000, max = 1000 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = playerData:get(a.player)
			if not state then
				return "not loaded"
			end
			state.data.reputation[a.settlement.id] = a.value
			return string.format("%s's reputation in %s = %d", a.player.Name, a.settlement.name, a.value)
		end,
	})
end
