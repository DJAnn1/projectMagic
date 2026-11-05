--!strict
-- Unit specs for the spellblade's shared rules (Shared/Magic/Melee, Data/MeleeTuning).
-- docs/Combat.md §13.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Melee = require(ReplicatedStorage.Shared.Magic.Melee)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local CombatAnimations = require(ReplicatedStorage.Shared.Magic.Data.CombatAnimations)
local ActionRules = require(ReplicatedStorage.Shared.Magic.ActionRules)
local ItemDatabase = require(ReplicatedStorage.Shared.Items.ItemDatabase)

local D = Melee.data

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Spellblade", function()
		it("has swings whose blade connects inside the swing, before the combo opens", function()
			for _, swing in D.swings do
				expect(CombatAnimations.animations[swing.clip] ~= nil).toBe(true)
				expect(swing.hitFrom < swing.hitTo and swing.hitTo <= swing.duration).toBe(true)
				expect(swing.comboFrom >= swing.hitTo).toBe(true)
				expect(swing.share > 0 and swing.share < 1).toBe(true)
			end
		end)
		it("chains Slash1 -> Slash2 -> Slash1 inside the window, and refuses early presses", function()
			expect((Melee.nextIndex(nil, 0, 1))).toBe(1)
			local s1 = Melee.swing(1)
			local early, wait = Melee.nextIndex(1, s1.comboFrom - 0.1, 1)
			expect(early).toBe(nil)
			expect(wait).toBeNear(0.1, 1e-6)
			expect((Melee.nextIndex(1, s1.comboFrom, 1))).toBe(2)
			expect((Melee.nextIndex(2, Melee.swing(2).comboFrom + 0.01, 1))).toBe(1)
			expect((Melee.nextIndex(1, s1.duration + D.comboGrace + 0.5, 1))).toBe(1) -- lapsed: restart
		end)
		it("scales the combo window with swing speed", function()
			local s1 = Melee.swing(1)
			expect((Melee.nextIndex(1, s1.comboFrom / 1.5, 1.5))).toBe(2)
			expect((Melee.nextIndex(1, s1.comboFrom / 1.5, 1))).toBe(nil)
		end)
		it("takes reach, speed and damage from a weapon, power from a focus, nothing from a bow", function()
			local sword = Melee.weaponBonus(ItemDatabase.get("iron_sword"), 0, 0)
			expect(sword.flat > 0 and sword.speed > 1).toBe(true)
			local spear = Melee.weaponBonus(ItemDatabase.get("hunting_spear"), 0, 0)
			expect(spear.reach > 0).toBe(true)
			local staff = Melee.weaponBonus(ItemDatabase.get("oak_staff"), 0, 0)
			expect(staff.powerMult).toBe(D.weapons.focusPower)
			local bow = Melee.weaponBonus(ItemDatabase.get("ash_shortbow"), 0, 0)
			expect(bow.flat).toBe(0)
			local bare = Melee.weaponBonus(nil, 5, 0)
			expect(bare.flat).toBe(5)
			expect(bare.speed).toBe(1)
		end)
		it("gives statuses only to real domains", function()
			for domain in D.status do
				expect(Registry.domains[domain] ~= nil).toBe(true)
			end
		end)
		it("lets a swing be cancelled into a block, a dash, a cast or the next swing", function()
			for _, action in { "block", "dash", "cast", "slash" } do
				expect(ActionRules.allows("slashing", action)).toBe(true)
			end
			expect(ActionRules.canEnter("slashing", "blocking")).toBe(true)
			expect(ActionRules.canEnter("slashing", "casting")).toBe(true)
		end)
	end)
end
