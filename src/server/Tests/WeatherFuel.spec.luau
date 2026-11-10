--!strict
--[[
	WeatherFuel.spec: the weather feeds and starves magic (docs/WeatherFuel.md). What matters most:
	every rule names real grammar and has a Journal line; climate alone never fires the storm rules;
	the directions are right (storms help lightning, rain dampens fire, cold helps frost); the total
	is always clamped; and MagicCore really applies it to power.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local WeatherFuel = require(Shared.Magic.WeatherFuel)
local Data = require(Shared.Magic.Data.WeatherFuel)
local Biomes = require(ServerScriptService.Server.World.Biomes)
local Flags = require(ServerScriptService.Server.Config.Flags)

local NEUTRAL = { stormCharge = 0.3, moisture = 0.5, temperature = 0.5 }

local function env(over: { [string]: number }): { [string]: number }
	local e = table.clone(NEUTRAL)
	for k, v in over do
		e[k] = v
	end
	return e
end

local function factor(property: string, verb: string, domains: { string }, e: { [string]: number }?): number
	local f = WeatherFuel.factor(property, verb, domains, e)
	return f
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Weather fuel data", function()
		it("every rule names real properties, verbs and domains, has a ramp, and a Journal line", function()
			local seen: { [string]: boolean } = {}
			for _, rule in Data.rules do
				expect(seen[rule.id]).toBe(nil)
				seen[rule.id] = true
				expect(rule.from ~= rule.to).toBe(true)
				expect(rule.bonus ~= 0).toBe(true)
				expect(#rule.journal > 20).toBe(true)
				expect(NEUTRAL[rule.fact] ~= nil).toBe(true)
				for _, p in rule.properties do
					expect(Registry.properties[p] ~= nil).toBe(true)
				end
				for _, v in (rule.verbs or {}) :: { string } do
					expect(Registry.verbs[v] ~= nil).toBe(true)
				end
				for _, d in (rule.domains or {}) :: { string } do
					expect(Registry.domains[d] ~= nil).toBe(true)
				end
			end
		end)

		it("has a flag to turn it off", function()
			expect((Flags :: any).weather_fuel_enabled ~= nil).toBe(true)
		end)

		it("climate alone never fires a storm rule: every biome's storm is below the ramp", function()
			for id, biome in Biomes.defs do
				for _, rule in Data.rules do
					if rule.fact == "stormCharge" then
						if WeatherFuel.strength(rule, biome.storm) ~= 0 then
							error(id .. " storms on its own (" .. rule.id .. ")")
						end
					end
				end
			end
		end)
	end)

	describe("Weather fuel rules", function()
		it("is exactly 1 with no environment, and in neutral weather", function()
			expect(factor("charge", "generate", { "energy" }, nil)).toBe(1)
			for _, property in { "charge", "temperature", "combustion", "flow", "growth" } do
				for _, verb in { "generate", "reduce", "redirect" } do
					expect(factor(property, verb, { "energy", "water", "air", "life" }, NEUTRAL)).toBe(1)
				end
			end
		end)

		it("a full storm makes lightning a quarter stronger, and leaves frost alone", function()
			local storm = env({ stormCharge = 1 })
			expect(math.abs(factor("charge", "generate", { "energy" }, storm) - 1.25) < 1e-6).toBe(true)
			expect(factor("temperature", "reduce", { "water" }, storm)).toBe(1)
		end)

		it("rain helps water and dampens fire; drought does the opposite", function()
			local rain, drought = env({ moisture = 1 }), env({ moisture = 0 })
			expect(factor("flow", "redirect", { "water" }, rain) > 1).toBe(true)
			expect(factor("flow", "redirect", { "water" }, drought) < 1).toBe(true)
			expect(factor("combustion", "generate", { "energy" }, rain) < 1).toBe(true)
			expect(factor("combustion", "generate", { "energy" }, drought) > 1).toBe(true)
			-- Water's rules ask for the water domain: an air spell moving flow ignores the rain.
			expect(factor("flow", "redirect", { "air" }, rain)).toBe(1)
		end)

		it("cold helps frost and fights fire; heat does the opposite", function()
			local cold, hot = env({ temperature = 0 }), env({ temperature = 1 })
			expect(factor("temperature", "reduce", { "water" }, cold) > 1).toBe(true)
			expect(factor("temperature", "reduce", { "water" }, hot) < 1).toBe(true)
			expect(factor("temperature", "generate", { "energy" }, cold) < 1).toBe(true)
			expect(factor("temperature", "generate", { "energy" }, hot) > 1).toBe(true)
		end)

		it("stays inside its clamp in every corner of the weather", function()
			local values = { 0, 0.25, 0.5, 0.75, 1 }
			for _, s in values do
				for _, m in values do
					for _, tp in values do
						local e = { stormCharge = s, moisture = m, temperature = tp }
						for _, rule in Data.rules do
							for _, property in rule.properties do
								local f = factor(property, if rule.verbs then rule.verbs[1] else "generate", rule.domains or { "energy" }, e)
								expect(f >= Data.minFactor and f <= Data.maxFactor).toBe(true)
							end
						end
					end
				end
			end
		end)

		it("names the rule that did the most", function()
			local f, rule = WeatherFuel.factor("combustion", "generate", { "energy" }, env({ moisture = 1, temperature = 1 }))
			expect(rule).toBe("rain_fire") -- -15% outweighs the heatwave's +12%
			expect(f < 1).toBe(true)
		end)
	end)

	describe("Weather fuel in MagicCore", function()
		it("multiplies a spell's power, and reports the factor and rule", function()
			local caster = {
				id = "spec_weather",
				affinities = { energy = 0.5 },
				awakened = { energy = true },
				mastery = { energy = 10 },
				unlocked = { energy = true },
			}
			local recipe = { branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1 }
			local calm = MagicCore.computeStats(recipe, caster :: any, { environment = NEUTRAL } :: any)
			local heat = MagicCore.computeStats(recipe, caster :: any, { environment = env({ temperature = 1 }) } :: any)
			expect(calm ~= nil and heat ~= nil).toBe(true)
			local a, b = (calm :: any), (heat :: any)
			expect(a.weatherFactor).toBe(1)
			expect(b.weatherFactor).toBe(1.12)
			expect(b.weatherRule).toBe("heat_fire")
			expect(math.abs(b.power / a.power - 1.12) < 0.01).toBe(true)
		end)
	end)
end
