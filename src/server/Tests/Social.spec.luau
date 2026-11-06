--!strict
--[[
	Social.spec: the rules behind parties, combos and duels, with no live players (docs/Social.md).
	Uses made-up user ids far from any Studio test player (who are small negatives), and clears
	everything it writes to PvpRules, because that module is live server state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local PartyModel = require(Server.Social.PartyModel)
local DuelModel = require(Server.Social.DuelModel)
local ComboMatcher = require(Server.Social.ComboMatcher)
local PvpRules = require(Server.Magic.Cast.PvpRules)
local Damage = require(Server.Magic.Cast.Damage)

local Shared = ReplicatedStorage.Shared
local Combos = require(Shared.Social.Data.Combos)
local DuelRules = require(Shared.Social.Data.DuelRules)
local Emotes = require(Shared.Social.Data.Emotes)
local Remotes = require(Shared.Net.Remotes)
local Settings = require(Shared.UI.Settings)

local A, B, C_, D, E, F = 91000001, 91000002, 91000003, 91000004, 91000005, 91000006
local INFO = { kind = "strike", domain = "energy", crit = false }

local function body(health: number): Humanoid
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = health
	humanoid.Parent = model
	return humanoid
end

local function cast(userId: number, domain: string, at: number, point: Vector3?): ComboMatcher.Cast
	return { userId = userId, domains = { domain }, tags = {}, verb = "generate", power = 3, branch = domain, point = point or Vector3.zero, at = at, backfired = false }
end

local function fightingDuel(rule: string): DuelModel.Duel
	local duel = DuelModel.new("spec", A, B, rule, Vector3.zero, 0)
	duel.phase = "fight"
	return duel
end

local function bodies(aShare: number, bShare: number, aDistance: number?, bDistance: number?): { [number]: DuelModel.Body }
	return {
		[A] = { alive = true, share = aShare, distance = aDistance or 0 },
		[B] = { alive = true, share = bShare, distance = bDistance or 0 },
	}
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Parties", function()
		local function pair(): PartyModel.Book
			local book = PartyModel.new()
			PartyModel.invite(book, A, B, 0)
			PartyModel.accept(book, B, A, 0)
			return book
		end

		it("forms a party from the first accepted invite, led by the inviter", function()
			local book = pair()
			local party = PartyModel.partyOf(book, B)
			expect(party ~= nil).toBe(true)
			expect((party :: PartyModel.Party).leader).toBe(A)
			expect(PartyModel.partyOf(book, A)).toBe(party)
		end)
		it("refuses a sixth member", function()
			local book = pair()
			for _, id in { C_, D, E } do
				PartyModel.invite(book, A, id, 0)
				PartyModel.accept(book, id, A, 0)
			end
			local ok, reason = PartyModel.invite(book, A, F, 0)
			expect(ok).toBe(false)
			expect(reason).toBe("FULL")
		end)
		it("won't fill past five when invites were sent before it filled up", function()
			local book = pair()
			for _, id in { C_, D, F } do
				PartyModel.invite(book, A, id, 0)
			end
			PartyModel.accept(book, C_, A, 0)
			PartyModel.accept(book, D, A, 0)
			PartyModel.invite(book, A, E, 0)
			PartyModel.accept(book, E, A, 0)
			local ok, reason = PartyModel.accept(book, F, A, 0)
			expect(ok).toBe(false)
			expect(reason).toBe("FULL")
			expect(#(PartyModel.partyOf(book, A) :: PartyModel.Party).members).toBe(PartyModel.MAX_MEMBERS)
		end)
		it("lets only the leader invite, kick and promote", function()
			local book = pair()
			expect(select(2, PartyModel.invite(book, B, C_, 0))).toBe("NOT_LEADER")
			expect(select(2, PartyModel.kick(book, B, A))).toBe("NOT_LEADER")
			expect(select(2, PartyModel.promote(book, B, B))).toBe("NOT_LEADER")
		end)
		it("expires invites, and refuses a late accept", function()
			local book = PartyModel.new()
			PartyModel.invite(book, A, B, 0)
			local ok, reason = PartyModel.accept(book, B, A, PartyModel.INVITE_SECONDS + 1)
			expect(ok).toBe(false)
			expect(reason).toBe("EXPIRED")
			expect(PartyModel.partyOf(book, A)).toBe(nil)
		end)
		it("stops the same person inviting right after a no", function()
			local book = PartyModel.new()
			PartyModel.invite(book, A, B, 0)
			PartyModel.decline(book, B, A, 0)
			expect(select(2, PartyModel.invite(book, A, B, 1))).toBe("COOLDOWN")
			expect((PartyModel.invite(book, A, B, PartyModel.DECLINE_COOLDOWN + 1))).toBe(true)
		end)
		it("limits how many invites one person can have open", function()
			local book = PartyModel.new()
			for i = 1, PartyModel.MAX_OPEN_INVITES do
				expect((PartyModel.invite(book, A, 92000000 + i, 0))).toBe(true)
			end
			expect(select(2, PartyModel.invite(book, A, 93000000, 0))).toBe("TOO_MANY_INVITES")
		end)
		it("disbands at one member and frees the one left behind", function()
			local book = pair()
			local _, disbanded, orphan = PartyModel.leave(book, A)
			expect(disbanded).toBe(true)
			expect(orphan).toBe(B)
			expect(PartyModel.partyOf(book, B)).toBe(nil)
		end)
		it("hands leadership on when the leader leaves a bigger party", function()
			local book = pair()
			PartyModel.invite(book, A, C_, 0)
			PartyModel.accept(book, C_, A, 0)
			PartyModel.leave(book, A)
			expect((PartyModel.partyOf(book, C_) :: PartyModel.Party).leader).toBe(B)
		end)
	end)

	describe("PvP rules", function()
		local function clean()
			for _, id in { A, B, C_ } do
				PvpRules.setParty(id, nil)
				PvpRules.setDuel(id, nil)
			end
			PvpRules.clearGrace(A, B)
		end

		it("follows the flag for strangers, and always lets you hurt yourself", function()
			clean()
			expect((PvpRules.canHurt(A, B, true, 0))).toBe(true)
			expect((PvpRules.canHurt(A, B, false, 0))).toBe(false)
			expect((PvpRules.canHurt(A, A, false, 0))).toBe(true)
		end)
		it("never lets party members hurt each other, even with PvP on", function()
			clean()
			PvpRules.setParty(A, "specparty")
			PvpRules.setParty(B, "specparty")
			local ok, why = PvpRules.canHurt(A, B, true, 0)
			expect(ok).toBe(false)
			expect(why).toBe("party")
			clean()
		end)
		it("lets duellists hurt each other only once the fight begins, with PvP off too", function()
			clean()
			PvpRules.setDuel(A, "specduel", false)
			PvpRules.setDuel(B, "specduel", false)
			expect((PvpRules.canHurt(A, B, true, 0))).toBe(false)
			PvpRules.setDuel(A, "specduel", true)
			PvpRules.setDuel(B, "specduel", true)
			expect((PvpRules.canHurt(A, B, false, 0))).toBe(true)
			clean()
		end)
		it("lets party members fight in a duel", function()
			clean()
			PvpRules.setParty(A, "specparty")
			PvpRules.setParty(B, "specparty")
			PvpRules.setDuel(A, "specduel", true)
			PvpRules.setDuel(B, "specduel", true)
			expect((PvpRules.canHurt(A, B, true, 0))).toBe(true)
			clean()
		end)
		it("keeps everyone else out of a duel, both ways", function()
			clean()
			PvpRules.setDuel(A, "specduel", true)
			PvpRules.setDuel(B, "specduel", true)
			expect((PvpRules.canHurt(C_, A, true, 0))).toBe(false)
			expect((PvpRules.canHurt(A, C_, true, 0))).toBe(false)
			expect(PvpRules.canHelp(C_, A)).toBe(false)
			expect(PvpRules.canHelp(A, A)).toBe(true)
			clean()
		end)
		it("protects the two for a moment after a duel", function()
			clean()
			PvpRules.setGrace(A, B, 5, 100)
			expect((PvpRules.canHurt(A, B, true, 101))).toBe(false)
			expect((PvpRules.canHurt(B, A, true, 106))).toBe(true)
			clean()
		end)
	end)

	describe("Health floor", function()
		it("stops a killing blow at the floor", function()
			local humanoid = body(30)
			humanoid:SetAttribute("HealthFloor", 15)
			Damage.apply(humanoid, 500, nil, "spec")
			expect(humanoid.Health).toBeNear(15, 0.01)
		end)
		it("does nothing once you're at the floor", function()
			local humanoid = body(15)
			humanoid:SetAttribute("HealthFloor", 15)
			expect(Damage.apply(humanoid, 10, nil, "spec")).toBe(0)
			expect(humanoid.Health).toBeNear(15, 0.01)
		end)
		it("doesn't touch anyone without a floor", function()
			local humanoid = body(100)
			Damage.apply(humanoid, 20, nil, "spec")
			expect(humanoid.Health).toBeNear(80, 0.01)
		end)
	end)

	describe("Duels", function()
		it("keeps every rule's floor above Brush with Death's 5%", function()
			for _, rule in DuelRules.ordered do
				expect(rule.floorShare > 0.05).toBe(true)
			end
		end)
		it("first blood ends at the first real wound, with the attacker winning", function()
			local duel = fightingDuel("first_blood")
			expect(DuelModel.noteHit(duel, A, B, 2, 98, 100, INFO, 1)).toBe(nil)
			local outcome = DuelModel.noteHit(duel, A, B, 4, 94, 100, INFO, 2)
			expect((outcome :: DuelModel.Outcome).winner).toBe(A)
			expect((outcome :: DuelModel.Outcome).reason).toBe("first_blood")
		end)
		it("no lethal ends when someone reaches the floor", function()
			local duel = fightingDuel("no_lethal")
			local outcome = DuelModel.noteHit(duel, B, A, 85, 15, 100, INFO, 2)
			expect((outcome :: DuelModel.Outcome).winner).toBe(B)
			expect((outcome :: DuelModel.Outcome).reason).toBe("floor")
		end)
		it("to yield holds at the floor, then yields after the wait", function()
			local duel = fightingDuel("yield")
			expect(DuelModel.noteHit(duel, A, B, 92, 8, 100, INFO, 10)).toBe(nil)
			expect(DuelModel.tick(duel, 0.2, 12, bodies(1, 0.08))).toBe(nil)
			local outcome = DuelModel.tick(duel, 0.2, 18.1, bodies(1, 0.08))
			expect((outcome :: DuelModel.Outcome).winner).toBe(A)
			expect((outcome :: DuelModel.Outcome).reason).toBe("floor_yield")
		end)
		it("healing off the floor resets the yield clock", function()
			local duel = fightingDuel("yield")
			DuelModel.noteHit(duel, A, B, 92, 8, 100, INFO, 10)
			DuelModel.tick(duel, 0.2, 12, bodies(1, 0.3))
			expect(DuelModel.tick(duel, 0.2, 19, bodies(1, 0.08))).toBe(nil)
		end)
		it("calls it off when something else brings a fighter to the floor", function()
			local duel = fightingDuel("no_lethal")
			local outcome = DuelModel.noteHit(duel, nil, A, 85, 15, 100, INFO, 2)
			expect((outcome :: DuelModel.Outcome).winner).toBe(nil)
			expect((outcome :: DuelModel.Outcome).reason).toBe("interrupted")
		end)
		it("your own backfire reaching the floor still loses", function()
			local duel = fightingDuel("no_lethal")
			local outcome = DuelModel.noteHit(duel, A, A, 85, 15, 100, INFO, 2)
			expect((outcome :: DuelModel.Outcome).winner).toBe(B)
		end)
		it("forfeits after long enough outside the ring, and stepping back resets it", function()
			local duel = fightingDuel("no_lethal")
			expect(DuelModel.tick(duel, 2, 1, bodies(1, 1, 60))).toBe(nil)
			expect(DuelModel.tick(duel, 0.2, 2, bodies(1, 1, 10))).toBe(nil)
			expect(DuelModel.tick(duel, 2, 3, bodies(1, 1, 60))).toBe(nil)
			local outcome = DuelModel.tick(duel, 1.5, 4, bodies(1, 1, 60))
			expect((outcome :: DuelModel.Outcome).winner).toBe(B)
			expect((outcome :: DuelModel.Outcome).reason).toBe("ring")
		end)
		it("at the time limit the healthier fighter wins, and a near tie is a draw", function()
			local duel = fightingDuel("no_lethal")
			local outcome = DuelModel.tick(duel, 0.2, duel.endsAt, bodies(0.9, 0.4))
			expect((outcome :: DuelModel.Outcome).winner).toBe(A)
			local even = DuelModel.tick(fightingDuel("no_lethal"), 0.2, duel.endsAt, bodies(0.5, 0.51))
			expect((even :: DuelModel.Outcome).winner).toBe(nil)
		end)
		it("a dead fighter loses", function()
			local duel = fightingDuel("no_lethal")
			local list = bodies(1, 1)
			list[B].alive = false
			expect((DuelModel.tick(duel, 0.2, 1, list) :: DuelModel.Outcome).winner).toBe(A)
		end)
		it("counts nothing in the countdown", function()
			local duel = DuelModel.new("spec", A, B, "no_lethal", Vector3.zero, 0)
			expect(DuelModel.noteHit(duel, A, B, 5, 95, 100, INFO, 1)).toBe(nil)
			expect(duel.fighters[A].dealt).toBe(0)
		end)
		it("sums the recap, and caps the hit log", function()
			local duel = fightingDuel("yield")
			for i = 1, DuelRules.limits.logCap + 5 do
				DuelModel.noteHit(duel, A, B, 1, 90, 100, { kind = "strike", domain = nil, crit = i == 1 }, i)
			end
			DuelModel.noteHit(duel, B, A, 7, 93, 100, INFO, 50)
			expect(#duel.log).toBe(DuelRules.limits.logCap)
			local recap = DuelModel.recap(duel, { winner = A, reason = "yielded" }, 60)
			expect(recap.fighters[1].hits).toBe(DuelRules.limits.logCap + 5)
			expect(recap.fighters[1].crits).toBe(1)
			expect(recap.fighters[2].biggest).toBe(7)
			expect(recap.hits).toBe(DuelRules.limits.logCap + 6)
		end)
	end)

	describe("Combos", function()
		local combo = Combos.byId.earthflare

		it("every combo has two roles, real numbers and a unique id", function()
			local seen: { [string]: boolean } = {}
			for _, c in Combos.list do
				expect(seen[c.id]).toBe(nil)
				seen[c.id] = true
				expect(#c.roles).toBe(2)
				expect(c.window > 0 and c.reach > 0 and c.cooldown > 0).toBe(true)
			end
		end)
		it("matches two different people's complementary spells, in either order", function()
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), cast(B, "energy", 1))).toBe(true)
			expect(ComboMatcher.matches(combo, cast(A, "energy", 0), cast(B, "earth", 1))).toBe(true)
		end)
		it("never triggers from one person alone", function()
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), cast(A, "energy", 1))).toBe(false)
		end)
		it("needs both halves", function()
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), cast(B, "earth", 1))).toBe(false)
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), cast(B, "water", 1))).toBe(false)
		end)
		it("needs them close in time and place", function()
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), cast(B, "energy", combo.window + 0.1))).toBe(false)
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), cast(B, "energy", 1, Vector3.new(combo.reach + 1, 0, 0)))).toBe(false)
		end)
		it("ignores a backfire or a sensing spell", function()
			local bad = cast(B, "energy", 1)
			bad.backfired = true
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), bad)).toBe(false)
			local sense = cast(B, "energy", 1)
			sense.verb = "sense"
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), sense)).toBe(false)
		end)
		it("a hybrid spell fills a role through either domain", function()
			local hybrid = cast(B, "water", 1)
			hybrid.domains = { "water", "energy" }
			expect(ComboMatcher.matches(combo, cast(A, "earth", 0), hybrid)).toBe(true)
		end)
		it("says which half a partner needs", function()
			expect((ComboMatcher.neededRole(combo, cast(A, "earth", 0)) :: Combos.Role).domain).toBe("energy")
			expect(ComboMatcher.neededRole(combo, cast(A, "water", 0))).toBe(nil)
		end)
		it("caps its power at 10", function()
			local strong = cast(A, "earth", 0)
			strong.power = 10
			local other = cast(B, "energy", 0)
			other.power = 10
			expect(ComboMatcher.powerOf(combo, strong, other)).toBe(10)
		end)
	end)

	describe("Social data", function()
		it("emotes do something, with unique ids and commands", function()
			local ids, commands = {}, {}
			for _, def in Emotes.list do
				expect(ids[def.id]).toBe(nil)
				expect(commands[def.command]).toBe(nil)
				ids[def.id], commands[def.command] = true, true
				expect(def.clip ~= nil or def.pose ~= nil or def.flourish ~= nil).toBe(true)
				expect(def.cooldown > 0 and def.seconds > 0).toBe(true)
			end
		end)
		it("declares its remotes with limits", function()
			for _, name in { "PartyAction", "DuelAction", "EmoteIntent", "ReportBlocks" } do
				local def = Remotes[name]
				expect(def ~= nil and def.from == "Client" and def.rate ~= nil and def.args ~= nil).toBe(true)
			end
		end)
		it("lets the block report carry a whole list, but nothing else", function()
			local args = (Remotes.ReportBlocks.args :: { any })[1]
			expect((args({ 1, 2, 3 }))).toBe(true)
			expect((args({ "x" }))).toBe(false)
		end)
		it("has an off switch for every way others can reach you", function()
			expect(table.find(Settings.partyInvites.options, "nobody") ~= nil).toBe(true)
			expect(table.find(Settings.duelChallenges.options, "nobody") ~= nil).toBe(true)
			expect(table.find(Settings.emotesFrom.options, "nobody") ~= nil).toBe(true)
		end)
	end)
end
