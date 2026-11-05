--!strict
-- Unit specs for the item backbone (docs/Items.md): the database, seeded generation, the
-- instance model, the inventory rules and transactions, stat derivation, the focus tradeoff and
-- the v3 -> v4 save migration. All pure: no players, no Instances in the world.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local StatCalc = require(Shared.Items.StatCalc)
local ItemRules = require(Shared.Items.Data.ItemRules)
local Rarities = require(Shared.Items.Data.Rarities)
local Server = ServerScriptService.Server
local Inventory = require(Server.Items.Inventory)
local ItemGenerator = require(Server.Items.ItemGenerator)
local StatCache = require(Server.Items.StatCache)
local Schemas = require(Server.Persistence.Schemas)

local OWNER = "spec"

-- A caster who meets everything up to Expert (tier 5) everywhere.
local function caster(mastery: number?): any
	local m = mastery or 60
	local all = {}
	for _, id in { "earth", "energy", "water", "time", "pyromancy" } do
		all[id] = m
	end
	return {
		id = "spec",
		affinities = { energy = 0.8, earth = 0.3, water = 0.6 },
		awakened = { energy = true, earth = true, water = true },
		mastery = all,
		unlocked = { earth = true, energy = true, water = true, pyromancy = true },
	}
end

local function give(inv: any, itemId: string, n: number?, opts: any?): (number, any)
	local rec = ItemGenerator.roll(itemId, ItemGenerator.rng(7, itemId .. tostring(n)), opts or { count = n, rarity = "common" })
	assert(rec, "roll failed for " .. itemId)
	local added, leftover = Inventory.add(inv, rec, OWNER)
	return added, leftover
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("ItemDatabase", function()
		it("has at least 40 items covering every category", function()
			expect(#ItemDatabase.ids >= 40).toBe(true)
			for category: string in ItemRules.categories :: { [string]: any } do
				local ids = ItemDatabase.byCategory[category]
				expect(ids ~= nil and #ids > 0).toBe(true)
			end
		end)
		it("has at least 60 affixes and every affix class can roll a Legendary's four", function()
			expect(#ItemDatabase.affixes >= 60).toBe(true)
			for _, class in { "weapon", "focus", "armor", "jewelry" } do
				local groups: { [string]: boolean } = {}
				for _, affix in ItemDatabase.affixes do
					if table.find(affix.on, class) then
						groups[affix.group] = true
					end
				end
				local count = 0
				for _ in groups do
					count += 1
				end
				expect(count >= 4).toBe(true)
			end
		end)
		it("finds items by tag", function()
			expect(table.find(ItemDatabase.withTag("metal_ingot"), "iron_ingot") ~= nil).toBe(true)
		end)
	end)

	describe("ItemGenerator", function()
		it("is deterministic for the same seed", function()
			local a = ItemGenerator.roll("oak_staff", ItemGenerator.rng(1337, "u.1"))
			local b = ItemGenerator.roll("oak_staff", ItemGenerator.rng(1337, "u.1"))
			expect(a).toEqual(b)
		end)
		it("rolls rarity's affix count with distinct groups and at most two per kind", function()
			for i = 1, 200 do
				local rec = ItemGenerator.roll("ember_orb", ItemGenerator.rng(1, "spec", i), { rarity = "legendary" }) :: any
				local groups: { [string]: boolean } = {}
				local kinds = { prefix = 0, suffix = 0 }
				local n = 0
				for id in (rec.a or {}) :: any do
					local affix = ItemDatabase.affix(id) :: any
					expect(groups[affix.group]).toBe(nil)
					groups[affix.group] = true
					kinds[affix.kind] += 1
					n += 1
				end
				expect(n).toBe(4)
				expect(kinds.prefix <= 2 and kinds.suffix <= 2).toBe(true)
			end
		end)
		it("honours forced affixes and refuses ones that don't fit", function()
			local rec = ItemGenerator.roll("apprentice_wand", ItemGenerator.rng(1, "f"), { rarity = "rare", affixes = { "ember_touched", "of_haste" } }) :: any
			expect(rec.a.ember_touched ~= nil and rec.a.of_haste ~= nil).toBe(true)
			local bad, err = ItemGenerator.roll("apprentice_wand", ItemGenerator.rng(1, "f"), { affixes = { "keen" } })
			expect(bad).toBe(nil)
			expect(err ~= nil).toBe(true)
		end)
		it("never varies artifacts or materials", function()
			local art = ItemGenerator.roll("still_hour_glass", ItemGenerator.rng(1, "a"), { rarity = "legendary" }) :: any
			expect(art.r).toBe(nil)
			expect(art.a).toBe(nil)
			local ore = ItemGenerator.roll("iron_ore", ItemGenerator.rng(1, "o"), { count = 30 }) :: any
			expect(ore.n).toBe(30)
			expect(ore.a).toBe(nil)
		end)
		it("matches the rarity weights over many rolls, and luck shifts them up", function()
			local counts = { 0, 0, 0, 0, 0 }
			local lucky = { 0, 0, 0, 0, 0 }
			local rng = Random.new(42)
			for _ = 1, 20000 do
				local i = ItemGenerator.rollRarity(rng)
				counts[i] += 1
				local j = ItemGenerator.rollRarity(rng, { luck = 1 })
				lucky[j] += 1
			end
			local total = 0
			for i = 1, 5 do
				total += Rarities.list[i].weight
			end
			for i = 1, 5 do
				expect(counts[i] / 20000).toBeNear(Rarities.list[i].weight / total, 0.012)
			end
			expect(lucky[5] > counts[5] * 3).toBe(true)
		end)
	end)

	describe("ItemInstance", function()
		it("keeps affix values inside the rarity band", function()
			local range = { 0.04, 0.12 }
			expect(ItemInstance.affixValue("power_energy", range, 0, 5)).toBeNear(0.04 + 0.08 * 0.55)
			expect(ItemInstance.affixValue("power_energy", range, 999, 5)).toBeNear(0.12)
			expect(ItemInstance.affixValue("power_energy", range, 999, 2)).toBeNear(0.04 + 0.08 * 0.5)
			expect(ItemInstance.affixValue("modifierSlots", { 1, 1 }, 0, 4)).toBe(1)
		end)
		it("names variants prefix + base + suffix", function()
			local rec = { i = "oak_staff", u = "x.1", r = 3, a = { ember_touched = 500, of_resonance = 500 } }
			expect(ItemInstance.displayName(rec)).toBe("Ember-touched Oak Staff of Resonance")
		end)
		it("validates saved records", function()
			expect((ItemInstance.validate({ i = "bread_loaf", n = 5 }))).toBe(true)
			expect((ItemInstance.validate({ i = "bread_loaf", n = 500 }))).toBe(false)
			expect((ItemInstance.validate({ i = "oak_staff" }))).toBe(false) -- unique without a uid
			expect((ItemInstance.validate({ i = "bread_loaf", zz = 1 }))).toBe(false)
			expect((ItemInstance.validate({ i = "gone_item", u = "x.9" }))).toBe(true) -- kept, shown as unknown
		end)
		it("breaks at zero durability and stops giving stats", function()
			local rec: any = { i = "chain_mail", u = "x.2", d = 0 }
			expect(ItemInstance.isBroken(rec)).toBe(true)
			local layers = StatCalc.gearLayers({ chest = rec }, caster())
			expect(#layers).toBe(0)
		end)
		it("stacks only state-free records", function()
			expect(ItemInstance.canStack({ i = "bread_loaf", n = 2 }, { i = "bread_loaf" })).toBe(true)
			expect(ItemInstance.canStack({ i = "bread_loaf" }, { i = "bread_loaf", q = 80 })).toBe(false)
			expect(ItemInstance.canStack({ i = "oak_staff", u = "a" }, { i = "oak_staff", u = "b" })).toBe(false)
		end)
	end)

	describe("Inventory", function()
		it("tops up stacks, then uses free slots, and returns what didn't fit", function()
			local inv = Inventory.new()
			give(inv, "bread_loaf", 15)
			give(inv, "bread_loaf", 10) -- stack is 20: 20 + 5
			expect(Inventory.countOf(inv, "bread_loaf")).toBe(25)
			expect((inv.slots["1"].n :: number)).toBe(20)
			expect((inv.slots["2"].n :: number)).toBe(5)
			for i = 3, ItemRules.inventory.baseSlots do
				inv.slots[tostring(i)] = { i = "torch", u = "fill." .. i }
			end
			local added, leftover = give(inv, "bread_loaf", 18) -- only 15 more fit on the second stack
			expect(added).toBe(15)
			expect((leftover :: any).n).toBe(3)
		end)
		it("mints unique uids and refuses a second copy of a unique artifact", function()
			local inv = Inventory.new()
			give(inv, "oak_staff", 1)
			give(inv, "oak_staff", 1)
			expect(inv.slots["1"].u ~= inv.slots["2"].u).toBe(true)
			local added = give(inv, "still_hour_glass", 1)
			expect(added).toBe(1)
			local again = give(inv, "still_hour_glass", 1)
			expect(again).toBe(0)
		end)
		it("merges, splits and swaps", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "iron_ore", n = 10 }
			inv.slots["2"] = { i = "iron_ore", n = 45 }
			expect((Inventory.move(inv, "s1", "s2"))).toBe(true) -- 45 + 10 > 50: 50 and 5 left
			expect(inv.slots["2"].n).toBe(50)
			expect(inv.slots["1"].n).toBe(5)
			expect((Inventory.move(inv, "s2", "s3", 20))).toBe(true)
			expect(inv.slots["3"].n).toBe(20)
			expect(inv.slots["2"].n).toBe(30)
			inv.slots["4"] = { i = "torch", u = "t.1" }
			expect((Inventory.move(inv, "s4", "s1"))).toBe(true)
			expect(inv.slots["1"].i).toBe("torch")
			expect(inv.slots["4"].i).toBe("iron_ore")
		end)
		it("equips by slot rules, and a two-handed weapon clears the off hand", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "apprentice_wand", u = "w.1" }
			inv.slots["2"] = { i = "oak_staff", u = "s.1" }
			inv.slots["3"] = { i = "chain_mail", u = "c.1" }
			expect((Inventory.move(inv, "s3", "e:head"))).toBe(false)
			expect((Inventory.move(inv, "s1", "e:offHand"))).toBe(true)
			expect((Inventory.move(inv, "s2", "e:mainHand"))).toBe(true)
			expect(inv.equip.offHand).toBe(nil) -- pushed back into the grid
			expect(Inventory.countOf(inv, "apprentice_wand")).toBe(1)
			local ok, why = Inventory.autoEquip(inv, Inventory.findUid(inv, "w.1") :: string)
			expect(ok).toBe(false) -- the first empty hand is the off hand, blocked by the two-handed staff
			expect(why).toBe("TWO_HANDED")
		end)
		it("checks requirements through the service's rules", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "oak_staff", u = "s.1" }
			local rules = {
				canEquip = function(rec: any)
					local def = ItemDatabase.get(rec.i) :: any
					return ItemInstance.meets(def.requires, caster(0))
				end,
			}
			expect((Inventory.move(inv, "s1", "e:mainHand", nil, rules :: any))).toBe(false)
		end)
		it("grows with bags and refuses to drop a bag that still holds items", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "traveler_pack", u = "p.1" }
			expect((Inventory.move(inv, "s1", "e:bag1"))).toBe(true)
			expect(Inventory.capacity(inv)).toBe(ItemRules.inventory.baseSlots + 12)
			inv.slots["30"] = { i = "torch", u = "t.30" }
			expect((Inventory.unequip(inv, "bag1"))).toBe(false)
			inv.slots["30"] = nil
			expect((Inventory.unequip(inv, "bag1"))).toBe(true)
			expect(Inventory.capacity(inv)).toBe(ItemRules.inventory.baseSlots)
		end)
		it("removes all or nothing", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "iron_ingot", n = 4 }
			inv.slots["5"] = { i = "iron_ingot", n = 3 }
			expect(Inventory.removeItem(inv, "iron_ingot", 9)).toBe(false)
			expect(Inventory.countOf(inv, "iron_ingot")).toBe(7)
			expect(Inventory.removeItem(inv, "iron_ingot", 5)).toBe(true)
			expect(Inventory.countOf(inv, "iron_ingot")).toBe(2)
			expect(inv.slots["5"]).toBe(nil) -- the last stack is spent first
		end)
		it("rolls back on an error, a refusal or a broken invariant", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "bread_loaf", n = 3 }
			inv.currency = 10
			local ok = Inventory.transact(inv, function(i)
				i.currency = 999
				i.slots["1"] = nil
				error("boom")
			end)
			expect(ok).toBe(false)
			expect(inv.currency).toBe(10)
			expect(inv.slots["1"].n).toBe(3)
			ok = Inventory.transact(inv, function(i)
				i.slots["2"] = { i = "oak_staff", u = "dup" }
				i.slots["3"] = { i = "oak_staff", u = "dup" } -- duplicate uid: invariant
				return true, nil
			end)
			expect(ok).toBe(false)
			expect(inv.slots["2"]).toBe(nil)
			local ok2, reason = Inventory.transact(inv, function(i)
				i.currency = -5
				return true, nil
			end)
			expect(ok2).toBe(false)
			expect(string.find(reason :: string, "INVARIANT", 1, true) ~= nil).toBe(true)
			expect(inv.currency).toBe(10)
		end)
		it("sorts, merges and leaves locked items in place", function()
			local inv = Inventory.new()
			inv.slots["3"] = { i = "bread_loaf", n = 2 }
			inv.slots["7"] = { i = "bread_loaf", n = 4 }
			inv.slots["2"] = { i = "torch", u = "t.1", f = ItemInstance.LOCKED }
			inv.slots["9"] = { i = "oak_staff", u = "s.1" }
			Inventory.sort(inv)
			expect(inv.slots["2"].u).toBe("t.1")
			expect(inv.slots["1"].i).toBe("oak_staff") -- focus category sorts first
			expect(Inventory.countOf(inv, "bread_loaf")).toBe(6)
			local stacks = 0
			for _, rec in inv.slots do
				if rec.i == "bread_loaf" then
					stacks += 1
				end
			end
			expect(stacks).toBe(1)
		end)
		it("normalizes saves: quarantines duplicates and junk, keeps the rest", function()
			local inv, report = Inventory.normalize({
				currency = 12,
				slots = {
					["1"] = { i = "oak_staff", u = "same" },
					["2"] = { i = "oak_staff", u = "same" },
					["3"] = { i = "bread_loaf", n = 2, junk = true },
					["4"] = { i = "bread_loaf", n = 2 },
				},
				equip = { head = { i = "chain_mail", u = "wrongslot" } },
			})
			expect(report.quarantined).toBe(2)
			expect(report.duplicates).toBe(1)
			expect(inv.equip.head).toBe(nil)
			expect(Inventory.findUid(inv, "wrongslot") ~= nil).toBe(true) -- moved to the grid
			expect(inv.currency).toBe(12)
		end)
		it("resolves quickslots to the first stack or the unique wherever it is", function()
			local inv = Inventory.new()
			inv.slots["4"] = { i = "healing_draught", n = 2 }
			inv.slots["2"] = { i = "healing_draught" }
			inv.slots["5"] = { i = "torch", u = "t.5" }
			Inventory.setQuick(inv, "1", "s4")
			Inventory.setQuick(inv, "2", "s5")
			expect(Inventory.resolveQuick(inv, "1")).toBe("s2")
			Inventory.move(inv, "s5", "e:offHand")
			expect(Inventory.resolveQuick(inv, "2")).toBe("e:offHand")
		end)
	end)

	describe("StatCalc", function()
		it("adds flats, then applies percentages, then caps", function()
			local sheet = StatCalc.derive({
				{ source = "gear", label = "a", stats = { health = 20, healthPct = 0.1 } },
				{ source = "buff", label = "b", stats = { health = 10, healthPct = 0.1, castSpeedPct = 0.9 } },
			}, 0)
			expect(sheet.final.health).toBeNear((100 + 20 + 10) * 1.2)
			expect(sheet.final.castSpeedPct).toBeNear(0.5) -- capped
		end)
		it("slows you down when overloaded", function()
			local light = StatCalc.derive({}, 10)
			local heavy = StatCalc.derive({}, 80)
			expect(light.load).toBe("light")
			expect(heavy.load).toBe("overloaded")
			expect(heavy.final.moveSpeedPct < 0).toBe(true)
		end)
		it("grants set bonuses by pieces worn", function()
			local equip = {
				head = { i = "leather_cap", u = "1", r = 3, a = { of_the_forgeborn = 500 } },
				chest = { i = "chain_mail", u = "2", r = 3, a = { of_the_forgeborn = 500 } },
			}
			local layers = StatCalc.gearLayers(equip :: any, caster())
			local sets = 0
			for _, layer in layers do
				if layer.source == "set" then
					sets += 1
				end
			end
			expect(sets).toBe(1)
		end)
		it("gives an item nothing when its requirements aren't met, and gates attunements", function()
			local orb = { offHand = { i = "ember_orb", u = "o" } }
			local layersMet, focus = StatCalc.gearLayers(orb :: any, caster())
			expect(#layersMet).toBe(1)
			expect(focus.grade).toBe("major")
			expect((layersMet[1].stats :: any).power_energy).toBeNear(0.12 + 0.06) -- focus + attunement (energy affinity 0.8)
			local layersUnmet = StatCalc.gearLayers(orb :: any, caster(0))
			expect(#layersUnmet).toBe(0)
		end)
	end)

	describe("Focus tradeoff", function()
		local bare = {}
		local held = { { grade = "major", domains = { earth = true }, stability = 0.2 } }
		local worn = { { grade = "minor", domains = { any = true }, stability = 0 } }
		it("costs nothing below power 6", function()
			local e = StatCache.focusPenalty(bare, { "earth" }, 5)
			expect(e.costMult).toBe(1)
			expect(e.backfireAdd).toBe(0)
		end)
		it("costs +30% and +10% backfire bare-handed at power 10", function()
			local e = StatCache.focusPenalty(bare, { "earth" }, 10)
			expect(e.costMult).toBeNear(1.3)
			expect(e.backfireAdd).toBeNear(0.1)
		end)
		it("a matching held focus removes it; a worn or mismatched one halves it", function()
			expect(StatCache.focusPenalty(held, { "earth" }, 10).costMult).toBe(1)
			expect(StatCache.focusPenalty(held, { "earth" }, 10).stability).toBeNear(0.2)
			expect(StatCache.focusPenalty(worn, { "earth" }, 10).costMult).toBeNear(1.15)
			expect(StatCache.focusPenalty(held, { "water" }, 10).costMult).toBeNear(1.15)
		end)
	end)

	describe("Save schema", function()
		it("migrates v3's placeholder inventory to v4", function()
			local migrated = Schemas.Player.migrations[3]({ inventory = { currency = 40, items = { { i = "bread_loaf", n = 2 } } } })
			expect(migrated.inventory.currency).toBe(40)
			expect(migrated.inventory.slots["1"].i).toBe("bread_loaf")
			expect(typeof(migrated.inventory.equip)).toBe("table")
			expect(Schemas.Player.version).toBe(4)
		end)
		it("validates the template", function()
			local ok = (Schemas.Player.validate :: any)(Schemas.Player.template())
			expect(ok).toBe(true)
		end)
	end)
end
