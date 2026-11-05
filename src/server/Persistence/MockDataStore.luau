--!strict
--[[
	MockDataStore: an in-memory stand-in for a GlobalDataStore, used in Studio (flag
	`data_use_mock_in_studio`) and by tests. Play-testing then never writes to live player data,
	and doesn't need "Studio Access to API Services".

	It mirrors the behaviour our code relies on:
	- values are JSON round-tripped, so non-serializable data fails here just as it would live
	- UpdateAsync passes the current value to the transform; returning nil cancels the write
	- an optional `failRate` makes calls error randomly, to exercise retry paths
]]

local HttpService = game:GetService("HttpService")

local MockDataStore = {}
MockDataStore.__index = MockDataStore

type MockData = { _values: { [string]: string }, failRate: number, _rng: Random }
export type MockDataStore = typeof(setmetatable({} :: MockData, MockDataStore))

local stores: { [string]: MockDataStore } = {}

-- One shared instance per name, like DataStoreService:GetDataStore.
function MockDataStore.get(name: string): MockDataStore
	local store = stores[name]
	if not store then
		store = setmetatable({ _values = {}, failRate = 0, _rng = Random.new() }, MockDataStore)
		stores[name] = store
	end
	return store
end

local function maybeFail(self: MockDataStore)
	task.wait() -- real calls always yield
	if self.failRate > 0 and self._rng:NextNumber() < self.failRate then
		error("MockDataStore: simulated failure")
	end
end

local function decode(raw: string?): any
	return if raw then HttpService:JSONDecode(raw) else nil
end

function MockDataStore.GetAsync(self: MockDataStore, key: string): any
	maybeFail(self)
	return decode(self._values[key])
end

function MockDataStore.SetAsync(self: MockDataStore, key: string, value: any)
	maybeFail(self)
	self._values[key] = HttpService:JSONEncode(value)
end

function MockDataStore.UpdateAsync(self: MockDataStore, key: string, transform: (any, any) -> any): any
	maybeFail(self)
	local nextValue = transform(decode(self._values[key]), nil)
	if nextValue == nil then
		return nil
	end
	self._values[key] = HttpService:JSONEncode(nextValue)
	return decode(self._values[key])
end

function MockDataStore.RemoveAsync(self: MockDataStore, key: string): any
	maybeFail(self)
	local old = decode(self._values[key])
	self._values[key] = nil
	return old
end

return MockDataStore
