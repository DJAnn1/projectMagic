--!strict
--[[
	SceneDirector: small stories that happen in every town whether or not anyone's watching
	(docs/LivingWorld.md §5). Content: Scenes/Data/SceneTemplates. Rules: Scenes/SceneRules.

	WHEN   every game hour, each town rolls Seed.random(worldSeed, town, "scene", hourIndex), so every
	       server agrees on when and what. Only a roll under ALONE_CHANCE happens with nobody near; a
	       player within STAGE_RADIUS sees the rarer rolls too, so there's something to stumble on.
	NOBODY NEAR  no Instances at all: an ending is rolled, memories go to the real NPCs (normal gossip
	       carries them) and the story reaches the town's barks. It costs a table lookup.
	SOMEONE NEAR the scene is staged with real rigs and the template's script, and a player can step in
	       (interventions). At most MAX_STAGED at once, one per town.
	ACTORS residents held with a quest-style leash and released afterwards, or strangers made for the
	       scene and removed. A resident already on a quest leash isn't used.

	Stories live in memory on this server only (AmbientLifeService). The Chronicle comes in a later
	stage. Nothing here writes to a DataStore, apart from what quest-style bonds already save.

	Admin: scene <template>, scenes
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local Activities = require(Server.NPC.Data.Activities)
local LOD = require(Server.NPC.NPCLOD)
local MemoryService = require(Server.NPC.MemoryService)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)
local WorldClock = require(Server.NPC.WorldClock)
local SceneRules = require(Server.Scenes.SceneRules)
local Templates = require(Server.Scenes.Data.SceneTemplates)

local ALONE_CHANCE = 0.06 -- per town, per game hour
local WATCHED_CHANCE = 0.16 -- with a player near
local STAGE_RADIUS = 200 -- a player this close to a town's centre can see its scenes
local MAX_STAGED = 2
local NEAR_MAGIC = 30 -- a spell landing this close to the scene can count as stepping in
local SAY_PAUSE = 2.6
local END_LINGER = 6
local RECENT_KEPT = 30
local MARK_REACH = { left = 7, right = 7, front = 7, back = 7, far = 26 }

local SceneDirector = {
	name = "SceneDirector",
	dependencies = { "AdminService", "AmbientLifeService", "CreatureService", "EffectRunner", "NPCService", "ReputationService", "WorldService", "WorldStateService" },
}

type Scene = {
	template: Templates.Template,
	town: any,
	center: Vector3,
	actors: { [string]: any },
	spawned: { [string]: boolean },
	leashes: { [any]: any },
	names: { [string]: string },
	group: any?,
	outcome: string?,
	player: Player?,
	clearedBy: { [number]: boolean },
	rng: Random,
}

local log: any = nil
local npcs: any = nil
local creatures: any = nil
local ambient: any = nil
local reputation: any = nil
local world: any = nil
local worldService: any = nil

local staged: { Scene } = {}
local recent: { string } = {}
local counters = { staged = 0, alone = 0, steppedIn = 0 }

local function note(line: string)
	table.insert(recent, 1, line)
	while #recent > RECENT_KEPT do
		table.remove(recent)
	end
end

local function dryNear(x: number, z: number): Vector3
	local dx, _, dz = world:findDryLand(x, z, 48)
	return Vector3.new(dx, world:surfaceHeight(dx, dz), dz)
end

local function locationFor(template: Templates.Template, town: any, rng: Random): Vector3
	local angle = rng:NextNumber() * 2 * math.pi
	local reach = if template.where == "plaza"
		then 6 + rng:NextNumber() * 8
		else town.radius * 0.9 + rng:NextNumber() * 24
	return dryNear(town.x + math.cos(angle) * reach, town.z + math.sin(angle) * reach)
end

local function markAt(center: Vector3, mark: string): Vector3
	local reach = MARK_REACH[mark]
	if not reach then
		return center
	end
	local dir = if mark == "left" then Vector3.new(-1, 0, 0)
		elseif mark == "right" then Vector3.new(1, 0, 0)
		elseif mark == "front" then Vector3.new(0, 0, -1)
		elseif mark == "back" then Vector3.new(0, 0, 1)
		else Vector3.new(0.7, 0, 0.7)
	local p = center + dir * reach
	return Vector3.new(p.X, world:surfaceHeight(p.X, p.Z), p.Z)
end

-- Someone awake and free in this town, for one role. Resident roles only.
local function chooseResident(template: Templates.Template, role: string, town: any, taken: { [any]: boolean }, rng: Random): any?
	local actor = template.actors[role]
	local fits: { any } = {}
	for _, npc in town.npcs do
		local free = not taken[npc] and not npc.leash and not npc.combat and not npc.knockedOut and not npc.frozen
			and npc.action ~= "sleep" and npc.action ~= "shelter"
		if free then
			local isChild = npc.ageBand == "child"
			local kindOk = if actor.child then isChild else not isChild
			local jobOk = not actor.occupations or table.find(actor.occupations, npc.occupation) ~= nil
			local mageOk = not actor.mage or NPCMagicLife.best(npc) ~= nil
			if kindOk and jobOk and mageOk then
				table.insert(fits, npc)
			end
		end
	end
	return if #fits > 0 then fits[rng:NextInteger(1, #fits)] else nil
end

-- Picks everyone. Returns nil if a resident role can't be filled: the scene just doesn't happen.
local function castResidents(template: Templates.Template, town: any, rng: Random): { [string]: any }?
	local taken: { [any]: boolean } = {}
	local cast: { [string]: any } = {}
	local roles: { string } = {}
	for role in template.actors do
		table.insert(roles, role)
	end
	table.sort(roles)
	for _, role in roles do
		if not template.actors[role].spawn then
			local npc = chooseResident(template, role, town, taken, rng)
			if not npc then
				return nil
			end
			taken[npc] = true
			cast[role] = npc
		end
	end
	return cast
end

local function namesFor(template: Templates.Template, town: any, cast: { [string]: any }): { [string]: string }
	local names: { [string]: string } = { town = town.settlement.name }
	for role, actor in template.actors do
		local npc = cast[role]
		names[role] = if npc then npc.name else (actor.name or "a stranger")
	end
	return names
end

-- ─── Endings ────────────────────────────────────────────────────────────────

local function applyEnding(template: Templates.Template, outcomeId: string, town: any, cast: { [string]: any }, names: { [string]: string }, player: Player?, spawned: { [string]: boolean }?)
	local outcome = template.outcomes[outcomeId]
	ambient:addStory(town.id, SceneRules.tellStory(outcome.story, names))
	local now = WorldClock.now()
	for _, m in (outcome.remember or {}) :: { any } do
		local npc, about = cast[m.role], cast[m.about]
		if npc and about then
			MemoryService.add(npc, m.kind, about.id, now, {})
		end
	end
	if player then
		if outcome.rep then
			reputation:addSettlement(player, town.id, outcome.rep, "scene:" .. template.id)
		end
		local bond = outcome.bond
		local npc = bond and cast[bond.role]
		-- A stranger made for the scene leaves when it ends, so there's nobody to remember you.
		if bond and npc and not (spawned and spawned[bond.role]) then
			npcs:questBond(npc, player, bond.delta, bond.memory)
		end
	end
end

-- ─── When nobody's there ────────────────────────────────────────────────────

local function runAlone(template: Templates.Template, town: any, rng: Random)
	local cast = castResidents(template, town, rng)
	if not cast then
		return
	end
	local names = namesFor(template, town, cast)
	local outcomeId = SceneRules.outcomeWhenAlone(template, rng)
	applyEnding(template, outcomeId, town, cast, names, nil)
	counters.alone += 1
	note(string.format("%s, %s: %s (nobody there)", town.id, template.id, outcomeId))
end

-- ─── When someone is ────────────────────────────────────────────────────────

local function runStep(scene: Scene, step: { any })
	local kind = step[1]
	if kind == "wait" then
		task.wait(step[2])
	elseif kind == "creatures" then
		scene.group = creatures:spawnGroup(step[2], step[3], scene.center)
	else
		local npc = scene.actors[step[2]]
		if not npc then
			return
		end
		if kind == "go" then
			local leash = { kind = "hold", position = markAt(scene.center, step[3]) }
			scene.leashes[npc] = leash
			npcs:setLeash(npc, leash)
		elseif kind == "say" then
			npcs:speak(npc, SceneRules.tellStory(step[3], scene.names), 40)
			task.wait(SAY_PAUSE)
		elseif kind == "clip" then
			LOD.playActivity(npc, step[3], Activities.Clips[step[3]], false)
		elseif kind == "hold" then
			LOD.playActivity(npc, step[3], Activities.Clips[step[3]], true)
		elseif kind == "cast" then
			local branchId = NPCMagicLife.best(npc)
			local branch = branchId and Registry.branches[branchId]
			local target = scene.actors[step[3]]
			if branch and target then
				local point = if target == npc then npc.position + Vector3.new(0, 10, 0) else target.position
				npcs:cueCast(npc, { domain = branch.domains[1], property = "luminosity", verb = "generate", form = "projectile", power = 2 }, point)
			end
		end
	end
end

local function runSteps(scene: Scene, steps: { any })
	for _, step in steps do
		runStep(scene, step)
		if step[1] == "go" or step[1] == "clip" or step[1] == "cast" then
			task.wait(0.4)
		end
	end
end

local function cleanup(scene: Scene)
	for npc, leash in scene.leashes do
		LOD.stopActivity(npc)
		if npc.leash == leash then -- a quest may have taken them since: then it's the quest's
			npcs:setLeash(npc, nil)
		end
	end
	for role in scene.spawned do
		local npc = scene.actors[role]
		if npc then
			npcs:remove(npc)
		end
	end
	if scene.group then
		creatures:clearGroup(scene.group)
	end
	local i = table.find(staged, scene)
	if i then
		table.remove(staged, i)
	end
end

local function stage(template: Templates.Template, town: any, rng: Random, at: Vector3?): (boolean, string)
	if #staged >= MAX_STAGED then
		return false, "already two scenes running"
	end
	for _, other in staged do
		if other.town == town then
			return false, "this town already has one running"
		end
	end
	local cast = castResidents(template, town, rng)
	if not cast then
		return false, "nobody in " .. town.id .. " fits the roles right now"
	end
	local center = at or locationFor(template, town, rng)
	local scene: Scene = {
		template = template,
		town = town,
		center = center,
		actors = cast,
		spawned = {},
		leashes = {},
		names = namesFor(template, town, cast),
		group = nil,
		outcome = nil,
		player = nil,
		clearedBy = {},
		rng = rng,
	}
	for role, actor in template.actors do
		if actor.spawn then
			local npc = npcs:spawn(center, { occupation = actor.spawn, name = actor.name, seed = rng:NextInteger(1, 2 ^ 30) })
			if npc then
				scene.actors[role] = npc
				scene.spawned[role] = true
				-- Held in place straight away: the brain would send a new resident home.
				local leash = { kind = "hold", position = center }
				scene.leashes[npc] = leash
				npcs:setLeash(npc, leash)
			end
		end
	end
	table.insert(staged, scene)
	counters.staged += 1
	log:info("scene_started", { template = template.id, town = town.id })
	task.spawn(function()
		local ok, err = pcall(function()
			runSteps(scene, template.intro)
			local deadline = os.clock() + template.wait
			while not scene.outcome and os.clock() < deadline do
				-- A creature fight is over when the last one falls. Credit whoever fought them.
				if scene.group and next(scene.clearedBy) and creatures:groupAlive(scene.group) == 0 then
					for _, i in template.interventions do
						if i.kind == "clear" then
							scene.outcome = i.outcome
							scene.player = Players:GetPlayerByUserId((next(scene.clearedBy)) :: number)
						end
					end
				end
				task.wait(0.25)
			end
			local outcomeId = scene.outcome or SceneRules.outcomeWhenAlone(template, rng)
			if scene.outcome then
				counters.steppedIn += 1
			end
			applyEnding(template, outcomeId, town, cast, scene.names, scene.player, scene.spawned)
			note(string.format("%s, %s: %s%s", town.id, template.id, outcomeId, if scene.player then " (" .. scene.player.Name .. " stepped in)" else ""))
			log:info("scene_ended", { template = template.id, town = town.id, outcome = outcomeId, steppedIn = scene.player ~= nil })
			runSteps(scene, template.outcomes[outcomeId].steps or {})
			task.wait(END_LINGER)
		end)
		if not ok then
			log:error("scene_failed", { template = template.id, err = err })
		end
		cleanup(scene)
	end)
	return true, string.format("%s at (%.0f, %.0f) in %s", template.id, center.X, center.Z, town.id)
end

-- ─── Stepping in ────────────────────────────────────────────────────────────

local function stepIn(scene: Scene, intervention: { [string]: any }, player: Player)
	if not scene.outcome then
		scene.outcome = intervention.outcome
		scene.player = player
	end
end

local function roleOf(scene: Scene, npcId: any): string?
	for role, npc in scene.actors do
		if npc.id == npcId then
			return role
		end
	end
	return nil
end

local function onTalked(payload: any)
	for _, scene in staged do
		local role = roleOf(scene, payload.npcId)
		if role then
			for _, i in scene.template.interventions do
				if i.kind == "talk" and i.role == role then
					stepIn(scene, i, payload.player)
				end
			end
		end
	end
end

local function onDamaged(payload: any)
	local source = payload.sourceUserId
	if not source then
		return
	end
	local player = Players:GetPlayerByUserId(source)
	if not player then
		return
	end
	for _, scene in staged do
		if payload.model and scene.group and creatures:inGroup(scene.group, payload.model) then
			scene.clearedBy[source] = true
		end
		local role = payload.npcId and roleOf(scene, payload.npcId)
		if role then
			for _, i in scene.template.interventions do
				if i.kind == "hit" and i.role == role then
					stepIn(scene, i, player)
				end
			end
		end
	end
end

local function onSpell(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	if not player or not payload.effective then
		return
	end
	for _, scene in staged do
		if typeof(payload.point) == "Vector3" and (payload.point - scene.center).Magnitude <= NEAR_MAGIC then
			for _, i in scene.template.interventions do
				if i.kind == "magic" and not (i.harmless and payload.harmful) then
					local wanted = i.domains == nil
					for _, domain in (i.domains or {}) :: { string } do
						if table.find(payload.domains, domain) then
							wanted = true
						end
					end
					if wanted then
						stepIn(scene, i, player)
					end
				end
			end
		end
	end
end

-- ─── The hourly roll ────────────────────────────────────────────────────────

local function playerNear(town: any): boolean
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			if Vector3.new(root.Position.X - town.x, 0, root.Position.Z - town.z).Magnitude <= STAGE_RADIUS then
				return true
			end
		end
	end
	return false
end

local function hourTick(hourIndex: number)
	local day = math.floor(hourIndex / 24)
	local hour = hourIndex % 24
	local weekday = WorldClock.weekdayOf(day)
	for _, town in npcs:towns() do
		local rng = Seed.random(worldService:getSeed(), "town:" .. town.id, "scene", hourIndex)
		local roll = rng:NextNumber()
		if roll < WATCHED_CHANCE then
			local template = SceneRules.pickTemplate(hour, weekday, rng)
			if template then
				if playerNear(town) then
					stage(template, town, rng, nil)
				elseif roll < ALONE_CHANCE then
					runAlone(template, town, rng)
				end
			end
		end
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function nearestTown(position: Vector3): any?
	local best, bestD = nil, math.huge
	for _, town in npcs:towns() do
		local d = (town.x - position.X) ^ 2 + (town.z - position.Z) ^ 2
		if d < bestD then
			best, bestD = town, d
		end
	end
	return best
end

local function registerAdmin(admin: any)
	local ids: { string } = {}
	for _, template in Templates do
		table.insert(ids, template.id)
	end
	admin:Register({
		name = "scene",
		category = "World",
		description = "Start a scene template right in front of you, in the nearest town",
		args = { { name = "template", type = "enum", options = ids } },
		handler = function(ctx: any, a: any)
			local root = ctx.player.Character and ctx.player.Character:FindFirstChild("HumanoidRootPart")
			if not root then
				return "no character"
			end
			local town = nearestTown(root.Position)
			if not town then
				return "no town"
			end
			for _, template in Templates do
				if template.id == a.template then
					local at = root.Position + root.CFrame.LookVector * 14
					local rng = Seed.random(worldService:getSeed(), "admin:" .. town.id, "scene", os.time())
					local _, text = stage(template, town, rng, Vector3.new(at.X, world:surfaceHeight(at.X, at.Z), at.Z))
					return text
				end
			end
			return "no such template"
		end,
	})
	admin:Register({
		name = "scenes",
		category = "World",
		description = "Scenes running now, and the most recent endings on this server",
		args = {},
		handler = function(_ctx: any, _a: any)
			local lines = { string.format("staged %d, nobody-there %d, stepped in %d, %d templates", counters.staged, counters.alone, counters.steppedIn, #Templates) }
			for _, scene in staged do
				table.insert(lines, string.format("RUNNING %s in %s at (%.0f, %.0f)", scene.template.id, scene.town.id, scene.center.X, scene.center.Z))
			end
			for i = 1, math.min(12, #recent) do
				table.insert(lines, recent[i])
			end
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function SceneDirector.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	creatures = ctx.get("CreatureService")
	ambient = ctx.get("AmbientLifeService")
	reputation = ctx.get("ReputationService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
	ctx.bus:subscribe(Topics.NpcTalked, onTalked)
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
end

function SceneDirector.start(_self: any, _ctx: any)
	task.spawn(function()
		while not npcs:isReady() do
			task.wait(1)
		end
		local last = math.floor(WorldClock.now() * 24)
		while true do
			task.wait(0.5)
			local hourIndex = math.floor(WorldClock.now() * 24)
			if hourIndex ~= last then
				last = hourIndex -- a jump of many hours runs one roll, like NPCService's hourly work
				if FeatureFlags.get("scenes_enabled") == true then
					hourTick(hourIndex)
				end
			end
		end
	end)
end

return SceneDirector
