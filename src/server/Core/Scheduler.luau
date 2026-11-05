--!strict
--[[
	Scheduler: runs heavy jobs (terrain chunks, quake deformation, wave simulation) across many
	frames under a shared per-frame time budget, so the server never hitches.

		Scheduler.spawn("chunk 3,4", function()
			for slab = 1, 12 do
				buildSlab(slab)
				Scheduler.checkpoint()   -- yields here if this frame's budget is spent
			end
		end, Scheduler.Priority.Normal)

	Rules for jobs:
	- Call Scheduler.checkpoint() often (every few ms of work).
	- Never yield any other way (no task.wait, no DataStore calls) inside a job. Fetch data first,
	  then spawn the job. Jobs are resumed only by the scheduler.
	- Errors are caught and logged; a failed job doesn't stop the others.
]]

local RunService = game:GetService("RunService")

local Logger = require(game:GetService("ReplicatedStorage").Shared.Core.Logger)

export type Job = {
	name: string,
	priority: number,
	thread: thread,
	done: boolean,
	startedAt: number,
	onDone: (() -> ())?,
}

local Scheduler = {}

Scheduler.Priority = table.freeze({ High = 1, Normal = 2, Low = 3 })

local log = Logger.new("Scheduler")
local queue: { Job } = {}
local budgetSeconds = 0.004
local frameStart = os.clock()
local inJob = false
local started = false

function Scheduler.setBudgetMs(ms: number)
	budgetSeconds = math.clamp(ms, 0.5, 20) / 1000
end

-- Inside a job: yield to the next frame if this frame's budget is used up.
function Scheduler.checkpoint()
	if inJob and os.clock() - frameStart > budgetSeconds then
		coroutine.yield()
	end
end

-- Seconds of budget left this frame (for jobs that size their work).
function Scheduler.remaining(): number
	return math.max(0, budgetSeconds - (os.clock() - frameStart))
end

function Scheduler.pending(): number
	return #queue
end

local function step()
	frameStart = os.clock()
	local i = 1
	while i <= #queue and os.clock() - frameStart < budgetSeconds do
		local job = queue[i]
		inJob = true
		local ok, err = coroutine.resume(job.thread)
		inJob = false
		if not ok then
			log:error("job_failed", { job = job.name, err = debug.traceback(job.thread, tostring(err)) })
			job.done = true
		elseif coroutine.status(job.thread) == "dead" then
			job.done = true
		end
		if job.done then
			table.remove(queue, i)
			if job.onDone then
				task.spawn(job.onDone)
			end
		else
			i += 1
		end
	end
end

function Scheduler.spawn(name: string, fn: () -> (), priority: number?, onDone: (() -> ())?): Job
	if not started then
		started = true
		RunService.Heartbeat:Connect(step)
	end
	local job: Job = {
		name = name,
		priority = priority or Scheduler.Priority.Normal,
		thread = coroutine.create(fn),
		done = false,
		startedAt = os.clock(),
		onDone = onDone,
	}
	-- Keep the queue ordered by priority (stable within a priority).
	local index = #queue + 1
	for i, other in queue do
		if other.priority > job.priority then
			index = i
			break
		end
	end
	table.insert(queue, index, job)
	return job
end

-- Yields the calling (normal) thread until the job finishes.
function Scheduler.await(job: Job)
	while not job.done do
		task.wait()
	end
end

return Scheduler
