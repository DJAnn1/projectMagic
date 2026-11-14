--!strict
--[[
	Dreams.spec: dreams about your own magic (docs/Dreams.md). What matters most: a mythic latent is
	never dreamt (not even an Amplify on a mythic domain); revealed latents aren't dreamt; every
	non-mythic domain, temperament and awakening category has lines; no line holds a digit or a
	domain's name; the same night always gives the same dream; and clarity only grows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Domains = require(Shared.Magic.Data.Domains)
local Temperaments = require(Shared.Magic.Data.Temperaments)
local Server = ServerScriptService.Server
local Data = require(Server.Magic.Data.Dreams)
local Dreams = require(Server.Magic.Dreams)
local AwakeningEvents = require(Server.Magic.Data.AwakeningEvents)
local Flags = require(Server.Config.Flags)

local function latent(id: string, kind: string, target: string, revealed: boolean?): any
	return { id = id, kind = kind, target = target, strength = 0.4, triggers = { "Danger", "Ritual" }, revealed = revealed == true }
end

local function profile(latents: { any }): any
	return { entityId = "player:spec", latents = latents }
end

local function record(): any
	return { count = 0, lastAt = 0, lastDay = -1, seen = {}, recalled = {} }
end

local function everyLine(): { string }
	local out = {}
	local function add(list: { string })
		for _, line in list do
			table.insert(out, line)
		end
	end
	for _, list in Data.domains do
		add(list)
	end
	for _, list in Data.temperaments do
		add(list)
	end
	for _, kind in Data.kinds do
		add(kind.mine)
		add(kind.recalled)
	end
	for _, list in Data.triggers do
		add(list)
	end
	add(Data.capacity)
	add(Data.ordinary)
	return out
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Dream lines", function()
		it("cover every non-mythic domain, temperament and awakening category, and no mythic domain", function()
			for id, def in Domains :: { [string]: any } do
				if def.rarity == "Mythic" then
					expect(Data.domains[id] == nil).toBe(true)
				else
					expect(Data.domains[id] ~= nil and #Data.domains[id] >= 1).toBe(true)
				end
			end
			for id in Temperaments :: { [string]: any } do
				expect(Data.temperaments[id] ~= nil and #Data.temperaments[id] >= 1).toBe(true)
			end
			for _, event in AwakeningEvents :: { [string]: any } do
				if event.category ~= "Mythic" then
					expect(Data.triggers[event.category] ~= nil).toBe(true)
				end
			end
			expect(Data.triggers.Mythic == nil and Data.kinds.Mythic == nil).toBe(true)
			expect((Flags :: any).dreams_enabled ~= nil).toBe(true)
		end)

		it("hold no digit and no domain's name", function()
			for _, line in everyLine() do
				expect(string.find(line, "%d") == nil).toBe(true)
				for _, def in Domains :: { [string]: any } do
					expect(string.find(line, def.name, 1, true) == nil).toBe(true)
				end
			end
		end)
	end)

	describe("Dream choice", function()
		it("never reaches a mythic latent, a mythic domain or a revealed latent", function()
			local p = profile({
				latent("LM", "Mythic", "time"),
				latent("L1", "Amplify", "gravity"),
				latent("L2", "Domain", "water", true),
			})
			expect(#Dreams.eligible(p)).toBe(0)
			local r = record()
			for n = 0, 60 do
				r.count = n
				local pick = Dreams.pick(p, r, 3, 1337)
				expect(pick.ordinary).toBe(true)
				expect(pick.latentId).toBe(nil)
			end
		end)

		it("the same night gives the same dream, and hidden latents are dreamt", function()
			local p = profile({ latent("L1", "Domain", "water"), latent("L2", "Temperament", "patient") })
			local r = record()
			r.count = 7
			local a, b = Dreams.pick(p, r, 0, 1337), Dreams.pick(p, r, 0, 1337)
			expect(a.text).toBe(b.text)
			local about = 0
			for n = 0, 60 do
				r.count = n
				if not Dreams.pick(p, r, 0, 1337).ordinary then
					about += 1
				end
			end
			expect(about > 25 and about < 61).toBe(true)
		end)

		it("grows clearer with each dream about the same latent, and with self-knowledge", function()
			expect(Dreams.clarity(0, 0)).toBe(1)
			expect(Dreams.clarity(1, 0)).toBe(1)
			expect(Dreams.clarity(2, 0)).toBe(2)
			expect(Dreams.clarity(4, 0)).toBe(3)
			expect(Dreams.clarity(40, 0)).toBe(3)
			expect(Dreams.clarity(0, 3)).toBe(2)
			local l = latent("L1", "Domain", "earth")
			local vague = Dreams.compose(l, 1, Random.new(5))
			local clear = Dreams.compose(l, 3, Random.new(5))
			expect(string.sub(clear, 1, #vague)).toBe(vague)
			expect(#clear > #vague).toBe(true)
			expect(#Dreams.recalled(l, 1337, "player:spec") > 20).toBe(true)
		end)
	end)
end
