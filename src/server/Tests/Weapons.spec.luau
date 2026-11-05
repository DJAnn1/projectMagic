--!strict
-- Unit specs for item weapons, stamina rules and repair (docs/Items.md §10-11): the shared, pure
-- parts (WeaponRules, Repair) and the data they depend on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local ItemRules = require(Shared.Items.Data.ItemRules)
local WeaponRules = require(Shared.Items.WeaponRules)
local Repair = require(Shared.Items.Repair)
local CombatAnimations = require(Shared.Magic.Data.CombatAnimations)

local W = WeaponRules.data

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Weapon data", function()
		it("gives every weapon item a kind the rules know", function()
			for _, id in ItemDatabase.ids do
				local def = ItemDatabase.get(id)
				if def and def.weapon then
					local class = WeaponRules.classify(def)
					expect(class ~= nil).toBe(true)
				end
			end
		end)
		it("gives every ranged weapon ammunition that exists", function()
			for _, id in ItemDatabase.ids do
				local def = ItemDatabase.get(id)
				local class = WeaponRules.classify(def)
				if def and def.weapon and class == "ranged" then
					expect(def.weapon.ammo ~= nil).toBe(true)
					expect(#ItemDatabase.withTag(def.weapon.ammo or "") > 0).toBe(true)
				end
			end
		end)
		it("only plays animation clips that exist", function()
			for _, kind in W.melee do
				for _, swing in kind.swings do
					expect(CombatAnimations.animations[swing.clip] ~= nil).toBe(true)
				end
			end
		end)
	end)

	describe("Weapon rules", function()
		local sword = W.melee.sword
		it("runs the combo: first swing, too early, in the window, lapsed", function()
			expect((WeaponRules.nextIndex(sword, nil, 0, 1))).toBe(1)
			local early = WeaponRules.nextIndex(sword, 1, 0.05, 1)
			expect(early).toBe(nil)
			expect((WeaponRules.nextIndex(sword, 1, sword.swings[1].comboFrom + 0.01, 1))).toBe(2)
			expect((WeaponRules.nextIndex(sword, 2, sword.swings[2].comboFrom + 0.01, 1))).toBe(1)
			expect((WeaponRules.nextIndex(sword, 1, 10, 1))).toBe(1)
		end)
		it("clamps swing speed", function()
			local fast = { kind = "dagger", damage = 1, damageType = "momentum", speed = 99, reach = 4, stamina = 1 }
			expect(WeaponRules.speed(fast, 1)).toBe(W.maxSpeed)
			local slow = { kind = "axe", damage = 1, damageType = "momentum", speed = 0.01, reach = 4, stamina = 1 }
			expect(WeaponRules.speed(slow, 0)).toBe(W.minSpeed)
		end)
		it("grows a bow's draw from minShare to full, and refuses an underdraw", function()
			local bow = W.ranged.bow
			local d = bow.draw :: any
			expect(WeaponRules.drawShare(bow, d.drawMin - 0.01)).toBe(nil)
			expect(WeaponRules.drawShare(bow, d.drawMin)).toBe(d.minShare)
			local mid = WeaponRules.drawShare(bow, (d.drawMin + d.drawFull) / 2) :: number
			expect(mid > d.minShare and mid < 1).toBe(true)
			expect(WeaponRules.drawShare(bow, d.drawFull)).toBe(1)
			expect(WeaponRules.drawShare(bow, d.holdMax)).toBe(1)
			expect((WeaponRules.drawShare(bow, d.holdMax + 2) :: number) < 1).toBe(true)
			expect(WeaponRules.holdDrain(bow, d.holdMax + 1) > 0).toBe(true)
			-- Crossbows and knives don't draw: always a full shot.
			expect(WeaponRules.drawShare(W.ranged.crossbow, 0)).toBe(1)
		end)
		it("reduces weapon damage with defense, with diminishing returns and a cap", function()
			expect(WeaponRules.defenseReduction(0)).toBe(0)
			local a, b = WeaponRules.defenseReduction(30), WeaponRules.defenseReduction(60)
			expect(a > 0 and b > a).toBe(true)
			expect(b - a < a).toBe(true)
			expect(WeaponRules.defenseReduction(100000)).toBe(W.hits.maxDefenseReduction)
		end)
		it("lets swords block but not daggers or bows", function()
			expect(WeaponRules.canBlock(ItemDatabase.get("iron_sword"))).toBe(true)
			expect(WeaponRules.canBlock(ItemDatabase.get("bone_dagger"))).toBe(false)
			expect(WeaponRules.canBlock(ItemDatabase.get("ash_shortbow"))).toBe(false)
			expect(WeaponRules.canBlock(nil)).toBe(false)
		end)
	end)

	describe("Repair", function()
		local function worn(id: string, share: number): any
			local rec: any = { i = id, u = "spec_" .. id }
			local max = ItemInstance.maxDurability(rec) :: number
			rec.d = math.floor(max * (1 - share))
			return rec
		end
		it("sends metal to the forge for coins and ingots, wood to the workbench", function()
			local quote = Repair.quote(worn("iron_sword", 0.5)) :: Repair.Quote
			expect(quote ~= nil).toBe(true)
			expect(quote.station).toBe("forge")
			expect(quote.material).toBe("metal_ingot")
			expect(quote.coins >= 1 and quote.materialCount >= 1).toBe(true)
			expect((Repair.quote(worn("ash_shortbow", 0.5)) :: Repair.Quote).station).toBe("workbench")
			expect((Repair.quote(worn("wool_cloak", 0.5)) :: Repair.Quote).station).toBe("loom")
		end)
		it("quotes nothing for an undamaged item", function()
			expect(Repair.quote({ i = "iron_sword", u = "spec_full" })).toBe(nil)
		end)
		it("costs more the more worn it is", function()
			local light = Repair.quote(worn("iron_sword", 0.2)) :: Repair.Quote
			local heavy = Repair.quote(worn("iron_sword", 1)) :: Repair.Quote
			expect(heavy.coins >= light.coins and heavy.materialCount >= light.materialCount).toBe(true)
		end)
		it("names only material tags some item carries", function()
			for _, row in ItemRules.repair.byTag do
				if row.material then
					expect(#ItemDatabase.withTag(row.material) > 0).toBe(true)
				end
			end
		end)
		it("mends metal by Earth magic from Novice, more with skill, never wood", function()
			local rec = worn("iron_sword", 1)
			local max = ItemInstance.maxDurability(rec) :: number
			expect(Repair.mendQuote(rec, ItemRules.mend.minTier - 1)).toBe(nil)
			local novice = Repair.mendQuote(rec, ItemRules.mend.minTier) :: Repair.MendQuote
			local master = Repair.mendQuote(rec, 6) :: Repair.MendQuote
			expect(novice.points > 0 and novice.points < max).toBe(true)
			expect(master.points).toBe(max)
			expect(master.reservoir > novice.reservoir).toBe(true)
			expect(Repair.mendQuote(worn("ash_shortbow", 1), 6)).toBe(nil)
		end)
		it("counts Metallurgy one tier higher for mending", function()
			expect(Repair.mendTier(2, 3)).toBe(3 + ItemRules.mend.metallurgyBonus)
			expect(Repair.mendTier(4, 0)).toBe(4)
		end)
	end)
end
