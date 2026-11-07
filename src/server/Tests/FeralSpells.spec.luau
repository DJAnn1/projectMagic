--!strict
--[[
	FeralSpells.spec: the rules behind loose spells, with no live players (docs/FeralSpells.md). The ones
	that matter most: limits on how many get loose, failing on purpose teaches nothing, every spell form and
	domain has a body and a name, and rumours only name what's near.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Flags = require(Server.Config.Flags)
local Schemas = require(Server.Persistence.Schemas)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Data = require(Server.Ferals.Data.FeralData)
local Rules = require(Server.Ferals.FeralRules)

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Topics = require(Shared.Core.Topics)

local T = Data.tuning

local function escape(over: { [string]: any }): Rules.EscapeView
	local base: { [string]: any } = {
		severity = 1,
		roll = 0,
		alive = 0,
		limit = T.maxAlive,
		fromCaster = 0,
		sinceLastEscape = math.huge,
		onIsland = true,
	}
	for key, value in over do
		base[key] = value
	end
	return base :: any
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Feral data", function()
		it("every domain has a name and a colour to draw it in", function()
			for _, id in Registry.domainIds do
				expect(Data.words[id] ~= nil).toBe(true)
				expect(#Registry.domains[id].feel.palette > 0).toBe(true)
			end
		end)

		it("every spell form has a body, and each body has a Head for its name", function()
			for _, id in Registry.formIds do
				expect(Data.forms[id] ~= nil).toBe(true)
				local head = false
				for _, part in Rules.bodyFor(id) do
					head = head or part.name == "Head"
				end
				expect(head).toBe(true)
			end
		end)

		it("is wired in: flags, the save field and the topic", function()
			expect((Flags :: any).feral_spells_enabled ~= nil).toBe(true)
			expect((Flags :: any).feral_spells_max ~= nil).toBe(true)
			expect(Schemas.Player.template().feral ~= nil).toBe(true)
			expect((Topics :: any).ControlLost ~= nil).toBe(true)
		end)
	end)

	describe("Getting loose", function()
		it("gets likelier the worse it went, within limits", function()
			expect(Rules.escapeChance(1)).toBe(T.escapeBase)
			expect(Rules.escapeChance(2) > Rules.escapeChance(1)).toBe(true)
			expect(Rules.escapeChance(100)).toBe(T.escapeMax)
			expect(Rules.escapeChance(-100)).toBe(T.escapeMin)
		end)

		it("needs the roll to come up", function()
			expect(Rules.mayEscape(escape({ roll = 0 }))).toBe(true)
			expect(Rules.mayEscape(escape({ roll = 0.99 }))).toBe(false)
		end)

		it("stops at the server's limit", function()
			expect(Rules.mayEscape(escape({ alive = T.maxAlive }))).toBe(false)
		end)

		it("won't let one caster fill the island", function()
			expect(Rules.mayEscape(escape({ fromCaster = T.maxPerCaster }))).toBe(false)
			expect(Rules.mayEscape(escape({ sinceLastEscape = T.perCasterCooldown - 1 }))).toBe(false)
			expect(Rules.mayEscape(escape({ sinceLastEscape = T.perCasterCooldown }))).toBe(true)
		end)

		it("stays in a Rift's pocket instead of getting out onto the island", function()
			expect(Rules.mayEscape(escape({ onIsland = false }))).toBe(false)
			expect(Rules.onIsland(6000, 0, 4096)).toBe(false)
			expect(Rules.onIsland(100, -100, 4096)).toBe(true)
		end)
	end)

	describe("Its life", function()
		it("a stronger spell lasts longer", function()
			expect(Rules.energyFor(10) > Rules.energyFor(1)).toBe(true)
		end)

		it("ley energy keeps it going, and thin air runs it down", function()
			expect(Rules.drainRate(T.densityHigh)).toBe(T.drainThick)
			expect(Rules.drainRate(T.densityLow)).toBe(T.drainThin)
			expect(Rules.drainRate(1) < Rules.drainRate(0)).toBe(true)
		end)

		it("leans towards ley energy, and never into the sea", function()
			local samples = {
				{ density = 0, land = true },
				{ density = 1, land = true },
				{ density = 1, land = false },
			}
			local counts = { 0, 0, 0 }
			for i = 0, 99 do
				local pick = Rules.pickDirection(samples, i / 100) :: number
				counts[pick] += 1
			end
			expect(counts[3]).toBe(0)
			expect(counts[2] > counts[1]).toBe(true)
			expect(Rules.pickDirection({ { density = 1, land = false } }, 0.5)).toBe(nil)
		end)
	end)

	describe("Its body", function()
		local recipe = { form = "burst", power = 5 }
		local palette = { Color3.fromRGB(255, 140, 40), Color3.fromRGB(255, 230, 120) }

		it("takes more from what opposes it, and little from its own domain", function()
			local def = Rules.def(recipe, "energy", palette, { "water", "void" }, "Stray Ember")
			expect(def.resist.energy).toBe(T.ownResist)
			expect(def.resist.water).toBe(T.opposedWeakness)
		end)

		it("a stronger spell has more health and is bigger", function()
			local weak = Rules.def({ form = "burst", power = 1 }, "energy", palette, {}, "x")
			local strong = Rules.def({ form = "burst", power = 10 }, "energy", palette, {}, "x")
			expect(strong.health > weak.health).toBe(true)
			expect(strong.hitbox.X > weak.hitbox.X).toBe(true)
		end)

		it("dims its Neon, because Bloom blows bright Neon out to white", function()
			local def = Rules.def(recipe, "air", { Color3.new(1, 1, 1) }, {}, "x")
			for _, part in def.body do
				if part.material == Enum.Material.Neon then
					expect(math.max(part.color.R, part.color.G, part.color.B) < 0.75).toBe(true)
				end
			end
		end)

		it("CreatureRig can build it, as something spells can hit", function()
			local def = Rules.def(recipe, "energy", palette, { "water" }, "Stray Ember")
			local model, humanoid = CreatureRig.build(def, CFrame.new())
			expect(humanoid.MaxHealth).toBe(def.health)
			expect(model:GetAttribute("Creature")).toBe("feral")
			expect(humanoid:GetAttribute("Resist_water")).toBe(T.opposedWeakness)
			model:Destroy()
		end)
	end)

	describe("What it leaves", function()
		local function learns(over: { [string]: any }): boolean
			local view: { [string]: any } = { dealt = 100, maxHealth = 100, known = false, studied = false }
			for key, value in over do
				view[key] = value
			end
			return Rules.learnsFrom(view :: any)
		end

		it("teaches someone who fought it a spell they didn't know", function()
			expect(learns({})).toBe(true)
		end)

		it("teaches nothing about a spell you know: failing on purpose is pointless", function()
			expect(learns({ known = true })).toBe(false)
		end)

		it("teaches nothing twice, or to someone who barely touched it", function()
			expect(learns({ studied = true })).toBe(false)
			expect(learns({ dealt = 100 * T.creditShare - 1 })).toBe(false)
			expect(learns({ dealt = 100 * T.creditShare })).toBe(true)
		end)

		it("names all four parts of the recipe in its clue", function()
			local text = Rules.clue({ branch = "stonecraft", property = "hardness", verb = "amplify", form = "burst" })
			for _, word in { "stonecraft", "hardness", "amplify", "burst" } do
				expect(string.find(text, word, 1, true) ~= nil).toBe(true)
			end
		end)

		it("keeps its record bounded, dropping the oldest", function()
			local studied = { a = 1, b = 2, c = 3 }
			Rules.pruneStudied(studied, 2)
			expect((studied :: any).a).toBe(nil)
			expect(studied.b).toBe(2)
			expect(studied.c).toBe(3)
		end)
	end)

	describe("Rumours", function()
		local near = { id = "near", x = 100, z = 0 }
		local far = { id = "far", x = T.rumorRadius + 500, z = 0 }

		it("names the nearest, if it's near enough to worry anyone", function()
			expect(Rules.rumorFor({ far, near }, {}, 0, 0, 0)).toBe(near)
			expect(Rules.rumorFor({ far }, {}, 0, 0, 0)).toBe(nil)
		end)

		it("doesn't tell you what you've already heard", function()
			expect(Rules.rumorFor({ near }, { near = true }, 0, 0, 0)).toBe(nil)
		end)

		it("not everyone has heard", function()
			expect(Rules.rumorFor({ near }, {}, 0, 0, T.rumorChance)).toBe(nil)
		end)

		it("says who lost it and where, in a person's words", function()
			for _, source in { "player", "npc" } do
				for _, roll in { 0, 0.99 } do
					local line = Rules.rumorLine(source, "Hedda", "north", roll)
					expect(string.find(line, "Hedda", 1, true) ~= nil).toBe(true)
					expect(string.find(line, "north", 1, true) ~= nil).toBe(true)
				end
			end
		end)
	end)
end
