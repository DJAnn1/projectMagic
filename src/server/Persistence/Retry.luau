--!strict
--[[
	Retry: call a function that may fail (DataStore, MessagingService) with exponential backoff.

		local ok, result = Retry.call(function() return store:GetAsync(key) end, {
			attempts = 5, budget = Enum.DataStoreRequestType.GetAsync, label = "load",
		})

	Delay before attempt n+1 = min(maxDelay, baseDelay * 2^(n-1)), jittered to 50-100%, so many
	servers retrying at once don't hit the service in lockstep. With `budget`, it also waits
	(up to 10 s) for DataStore request budget before each attempt instead of burning a request
	on a guaranteed throttle.
]]

local DataStoreService = game:GetService("DataStoreService")

local Logger = require(game:GetService("ReplicatedStorage").Shared.Core.Logger)

export type Options = {
	attempts: number?,
	baseDelay: number?,
	maxDelay: number?,
	budget: Enum.DataStoreRequestType?,
	label: string?,
}

local Retry = {}

local log = Logger.new("Retry")
local jitter = Random.new()

local function waitForBudget(requestType: Enum.DataStoreRequestType)
	local waited = 0
	while waited < 10 do
		local ok, budget = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, requestType)
		if not ok or budget >= 1 then
			return
		end
		task.wait(0.5)
		waited += 0.5
	end
	log:throttled("budget:" .. tostring(requestType), 30, "Warn", "budget_exhausted", { type = tostring(requestType) })
end

-- Returns (true, result) or (false, lastError).
function Retry.call<T>(fn: () -> T, options: Options?): (boolean, any)
	local o: Options = options or {}
	local attempts = o.attempts or 5
	local baseDelay = o.baseDelay or 1
	local maxDelay = o.maxDelay or 16
	local lastError: any = nil

	for attempt = 1, attempts do
		if o.budget then
			waitForBudget(o.budget)
		end
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < attempts then
			local delay = math.min(maxDelay, baseDelay * 2 ^ (attempt - 1)) * (0.5 + 0.5 * jitter:NextNumber())
			log:warn("retrying", { label = o.label, attempt = attempt, delay = math.floor(delay * 10) / 10, err = result })
			task.wait(delay)
		end
	end
	log:error("gave_up", { label = o.label, attempts = attempts, err = lastError })
	return false, lastError
end

return Retry
