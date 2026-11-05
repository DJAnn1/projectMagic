--!strict
--[[
	RateLimiter: a token bucket per key.
	Each key starts with `capacity` tokens and regains `refillPerSecond` tokens per second, up to
	`capacity`. take() spends tokens and returns false when there aren't enough. That allows
	short bursts (capacity) while capping the sustained rate (refillPerSecond).

		local limiter = RateLimiter.new(8, 4)   -- bursts of 8, 4/s sustained
		if not limiter:take(player.UserId) then return end

	Buckets are created lazily. Call reset(key) when a player leaves and prune() occasionally.
]]

type Bucket = { tokens: number, last: number }

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type LimiterData = {
	capacity: number,
	refill: number,
	_clock: () -> number,
	_buckets: { [any]: Bucket },
}
export type RateLimiter = typeof(setmetatable({} :: LimiterData, RateLimiter))

-- clock is injectable so tests can control time.
function RateLimiter.new(capacity: number, refillPerSecond: number, clock: (() -> number)?): RateLimiter
	assert(capacity > 0 and refillPerSecond >= 0, "RateLimiter: bad parameters")
	return setmetatable({
		capacity = capacity,
		refill = refillPerSecond,
		_clock = clock or os.clock,
		_buckets = {},
	}, RateLimiter)
end

local function refilled(self: RateLimiter, key: any): Bucket
	local now = self._clock()
	local bucket = self._buckets[key]
	if not bucket then
		bucket = { tokens = self.capacity, last = now }
		self._buckets[key] = bucket
	else
		bucket.tokens = math.min(self.capacity, bucket.tokens + (now - bucket.last) * self.refill)
		bucket.last = now
	end
	return bucket
end

function RateLimiter.take(self: RateLimiter, key: any, cost: number?): boolean
	local bucket = refilled(self, key)
	local amount = cost or 1
	if bucket.tokens >= amount then
		bucket.tokens -= amount
		return true
	end
	return false
end

function RateLimiter.peek(self: RateLimiter, key: any): number
	return refilled(self, key).tokens
end

function RateLimiter.reset(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

-- Drops buckets that are full again (they behave exactly like new ones). Returns how many.
function RateLimiter.prune(self: RateLimiter): number
	local removed = 0
	for key in self._buckets do
		if refilled(self, key).tokens >= self.capacity then
			self._buckets[key] = nil
			removed += 1
		end
	end
	return removed
end

return RateLimiter
