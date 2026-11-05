--!strict
--[[
	AdminToolsService: the Admin/Developer Panel's test tools. It registers the shared argument
	types (magic ids, NPC data ids, NPCs, bookmarks) and loads one module per category from
	Server/Admin/Commands, each `return function(admin, deps)`:

		Teleport   tp (settlements, POIs, biomes, spawn, nexus, ley, coords, players, NPCs, random,
		           up/down, cursor, bookmarks), bookmark, fly, noclip, walkspeed, jumppower
		Magic      setmastery, setxp, addxp, resetbranch, resetprogression, unlock, lock, commit,
		           renounce, mythic, unlockall
		Profile    affinity, capacity, regen, temperament, growth, signature, reroll, forcerarity,
		           awaken, revealall
		Spells     cheat, overpower, density, cast, spellstats, dummy
		World      seed, reseed, regenworld, regenchunk, regensettlements, time, daylength,
		           timescale, spawnpoi, spawnsettlement
		Terrain    terrain (carve, raise, flood, smooth), deltas
		Overlays   overlay (density, resonance, ley, stress, water, biomes, chunks, settlements, npclod)
		Npc        every NPC tool and population control
		Deferred   commands for systems that don't exist yet (listed, greyed out)

	Commands owned by a service (CastService's refill, EventDirector's startevent, ...) are
	registered by that service; this one only adds tools that span several systems.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local Temperaments = require(Shared.Magic.Data.Temperaments)
local GrowthCurves = require(Shared.Magic.Data.GrowthCurves)

local Server = script.Parent.Parent
local Schemas = require(Server.Persistence.Schemas)
local AwakeningEvents = require(Server.Magic.Data.AwakeningEvents)
local NpcData = require(Server.NPC.Data.NpcData)
local Quirks = require(Server.NPC.Data.Quirks)
local NeedsActions = require(Server.NPC.Data.NeedsActions)
local Commands = Server.Admin.Commands

local AdminToolsService = {
	name = "AdminToolsService",
	dependencies = {
		"AdminService",
		"DataService",
		"WorldService",
		"WorldStateService",
		"PlayerDataService",
		"ProgressionService",
		"SpecializationService",
		"ReservoirService",
		"CastService",
		"EventDirector",
		"EffectRunner",
		"NPCService",
		"SettlementService",
	},
}

local function sortedKeys(t: { [string]: any }): { string }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- An id type over a fixed list; ids or display names both match.
local function idType(admin: any, name: string, ids: { string }, displayName: ((string) -> string)?)
	local byName: { [string]: string } = {}
	local options = table.clone(ids)
	if displayName then
		for _, id in ids do
			byName[string.lower(displayName(id))] = id
		end
	end
	admin:RegisterType(name, {
		parse = function(raw: string)
			local viaName = byName[string.lower(raw)]
			if viaName then
				return viaName, nil
			end
			return admin.matchOption(raw, options)
		end,
		options = function()
			return options
		end,
	})
end

local function registerTypes(admin: any, npcs: any, bookmarks: any)
	idType(admin, "domain", Registry.domainIds, function(id)
		return Registry.domains[id].name
	end)
	idType(admin, "branch", Registry.branchIds, function(id)
		return Registry.branches[id].name
	end)
	idType(admin, "property", Registry.propertyIds)
	idType(admin, "verb", Registry.verbIds)
	idType(admin, "form", Registry.formIds)
	idType(admin, "modifier", Registry.modifierIds)
	idType(admin, "temperament", sortedKeys(Temperaments))
	idType(admin, "growth", sortedKeys(GrowthCurves))
	idType(admin, "awakening", sortedKeys(AwakeningEvents))
	idType(admin, "specialization", sortedKeys(Registry.specializations))
	idType(admin, "occupation", NpcData.occupationIds)
	idType(admin, "quirk", Quirks.ids)
	local traits = table.clone(NpcData.bigFive)
	for _, t in NpcData.custom do
		table.insert(traits, t)
	end
	idType(admin, "trait", traits)
	idType(admin, "need", NeedsActions.needs)
	local actions = table.clone(NeedsActions.actionIds)
	for _, a in npcs.specialActions do
		table.insert(actions, a)
	end
	idType(admin, "npcaction", actions)
	local ambitions = {}
	for _, a in NpcData.ambitions do
		table.insert(ambitions, a.id)
	end
	idType(admin, "ambition", ambitions)
	local mythics = {}
	for _, id in Registry.domainIds do
		if Registry.domains[id].rarity == "Mythic" then
			table.insert(mythics, id)
		end
	end
	idType(admin, "mythic", mythics)

	-- Mastery tier: 0-8 or a tier name (Grandmaster).
	local tierNames = {}
	for _, t in MasteryTiers.tiers do
		table.insert(tierNames, t.name)
	end
	admin:RegisterType("tier", {
		parse = function(raw: string)
			local n = tonumber(raw)
			if n then
				if n % 1 == 0 and n >= 0 and n <= 8 then
					return n, nil
				end
				return nil, "tier must be 0-8"
			end
			local name, err = admin.matchOption(raw, tierNames)
			for _, t in MasteryTiers.tiers do
				if t.name == name then
					return t.index, nil
				end
			end
			return nil, err
		end,
		options = function()
			return tierNames
		end,
	})

	-- What setmastery applies to: all, a domain, a branch, or "Domain/Branch" (the branch wins).
	admin:RegisterType("masterytarget", {
		parse = function(raw: string)
			if string.lower(raw) == "all" then
				return { kind = "all" }, nil
			end
			local last = string.match(raw, "([^/]+)$") or raw
			local lower = string.lower(last)
			if Registry.domains[lower] and not string.find(raw, "/") then
				return { kind = "domain", id = lower }, nil
			end
			for _, id in Registry.branchIds do
				if id == lower or string.lower(Registry.branches[id].name) == lower then
					return { kind = "branch", id = id }, nil
				end
			end
			for _, id in Registry.domainIds do
				if string.lower(Registry.domains[id].name) == lower then
					return { kind = "domain", id = id }, nil
				end
			end
			return nil, "no domain or branch '" .. raw .. "'"
		end,
		options = function()
			local out = { "all" }
			for _, id in Registry.domainIds do
				table.insert(out, id)
			end
			for _, id in Registry.branchIds do
				if not Registry.branches[id].isRoot then
					table.insert(out, id)
				end
			end
			return out
		end,
	})

	-- An NPC: id, (part of) a name, "nearest", or "@selected" (filled in by the panel).
	admin:RegisterType("npc", {
		parse = function(raw: string, ctx: any)
			if not npcs:isReady() then
				return nil, "NPCs aren't ready"
			end
			local query: string? = if string.lower(raw) == "nearest" then nil else raw
			local npc = npcs:find(query, ctx.player)
			return npc, if npc then nil else "no NPC '" .. raw .. "'"
		end,
		options = function()
			local out = { "nearest" }
			for _, npc in npcs:all() do
				table.insert(out, npc.name)
			end
			return out
		end,
	})

	admin:RegisterType("bookmark", {
		parse = function(raw: string, ctx: any)
			local list = bookmarks.list(ctx.player)
			local names = {}
			for name in list do
				table.insert(names, name)
			end
			local name, err = admin.matchOption(raw, names)
			return if name then { name = name, at = list[name] } else nil, err
		end,
		options = function(ctx: any)
			local names = {}
			for name in bookmarks.list(ctx.player) do
				table.insert(names, name)
			end
			table.sort(names)
			return names
		end,
	})
end

-- Bookmarks persist per admin (AdminData store, key "admin_<userId>"), cached per session.
local function bookmarkStore(dataService: any)
	local store = dataService:openStore(Schemas.AdminData)
	local cache: { [number]: { [string]: any } } = {}
	local api = {}
	function api.list(player: Player): { [string]: any }
		local list = cache[player.UserId]
		if not list then
			local data = store:read("admin_" .. player.UserId)
			list = if data then data.bookmarks else {}
			cache[player.UserId] = list :: any
		end
		return list :: any
	end
	function api.set(player: Player, name: string, value: any?): boolean
		local list = api.list(player)
		list[name] = value
		local _, err = store:update("admin_" .. player.UserId, function(data)
			data.bookmarks[name] = value
			return data
		end)
		return err == nil
	end
	return api
end

function AdminToolsService.init(_self: any, ctx: any)
	local admin = ctx.get("AdminService")
	local deps = {
		admin = admin,
		log = ctx.log,
		flags = ctx.flags,
		bus = ctx.bus,
		dataService = ctx.get("DataService"),
		worldService = ctx.get("WorldService"),
		world = ctx.get("WorldStateService"),
		playerData = ctx.get("PlayerDataService"),
		progression = ctx.get("ProgressionService"),
		specialization = ctx.get("SpecializationService"),
		reservoirs = ctx.get("ReservoirService"),
		cast = ctx.get("CastService"),
		events = ctx.get("EventDirector"),
		runner = ctx.get("EffectRunner"),
		npcs = ctx.get("NPCService"),
		settlements = ctx.get("SettlementService"),
		bookmarks = nil :: any,
	}
	deps.bookmarks = bookmarkStore(deps.dataService)
	registerTypes(admin, deps.npcs, deps.bookmarks)
	for _, name in { "Teleport", "Magic", "Profile", "Spells", "Combat", "World", "Terrain", "Overlays", "Npc", "Deferred", "Fx" } do
		local module = Commands:FindFirstChild(name)
		assert(module and module:IsA("ModuleScript"), "AdminToolsService: missing Admin/Commands/" .. name)
		local register = (require :: any)(module)
		register(admin, deps)
	end
end

return AdminToolsService
