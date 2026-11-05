--!strict
-- Unit specs for the combat pipeline's pure parts: the damage formula (Cast/DamageModel), chain
-- jumps (Cast/Targeting) and projectile flight planning (Cast/Delivery). docs/Combat.md.

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local C = require(Server.Magic.Data.CombatTuning)
local DamageModel = require(Server.Magic.Cast.DamageModel)
local Targeting = require(Server.Magic.Cast.Targeting)
local Delivery = require(Server.Magic.Cast.Delivery)
local Resistances = require(Server.Magic.Cast.Resistances)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local HitReactions = require(Server.Magic.Cast.HitReactions)
local Explosion = require(Server.Magic.Cast.Explosion)
local Conduction = require(Server.Magic.Cast.Conduction)
local NPCCombat = require(Server.NPC.NPCCombat)
local StatusInfo = require(game:GetService("ReplicatedStorage").Shared.Magic.Data.StatusInfo)

-- A detached character (never parented to workspace): a Model with a Humanoid and a root.
local function dummy(position: Vector3): any
	local model = Instance.new("Model")
	model.Name = "SpecDummy"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Position = position
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	return { model = model, humanoid = humanoid, root = root, distance = 0 }
end

-- The smallest EffectContext the formula reads.
local function ctxFor(form: string, power: number, opts: { [string]: any }?): any
	local o = opts or {}
	local root = Instance.new("Part")
	root.CFrame = CFrame.new(0, 3, 0)
	return {
		player = { UserId = -1 },
		character = Instance.new("Model"),
		root = root,
		power = power,
		origin = Vector3.new(0, 3, 0),
		point = o.point or Vector3.new(0, 3, -20),
		rng = Random.new(o.seed or 7),
		stats = {
			recipe = { form = form, property = o.property or "combustion", power = o.recipePower or 3 },
			domains = o.domains or { "energy" },
			area = o.area or 10,
			range = o.range or 60,
			maxTargets = 1,
			overreach = o.overreach or 0,
			masteryTier = o.masteryTier or 0,
			flags = o.flags or {},
		},
	}
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Damage formula", function()
		it("hits meaningfully at P1 and scales up with power", function()
			local p1 = DamageModel.base(1)
			expect(p1 >= 8 and p1 <= 10).toBe(true)
			expect(DamageModel.base(3.4) > p1).toBe(true)
			expect(DamageModel.base(254) > DamageModel.base(12)).toBe(true)
			expect(DamageModel.base(0)).toBe(0)
		end)
		it("is reproducible from the cast seed", function()
			local hit = dummy(Vector3.new(0, 3, -20))
			local a = DamageModel.compute(ctxFor("projectile", 5, { seed = 42 }), hit, 1)
			local b = DamageModel.compute(ctxFor("projectile", 5, { seed = 42 }), hit, 1)
			expect(a.amount).toBe(b.amount)
			expect(a.crit).toBe(b.crit)
		end)
		it("applies resistance and vulnerability, clamped", function()
			local plain = dummy(Vector3.new(0, 3, -20))
			local resistant = dummy(Vector3.new(0, 3, -20))
			resistant.humanoid:SetAttribute("Resist_energy", 0.5)
			local weak = dummy(Vector3.new(0, 3, -20))
			weak.humanoid:SetAttribute("Resist_combustion", -5) -- far past the clamp
			local base = DamageModel.compute(ctxFor("projectile", 5), plain, 1, { noCrit = true })
			local less = DamageModel.compute(ctxFor("projectile", 5), resistant, 1, { noCrit = true })
			local more = DamageModel.compute(ctxFor("projectile", 5), weak, 1, { noCrit = true })
			expect(less.amount < base.amount).toBe(true)
			expect(more.amount > base.amount).toBe(true)
			expect(more.resist).toBe(-C.damage.maxVulnerability)
		end)
		it("falls off toward the rim of an area spell", function()
			local centre = dummy(Vector3.new(0, 3, -20))
			local rim = dummy(Vector3.new(9, 3, -20))
			local near = DamageModel.compute(ctxFor("burst", 5), centre, 1, { noCrit = true })
			local far = DamageModel.compute(ctxFor("burst", 5), rim, 1, { noCrit = true })
			expect(far.falloff < near.falloff).toBe(true)
			expect(far.falloff >= C.damage.areaFalloffMin).toBe(true)
		end)
		it("never exceeds the per-hit cap", function()
			local hit = dummy(Vector3.new(0, 3, -20))
			local huge = DamageModel.compute(ctxFor("projectile", 1e6), hit, 1)
			expect(huge.amount <= C.damage.maxHit).toBe(true)
		end)
		it("crits at roughly the tuned rate", function()
			local hit = dummy(Vector3.new(0, 3, -20))
			local ctx = ctxFor("projectile", 5, { masteryTier = 4, seed = 99 })
			local crits, n = 0, 4000
			for _ = 1, n do
				if DamageModel.compute(ctx, hit, 1).crit then
					crits += 1
				end
			end
			local expected = C.damage.critBase + C.damage.critPerTier * 4
			expect(math.abs(crits / n - expected) < 0.025).toBe(true)
		end)
	end)

	describe("Delivery", function()
		it("lets chains actually jump (chain forms have area 0)", function()
			expect(Targeting.chainJump(1) >= 8).toBe(true)
			expect(Targeting.chainJump(5) > Targeting.chainJump(1)).toBe(true)
		end)
		it("lobs earth projectiles and caps speed", function()
			local earth = Delivery.plan(ctxFor("projectile", 5, { domains = { "earth" } }))
			local energy = Delivery.plan(ctxFor("projectile", 5, { domains = { "energy" } }))
			expect(earth.gravity > 0).toBe(true)
			expect(earth.velocity.Y > energy.velocity.Y).toBe(true)
			local fast = Delivery.plan(ctxFor("projectile", 5, { recipePower = 10 }))
			expect(fast.velocity.Magnitude <= C.projectile.maxSpeed + 1e-3).toBe(true)
		end)
		it("only pierces with the Piercing modifier", function()
			expect(Delivery.plan(ctxFor("projectile", 5)).pierce).toBe(0)
			expect(Delivery.plan(ctxFor("projectile", 5, { flags = { piercing = true } })).pierce > 0).toBe(true)
		end)
	end)

	describe("Resistances", function()
		it("gives NPCs resistance to their own domains, capped", function()
			local m = Resistances.innateFor({ energy = 0.95, water = 0.1 }, {})
			expect((m.energy or 0) > 0).toBe(true)
			expect((m.energy or 0) <= C.resistances.affinityMax + 1e-6).toBe(true)
			expect(m.water).toBe(nil)
		end)
		it("makes anxious NPCs easier to frighten", function()
			local m = Resistances.innateFor({}, { neuroticism = 0.9 })
			expect((m.mind or 0) < 0).toBe(true)
		end)
		it("stacks gear and manual sources and clamps the total", function()
			local hit = dummy(Vector3.zero)
			local base = Resistances.total(hit.humanoid, { "energy" }, "combustion")
			expect(Resistances.setGear(hit.humanoid, "body", "leather_apron")).toBe(true)
			local geared = Resistances.total(hit.humanoid, { "energy" }, "combustion")
			expect(geared > base).toBe(true)
			expect(Resistances.setGear(hit.humanoid, "head", "leather_apron")).toBe(false) -- wrong slot
			hit.humanoid:SetAttribute("Resist_all", 5)
			expect(Resistances.total(hit.humanoid, { "energy" }, "combustion")).toBe(C.damage.maxResist)
		end)
		it("makes stronger wards resist more, up to the cap", function()
			expect(Resistances.wardFor(8).all > Resistances.wardFor(1).all).toBe(true)
			expect(Resistances.wardFor(100).all).toBe(C.resistances.wardMax)
		end)
		it("lets a ward status carry its resistance", function()
			local hit = dummy(Vector3.zero)
			StatusEffects.apply(hit.humanoid, "ward", { duration = 5, magnitude = 10, resist = { all = 0.2 } })
			local m = StatusEffects.resistOf(hit.humanoid)
			expect(m ~= nil and m.all == 0.2).toBe(true)
			StatusEffects.remove(hit.humanoid, "ward")
		end)
	end)

	describe("Reactions and world", function()
		it("knocks down on a heavy hit or strong kinetic magic, not a scratch", function()
			local h = dummy(Vector3.zero).humanoid
			expect(HitReactions.shouldKnockDown(h, h.MaxHealth * 0.35, "combustion", {})).toBe(true)
			expect(HitReactions.shouldKnockDown(h, h.MaxHealth * 0.15, "momentum", { power = 5 })).toBe(true)
			expect(HitReactions.shouldKnockDown(h, h.MaxHealth * 0.15, "momentum", { power = 2 })).toBe(false)
			expect(HitReactions.shouldKnockDown(h, 3, "combustion", { power = 9 })).toBe(false)
		end)
		it("describes every server status for the HUD", function()
			for id, def in StatusEffects.defs do
				local info = StatusInfo[id]
				expect(info ~= nil).toBe(true)
				expect(info and info.harmful == (def.harmful == true)).toBe(true)
			end
		end)
		it("explodes only strong area harm of a blasting kind", function()
			local function stats(form: string, category: string, power: number, harmful: boolean): any
				return { harmful = harmful, category = category, area = 10, recipe = { form = form, power = power } }
			end
			expect(Explosion.applies(stats("burst", "Thermal", 5, true))).toBe(true)
			expect(Explosion.applies(stats("touch", "Thermal", 5, true))).toBe(false)
			expect(Explosion.applies(stats("burst", "Thermal", 1, true))).toBe(false)
			expect(Explosion.applies(stats("burst", "Mental", 9, true))).toBe(false)
		end)
		it("conducts lightning only", function()
			expect(Conduction.conducts("charge")).toBe(true)
			expect(Conduction.conducts("combustion")).toBe(false)
		end)
		it("makes guards braver than the anxious", function()
			local function npc(occupation: string, neuroticism: number): any
				return { occupation = occupation, traits = { neuroticism = neuroticism }, magic = { mastery = {}, unlocked = {} } }
			end
			expect(NPCCombat.courage(npc("guard", 0.3), 1) > NPCCombat.courage(npc("merchant", 0.9), 1)).toBe(true)
		end)
	end)
end
