--!strict
--[[
	ParallelPool: runs pure computation on several Actors (Parallel Luau).

		local pool = ParallelPool.new("NpcScoring", ServerStorage.Workers.NpcScoringWorker, 4)
		local results = pool:map(batches)   -- yields; one result per input, same order

	Each Actor gets a clone of the worker script, which binds a parallel "Job" handler and
	answers through a BindableEvent. Inputs and outputs are deep-copied between Actors, so
	keep them to plain data (numbers, strings, tables) and send BATCHES (e.g. 50 NPCs per job),
	not one message per item: per-message overhead dominates small jobs.

	Good fits: NPC utility scoring, noise/terrain sampling, wave and fluid steps, batch profile
	generation. Bad fits: anything that touches Instances, DataStores or yields per item.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local ParallelPool = {}
ParallelPool.__index = ParallelPool

type PoolData = {
	name: string,
	_actors: { Actor },
	_ready: { [Actor]: boolean },
	_readyWaiters: { thread },
	_pending: { [number]: thread },
	_nextJob: number,
	_nextActor: number,
}
export type ParallelPool = typeof(setmetatable({} :: PoolData, ParallelPool))

function ParallelPool.new(name: string, workerTemplate: Script, size: number): ParallelPool
	local self: ParallelPool = setmetatable({
		name = name,
		_actors = {},
		_ready = {},
		_readyWaiters = {},
		_pending = {},
		_nextJob = 0,
		_nextActor = 0,
	}, ParallelPool)

	local folder = Instance.new("Folder")
	folder.Name = name .. "Actors"
	folder.Parent = ServerScriptService

	for i = 1, size do
		local actor = Instance.new("Actor")
		actor.Name = name .. i

		local result = Instance.new("BindableEvent")
		result.Name = "Result"
		result.Parent = actor
		result.Event:Connect(function(jobId: number, output: any)
			local thread = self._pending[jobId]
			self._pending[jobId] = nil
			if thread then
				task.spawn(thread, output)
			end
		end)

		-- The worker fires Ready once its message handler is bound; messages sent earlier would be lost.
		local ready = Instance.new("BindableEvent")
		ready.Name = "Ready"
		ready.Parent = actor
		ready.Event:Once(function()
			self._ready[actor] = true
			local waiters = self._readyWaiters
			self._readyWaiters = {}
			for _, thread in waiters do
				task.spawn(thread)
			end
		end)

		workerTemplate:Clone().Parent = actor
		actor.Parent = folder
		table.insert(self._actors, actor)
	end
	return self
end

local function nextReadyActor(self: ParallelPool): Actor
	while true do
		for _ = 1, #self._actors do
			self._nextActor = self._nextActor % #self._actors + 1
			local actor = self._actors[self._nextActor]
			if self._ready[actor] then
				return actor
			end
		end
		table.insert(self._readyWaiters, coroutine.running())
		coroutine.yield()
	end
end

-- Runs one job and yields for its result.
function ParallelPool.run(self: ParallelPool, input: any): any
	local actor = nextReadyActor(self)
	self._nextJob += 1
	local jobId = self._nextJob
	self._pending[jobId] = coroutine.running()
	actor:SendMessage("Job", jobId, input)
	return coroutine.yield()
end

-- Runs every input in parallel; returns outputs in input order. Yields until all finish.
function ParallelPool.map(self: ParallelPool, inputs: { any }): { any }
	local outputs = table.create(#inputs)
	local remaining = #inputs
	if remaining == 0 then
		return outputs
	end
	local caller = coroutine.running()
	for i, input in inputs do
		task.spawn(function()
			outputs[i] = self:run(input)
			remaining -= 1
			if remaining == 0 then
				task.spawn(caller)
			end
		end)
	end
	coroutine.yield()
	return outputs
end

return ParallelPool
