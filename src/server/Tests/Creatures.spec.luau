--!strict
--[[
	Creatures.spec: the first creatures (docs/EarlyGamePlan.md §7). The data's promises (every domain
	is strong against something, loot exists), den planning (seeded, dry, outside towns), behaviour
	decisions, the anti-grind curve and seeded loot.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local ItemDatabase = require(ReplicatedStorage.Shared.Items.ItemDatabase)
local Server = ServerScriptService.Server
local Creatures = require(Server.Creatures.Data.Creatures)
local CreatureRules = require(Server.Creatures.CreatureRules)
local CreatureRig = require(Server.Creatures.CreatureRig)

local T = Creatures.tuning
local SEA = 48

local TOWNS: { CreatureRules.Town } = {
	{ id = "a", x = 0, z = 0, radius = 60, biome = "grasslands" },
	{ id = "b", x = 600, z = 0, radius = 80, biome = "swamp" },
	{ id = "c", x = 0, z = 700, radius = 50, biome = "desert_dunes" },
}

local function flatLand(_x: number, _z: number): (number, number)
	return 80, 0.1
end

local function view(overrides: { [string]: any }): CreatureRules.View
	local v: any = { distanceToDen = 5, returning = false, hasAttacker = false, nearestPlayer = nil, playerToDen = nil }
	for k, value in overrides do
		v[k] = value
	end
	return v
end

return function(t: any)
	t.describe("Creatures", function()
		t.it("leaves every domain strong against at least one creature", function()
			for _, domainId in Registry.domainIds do
				if #CreatureRules.strongAgainst(domainId) == 0 then
					error(domainId .. " is strong against nothing")
				end
			end
		end)

		t.it("has 4-6 creatures with sound data", function()
			t.expect(#Creatures.ids >= 4 and #Creatures.ids <= 6).toBe(true)
			for _, id in Creatures.ids do
				local def = Creatures.defs[id]
				t.expect(Registry.domains[def.domain] ~= nil).toBe(true)
				t.expect(def.health > 0 and def.leash > T.denRadius).toBe(true)
				t.expect(def.pack.min >= 1 and def.pack.max >= def.pack.min).toBe(true)
				for key, value in def.resist do
					if value < -0.5 or value > 0.8 then
						error(id .. " resist " .. key .. " is past the Resistances clamp")
					end
				end
				for _, entry in def.loot do
					if not ItemDatabase.get(entry.item) then
						error(id .. " drops unknown item " .. entry.item)
					end
				end
				local hasHead = false
				for _, part in def.body do
					hasHead = hasHead or part.name == "Head"
				end
				t.expect(hasHead).toBe(true)
			end
		end)

		t.it("builds a rig that spells can target", function()
			for _, id in Creatures.ids do
				local def = Creatures.defs[id]
				local model, humanoid, root = CreatureRig.build(def, CFrame.new())
				t.expect(root.Name).toBe("HumanoidRootPart")
				t.expect(model:FindFirstChild("Head") ~= nil).toBe(true)
				t.expect(humanoid.MaxHealth).toBe(def.health)
				t.expect(model:GetAttribute("Creature")).toBe(id)
				for key, value in def.resist do
					t.expect(humanoid:GetAttribute("Resist_" .. key)).toBe(value)
				end
				model:Destroy()
			end
		end)

		t.it("plans the same dens from the same seed, and different ones from another", function()
			local a = CreatureRules.planDens(1337, TOWNS, flatLand, SEA)
			local b = CreatureRules.planDens(1337, TOWNS, flatLand, SEA)
			local c = CreatureRules.planDens(1338, TOWNS, flatLand, SEA)
			t.expect(#a).toBe(#b)
			t.expect(#a >= #TOWNS * 3).toBe(true)
			local differs = false
			for i, den in a do
				t.expect(den.id).toBe(b[i].id)
				t.expect(den.type).toBe(b[i].type)
				t.expect(den.x).toBe(b[i].x)
				t.expect(den.count).toBe(b[i].count)
				differs = differs or c[i] == nil or c[i].x ~= den.x
			end
			t.expect(differs).toBe(true)
		end)

		t.it("keeps dens out of towns, off the water and apart", function()
			local function coast(x: number, _z: number): (number, number)
				return if x < 0 then 20 else 80, 0.1 -- everything west of x = 0 is sea
			end
			local dens = CreatureRules.planDens(1337, TOWNS, coast, SEA)
			t.expect(#dens > 0).toBe(true)
			for i, den in dens do
				t.expect(den.x >= 0).toBe(true)
				for _, town in TOWNS do
					local d = math.sqrt((town.x - den.x) ^ 2 + (town.z - den.z) ^ 2)
					t.expect(d >= town.radius + T.townMargin).toBe(true)
				end
				for j = i + 1, #dens do
					local other = dens[j]
					t.expect(math.sqrt((other.x - den.x) ^ 2 + (other.z - den.z) ^ 2) >= T.denSpacing).toBe(true)
				end
			end
		end)

		t.it("makes each behaviour act its part", function()
			local D = Creatures.defs
			-- A moth runs, and never attacks.
			t.expect(CreatureRules.decide(D.gust_moth, view({ nearestPlayer = 5 }))).toBe("flee")
			t.expect(CreatureRules.decide(D.gust_moth, view({ nearestPlayer = 200 }))).toBe("wander")
			t.expect(CreatureRules.decide(D.gust_moth, view({ hasAttacker = true }))).toBe("flee")
			-- Rats come when you're close.
			t.expect(CreatureRules.decide(D.gloom_rat, view({ nearestPlayer = 5 }))).toBe("chase")
			t.expect(CreatureRules.decide(D.gloom_rat, view({ nearestPlayer = 100 }))).toBe("wander")
			-- A crawler only cares about its den.
			t.expect(CreatureRules.decide(D.mud_crawler, view({ nearestPlayer = 5, playerToDen = 100 }))).toBe("wander")
			t.expect(CreatureRules.decide(D.mud_crawler, view({ nearestPlayer = 5, playerToDen = 10 }))).toBe("chase")
			t.expect(CreatureRules.decide(D.mud_crawler, view({ hasAttacker = true, playerToDen = 100 }))).toBe("chase")
			-- A wisp ignores you until you hit it.
			t.expect(CreatureRules.decide(D.mana_wisp, view({ nearestPlayer = 2, playerToDen = 2 }))).toBe("wander")
			t.expect(CreatureRules.decide(D.mana_wisp, view({ hasAttacker = true }))).toBe("chase")
		end)

		t.it("goes home past the leash and stays on its way until it's there", function()
			local rat = Creatures.defs.gloom_rat
			t.expect(CreatureRules.decide(rat, view({ distanceToDen = rat.leash + 1, hasAttacker = true }))).toBe("return")
			t.expect(CreatureRules.decide(rat, view({ distanceToDen = T.denRadius + 1, returning = true, hasAttacker = true }))).toBe("return")
			t.expect(CreatureRules.decide(rat, view({ distanceToDen = T.denRadius - 1, returning = true, nearestPlayer = 100 }))).toBe("wander")
		end)

		t.it("clamps goals inside the leash", function()
			local den = Vector3.new(100, 50, 100)
			local inside = Vector3.new(105, 60, 100)
			t.expect(CreatureRules.clampToLeash(den, inside, 40)).toBe(inside)
			local clamped = CreatureRules.clampToLeash(den, Vector3.new(500, 60, 100), 40)
			t.expect(math.abs((clamped.X - den.X) - 36) < 0.01).toBe(true)
			t.expect(clamped.Y).toBe(60)
		end)

		t.it("pays less for each kill of a type in an hour, never nothing", function()
			t.expect(CreatureRules.rewardFactor(0)).toBe(1)
			local last = 1
			for kills = 1, 60 do
				local factor = CreatureRules.rewardFactor(kills)
				t.expect(factor < last and factor > 0).toBe(true)
				last = factor
			end
			t.expect(CreatureRules.rewardFactor(T.decayScale)).toBe(0.5)
		end)

		t.it("rolls the same loot from the same seed, and less of it when grinding", function()
			local def = Creatures.defs.mud_crawler
			local a, ca = CreatureRules.rollLoot(def, Random.new(5), 1)
			local b, cb = CreatureRules.rollLoot(def, Random.new(5), 1)
			t.expect(#a).toBe(#b)
			t.expect(ca).toBe(cb)
			local fresh, tired = 0, 0
			for seed = 1, 400 do
				fresh += #(CreatureRules.rollLoot(def, Random.new(seed), 1))
				tired += #(CreatureRules.rollLoot(def, Random.new(seed), 0.2))
			end
			t.expect(tired < fresh).toBe(true)
		end)
	end)
end
