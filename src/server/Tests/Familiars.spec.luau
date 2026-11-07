--!strict
--[[
	Familiars.spec: the rules behind familiars, with no live players (docs/Familiars.md). The ones that
	matter most: every server draws the same familiar, every domain has a body and an ability, it can't
	be farmed past the daily limit, and it obeys your orders.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Flags = require(Server.Config.Flags)
local Schemas = require(Server.Persistence.Schemas)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local FamiliarRig = require(Server.Familiars.FamiliarRig)

local Shared = ReplicatedStorage.Shared
local F = require(Shared.Familiars.Data.Familiars)
local Rules = require(Shared.Familiars.FamiliarRules)
local Registry = require(Shared.Magic.Registry)
local Temperaments = require(Shared.Magic.Data.Temperaments)
local Controls = require(Shared.UI.Controls)
local Remotes = require(Shared.Net.Remotes)

local T = F.tuning

local COLORS: Rules.Colors = {
	primary = Color3.fromRGB(200, 40, 40),
	secondary = Color3.fromRGB(40, 200, 40),
	accent = Color3.fromRGB(40, 40, 200),
}

local function identity(domain: string?): Rules.Identity
	return Rules.generate(1337, 42, domain or "energy", { "swift" }, COLORS)
end

local function view(over: { [string]: any }): Rules.View
	local base: { [string]: any } = {
		hasOwner = true,
		frozen = false,
		mode = "guard",
		ownerDistance = 3,
		hasTarget = false,
		targetInReach = false,
		targetToOwner = 10,
		inDuel = false,
	}
	for key, value in over do
		base[key] = value
	end
	return base :: any
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Familiar data", function()
		it("every domain has an ability and a look", function()
			for _, id in Registry.domainIds do
				expect(F.abilities[id] ~= nil).toBe(true)
				expect(F.looks[id] ~= nil).toBe(true)
			end
		end)

		it("an ability's status is real, and each ability's kind is one the service handles", function()
			local kinds = { bolt = true, hinder = true, mend = true, ward = true, haste = true }
			for id, ability in F.abilities do
				expect(ability.id).toBe(id)
				expect((kinds :: any)[ability.kind]).toBe(true)
				expect(#ability.name > 0 and #ability.text > 0).toBe(true)
				if ability.status then
					expect(StatusEffects.defs[ability.status] ~= nil).toBe(true)
				end
			end
		end)

		it("stages start at 0 XP and rise, in XP, size and strength", function()
			expect(F.stages[1].xp).toBe(0)
			for i = 2, #F.stages do
				expect(F.stages[i].xp > F.stages[i - 1].xp).toBe(true)
				expect(F.stages[i].scale > F.stages[i - 1].scale).toBe(true)
				expect(F.stages[i].bite > F.stages[i - 1].bite).toBe(true)
				expect(F.stages[i].health > F.stages[i - 1].health).toBe(true)
			end
		end)

		it("an ability comes before the one it learns, and both exist as stages", function()
			expect(T.abilityStage < T.learnStage).toBe(true)
			expect(F.stages[T.learnStage] ~= nil).toBe(true)
		end)

		it("every shape has eyes, and every part names a known colour slot", function()
			local slots = { primary = true, secondary = true, accent = true, glow = true, dark = true, eye = true }
			for _, shape in F.shapes do
				local eyes = 0
				for _, part in shape.parts do
					expect((slots :: any)[part.slot]).toBe(true)
					if part.slot == "eye" then
						eyes += 1
					end
				end
				expect(eyes >= 2).toBe(true)
			end
		end)

		it("part names are unique within a shape, and every anim is one the client plays", function()
			local kinds = { wag = true, flap = true, bob = true, orbit = true }
			for _, shape in F.shapes do
				local seen: { [string]: boolean } = {}
				for _, part in shape.parts do
					expect(seen[part.name]).toBe(nil)
					seen[part.name] = true
					if part.anim then
						expect((kinds :: any)[part.anim.kind]).toBe(true)
					end
					expect(part.fromStage == nil or F.stages[part.fromStage] ~= nil).toBe(true)
				end
			end
		end)

		it("default names are unique and short enough", function()
			local seen: { [string]: boolean } = {}
			for _, name in F.names do
				expect(seen[name]).toBe(nil)
				seen[name] = true
				expect(#name <= T.nameChars).toBe(true)
			end
		end)

		it("personalities are for real temperaments", function()
			for id in F.personalities do
				expect((Temperaments :: any)[id] ~= nil).toBe(true)
			end
		end)

		it("the default mode is one of the modes", function()
			expect(Rules.modeExists(F.defaultMode)).toBe(true)
			expect(Rules.modeExists("fetch")).toBe(false)
			expect(Rules.modeExists(nil)).toBe(false)
		end)
	end)

	describe("Familiar wiring", function()
		it("has its flags, its save field, a free key and its remotes", function()
			expect((Flags :: any).familiars_enabled ~= nil).toBe(true)
			expect((Flags :: any).familiars_max_alive ~= nil).toBe(true)
			local save = Schemas.Player.template().familiar
			expect(save.bonded).toBe(0)
			expect(save.mode).toBe(F.defaultMode)
			expect(save.summoned).toBe(true)
			expect(Controls.byId.open_familiar ~= nil).toBe(true)
			expect((Remotes :: any).FamiliarAction.kind).toBe("Function")
			expect((Remotes :: any).FamiliarState.from).toBe("Server")
		end)

		it("its body can't be seen by spells or walked into", function()
			local rig = FamiliarRig.build(Rules.body(identity(), 1), CFrame.new(), 42)
			for _, part in rig.model:GetDescendants() do
				if part:IsA("BasePart") then
					expect(part.CanCollide).toBe(false)
					expect(part.CanQuery).toBe(false)
					expect(part.CanTouch).toBe(false)
				end
			end
			expect(rig.model:FindFirstChildOfClass("Humanoid")).toBe(nil)
			-- The client poses parts through these, so they have to be Welds.
			expect(rig.model:FindFirstChild("WeldConstraint", true)).toBe(nil)
			expect(rig.model:FindFirstChild("Pose", true) ~= nil).toBe(true)
			rig.model:Destroy()
		end)
	end)

	describe("Bonding", function()
		it("comes from a few spells or from reaching Novice", function()
			expect(Rules.shouldBond(0, 1)).toBe(false)
			expect(Rules.shouldBond(T.bondCasts - 1, 1)).toBe(false)
			expect(Rules.shouldBond(T.bondCasts, 1)).toBe(true)
			expect(Rules.shouldBond(0, T.bondTier)).toBe(true)
		end)

		it("picks your strongest awakened domain, with ties by id", function()
			expect(Rules.bondDomain({ "air", "energy" }, { air = 0.2, energy = 0.7, gravity = 0.9 })).toBe("energy")
			expect(Rules.bondDomain({ "water", "air" }, { air = 0.5, water = 0.5 })).toBe("air")
		end)

		it("with nothing awakened, picks your strongest of all", function()
			expect(Rules.bondDomain({}, { air = 0.2, life = 0.6 })).toBe("life")
		end)
	end)

	describe("Generation", function()
		it("draws the same familiar on every server", function()
			local a, b = identity(), identity()
			expect(a.shape).toBe(b.shape)
			expect(a.defaultName).toBe(b.defaultName)
			expect(a.sizeJitter).toBe(b.sizeJitter)
			expect(a.followAngle).toBe(b.followAngle)
		end)

		it("gives different players different familiars", function()
			local seen: { [string]: boolean } = {}
			local kinds = 0
			for userId = 1, 40 do
				local key = Rules.generate(1337, userId, "energy", {}, COLORS).defaultName
				if not seen[key] then
					seen[key] = true
					kinds += 1
				end
			end
			expect(kinds > 10).toBe(true)
		end)

		it("doesn't depend on the order temperaments are saved in", function()
			expect(Rules.personalityOf({ "swift", "deepwell" }).word).toBe(Rules.personalityOf({ "deepwell", "swift" }).word)
		end)

		it("a temperament with no personality gets the default", function()
			expect(Rules.personalityOf({}).word).toBe(F.defaultPersonality.word)
			expect(Rules.personalityOf({ "not_a_temperament" }).word).toBe(F.defaultPersonality.word)
		end)
	end)

	describe("Growth", function()
		it("finds the stage from XP", function()
			expect(Rules.stageOf(0)).toBe(1)
			expect(Rules.stageOf(F.stages[2].xp - 1)).toBe(1)
			expect(Rules.stageOf(F.stages[2].xp)).toBe(2)
			expect(Rules.stageOf(1e9)).toBe(#F.stages)
		end)

		it("stops at the daily limit, and a new day starts again", function()
			local record = { xp = 0, day = 5, dayXp = 0 }
			expect(Rules.addXp(record, T.dailyXp + 50, 5)).toBe(T.dailyXp)
			expect(Rules.addXp(record, 10, 5)).toBe(0)
			expect(record.xp).toBe(T.dailyXp)
			expect(Rules.addXp(record, 10, 6)).toBe(10)
			expect(record.dayXp).toBe(10)
		end)

		it("kill XP rises with the target's health, up to a limit", function()
			expect(Rules.killXp(0)).toBe(T.killXp)
			expect(Rules.killXp(250) > T.killXp).toBe(true)
			expect(Rules.killXp(1000000)).toBe(T.killXpMax)
		end)

		it("learns from what you cast most, never its own domain", function()
			expect(Rules.learnedDomain({ energy = 50, air = 9, water = 12 }, "energy")).toBe("water")
			expect(Rules.learnedDomain({ energy = 50 }, "energy")).toBe(nil)
			expect(Rules.learnedDomain({ air = 5, water = 5 }, "energy")).toBe("air")
		end)

		it("having cast nothing else, learns from a domain that pairs with its own", function()
			expect(Rules.learnedDomain({ energy = 50 }, "energy", { "air", "earth" })).toBe("air")
			expect(Rules.learnedDomain({}, "energy", { "energy", "earth" })).toBe("earth")
			expect(Rules.learnedDomain({ water = 1 }, "energy", { "air" })).toBe("water")
		end)

		it("every domain can learn a second ability, even with nothing else cast", function()
			for _, id in Registry.domainIds do
				expect(Rules.learnedDomain({}, id, Registry.domains[id].synergies) ~= nil).toBe(true)
			end
		end)

		it("gets its abilities at the right stages", function()
			local record = { domain = "energy", learned = "water" }
			expect(#Rules.abilitiesOf(record, 1)).toBe(0)
			expect(#Rules.abilitiesOf(record, T.abilityStage)).toBe(1)
			expect(#Rules.abilitiesOf(record, T.learnStage)).toBe(2)
			expect(#Rules.abilitiesOf({ domain = "energy", learned = "" }, T.learnStage)).toBe(1)
		end)

		it("stays a helper: even an Ascendant bites for under half a full hit", function()
			local stats = Rules.statsFor(Rules.generate(1, 1, "energy", { "brittle" }, COLORS), #F.stages, 8, 100)
			expect(stats.bite > 0 and stats.bite <= 55).toBe(true)
		end)

		it("mythic domains hit harder, and tier raises health", function()
			local plain = Rules.statsFor(identity("earth"), 3, 1, 10)
			local mythic = Rules.statsFor(identity("gravity"), 3, 1, 10)
			expect(mythic.bite > plain.bite).toBe(true)
			expect(Rules.statsFor(identity("earth"), 3, 8, 10).maxHealth > plain.maxHealth).toBe(true)
		end)

		it("grows bigger with each stage", function()
			expect(Rules.body(identity(), 5).radius > Rules.body(identity(), 1).radius).toBe(true)
		end)

		it("shows its growth: more parts, then a trail, then a light", function()
			for _, shape in F.shapes do
				local who = identity()
				who.shape = shape.id
				local young, old = Rules.body(who, 1), Rules.body(who, 5)
				expect(#old.parts > #young.parts).toBe(true)
				expect(young.trail).toBe(false)
				expect(old.trail).toBe(true)
				expect(young.light).toBe(false)
				expect(old.light).toBe(true)
			end
		end)

		it("gives every eye a pupil, and every body part a real colour and unique name", function()
			for _, shape in F.shapes do
				local who = identity()
				who.shape = shape.id
				local names: { [string]: boolean } = {}
				for _, part in Rules.body(who, 5).parts do
					expect(names[part.name]).toBe(nil)
					names[part.name] = true
					expect(typeof(part.color)).toBe("Color3")
				end
				expect(names.EyeLPupil).toBe(true)
				expect(names.EyeRPupil).toBe(true)
			end
		end)

		it("makes the domain's colour show, whatever the signature", function()
			local function gap(a: Color3, b: Color3): number
				return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)
			end
			local who = identity("water")
			who.shape = "wisp"
			local color: Color3? = nil
			for _, part in Rules.body(who, 1).parts do
				if part.name == "Body" then
					color = part.color
				end
			end
			expect(color ~= nil).toBe(true)
			expect(gap(color :: Color3, F.looks.water.glow) < gap(color :: Color3, COLORS.primary)).toBe(true)
		end)
	end)

	describe("Orders", function()
		it("does nothing with no owner, or in stopped time", function()
			expect(Rules.decide(view({ hasOwner = false, ownerDistance = 999 }))).toBe("idle")
			expect(Rules.decide(view({ frozen = true, hasTarget = true }))).toBe("idle")
		end)

		it("follows you, and catches up by appearing when you're far off", function()
			expect(Rules.decide(view({ ownerDistance = T.followAt + 1 }))).toBe("follow")
			expect(Rules.decide(view({ ownerDistance = T.followAt - 1 }))).toBe("idle")
			expect(Rules.decide(view({ ownerDistance = T.teleportAt + 1 }))).toBe("teleport")
		end)

		it("Follow never fights", function()
			expect(Rules.decide(view({ mode = "follow", hasTarget = true, targetInReach = true }))).toBe("idle")
		end)

		it("Guard and Hunt fight a target near you, not one past the leash", function()
			expect(Rules.decide(view({ hasTarget = true }))).toBe("attack")
			expect(Rules.decide(view({ mode = "hunt", hasTarget = true }))).toBe("attack")
			expect(Rules.decide(view({ hasTarget = true, targetToOwner = T.leash + 1, ownerDistance = T.followAt + 1 }))).toBe("follow")
		end)

		it("sits out your duels", function()
			expect(Rules.decide(view({ hasTarget = true, inDuel = true }))).toBe("idle")
		end)

		it("Stay holds its spot, and bites only what's in reach", function()
			expect(Rules.decide(view({ mode = "stay", ownerDistance = T.teleportAt + 50 }))).toBe("idle")
			expect(Rules.decide(view({ mode = "stay", hasTarget = true }))).toBe("idle")
			expect(Rules.decide(view({ mode = "stay", hasTarget = true, targetInReach = true }))).toBe("attack")
			expect(Rules.decide(view({ mode = "stay", ownerDistance = T.stayLimit + 1 }))).toBe("teleport")
		end)
	end)

	describe("Limits", function()
		it("big targets hurt it more", function()
			expect(Rules.retaliation(100, 10)).toBe(100 * T.retaliation)
			expect(Rules.retaliation(100, T.bigTarget)).toBe(100 * T.retaliationBig)
		end)

		it("stops counting you as playing after a while", function()
			expect(Rules.active(100, 100 - T.activeSeconds)).toBe(true)
			expect(Rules.active(100, 100 - T.activeSeconds - 1)).toBe(false)
		end)

		it("cleans names: trimmed, limited, and blank means its own", function()
			expect(Rules.cleanName("  Pip  ")).toBe("Pip")
			expect(Rules.cleanName("   ")).toBe("")
			expect(utf8.len(Rules.cleanName(string.rep("é", T.nameChars + 10)))).toBe(T.nameChars)
			expect(Rules.cleanName("a\nb")).toBe("ab")
		end)
	end)
end
