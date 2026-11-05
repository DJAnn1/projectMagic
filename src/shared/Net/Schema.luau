--!strict
--[[
	Schema: validators for untrusted remote arguments.
	A validator is `(value) -> (ok, reason?)`. Build them by composing:

		S.struct({ name = S.string(1, 32), power = S.integer(1, 10), tags = S.optional(S.array(S.string(1, 16), 4)) })

	Rules every validator follows:
	- Numbers must be finite (NaN and ±inf are rejected everywhere).
	- Tables must have exactly the expected shape: structs reject unknown keys, arrays reject holes.
	- Everything has an upper bound (string length, array length, map size, vector magnitude).
]]

export type Validator = (any) -> (boolean, string?)

local S = {}

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

function S.string(minLen: number, maxLen: number): Validator
	return function(value)
		if typeof(value) ~= "string" then
			return false, "expected string"
		end
		if #value < minLen or #value > maxLen then
			return false, string.format("string length %d not in %d-%d", #value, minLen, maxLen)
		end
		if not utf8.len(value) then
			return false, "invalid utf8"
		end
		return true
	end
end

function S.number(min: number, max: number): Validator
	return function(value)
		if typeof(value) ~= "number" or not finite(value) then
			return false, "expected finite number"
		end
		if value < min or value > max then
			return false, string.format("%s not in %s-%s", tostring(value), tostring(min), tostring(max))
		end
		return true
	end
end

function S.integer(min: number, max: number): Validator
	local inner = S.number(min, max)
	return function(value)
		local ok, why = inner(value)
		if not ok then
			return false, why
		end
		if value % 1 ~= 0 then
			return false, "expected integer"
		end
		return true
	end
end

function S.boolean(value: any): (boolean, string?)
	if typeof(value) ~= "boolean" then
		return false, "expected boolean"
	end
	return true
end

function S.vector3(maxMagnitude: number): Validator
	return function(value)
		if typeof(value) ~= "Vector3" then
			return false, "expected Vector3"
		end
		if not (finite(value.X) and finite(value.Y) and finite(value.Z)) then
			return false, "non-finite Vector3"
		end
		if value.Magnitude > maxMagnitude then
			return false, "Vector3 too large"
		end
		return true
	end
end

-- Accepts exactly one of the given values.
function S.literal(...: any): Validator
	local allowed = table.pack(...)
	return function(value)
		for i = 1, allowed.n do
			if allowed[i] == value then
				return true
			end
		end
		return false, "unexpected value"
	end
end

function S.optional(inner: Validator): Validator
	return function(value)
		if value == nil then
			return true
		end
		return inner(value)
	end
end

-- An Instance of a class, optionally required to be a descendant of `ancestor` (e.g. workspace).
function S.instance(className: string, ancestor: Instance?): Validator
	return function(value)
		if typeof(value) ~= "Instance" then
			return false, "expected Instance"
		end
		if not value:IsA(className) then
			return false, "expected " .. className
		end
		if ancestor and not value:IsDescendantOf(ancestor) then
			return false, "instance outside allowed area"
		end
		return true
	end
end

function S.array(inner: Validator, maxLen: number): Validator
	return function(value)
		if typeof(value) ~= "table" then
			return false, "expected array"
		end
		local count = 0
		for key in value do
			if typeof(key) ~= "number" then
				return false, "array has non-numeric key"
			end
			count += 1
			if count > maxLen then
				return false, "array too long"
			end
		end
		for i = 1, count do
			if value[i] == nil then
				return false, "array has holes"
			end
			local ok, why = inner(value[i])
			if not ok then
				return false, string.format("[%d] %s", i, why or "invalid")
			end
		end
		return true
	end
end

-- A table with exactly these string keys (missing keys must be S.optional).
function S.struct(fields: { [string]: Validator }): Validator
	return function(value)
		if typeof(value) ~= "table" then
			return false, "expected table"
		end
		for key in value do
			if typeof(key) ~= "string" or fields[key] == nil then
				return false, "unexpected key " .. tostring(key)
			end
		end
		for key, validator in fields do
			local ok, why = validator(value[key])
			if not ok then
				return false, key .. ": " .. (why or "invalid")
			end
		end
		return true
	end
end

function S.map(keyValidator: Validator, valueValidator: Validator, maxEntries: number): Validator
	return function(value)
		if typeof(value) ~= "table" then
			return false, "expected map"
		end
		local count = 0
		for k, v in value do
			count += 1
			if count > maxEntries then
				return false, "map too large"
			end
			local ok, why = keyValidator(k)
			if not ok then
				return false, "key: " .. (why or "invalid")
			end
			ok, why = valueValidator(v)
			if not ok then
				return false, tostring(k) .. ": " .. (why or "invalid")
			end
		end
		return true
	end
end

return S
