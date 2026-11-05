--!strict
--[[
	NpcScoringWorker: the ParallelPool worker for NPC utility scoring. It lives in ServerStorage
	(so it never runs there) and is cloned into each Actor by the pool.

	It runs the SAME module as the main thread (Server/NPC/UtilityScore), so a far NPC scored in
	parallel decides exactly as it would have serially.

	Job input:  { jobs = { { id, compiled, needs, block, current, hour, threat } } }
	Job output: { [npcId] = actionId }

	The handler runs in PARALLEL: pure math only (no Instance writes, no yields). It switches back
	to serial (task.synchronize) only to fire the result.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local actor = script:GetActor()
if not actor then
	return -- not inside an Actor (e.g. the ServerStorage template itself)
end

local UtilityScore = require(ServerScriptService:WaitForChild("Server"):WaitForChild("NPC"):WaitForChild("UtilityScore"))

local result = actor:WaitForChild("Result") :: BindableEvent
local ready = actor:WaitForChild("Ready") :: BindableEvent

actor:BindToMessageParallel("Job", function(jobId: number, input: any)
	local ok, output = pcall(UtilityScore.batch, input.jobs)
	task.synchronize()
	result:Fire(jobId, if ok then output else { error = tostring(output) })
end)

ready:Fire()
