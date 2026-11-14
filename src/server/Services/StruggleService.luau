--!strict
--[[
	StruggleService: spells that meet in the air, and spell struggles (docs/SpellStruggle.md).

	Wires the pieces together:
		Cast/Delivery.collisions   who collides (people who could hurt each other: Targeting.canHarm
		                           for players, anyone for NPCs and ferals), starting a struggle from
		                           two held flights, the clash cue and its reactions
		Cast/Struggle              the struggle itself (setup with the reservoirs; remote
		                           StruggleIntent -> Struggle.intent)
	Reactions: both spells leave a presence at the meeting point (EffectRunner:addPresence), so the
	InteractionMatrix fires whatever their tags make (steam, sparks...), as when spells overlap.

	Flags: spell_collisions_enabled (off: flights pass through each other, beams meet nothing),
	struggles_enabled (off: a head-on meeting of equals shatters instead).
	Admin: `struggles` lists the running ones; `struggleend` bursts them all; `struggletest on|off`
	widens the struggle band (any ratio under 3 struggles) so testing against weaker NPC mages works.
	Log: `spell_clash` { kind, a, b } (at most one a second), `struggle_started`, `struggle_ended`
	{ how, loser, seconds, wa, wb }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)
local Cast = ServerScriptService.Server.Magic.Cast
local Delivery = require(Cast.Delivery)
local Struggle = require(Cast.Struggle)
local Targeting = require(Cast.Targeting)

local StruggleService = {
	name = "StruggleService",
	dependencies = { "AdminService", "EffectRunner", "NetService", "ReservoirService" },
}

local log: any = nil
local runner: any = nil
local testBand: number? = nil
local lastClashLog = 0

local function collisionsOn(): boolean
	return FeatureFlags.get("spell_collisions_enabled") == true
end

function StruggleService.canCollide(_self: any, a: Model, b: Model): boolean
	if not collisionsOn() or a == b then
		return false
	end
	local pa, pb = Players:GetPlayerFromCharacter(a), Players:GetPlayerFromCharacter(b)
	if pa then
		return Targeting.canHarm(pa, b)
	elseif pb then
		return Targeting.canHarm(pb, a)
	end
	return true
end

function StruggleService.band(_self: any): number?
	return testBand
end

local function canCollide(a: Model, b: Model): boolean
	return StruggleService:canCollide(a, b)
end

local function ownerId(model: Model?): number?
	local player = model and Players:GetPlayerFromCharacter(model)
	return if player then player.UserId else nil
end

local function onClash(info: any)
	local at: Vector3 = info.at
	Struggle.clashCue(at, info.kind, info.a and info.a.domain, info.b and info.b.domain)
	for _, side in { info.a, info.b } do
		if side and side.tags and #side.tags > 0 then
			runner:addPresence(side.tags, at, 6, math.clamp(side.weight or 1, 1, 10), ownerId(side.model))
		end
	end
	local now = os.clock()
	if now - lastClashLog >= 1 then
		lastClashLog = now
		log:info("spell_clash", { kind = info.kind, a = info.a and info.a.domain, b = info.b and info.b.domain })
	end
end

local function hitOf(model: Model): any
	local root = model:FindFirstChild("HumanoidRootPart")
	return root and Targeting.characterOf(root)
end

-- A side for a held flight: when it lands, Delivery hands its caster an impact on that target.
local function flightSide(flight: any): Struggle.Side
	local side = flight.side or {}
	return {
		model = flight.ownerModel,
		player = side.player,
		courage = side.courage,
		weight = flight.weight or 1,
		domain = flight.domain,
		tags = flight.tags or {},
		land = function(target: Model?, at: Vector3, mult: number)
			local hit = target and hitOf(target)
			Delivery.settle(flight, { point = at, hits = if hit then { hit } else {}, powerMult = mult })
		end,
		lose = function()
			Delivery.settle(flight, { destroyed = true, expired = true, powerMult = 0 })
		end,
	}
end

local function startFromFlights(a: any, b: any, at: Vector3): boolean
	if FeatureFlags.get("struggles_enabled") ~= true then
		return false
	end
	return Struggle.begin(flightSide(a), flightSide(b), at)
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "struggles",
		category = "Magic",
		description = "List the spell struggles running on this server: who, how long, the weights and where the knot sits (0 = at the first caster, 1 = at the second)",
		args = {},
		handler = function()
			local list = Struggle.list()
			if #list == 0 then
				return "none · collisions " .. tostring(collisionsOn()) .. " · struggles " .. tostring(FeatureFlags.get("struggles_enabled")) .. " · test band " .. tostring(testBand)
			end
			local lines = {}
			for _, f in list do
				table.insert(lines, string.format("#%d %s (%.1f) vs %s (%.1f): knot %.2f, %.1fs", f.id, f.a.Name, f.wa, f.b.Name, f.wb, f.point, f.age))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "struggleend",
		category = "Magic",
		description = "Burst every running spell struggle now (each spell lands on the other caster at the burst share)",
		args = {},
		handler = function()
			return string.format("burst %d", Struggle.endAll())
		end,
	})
	admin:Register({
		name = "struggletest",
		category = "Magic",
		description = "Widen the struggle band for testing: on = any two head-on spells within 3x of each other's weight struggle (so a strong mage can struggle a weak NPC); off = the normal band",
		args = { { name = "state", type = "string", default = "on" } },
		handler = function(_ctx: any, a: any)
			testBand = if a.state == "off" then nil else 3
			return "struggle band " .. (if testBand then "wide (3x)" else "normal")
		end,
	})
end

function StruggleService.init(_self: any, ctx: any)
	log = ctx.log
	runner = ctx.get("EffectRunner")
	Struggle.setup({
		reservoirs = ctx.get("ReservoirService"),
		onStarted = function(f: any)
			log:info("struggle_started", { a = f.a.model.Name, b = f.b.model.Name, wa = f.a.weight, wb = f.b.weight })
		end,
		onEnded = function(f: any, how: string, loser: string?)
			log:info("struggle_ended", { how = how, loser = loser, seconds = math.round(f.age * 10) / 10, wa = f.a.weight, wb = f.b.weight })
		end,
	})
	Delivery.collisions = {
		canCollide = canCollide,
		struggle = startFromFlights,
		clash = onClash,
		band = function()
			return testBand
		end,
	}
	Net.on("StruggleIntent", function(player: Player, kind: any)
		Struggle.intent(player, kind)
	end)
	registerAdmin(ctx.get("AdminService"))
end

function StruggleService.start(_self: any, _ctx: any) end

return StruggleService
