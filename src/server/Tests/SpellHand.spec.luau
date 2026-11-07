--!strict
--[[
	SpellHand.spec: the rules behind a caster's own style and the spell conjured while charging
	(docs/SpellHand.md). The ones that matter most: the same player always gets the same hand,
	temperaments lean it without forcing it, every form and domain knows how to conjure, and the
	wire format can't be pushed past what the rules allow.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)
local SpellHand = require(Shared.Magic.SpellHand)
local Temperaments = require(Shared.Magic.Data.Temperaments)
local Forms = require(Shared.Magic.Data.Forms)

local Data = SpellHand.data

local function handFor(id: number, temperaments: { string }?, tier: number?): SpellHand.Hand
	return SpellHand.generate(Seed.random(1337, "player:" .. id, "hand"), temperaments or {}, tier or 0)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Spell hand data", function()
		it("every form has a place to be conjured", function()
			for id in Forms do
				local mode = Data.formMode[id]
				expect(mode == "hand" or mode == "overhead" or mode == "ground").toBe(true)
			end
		end)

		it("every domain has a conjured look, with a real material and no Neon", function()
			for _, id in Registry.domainIds do
				local look = Data.domains[id]
				expect(look ~= nil).toBe(true)
				expect(look.material ~= "Neon").toBe(true)
				local ok = pcall(function()
					return (Enum.Material :: any)[look.material]
				end)
				expect(ok).toBe(true)
			end
		end)

		it("property overrides name real properties of their domain", function()
			for key, look in Data.properties do
				local domain, property = string.match(key, "^(%a+)%.(%a+)$")
				expect(domain ~= nil and Registry.domains[domain :: string] ~= nil).toBe(true)
				expect(table.find(Registry.domains[domain :: string].properties, property) ~= nil).toBe(true)
				expect(look.material ~= "Neon").toBe(true)
			end
		end)

		it("temperaments that lean a shape are real, and lean to a real shape", function()
			for temperament, shape in Data.temperamentShape do
				expect(Temperaments[temperament] ~= nil).toBe(true)
				expect(table.find(Data.shapes, shape) ~= nil).toBe(true)
			end
		end)

		it("sizes grow, and detail arrives in order", function()
			for _, range in Data.size do
				expect(range[2] > range[1]).toBe(true)
			end
			expect(Data.detail.secondRingAt < Data.detail.crownAt).toBe(true)
		end)
	end)

	describe("Generating a hand", function()
		it("is the same for the same player every time", function()
			local a = SpellHand.encode(handFor(42))
			local b = SpellHand.encode(handFor(42))
			expect(a).toBe(b)
		end)

		it("differs between players: every shape and rune turns up across 200 people", function()
			local shapes: { [number]: boolean } = {}
			local runes: { [number]: boolean } = {}
			for id = 1, 200 do
				local hand = handFor(id)
				shapes[hand.shape] = true
				runes[hand.rune] = true
			end
			for i = 1, #Data.shapes do
				expect(shapes[i]).toBe(true)
			end
			for i = 1, #Data.runes do
				expect(runes[i]).toBe(true)
			end
		end)

		it("a temperament leans the shape without forcing it", function()
			local leaned = 0
			for id = 1, 400 do
				if SpellHand.shapeName(handFor(id, { "swift" })) == "helix" then
					leaned += 1
				end
			end
			local share = leaned / 400
			t.log(string.format("  swift casters with a helix: %.0f%%", share * 100))
			expect(share > 0.35 and share < 0.8).toBe(true)
		end)

		it("stays within its ranges", function()
			for id = 1, 100 do
				local hand = handFor(id, nil, 5)
				expect(hand.speed >= Data.spinSpeed[1] and hand.speed <= Data.spinSpeed[2]).toBe(true)
				expect(hand.pitch >= Data.pitch[1] and hand.pitch <= Data.pitch[2]).toBe(true)
				expect(hand.spin == 1 or hand.spin == -1).toBe(true)
				expect(hand.tier).toBe(5)
			end
		end)

		it("maturing changes only the tier", function()
			local hand = handFor(7, nil, 1)
			local older = SpellHand.withTier(hand, 8)
			expect(older.tier).toBe(8)
			expect(older.rune).toBe(hand.rune)
			expect(older.shape).toBe(hand.shape)
			expect(hand.tier).toBe(1)
		end)
	end)

	describe("Wire format", function()
		it("round-trips", function()
			local hand = handFor(99, { "patient" }, 6)
			local back = SpellHand.decode(SpellHand.encode(hand)) :: SpellHand.Hand
			expect(back.rune).toBe(hand.rune)
			expect(back.shape).toBe(hand.shape)
			expect(back.spin).toBe(hand.spin)
			expect(back.speed).toBeNear(hand.speed, 0.011)
			expect(back.pitch).toBeNear(hand.pitch, 0.011)
			expect(back.tier).toBe(6)
		end)

		it("clamps nonsense to an ordinary hand, and refuses what isn't one", function()
			local hand = SpellHand.decode("99|99|-5|9999|1|42") :: SpellHand.Hand
			expect(hand.rune).toBe(#Data.runes)
			expect(hand.shape).toBe(#Data.shapes)
			expect(hand.spin).toBe(-1)
			expect(hand.speed).toBe(Data.spinSpeed[2])
			expect(hand.pitch).toBe(Data.pitch[1])
			expect(hand.tier).toBe(8)
			expect(SpellHand.decode("1|2")).toBe(nil)
			expect(SpellHand.decode(nil)).toBe(nil)
			expect(SpellHand.decode("")).toBe(nil)
		end)
	end)

	describe("Conjuring", function()
		it("detail grows with tier: nothing at the start, everything at the top", function()
			local first = SpellHand.detail(0)
			expect(first.motes).toBe(0)
			expect(first.secondRing).toBe(false)
			expect(first.crown).toBe(false)
			local top = SpellHand.detail(8)
			expect(top.motes).toBe(Data.detail.motesMax)
			expect(top.secondRing).toBe(true)
			expect(top.crown).toBe(true)
		end)

		it("forms land in the right place, and unknown forms in the hand", function()
			expect(SpellHand.modeFor("projectile")).toBe("hand")
			expect(SpellHand.modeFor("burst")).toBe("overhead")
			expect(SpellHand.modeFor("zone")).toBe("ground")
			expect(SpellHand.modeFor("nonsense")).toBe("hand")
			expect(SpellHand.modeFor(nil)).toBe("hand")
		end)

		it("lightning conjures as lightning, and an unknown domain still conjures", function()
			expect(SpellHand.lookFor("energy", "charge")).toBe(Data.properties["energy.charge"])
			expect(SpellHand.lookFor("energy", "combustion")).toBe(Data.domains.energy)
			expect(SpellHand.lookFor("nonsense", nil)).toBe(Data.domains.energy)
		end)

		it("grows over the safe stages, and only a little more when overcharged", function()
			local tap = SpellHand.sizeAt("hand", 0)
			local full = SpellHand.sizeAt("hand", 2)
			local over = SpellHand.sizeAt("hand", 3)
			expect(tap).toBeNear(Data.size.hand[1], 1e-9)
			expect(full).toBeNear(Data.size.hand[2], 1e-9)
			expect(over > full).toBe(true)
			expect(over < full * 1.2).toBe(true)
			expect(SpellHand.progress(10, 1)).toBe(3)
			expect(SpellHand.progress(1, 0)).toBe(0)
		end)
	end)
end
