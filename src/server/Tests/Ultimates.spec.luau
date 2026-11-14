--!strict
--[[
	Ultimates.spec: domain ultimates (docs/SpellOverhaul.md §10, stage 5). What matters: every
	ultimate belongs to a real domain other than Time, Gravity and Reality (they keep their own
	powers), and every status, look and number in its beats is sane; a power 8+ Ritual in that
	domain reaches it, a power 7 one doesn't; the Composer calls it useful; and the beats stay
	inside a damage budget.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Data = require(Shared.Magic.Data.Ultimates)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local SpellRoute = require(Shared.Magic.SpellRoute)
local SpellOutcome = require(Shared.Magic.SpellOutcome)

local LOOKS = { drop = true, nova = true, erupt = true, hit = true }
local WHERE = { center = true, scatter = true, ring = true, targets = true, caster = true }
local KEEP_THEIR_OWN = { time = true, gravity = true, reality = true }

-- A property that takes this domain's ritual to the ultimate (amplify: never the quake or the wave).
local function reaching(id: string, u: any, power: number): string?
	local ids: { string } = {}
	for p in Registry.properties do
		table.insert(ids, p)
	end
	table.sort(ids)
	for _, p in (u.properties or ids) :: { string } do
		local route = SpellRoute.find({ branch = u.domain, property = p, verb = "amplify", form = "ritual", power = power })
		if route.id == "ult_" .. id then
			return p
		end
	end
	return nil
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Ultimates data", function()
		it("every ultimate is a real domain's (not Time, Gravity or Reality) and its beats are sane", function()
			local count = 0
			for _, u in Data.list do
				count += 1
				expect(Registry.domains[u.domain] ~= nil).toBe(true)
				expect(KEEP_THEIR_OWN[u.domain]).toBe(nil)
				for _, p in (u.properties or {}) :: { string } do
					expect(Registry.properties[p] ~= nil).toBe(true)
				end
				local budget = 0
				for _, beat in u.beats do
					expect(LOOKS[beat.look]).toBe(true)
					expect(WHERE[beat.where]).toBe(true)
					expect(beat.radius > 0 and beat.radius <= 30).toBe(true)
					expect(beat.share > 0 and beat.share <= 1.6).toBe(true)
					if beat.status then
						expect((StatusInfo :: any)[beat.status.id] ~= nil).toBe(true)
					end
					if beat.zone then
						expect(beat.zone.every >= 0.5).toBe(true)
						budget += beat.share * math.floor(beat.zone.seconds / beat.zone.every)
					else
						budget += beat.share
					end
				end
				-- About 4 to 6 hits' worth, spread over the beats (an area, so not all on one person).
				expect(budget >= 2 and budget <= 7).toBe(true)
			end
			expect(count >= 9).toBe(true)
			expect(#Data.cooldown).toBe(8)
		end)
	end)

	describe("Ultimates routing", function()
		it("a power 8 Ritual in the domain reaches its ultimate; power 7 doesn't; the Composer calls it useful", function()
			for id, u in Data.list do
				local p = reaching(id, u, 8)
				expect(p ~= nil).toBe(true)
				if p then
					expect(SpellRoute.find({ branch = u.domain, property = p, verb = "amplify", form = "ritual", power = 7 }).id ~= "ult_" .. id).toBe(true)
					local outcome = SpellOutcome.of({ branch = u.domain, property = p, verb = "amplify", form = "ritual", power = 8 })
					expect(outcome.useful).toBe(true)
					expect(string.find(outcome.text, u.name, 1, true) ~= nil).toBe(true)
				end
			end
		end)

		it("Time, Gravity and Reality rituals never become a domain ultimate", function()
			for domain in KEEP_THEIR_OWN do
				for p in Registry.properties do
					local route = SpellRoute.find({ branch = domain, property = p, verb = "amplify", form = "ritual", power = 10 })
					expect(string.sub(route.id, 1, 4) ~= "ult_").toBe(true)
				end
			end
		end)
	end)
end
