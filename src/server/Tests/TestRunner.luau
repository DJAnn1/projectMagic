--!strict
--[[
	TestRunner: a minimal describe/it/expect runner for pure logic, run in Studio at boot.
	Runs every ModuleScript named "*.spec" in a folder. A spec returns `function(t)`:

		return function(t)
			t.describe("RateLimiter", function()
				t.it("allows a burst", function()
					t.expect(limiter:take(1)).toBe(true)
				end)
			end)
		end

	Tests run in order, synchronously; a test may yield (e.g. MockDataStore calls).
	For CI outside Studio, the same specs port almost directly to Jest-Lua under Lune (see docs/Backend.md §7).
]]

local TestRunner = {}

type Expectation = {
	toBe: (any) -> (),
	toEqual: (any) -> (),
	toBeNear: (number, number?) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toThrow: (string?) -> (),
}

local function deepEqual(a: any, b: any): boolean
	if typeof(a) ~= typeof(b) then
		return false
	end
	if typeof(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function expect(actual: any): Expectation
	local function fail(message: string)
		error(message, 3)
	end
	return {
		toBe = function(expected)
			if actual ~= expected then
				fail(string.format("expected %s, got %s", tostring(expected), tostring(actual)))
			end
		end,
		toEqual = function(expected)
			if not deepEqual(actual, expected) then
				fail("tables differ")
			end
		end,
		toBeNear = function(expected, epsilon)
			if typeof(actual) ~= "number" or math.abs(actual - expected) > (epsilon or 1e-6) then
				fail(string.format("expected ~%s, got %s", tostring(expected), tostring(actual)))
			end
		end,
		toBeTruthy = function()
			if not actual then
				fail("expected truthy, got " .. tostring(actual))
			end
		end,
		toBeFalsy = function()
			if actual then
				fail("expected falsy, got " .. tostring(actual))
			end
		end,
		toThrow = function(pattern)
			local ok, err = pcall(actual)
			if ok then
				fail("expected an error")
			elseif pattern and not string.find(tostring(err), pattern, 1, true) then
				fail(string.format("error %q does not contain %q", tostring(err), pattern))
			end
		end,
	}
end

-- Returns passed, failed.
function TestRunner.run(folder: Instance): (number, number)
	local passed, failed = 0, 0
	local path: { string } = {}

	local t = {
		expect = expect,
		describe = function(name: string, body: () -> ())
			table.insert(path, name)
			body()
			table.remove(path)
		end,
		it = function(name: string, body: () -> ())
			local fullName = table.concat(path, " › ") .. " › " .. name
			local ok, err = xpcall(body, debug.traceback)
			if ok then
				passed += 1
			else
				failed += 1
				warn("  ✗ " .. fullName .. "\n" .. tostring(err))
			end
		end,
	}

	local specs = {}
	for _, child in folder:GetDescendants() do
		if child:IsA("ModuleScript") and string.sub(child.Name, -5) == ".spec" then
			table.insert(specs, child)
		end
	end
	table.sort(specs, function(a, b)
		return a.Name < b.Name
	end)

	print("──────── Unit specs ────────")
	for _, spec in specs do
		local ok, err = pcall(function()
			(require :: any)(spec)(t)
		end)
		if not ok then
			failed += 1
			warn("  ✗ " .. spec.Name .. " failed to load: " .. tostring(err))
		end
	end
	print(string.format("──────── %d passed, %d failed ────────", passed, failed))
	return passed, failed
end

return TestRunner
