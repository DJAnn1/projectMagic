--!strict
--[[
	LivingWorld.spec: daily life data, barks, greetings and scenes (docs/LivingWorld.md).
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Activities = require(Server.NPC.Data.Activities)
local Barks = require(Server.NPC.Data.Barks)
local BarkEngine = require(Server.NPC.BarkEngine)
local GreetingRules = require(Server.NPC.GreetingRules)
local NeedsActions = require(Server.NPC.Data.NeedsActions)
local NpcData = require(Server.NPC.Data.NpcData)
local Quirks = require(Server.NPC.Data.Quirks)
local ScheduleService = require(Server.NPC.ScheduleService)
local MemoryService = require(Server.NPC.MemoryService)
local SceneRules = require(Server.Scenes.SceneRules)
local Templates = require(Server.Scenes.Data.SceneTemplates)

local function ctx(overrides: { [string]: any }): any
	local base: any = {
		hour = 12, occupation = "smith", action = "work", mood = "content", rel = "stranger",
		traits = {}, quirks = {}, events = {}, biome = "grasslands", culture = "forgehold",
		child = false, mage = false, deeds = {}, vars = { town = "Testford", name = "Hedda" },
	}
	for k, v in overrides do
		base[k] = v
	end
	return base
end

local function input(overrides: { [string]: any }): any
	local base: any = {
		settlement = 0, faction = 0, opinion = 0, infamy = 0, bounty = false,
		notoriety = 0, attuned = false, agreeable = 0.5, nervous = 0.5, child = false,
	}
	for k, v in overrides do
		base[k] = v
	end
	return base
end

return function(t: any)
	t.describe("Daily life", function()
		t.it("has a real clip and prop behind every activity", function()
			local function check(where: string, a: any)
				if a.clip and not Activities.Clips[a.clip] then
					error(where .. ": no clip " .. a.clip)
				end
				if a.prop and not Activities.Props[a.prop] then
					error(where .. ": no prop " .. a.prop)
				end
				if not a.clip and not a.patrol and not a.roam then
					error(where .. " does nothing")
				end
			end
			for occupation, actions in Activities.byOccupation do
				if not NpcData.occupations[occupation] then
					error("no occupation " .. occupation)
				end
				for action, a in actions do
					if not NeedsActions.actions[action] then
						error(occupation .. ": no action " .. action)
					end
					check(occupation .. "." .. action, a)
				end
			end
			for action, a in Activities.byAction do
				if not NeedsActions.actions[action] then
					error("no action " .. action)
				end
				check(action, a)
			end
		end)

		t.it("splits guards across shifts so the town is watched around the clock", function()
			for hour = 0, 23 do
				local on = 0
				for seed = 0, 2 do
					local guard = { occupation = "guard", seed = seed, scheduleShift = 0 }
					if ScheduleService.blockAt(guard, hour, false) == "work" then
						on += 1
					end
				end
				if on == 0 then
					error("no guard works at hour " .. hour)
				end
			end
		end)
	end)

	t.describe("Barks", function()
		t.it("has at least 100 ambient lines and a line for every greeting band", function()
			local ambient = 0
			local cats: { [string]: number } = {}
			for _, line in Barks do
				cats[line.cat] = (cats[line.cat] or 0) + 1
				if string.sub(line.cat, 1, 6) ~= "greet_" then
					ambient += 1
				end
			end
			t.log("  ambient bark lines: " .. ambient)
			t.expect(ambient >= 100).toBe(true)
			for _, band in { "fawn", "warm", "neutral", "awe", "wary", "avoid", "whisper_good", "whisper_bad" } do
				t.expect((cats["greet_" .. band] or 0) > 0).toBe(true)
			end
		end)

		t.it("uses only real occupations, quirks, memories and known vars", function()
			local known = { town = true, name = true, player = true, story = true, friend = true }
			for _, line in Barks do
				for _, occupation in (line.occ or {}) :: { string } do
					if not NpcData.occupations[occupation] then
						error(line.text .. ": no occupation " .. occupation)
					end
				end
				for _, action in (line.action or {}) :: { string } do
					if not NeedsActions.actions[action] then
						error(line.text .. ": no action " .. action)
					end
				end
				for _, quirk in (line.quirk or {}) :: { string } do
					if not Quirks.defs[quirk] then
						error(line.text .. ": no quirk " .. quirk)
					end
				end
				for _, deed in (line.deed or {}) :: { string } do
					if not MemoryService.KINDS[deed] then
						error(line.text .. ": no memory kind " .. deed)
					end
				end
				for var in string.gmatch(line.text, "{(%a+)}") do
					if not known[var] then
						error(line.text .. ": unknown var " .. var)
					end
				end
			end
		end)

		t.it("matches a line to its conditions", function()
			local smithLine: any = { cat = "work", text = "x", occ = { "smith" }, action = { "work" } }
			t.expect(BarkEngine.eligible(smithLine, ctx({}))).toBe(true)
			t.expect(BarkEngine.eligible(smithLine, ctx({ occupation = "farmer" }))).toBe(false)
			t.expect(BarkEngine.eligible({ cat = "t", text = "x", hours = { 22, 4 } } :: any, ctx({ hour = 23 }))).toBe(true)
			t.expect(BarkEngine.eligible({ cat = "t", text = "x", hours = { 22, 4 } } :: any, ctx({ hour = 3 }))).toBe(true)
			t.expect(BarkEngine.eligible({ cat = "t", text = "x", hours = { 22, 4 } } :: any, ctx({ hour = 12 }))).toBe(false)
			t.expect(BarkEngine.eligible({ cat = "t", text = "x", high = { pride = 0.7 } } :: any, ctx({ traits = { pride = 0.8 } }))).toBe(true)
			t.expect(BarkEngine.eligible({ cat = "t", text = "x", high = { pride = 0.7 } } :: any, ctx({}))).toBe(false)
			t.expect(BarkEngine.eligible({ cat = "t", text = "x", child = true } :: any, ctx({}))).toBe(false)
		end)

		t.it("skips a line whose var isn't there, and capitalises one that opens with a var", function()
			t.expect(BarkEngine.fill("Did you hear? {story}.", {})).toBe(nil)
			t.expect(BarkEngine.fill("{story}, they say.", { story = "rats ate it" })).toBe("Rats ate it, they say.")
		end)

		t.it("never repeats a line an NPC said recently", function()
			local recent: { [number]: boolean } = {}
			local c = ctx({})
			local seen = 0
			for i = 1, 40 do
				local index = BarkEngine.pick("ambient", c, Random.new(i), recent, nil)
				if not index then
					break
				end
				t.expect(recent[index]).toBe(nil)
				recent[index] = true
				seen += 1
			end
			t.expect(seen > 5).toBe(true)
		end)

		t.it("says things about the player only when it has a memory of them", function()
			local index = BarkEngine.pick("greet_warm", ctx({ vars = { town = "T" } }), Random.new(1), {}, nil)
			if index then
				t.expect(string.find(Barks[index].text, "{player}", 1, true)).toBe(nil)
			end
			for seed = 1, 60 do
				local i = BarkEngine.pick("ambient", ctx({}), Random.new(seed), {}, nil)
				if i then
					t.expect(Barks[i].cat ~= "deed").toBe(true)
				end
			end
		end)
	end)

	t.describe("Greetings", function()
		t.it("runs from fawning to fleeing as your name changes", function()
			t.expect(GreetingRules.band(input({ settlement = 80 }))).toBe("fawn")
			t.expect(GreetingRules.band(input({ settlement = 25 }))).toBe("warm")
			t.expect(GreetingRules.band(input({}))).toBe("neutral")
			t.expect(GreetingRules.band(input({ infamy = 15 }))).toBe("wary")
			t.expect(GreetingRules.band(input({ infamy = 50 }))).toBe("avoid")
		end)

		t.it("takes a bounty and notoriety seriously", function()
			t.expect(GreetingRules.band(input({ settlement = 80, bounty = true }))).toBe("wary")
			t.expect(GreetingRules.band(input({ notoriety = 40 }))).toBe("wary")
		end)

		t.it("stares at a readied spell, unless it already knows you", function()
			t.expect(GreetingRules.band(input({ attuned = true }))).toBe("awe")
			t.expect(GreetingRules.band(input({ settlement = 80, attuned = true }))).toBe("fawn")
		end)

		t.it("lets children be children", function()
			t.expect(GreetingRules.band(input({ settlement = 80, child = true }))).toBe("warm")
			t.expect(GreetingRules.band(input({ infamy = 50, child = true }))).toBe("avoid")
		end)

		t.it("only whispers about people worth whispering about", function()
			t.expect(GreetingRules.whisper("neutral")).toBe(nil)
			t.expect(GreetingRules.whisper("warm")).toBe(nil)
			t.expect(GreetingRules.whisper("fawn")).toBe("greet_whisper_good")
			t.expect(GreetingRules.whisper("avoid")).toBe("greet_whisper_bad")
		end)
	end)

	t.describe("Scenes", function()
		t.it("has at least 10 templates, all consistent with the real data", function()
			t.expect(#Templates >= 10).toBe(true)
			local problems = SceneRules.validate()
			if #problems > 0 then
				error(table.concat(problems, "; "))
			end
		end)

		t.it("gives every template something a player can do", function()
			for _, template in Templates do
				if #template.interventions == 0 then
					error(template.id .. " can't be changed by a player")
				end
			end
		end)

		t.it("honours hours and weekdays, across midnight too", function()
			local template: any = { hours = { 20, 4 } }
			t.expect(SceneRules.timeFits(template, 22, 3)).toBe(true)
			t.expect(SceneRules.timeFits(template, 2, 3)).toBe(true)
			t.expect(SceneRules.timeFits(template, 12, 3)).toBe(false)
			local rest: any = { hours = { 10, 17 }, weekday = 0 }
			t.expect(SceneRules.timeFits(rest, 12, 0)).toBe(true)
			t.expect(SceneRules.timeFits(rest, 12, 1)).toBe(false)
		end)

		t.it("ends the same way from the same seed, and only on outcomes that can happen alone", function()
			for _, template in Templates do
				for seed = 1, 20 do
					local a = SceneRules.outcomeWhenAlone(template, Random.new(seed))
					local b = SceneRules.outcomeWhenAlone(template, Random.new(seed))
					t.expect(a).toBe(b)
					t.expect((template.outcomes[a].weight or 0) > 0).toBe(true)
				end
			end
		end)

		t.it("tells a story with the actors' names", function()
			t.expect(SceneRules.tellStory("{a} beat {b} in {town}", { a = "Ann", b = "Bo", town = "Hale" })).toBe("Ann beat Bo in Hale")
			t.expect(SceneRules.tellStory("{a} ran", {})).toBe("someone ran")
		end)
	end)
end
