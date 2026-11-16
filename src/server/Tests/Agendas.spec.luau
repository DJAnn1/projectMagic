--!strict
--[[
	Agendas.spec: the world acts without you (docs/LivingHistory.md §5, §8, stage 4a). What matters
	most: every server computes the same day from the seed; sieges only where Wildborn live near,
	raids only between feuding towns, alliances only between friends; a fallen town stays fallen
	exactly from the siege's end to its retake day, the same whatever order towns are listed in; every
	outcome can be told, with no digits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Rules = require(Server.Agendas.AgendaRules)
local Data = require(Server.Agendas.Data.Agendas)
local Kinds = require(Server.Chronicle.Data.ChronicleKinds)
local Flags = require(Server.Config.Flags)
local Omens = require(ReplicatedStorage.Shared.Magic.Data.Omens)

local T = Rules.Tuning

local function world(): ({ Rules.Town }, { Rules.Haunt })
	local towns: { Rules.Town } = {
		{ id = "a", x = 0, z = 0, radius = 120, relations = { b = -0.5, c = 0.6 } },
		{ id = "b", x = 500, z = 0, radius = 120, relations = { a = -0.5, c = 0 } },
		{ id = "c", x = 3000, z = 3000, radius = 120, relations = { a = 0.6, b = 0 } },
	}
	local haunts: { Rules.Haunt } = { { theme = "fire", x = 100, z = 0 } }
	return towns, haunts
end

local function key(plan: { Rules.Agenda }): string
	local parts = {}
	for _, a in plan do
		table.insert(parts, string.format("%s|%s|%.4f", a.id, a.outcome, a.at))
	end
	return table.concat(parts, ";")
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Agendas", function()
		it("plans the same day the same way, whatever order the towns come in", function()
			local towns, haunts = world()
			local reversed = { towns[3], towns[2], towns[1] }
			local any = 0
			for day = 0, 60 do
				local a = Rules.plan(1337, day, towns, haunts)
				local b = Rules.plan(1337, day, reversed, haunts)
				expect(key(a)).toBe(key(b))
				expect(#a <= T.perDay).toBe(true)
				any += #a
			end
			expect(any > 0).toBe(true)
		end)

		it("besieges only near Wildborn, raids only feuds, allies only friends", function()
			local towns, haunts = world()
			local seen: { [string]: boolean } = {}
			for day = 0, 300 do
				for _, a in Rules.plan(1337, day, towns, haunts) do
					seen[a.kind] = true
					if a.kind == "siege" then
						expect(a.town == "a" or a.town == "b").toBe(true) -- c is far from any haunt
						expect(a.theme).toBe("fire")
						expect(a.outcome == "held" or a.outcome == "fell").toBe(true)
					elseif a.kind == "raid" then
						expect((a.town == "a" and a.other == "b") or (a.town == "b" and a.other == "a")).toBe(true)
					elseif a.kind == "alliance" then
						expect((a.town == "a" and a.other == "c") or (a.town == "c" and a.other == "a")).toBe(true)
					end
					expect(a.at >= day and a.at < day + 2).toBe(true)
				end
			end
			expect(seen.siege and seen.raid and seen.alliance and seen.trade).toBe(true)
		end)

		it("keeps a fallen town fallen from the siege's end to its retake day", function()
			local towns, haunts = world()
			local found: Rules.Agenda? = nil
			for day = 0, 400 do
				for _, a in Rules.plan(1337, day, towns, haunts) do
					if a.kind == "siege" and a.outcome == "fell" then
						found = a
						break
					end
				end
				if found then
					break
				end
			end
			expect(found ~= nil).toBe(true)
			local siege = found :: Rules.Agenda
			local done = siege.at + siege.hours / 24
			local retake = siege.retake :: number
			expect(retake > done).toBe(true)
			-- Another siege of the same town may overlap: only this one's fall is checked.
			local function fallenBy(now: number): boolean
				local f = Rules.fallen(1337, now, towns, haunts)[siege.town]
				return f ~= nil and f.agenda == siege.id
			end
			expect(fallenBy(done - 0.01)).toBe(false)
			expect(fallenBy(done + 0.01)).toBe(true)
			expect(fallenBy(retake + 0.01)).toBe(false)
		end)

		it("can tell every outcome, with no digits, and has its kinds, flag and omen", function()
			expect((Flags :: any).agendas_enabled ~= nil).toBe(true)
			expect(Omens.sources.agenda_siege ~= nil).toBe(true)
			for _, kind in { "siege_broken", "town_fell", "town_retaken" } do
				expect(Kinds[kind] ~= nil).toBe(true)
			end
			local cats: { [string]: boolean } = {}
			for _, line in Data.lines do
				cats[line.cat] = true
				expect(string.find(line.text, "%d") == nil).toBe(true)
			end
			for _, outcome in { "held", "fell", "retaken", "burned", "driven_off", "sworn", "boom", "bust" } do
				expect(cats["news_" .. outcome] == true).toBe(true)
				expect(Data.journal[outcome] ~= nil).toBe(true)
			end
			expect(cats.shout_raid and cats.shout_siege).toBe(true)
			expect(T.liveReach < 320).toBe(true) -- under Wildborn sleepRadius
		end)
	end)
end
