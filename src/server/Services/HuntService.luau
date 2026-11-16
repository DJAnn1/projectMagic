--!strict
--[[
	HuntService: people who live off the land work where the land really is (docs/Hunting.md).

	HUNTERS  A hunter's work spot is a stand ~26 studs off one of their own town's herds of game (deer, wild
	         fowl, hares: Creatures/Data/Creatures `game`, planned by CreatureRules.planHerds), on the town's
	         side, picked by seed per person and game day (NPCService.setWorkSpotHook). Standing there with an
	         animal in range, they turn to it and loose an arrow every 18-35 s: the same arrow the players'
	         bows draw (the `weapon` cue). A hit drops the animal nearest them (CreatureService:shoot: nobody is
	         paid), a miss startles the herd; either way the herd runs from them, and after a kill they move
	         round to a new stand. Herds only exist while a player is near, so this only happens in sight.
	FISHERS  Their harbour spot is on the town's real shoreline (Life/Shore, in NPCService); here they turn to
	         face the water they stand by, so the line and bobber land on it. A town with no shore within reach
	         has its fishers mending nets (ActivityLibrary `shore`).

	Budget: one 1 Hz sweep over rig NPCs; only hunters and fishers at work do anything. Shots: at most one per
	hunter per 18 s.

	Flag `hunting_enabled`. Admin `hunts` (hunters and their herds), `huntnow [npc]` (the nearest hunter shoots
	now). Log `hunt_shot`.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local Delivery = require(Server.Magic.Cast.Delivery)
local Navigation = require(Server.NPC.NavigationService)
local WorldClock = require(Server.NPC.WorldClock)
local Util = require(Server.Admin.Util)

local HuntService = {
	name = "HuntService",
	dependencies = { "AdminService", "CreatureService", "EffectRunner", "NPCService", "WorldService", "WorldStateService" },
}

local STAND_OFF = 26 -- studs from the herd's grazing spot to the hunter's stand
local AT_STAND = 6 -- studs: close enough to the stand to start hunting
local RANGE = 60 -- studs: the furthest animal they'll shoot at
local SHOT_GAP = { 18, 35 } -- seconds between shots
local HIT_CHANCE = 0.55
local ARROW_SPEED = 110

local LINES_HIT = { "Got it.", "There. That's supper.", "Clean shot.", "Steady... yes." }
local LINES_MISS = { "Damn it.", "Too slow.", "Wind took it.", "Next time." }

type Hunter = { herdId: string, stand: Vector3, day: number, turn: number, nextShot: number, shots: number }

local log: any = nil
local npcs: any = nil
local creatures: any = nil
local runner: any = nil
local world: any = nil
local worldService: any = nil

local hunters: { [any]: Hunter } = setmetatable({}, { __mode = "k" }) :: any
local facing: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function enabled(): boolean
	return FeatureFlags.get("hunting_enabled") ~= false
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function townOf(npc: any): any?
	for _, town in npcs:towns() do
		if town.id == npc.settlementId then
			return town
		end
	end
	return nil
end

-- A stand off the herd: on the town's side, turned round it by `turn` steps of 50 degrees after each kill.
local function standFor(npc: any, herd: any, turn: number): Vector3
	local town = townOf(npc)
	local base = if town then math.atan2(town.z - herd.z, town.x - herd.x) else 0
	local jitter = ((Seed.derive(npc.seed, herd.id, "hunt_stand") % 1000) / 1000 - 0.5) * 0.8
	local a = base + jitter + turn * math.rad(50)
	local x, z = herd.x + math.cos(a) * STAND_OFF, herd.z + math.sin(a) * STAND_OFF
	return Vector3.new(x, world:surfaceHeight(x, z), z)
end

-- NPCService.setWorkSpotHook: where a hunter works today.
local function workSpot(npc: any): Vector3?
	if npc.occupation ~= "hunter" or not enabled() then
		return nil
	end
	local herds = creatures:herdsOf(npc.settlementId)
	if #herds == 0 then
		return nil -- no game near this town: the old district spot in the wilds
	end
	local day = math.floor(WorldClock.day())
	local state = hunters[npc]
	if state and state.day == day then
		return state.stand
	end
	local herd = herds[Seed.derive(npc.seed, tostring(day), "hunt_herd") % #herds + 1]
	local stand = standFor(npc, herd, 0)
	hunters[npc] = { herdId = herd.id, stand = stand, day = day, turn = 0, nextShot = os.clock() + 8, shots = 0 }
	return stand
end

local function herdById(npc: any, id: string): any?
	for _, herd in creatures:herdsOf(npc.settlementId) do
		if herd.id == id then
			return herd
		end
	end
	return nil
end

local function arrow(from: Vector3, to: Vector3)
	local offset = to - from
	local distance = offset.Magnitude
	if distance < 1 then
		return
	end
	local id = Delivery.newId()
	local lifetime = distance / ARROW_SPEED
	runner:cue("weapon", { stage = "launch", projectileId = id, origin = from, velocity = offset.Unit * ARROW_SPEED, gravity = 0, lifetime = lifetime, look = "arrow" }, from, false)
	task.delay(lifetime, function()
		runner:cue("weapon", { stage = "impact", projectileId = id, point = to, struck = true }, to, false)
	end)
end

-- One shot from this hunter at the nearest animal of their herd. Returns what happened, for the admin.
local function shoot(npc: any, state: Hunter, force: boolean): string
	local herd = herdById(npc, state.herdId)
	local rig = npc.rig
	if not herd or not rig then
		return "no herd"
	end
	local from = rig.root.Position
	local target: Vector3? = nil
	local best = RANGE
	for _, at in herd.living do
		local d = flat(at, from)
		if d <= best then
			target, best = at, d
		end
	end
	if not target then
		return "nothing in range"
	end
	Navigation.FaceNow(npc, Vector3.new(target.X - from.X, 0, target.Z - from.Z))
	state.shots += 1
	local rng = Seed.random(worldService:getSeed(), npc.id, "hunt_shot", state.shots)
	local hits = force or rng:NextNumber() < HIT_CHANCE
	local muzzle = from + Vector3.new(0, 1.5, 0) + rig.root.CFrame.LookVector * 1.5
	local landed, kind = creatures:shoot(state.herdId, from, hits)
	if not landed then
		return "nothing to shoot"
	end
	arrow(muzzle, landed + Vector3.new(0, 0.6, 0))
	if rng:NextNumber() < 0.35 then
		local lines = if kind then LINES_HIT else LINES_MISS
		npcs:speak(npc, lines[rng:NextInteger(1, #lines)], 40)
	end
	log:info("hunt_shot", { npc = npc.id, herd = state.herdId, hit = kind ~= nil, kind = kind })
	if kind then
		-- The herd has bolted: next time, from further round.
		state.turn += 1
		state.stand = standFor(npc, herd, state.turn)
		npcs:reroute(npc)
	end
	return if kind then "hit " .. kind else "missed"
end

local function release(npc: any)
	if facing[npc] then
		facing[npc] = nil
		Navigation.Face(npc, nil)
	end
end

local function sweep()
	local now = os.clock()
	for _, npc in npcs:all() do
		local rig = npc.rig
		local ready = rig ~= nil and npc.tier == 0 and not npc.knockedOut and npc.combat == nil and npc.leash == nil and npc.action == "work"
		if not ready or not enabled() then
			release(npc)
			continue
		end
		local position: Vector3 = rig.root.Position
		if npc.occupation == "fisher" then
			local spot = npc.spots and npc.spots.harbor
			local water = npc.waterAt
			if water and spot and flat(position, spot) <= AT_STAND and not Navigation.IsMoving(npc) then
				if not facing[npc] then
					facing[npc] = true
					Navigation.Face(npc, water)
				end
			else
				release(npc)
			end
		elseif npc.occupation == "hunter" then
			local state = hunters[npc]
			if state and flat(position, state.stand) <= AT_STAND and not Navigation.IsMoving(npc) and now >= state.nextShot then
				local rng = Seed.random(worldService:getSeed(), npc.id, "hunt_gap", state.shots)
				state.nextShot = now + SHOT_GAP[1] + rng:NextNumber() * (SHOT_GAP[2] - SHOT_GAP[1])
				shoot(npc, state, false)
			end
		end
	end
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "hunts",
		category = "NPCs",
		description = "Hunters at work, the herd each is after, and how far they are from their stand",
		args = {},
		handler = function(_ctx: any, _a: any)
			local lines = {}
			for _, npc in npcs:all() do
				if npc.occupation == "hunter" then
					local state = hunters[npc]
					if state then
						local herd = herdById(npc, state.herdId)
						table.insert(lines, string.format("%s (%s)  %s  herd %s %s, %d living  stand %.0f studs  shots %d",
							npcs:nameOf(npc.id), npc.id, npc.action or "?", state.herdId, if herd then herd.type else "?", if herd then #herd.living else 0,
							flat(npc.position, state.stand), state.shots))
					end
				end
			end
			if #lines == 0 then
				return "no hunter has gone out to a herd yet (they go at work hours)"
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "huntnow",
		category = "NPCs",
		description = "The nearest hunter shoots at their herd now (always a hit, if an animal is within range)",
		args = {},
		handler = function(ctx: any, _a: any)
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local best, bestD = nil, math.huge
			for _, npc in npcs:all() do
				if npc.occupation == "hunter" and npc.rig then
					local d = flat(npc.position, root.Position)
					if d < bestD then
						best, bestD = npc, d
					end
				end
			end
			if not best then
				return "no hunter with a body near you"
			end
			local state = hunters[best]
			if not state then
				workSpot(best)
				state = hunters[best]
			end
			if not state then
				return npcs:nameOf(best.id) .. "'s town has no herds"
			end
			return npcs:nameOf(best.id) .. ": " .. shoot(best, state, true)
		end,
	})
end

function HuntService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	creatures = ctx.get("CreatureService")
	runner = ctx.get("EffectRunner")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	npcs:setWorkSpotHook(workSpot)
	registerAdmin(ctx.get("AdminService"))
end

function HuntService.start(_self: any, _ctx: any)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(sweep)
			if not ok then
				warn("[Hunt] sweep failed: " .. tostring(err))
			end
		end
	end)
end

return HuntService
