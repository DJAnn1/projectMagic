--!strict
--[[
	Wildborn.spec: people the land remade (docs/Wildborn.md). What matters most: every theme has
	its ordinary Wildborn and its boss; every move names a kind the library has; domains, resists,
	biomes and loot are real; moves are chosen by priority, cooldown, range, health and once-only;
	haunts and lairs are deterministic and keep clear of towns; bosses return after a day; and the
	body is a real R6 humanoid rig marked as a creature.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local Server = ServerScriptService.Server
local Data = require(Server.Wildborn.Data.Wildborn)
local Rules = require(Server.Wildborn.WildbornRules)
local Moves = require(Server.Wildborn.WildbornMoves)
local Rig = require(Server.Wildborn.WildbornRig)
local Biomes = require(Server.World.Biomes)
local Flags = require(Server.Config.Flags)

local T = Data.tuning

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Wildborn data", function()
		it("every theme has its ordinary Wildborn and its boss, in real biomes", function()
			for _, themeId in Data.themeOrder do
				local theme = Data.themes[themeId]
				expect(theme ~= nil).toBe(true)
				local regular, boss = Data.enemies[theme.regular], Data.enemies[theme.boss]
				expect(regular ~= nil and regular.theme == themeId and not regular.boss).toBe(true)
				expect(boss ~= nil and boss.theme == themeId and boss.boss and boss.title ~= nil).toBe(true)
				for biome in theme.biomes do
					expect((Biomes.defs :: any)[biome] ~= nil).toBe(true)
				end
				expect(string.find(theme.story, "{dir}", 1, true) ~= nil and string.find(theme.story, "{name}", 1, true) ~= nil).toBe(true)
				expect(string.find(theme.slain, "{", 1, true)).toBe(nil)
			end
			expect((Flags :: any).wildborn_enabled ~= nil).toBe(true)
		end)

		it("every enemy's moves, domain, resists and loot are real", function()
			local kinds = Moves.kinds()
			for id, enemy in Data.enemies do
				expect(enemy.id).toBe(id)
				expect(Registry.domains[enemy.domain] ~= nil).toBe(true)
				for key in enemy.resist do
					expect(Registry.domains[key] ~= nil or Registry.properties[key] ~= nil or key == "all").toBe(true)
				end
				for _, entry in enemy.loot do
					expect(ItemDatabase.get(entry.item) ~= nil).toBe(true)
				end
				expect(#enemy.moves >= 2).toBe(true)
				for _, move in enemy.moves do
					expect(table.find(kinds, move.move) ~= nil).toBe(true)
					expect(typeof(move.style) == "string").toBe(true)
				end
			end
		end)
	end)

	describe("Wildborn decisions", function()
		local enemy: any = {
			moves = {
				{ move = "rally", once = true, below = 0.3 },
				{ move = "burst", cd = 10, min = 0, max = 10 },
				{ move = "bolt", cd = 3, min = 8, max = 60 },
			},
		}
		it("chooses by priority, cooldown, range, health and once-only", function()
			local index = Rules.chooseMove(enemy, { distance = 5, healthShare = 1, now = 0, readyAt = {}, used = {} })
			expect(index).toBe(2) -- close: the burst, not the bolt (out of its min range)
			index = Rules.chooseMove(enemy, { distance = 30, healthShare = 1, now = 0, readyAt = {}, used = {} })
			expect(index).toBe(3)
			index = Rules.chooseMove(enemy, { distance = 30, healthShare = 1, now = 0, readyAt = { [3] = 5 }, used = {} })
			expect(index).toBe(nil) -- the bolt is cooling down: walk in
			index = Rules.chooseMove(enemy, { distance = 30, healthShare = 0.2, now = 0, readyAt = {}, used = {} })
			expect(index).toBe(1) -- low on health: rally first
			index = Rules.chooseMove(enemy, { distance = 30, healthShare = 0.2, now = 0, readyAt = {}, used = { [1] = true } })
			expect(index).toBe(3) -- once only
		end)

		it("a beaten boss returns after a day, and a far one goes home", function()
			expect(Rules.bossBack(nil, 1000)).toBe(true)
			expect(Rules.bossBack(1000, 1000 + T.bossReturnSeconds - 1)).toBe(false)
			expect(Rules.bossBack(1000, 1000 + T.bossReturnSeconds)).toBe(true)
			expect(Rules.shouldReturn(91, 90)).toBe(true)
			expect(Rules.shouldReturn(50, 90)).toBe(false)
		end)
	end)

	describe("Wildborn places", function()
		-- A fake island: the west half badlands, the east half deep forest, a town in the middle.
		local function sample(x: number, _z: number): Rules.Sample
			return { biome = if x < 0 then "badlands" else "deep_forest", height = 50, slope = 0.1 }
		end
		local towns = { { x = 0, z = 0 } }

		it("plans the same haunts and lairs every time, clear of towns", function()
			local a = Rules.planHaunts(42, sample, towns, 4096, 20)
			local b = Rules.planHaunts(42, sample, towns, 4096, 20)
			expect(#a > 0 and #a <= T.hauntMax).toBe(true)
			expect(#a).toBe(#b)
			for i, haunt in a do
				expect(haunt.id).toBe(b[i].id)
				expect(haunt.x).toBe(b[i].x)
				expect(math.sqrt(haunt.x ^ 2 + haunt.z ^ 2) >= T.townClearance).toBe(true)
				expect(haunt.theme == "fire" or haunt.theme == "nature").toBe(true)
			end
			local lairs = Rules.planLairs(42, sample, towns, 4096, 20)
			expect(lairs.fire ~= nil and lairs.nature ~= nil).toBe(true)
			expect(lairs.water).toBe(nil) -- no tidal flats or swamp on this island
			for _, lair in lairs do
				expect(math.sqrt(lair.x ^ 2 + lair.z ^ 2) >= T.lairClearance).toBe(true)
				expect(Data.enemies[lair.enemy].boss).toBe(true)
			end
		end)
	end)

	describe("Wildborn bodies", function()
		it("is a real R6 humanoid rig, marked as a creature, with its resists", function()
			local enemy = Data.enemies.ember_wraith
			local rig = Rig.build(enemy, CFrame.new(0, -500, 0), 1)
			expect(rig ~= nil).toBe(true)
			if rig then
				expect(rig.humanoid.RigType).toBe(Enum.HumanoidRigType.R6)
				for _, name in { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "HumanoidRootPart" } do
					expect(rig.model:FindFirstChild(name) ~= nil).toBe(true)
				end
				expect(rig.model:GetAttribute("Creature")).toBe(enemy.id)
				expect(rig.model:GetAttribute("Wildborn")).toBe(enemy.id)
				expect(rig.humanoid:GetAttribute("Resist_water")).toBe(enemy.resist.water)
				expect(rig.humanoid.MaxHealth).toBe(enemy.health)
				rig.model:Destroy()
			end
		end)
	end)
end
