--!strict
--[[
	NpcLooks.spec: NPC looks are deterministic, follow the data's rules, and cover every hair
	colour NPCFactory can roll. Pure choosing only: loading and applying need real catalog assets.
]]

local Server = game:GetService("ServerScriptService").Server
local NpcLooks = require(Server.NPC.NpcLooks)
local Data = require(Server.NPC.Data.NpcLooks)
local NpcData = require(Server.NPC.Data.NpcData)

local function npc(fields: { [string]: any }): any
	local base = {
		id = "npc_test",
		seed = 424242,
		appearance = { hair = "brown", build = "average", feature = "freckles" },
		ageBand = "adult",
		occupation = "merchant",
		culture = "tidecall",
	}
	for k, v in fields do
		base[k] = v
	end
	return base
end

local function setOf(list: { number }): { [number]: boolean }
	local out = {}
	for _, id in list do
		out[id] = true
	end
	return out
end

return function(t: any)
	t.describe("NpcLooks", function()
		t.it("is deterministic per NPC and varies between NPCs", function()
			local a1 = NpcLooks.choose(npc({}))
			local a2 = NpcLooks.choose(npc({}))
			t.expect(table.concat(a1.ids, ",")).toBe(table.concat(a2.ids, ","))
			local differ = 0
			for i = 1, 40 do
				local other = NpcLooks.choose(npc({ seed = 1000 + i * 7919 }))
				if table.concat(other.ids, ",") ~= table.concat(a1.ids, ",") then
					differ += 1
				end
			end
			t.expect(differ >= 30).toBe(true)
		end)

		t.it("maps every rollable hair colour to a hair pool", function()
			for _, colour in NpcData.hair do
				local pool = Data.hairColour[colour]
				if not pool or not Data.hair[pool] then
					error("no hair pool for " .. colour)
				end
			end
		end)

		t.it("gives guards helms that replace their hair, northern helms in the north", function()
			local helms = setOf(Data.headwear.helm.ids)
			local north = setOf(Data.headwear.northHelm.ids)
			local hairs: { [number]: boolean } = {}
			for _, list in Data.hair do
				for _, id in list do
					hairs[id] = true
				end
			end
			local helmed = 0
			for i = 1, 60 do
				local frost = NpcLooks.choose(npc({ seed = i * 104729, occupation = "guard", culture = "frostfolk" }))
				local south = NpcLooks.choose(npc({ seed = i * 104729, occupation = "guard", culture = "verdant" }))
				for _, id in frost.ids do
					t.expect(helms[id] == true and not north[id]).toBe(false) -- never a southern-only helm
				end
				for _, look in { frost, south } do
					local hasHelm, hasHair = false, false
					for _, id in look.ids do
						hasHelm = hasHelm or helms[id] == true or north[id] == true
						hasHair = hasHair or hairs[id] == true
					end
					if hasHelm then
						helmed += 1
						t.expect(hasHair).toBe(false)
					end
				end
			end
			t.expect(helmed >= 90).toBe(true) -- 90% of 120 guards
		end)

		t.it("scales by build and makes children small", function()
			t.expect(NpcLooks.choose(npc({ appearance = { hair = "brown", build = "heavy", feature = "" } })).scale).toBe(Data.scale.heavy)
			t.expect(NpcLooks.choose(npc({ ageBand = "child", occupation = "child" })).scale).toBe(Data.childScale)
		end)

		t.it("puts glasses on anyone with spectacles", function()
			local look = NpcLooks.choose(npc({ appearance = { hair = "black", build = "average", feature = "spectacles" } }))
			t.expect(table.find(look.ids, Data.glasses) ~= nil).toBe(true)
		end)

		t.it("dresses every occupation, with pieces that exist, coloured by culture", function()
			for occupation in NpcData.occupations do
				t.expect(Data.outfits[occupation] ~= nil).toBe(true)
			end
			for _, outfit in Data.outfits do
				for kind in (outfit.always or {}) :: { [string]: any } do
					t.expect(Data.garments[kind] ~= nil).toBe(true)
				end
				for kind in (outfit.maybe or {}) :: { [string]: any } do
					t.expect(Data.garments[kind] ~= nil).toBe(true)
				end
			end
			local guard = NpcLooks.choose(npc({ occupation = "guard" }))
			local kinds: { [string]: boolean } = {}
			for _, g in guard.garments do
				kinds[g.kind] = true
			end
			t.expect(kinds.tabardFront and kinds.tabardBack and kinds.belt).toBe(true)
			-- The same NPC always wears the same thing.
			local again = NpcLooks.choose(npc({ occupation = "guard" }))
			t.expect(#again.garments).toBe(#guard.garments)
			t.expect(again.garments[1].color).toBe(guard.garments[1].color)
			-- The well-off get a buckle.
			local rich = NpcLooks.choose(npc({ occupation = "smith", socialClass = "high" }))
			local buckle = false
			for _, g in rich.garments do
				buckle = buckle or g.kind == "buckle"
			end
			t.expect(buckle).toBe(true)
		end)

		t.it("shows a strong mage's signature, and nobody else's", function()
			t.expect(NpcLooks.choose(npc({})).accent).toBe(nil) -- no magic at all
			local mage = npc({
				magic = { mastery = { pyromancy = 100000 }, unlocked = {} },
				profile = { signature = { primary = "#ff4020", secondary = "#ffd040", accent = "#40a0ff" } },
			})
			local look = NpcLooks.choose(mage)
			t.expect(look.accent ~= nil).toBe(true)
			local neon = 0
			for _, g in look.garments do
				if g.neon then
					neon += 1
				end
			end
			t.expect(neon >= 3).toBe(true) -- both wrists and a belt or sash
		end)

		t.it("lists every id once for preloading", function()
			local ids = NpcLooks.allIds()
			t.expect(#ids >= 60).toBe(true)
			local seen: { [number]: boolean } = {}
			for _, id in ids do
				t.expect(seen[id]).toBe(nil)
				seen[id] = true
			end
		end)
	end)
end
