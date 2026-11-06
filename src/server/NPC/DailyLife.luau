--!strict
--[[
	DailyLife: runs an NPC's visible activity (Data/Activities) on its T0 rig, once a second.

	It only decorates what the schedule already decided: NPCBrain picks the action, NPCService routes
	the NPC, and this plays the clip, carries the prop and walks the short rounds. Never at T1 or T2:
	no rig detail exists out there, so distant NPCs stay plain data.

		DailyLife.step(npc, clock, env)
		DailyLife.clear(npc)

	env (given by Services/AmbientLifeService)
		ground(Vector3) -> Vector3
		patrolPoints(npc, kind) -> { Vector3 }
		onStop(npc, kind, index)     arrived at a patrol stop (a lamplighter's lamp)
		spark(npc)                   the tiny cosmetic spell
]]

local Activities = require(script.Parent.Data.Activities)
local LOD = require(script.Parent.NPCLOD)

local DailyLife = {}

-- A stable 0..1 from the NPC and a counter, so timing varies by person without a shared Random.
local function wobble(npc: any, n: number): number
	return ((npc.seed + n * 7919) % 1000) / 1000
end

local function between(range: { number }, npc: any, n: number): number
	return range[1] + (range[2] - range[1]) * wobble(npc, n)
end

function DailyLife.clear(npc: any)
	if npc.life then
		npc.life = nil
		LOD.stopActivity(npc)
		LOD.setProp(npc, nil)
	end
end

local function startClip(npc: any, def: Activities.Activity)
	local clip = def.clip
	local id = clip and Activities.Clips[clip]
	if clip and id then
		LOD.playActivity(npc, clip, id, def.looped == true)
	end
end

local function walkTo(npc: any, life: any, point: Vector3)
	LOD.stopActivity(npc)
	LOD.setDestination(npc, point)
	life.moving = true
end

function DailyLife.step(npc: any, clock: number, env: any)
	if not npc.rig or npc.tier ~= 0 or npc.leash or npc.combat or npc.knockedOut or npc.frozen then
		DailyLife.clear(npc)
		return
	end
	local key = npc.occupation .. "." .. tostring(npc.action)
	local def = Activities.lookup(npc.occupation, npc.action)
	if not def then
		DailyLife.clear(npc)
		return
	end
	local life = npc.life
	if not life or life.key ~= key then
		DailyLife.clear(npc)
		life = { key = key, n = 0, nextClip = 0, nextMove = 0, stop = 0, center = nil, moving = false }
		npc.life = life
		LOD.setProp(npc, if def.prop then Activities.Props[def.prop] else nil)
	end
	if (npc.talkingUntil or 0) > clock then
		return
	end
	if not LOD.arrived(npc) then
		if not life.moving then
			life.moving = true
			LOD.stopActivity(npc)
		end
		if def.jump and npc.rig and wobble(npc, math.floor(clock)) < 0.08 then
			npc.rig.humanoid.Jump = true
		end
		return
	end
	-- Just arrived, or still here.
	if life.moving then
		life.moving = false
		life.nextMove = clock + (if def.pause then def.pause elseif def.roamEvery then between(def.roamEvery, npc, life.n) else 0)
		if def.patrol and env.onStop then
			env.onStop(npc, def.patrol, life.stop)
		end
	end
	life.center = life.center or npc.destination or npc.position

	-- Patrols and roaming: on to the next spot when it's time.
	if clock >= life.nextMove then
		if def.patrol then
			local points = env.patrolPoints(npc, def.patrol)
			if #points > 0 then
				life.stop = life.stop % #points + 1
				walkTo(npc, life, points[life.stop])
				return
			end
		elseif def.roam then
			life.n += 1
			local angle = wobble(npc, life.n) * 2 * math.pi
			local reach = def.roam * (0.4 + 0.6 * wobble(npc, life.n + 50))
			walkTo(npc, life, env.ground(life.center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach))
			return
		end
	end

	-- Standing at the spot: hold the clip, or play it now and then.
	if def.looped then
		startClip(npc, def)
	elseif clock >= life.nextClip and def.every then
		life.n += 1
		life.nextClip = clock + between(def.every, npc, life.n)
		startClip(npc, def)
		if def.spark and env.spark and wobble(npc, life.n + 90) < 0.35 then
			env.spark(npc)
		end
	end
end

return DailyLife
