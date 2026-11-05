--!strict
--[[
	Schemas: the save shapes for Player, World and NPC records, with their migrations.
	See docs/Backend.md §3 for annotated example payloads.

	version     current schema version; records are migrated up to it on load
	template    a fresh record's data. Missing keys in older records are filled from it (reconcile)
	migrations  migrations[n] upgrades a version-n data table to n+1. Never edit a shipped entry: append.
	compress    top-level fields stored through Codec (large and rarely read whole)
	validate    last check before every write; failing it skips the write (and logs an error)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MagicCore = require(ReplicatedStorage.Shared.Magic.MagicCore)
local MasteryTiers = require(ReplicatedStorage.Shared.Magic.Data.MasteryTiers)
local UISettings = require(ReplicatedStorage.Shared.UI.Settings)

-- Settings with their defaults: the console key plus every interface setting in Shared/UI/Settings.
local function defaultSettings(): { [string]: any }
	local settings: { [string]: any } = { consoleKey = "F2" }
	for id, def in UISettings do
		settings[id] = def.default
	end
	return settings
end

export type StoreConfig = {
	name: string,
	scope: string?,
	version: number,
	template: () -> any,
	migrations: { [number]: (any) -> any },
	compress: { string }?,
	validate: ((any) -> (boolean, string?))?,
}

local Schemas = {}

-- ─── Player (session-locked, key "player_<userId>") ─────────────────────────

Schemas.Player = {
	name = "PlayerData",
	version = 4,
	template = function()
		return {
			-- profile: the InnateProfile (see InnateProfiles.md §7). Absent until first join.
			progression = {
				xp = {}, -- branchId -> XP (source of truth)
				mastery = {}, -- branchId -> 0..100, derived from XP and breakthrough caps
				unlocked = {}, -- branchId -> true
				breakthroughs = {}, -- branchId -> { ["5"] = unix, ... } completed breakthrough tiers
				records = {
					insights = {}, -- "<domain>:<site>" -> unix
					catalysts = {}, -- exposure id -> unix
					survived = {}, -- "<domain>:<event>" -> unix
					taught = {}, -- branchId -> students brought to Novice
					discoveries = {}, -- branchId -> recipes first cast
					feats = {}, -- branchId -> best power cast
					challengeFeats = {}, -- branchId -> best power cast under real danger
					mentors = {}, -- branchId -> best mentor tier studied under
					paradigms = 0, -- signature spells declared
				},
				lore = {}, -- knowledge item id -> unix
				commitments = {}, -- specialization id -> unix
				renouncedAt = 0,
				signatures = {}, -- recipeKey -> unix
				focus = {}, -- domainId -> { v, t } decaying recent XP
				daily = { day = 0, channels = {} },
				hourly = { hour = 0, practice = {} },
				studied = {}, -- study source id -> unix (books once, mentors on cooldown)
				knowledge = 0, -- self-knowledge level 0..3
			},
			spellbook = {}, -- recipeKey -> { recipe, name, favorite, casts, addedAt }
			hotbar = {}, -- slot "1".."10" -> recipeKey (a spellbook entry; cleared when the spell is removed)
			cantrips = {}, -- "<domain>:<kind>" -> unix (a bare "<domain>" = strike + utility, older saves): innate spells granted (CantripService; reconcile fills old saves)
			discoveries = { -- compressed
				recipes = {}, -- recipeKey -> first cast by you (unix)
				worldFirsts = {}, -- recipeKey -> unix; recipes nobody in the world had cast before you
				locations = {}, -- locationId -> first visit (unix)
				lore = {}, -- loreId -> unix
			},
			relationships = {}, -- npcId -> { affinity, trust, memories = { {t, kind} } }
			reputation = {}, -- settlementId -> standing (crimes negative, deeds positive)
			-- Quests and factions (docs/Quests.md §4). New fields: old saves get them by reconcile.
			quests = {
				active = {}, -- questId -> QuestState (personal quests in progress)
				offers = {}, -- questId -> QuestState (offered, not yet accepted)
				finished = {}, -- { id, template, title, outcome, text, success, t, creative } (last 30)
				history = {}, -- templateId -> { n, last } (novelty and cooldowns)
				recent = {}, -- last 10 template ids
				tension = { v = 0, t = 0 }, -- the Director's pacing (decays)
				followUps = {}, -- { template, situation, slots } grown from endings
			},
			journal = { log = {}, revealed = {} }, -- entries (last 200) and secret factions you know of
			factions = {}, -- factionId -> standing -1000..1000
			infamy = { v = 0, t = 0 },
			bounties = {}, -- settlementId -> { amount, faction, reason, t }
			notoriety = {}, -- mythic domain -> { v, t }
			-- Items (docs/Items.md §6; Server/Items/Inventory). Records use short keys (ItemTypes.Record).
			inventory = {
				currency = 0, -- coins
				rare = 0, -- rare currency (economy stage)
				slots = {}, -- "1".."72" -> Record (string keys: no sparse arrays in DataStores)
				equip = {}, -- equipment slot id -> Record
				quick = {}, -- "1".."4" -> "i:<itemId>" | "u:<uid>"
				nextUid = 0, -- uid counter; uids are "<owner>.<counter>" and never reused
				audit = {}, -- last 30 operations { t, op, d } (support)
				-- starter = true once the starter kit was given; quarantine = records that failed validation
			},
			-- Player housing (docs/Buildings.md §8): your house, its placed furniture and your
			-- personal storage. Old saves get it by reconcile (no schema bump).
			housing = {
				lot = "", -- the lot id of your house ("" = none); the claim itself is in the world store
				settlement = "",
				name = "",
				since = 0,
				decor = {}, -- { { rec = Record, x, z, r } } lot-local position, rotation in 15-degree steps
				chest = { currency = 0, rare = 0, slots = {}, equip = {}, quick = {}, nextUid = 0, audit = {}, cap = 24 },
			},
			settings = defaultSettings(), -- consoleKey + Shared/UI/Settings; new settings reach old saves via reconcile
			moderation = { warnings = 0, notes = {} },
			stats = { joins = 0, firstJoin = 0, lastJoin = 0, playtime = 0, casts = 0 },
		}
	end,
	migrations = {
		-- v1 -> v2: the spellbook was an array of raw recipes; it becomes a map keyed by the
		-- canonical recipe key (dedupes, O(1) lookup). Recipes that no longer validate are
		-- kept in spellbookQuarantine for support instead of being silently dropped.
		-- Also introduces `settings` (filled by reconcile) and `stats.casts`.
		[1] = function(data: any): any
			local book = {}
			local quarantine = {}
			for _, raw in data.spellbook or {} do
				local ok, _, recipe = MagicCore.validateRecipe(raw)
				if ok and recipe then
					book[MagicCore.recipeKey(recipe)] = { recipe = recipe, name = "", favorite = false, casts = 0, addedAt = 0 }
				else
					table.insert(quarantine, raw)
				end
			end
			data.spellbook = book
			if #quarantine > 0 then
				data.spellbookQuarantine = quarantine
			end
			return data
		end,

		-- v2 -> v3: XP becomes the source of truth. Existing mastery converts to the XP that
		-- produces it; breakthroughs already passed are granted (grandfathered) so nobody drops a
		-- tier; every branch with mastery, and every awakened domain root, becomes unlocked.
		-- The other new fields are filled by reconcile.
		[2] = function(data: any): any
			local p = data.progression or {}
			p.xp = p.xp or {}
			p.unlocked = p.unlocked or {}
			p.breakthroughs = p.breakthroughs or {}
			for branchId, mastery in p.mastery or {} do
				if typeof(mastery) == "number" and mastery > 0 then
					p.xp[branchId] = MasteryTiers.xpScale * math.min(mastery, 100) ^ MasteryTiers.xpExponent
					p.unlocked[branchId] = true
					for _, tier in MasteryTiers.tiers do
						if tier.breakthrough and mastery >= tier.minMastery then
							p.breakthroughs[branchId] = p.breakthroughs[branchId] or {}
							p.breakthroughs[branchId][tostring(tier.index)] = 0
						end
					end
				end
			end
			local manifest = data.profile and data.profile.manifest
			for _, domainId in manifest or {} do
				p.unlocked[domainId] = true
			end
			data.progression = p
			return data
		end,

		-- v3 -> v4: the inventory placeholder { currency, items = {} } becomes the real inventory
		-- (grid slots, equipment, quickslots, uid counter). Coins carry over; anything in the old
		-- `items` list moves into grid slots (InventoryService validates every record on load).
		-- The starter kit is given on the next join because `starter` is unset.
		[3] = function(data: any): any
			local old = data.inventory or {}
			local slots = {}
			local n = 0
			for _, rec in (if typeof(old.items) == "table" then old.items else {}) :: { any } do
				n += 1
				slots[tostring(n)] = rec
			end
			data.inventory = {
				currency = if typeof(old.currency) == "number" then old.currency else 0,
				rare = 0,
				slots = slots,
				equip = {},
				quick = {},
				nextUid = 0,
				audit = {},
			}
			return data
		end,
	},
	compress = { "discoveries" },
	validate = function(data: any): (boolean, string?)
		if typeof(data.progression) ~= "table" or typeof(data.progression.mastery) ~= "table" then
			return false, "progression missing"
		end
		for branchId, value in data.progression.mastery do
			if typeof(value) ~= "number" or value ~= value or value < 0 or value > 100 then
				return false, "bad mastery for " .. tostring(branchId)
			end
		end
		for branchId, value in data.progression.xp or {} do
			if typeof(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
				return false, "bad xp for " .. tostring(branchId)
			end
		end
		local inv = data.inventory
		if typeof(inv) ~= "table" or typeof(inv.slots) ~= "table" or typeof(inv.equip) ~= "table" then
			return false, "inventory missing"
		end
		if typeof(inv.currency) ~= "number" or inv.currency ~= inv.currency or inv.currency < 0 or inv.currency == math.huge then
			return false, "bad currency"
		end
		local records = 0
		for _, container in { inv.slots, inv.equip } do
			for key, rec in container do
				records += 1
				if typeof(rec) ~= "table" or typeof(rec.i) ~= "string" or (rec.n ~= nil and (typeof(rec.n) ~= "number" or rec.n < 1 or rec.n % 1 ~= 0)) then
					return false, "bad item record at " .. tostring(key)
				end
			end
		end
		if records > 120 then
			return false, "too many item records"
		end
		return true, nil
	end,
} :: StoreConfig

-- ─── World terrain deltas (key "d_<cx>_<cz>", one per touched chunk) ─────────
-- Ops are idempotent terrain edits (see TerrainBuilder.TerrainOp), appended with unique ids so
-- concurrent servers merge by union. An op touching several chunks is stored in each of them.

Schemas.WorldDeltas = {
	name = "WorldDeltas",
	version = 1,
	template = function()
		return {
			ops = {}, -- { TerrainOp }, compressed
			rev = 0, -- increments on every write
		}
	end,
	migrations = {},
	compress = { "ops" },
} :: StoreConfig

-- ─── Tectonics and region state (key "regions") ─────────────────────────────
-- Sparse: only regions that changed. Stress regenerates lazily from (value, timestamp).

Schemas.Regions = {
	name = "WorldRegions",
	version = 1,
	template = function()
		return {
			stress = {}, -- regionId -> { s = stress after last change, t = unix of that change }
			vegetation = {}, -- regionId -> { v = 0..1 multiplier, t = unix } (burned, salted, regrown)
			ore = {}, -- regionId -> 0..1 remaining share
		}
	end,
	migrations = {},
	compress = { "stress", "vegetation", "ore" },
} :: StoreConfig

-- ─── Settlement state (key "settlements") ───────────────────────────────────
-- Additive deltas only, so concurrent writes from many servers commute.

Schemas.SettlementState = {
	name = "WorldSettlements",
	version = 1,
	template = function()
		return {
			prosperity = {}, -- settlementId -> accumulated delta
			relations = {}, -- "idA|idB" -> accumulated drift
			damage = {}, -- settlementId -> accumulated structural damage (repairs subtract)
		}
	end,
	migrations = {},
} :: StoreConfig

-- ─── Discoveries (world-first recipe claims, key "r_<hash of recipe key>") ──

Schemas.Discovery = {
	name = "Discoveries",
	version = 1,
	template = function()
		return {
			key = "", -- full recipe key (guards against hash collisions)
			by = 0, -- UserId of the first caster
			t = 0, -- unix time of the first cast
		}
	end,
	migrations = {},
} :: StoreConfig

-- ─── World (shared by all servers, key "world_main", optimistic updates) ────

Schemas.World = {
	name = "World",
	version = 1,
	template = function()
		return {
			seed = 0, -- 0 = not yet created; WorldService creates it exactly once
			createdAt = 0,
			epoch = 0, -- unix time of world day 0 (drives offline NPC simulation)
			generation = 0, -- +1 per admin reseed; world-keyed stores use WorldService:scopedKey
			chronicle = {}, -- compressed; capped list of { id, kind, t, data } global events
			flags = {}, -- world-wide facts, e.g. { firstMythicTime = 1793600000 }
		}
	end,
	migrations = {},
	compress = { "chronicle" },
} :: StoreConfig

-- ─── Housing claims (shared by all servers, key "housing", world-scoped) ─────
-- Who owns which house. One record, optimistic updates: two servers selling the same house at
-- once can't both win (the second update sees the first claim and cancels).

Schemas.Housing = {
	name = "Housing",
	version = 1,
	template = function()
		return {
			claims = {}, -- lotId -> { u = userId, t = unix, n = display name }
		}
	end,
	migrations = {},
} :: StoreConfig

-- ─── Admin panel (one record per admin, key "admin_<userId>") ────────────────
-- Panel conveniences that should follow an admin between sessions and servers.

Schemas.AdminData = {
	name = "AdminData",
	version = 1,
	template = function()
		return {
			bookmarks = {}, -- name -> { x, y, z, at }
		}
	end,
	migrations = {},
	compress = {},
} :: StoreConfig

-- ─── NPC towns (one record per settlement, key "town_<settlementId>") ───────
-- Only what can't be regenerated: everything else about an NPC (identity, personality, quirks,
-- profile, magical career, family) is rebuilt from the seed. Player-NPC relationships live in
-- the PLAYER's save (relationships). Merged on write, so concurrent servers never lose facts.

Schemas.NpcTown = {
	name = "NpcTowns",
	version = 1,
	template = function()
		return {
			npcs = {}, -- compressed; npcId -> { mythic = { domain, day }?, memories = { { t, k, s, v, i } } }
			rev = 0,
		}
	end,
	migrations = {},
	compress = { "npcs" },
} :: StoreConfig

-- ─── NPC (only named NPCs with state worth keeping, key "npc_<npcId>") ───────

Schemas.Npc = {
	name = "Npcs",
	version = 1,
	template = function()
		return {
			npcId = "",
			gen = 0, -- generator version of the profile snapshot
			-- profile: optional InnateProfile snapshot (taken once the NPC matters)
			alive = true,
			faction = "",
			lastSimDay = 0, -- last world day the offline simulation was applied
			progression = { mastery = {} },
			notoriety = {}, -- mythic domain -> 0..100
			memories = {}, -- compressed; world-level memories, NOT per-player (those live in player data)
		}
	end,
	migrations = {},
	compress = { "memories" },
} :: StoreConfig

return Schemas
