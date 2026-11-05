--!strict
--[[
	FeatureFlags
	Runtime switches: kill switches, tuning and debug toggles, changeable live from the admin
	console without a new release.

	Server: FeatureFlags.init(definitions) once at boot (definitions in Server/Config/Flags).
	        Flags with `replicate = true` are mirrored as attributes on
	        ReplicatedStorage.FeatureFlags so clients can read them. All others stay server-only.
	Client: FeatureFlags.get(name) reads the replicated attribute (nil if not replicated).

	Names use snake_case because attribute names can't contain dots.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Signal)

export type FlagDefinition = {
	default: any,
	replicate: boolean?,
	description: string,
}

local FOLDER_NAME = "FeatureFlags"
local isServer = RunService:IsServer()

local FeatureFlags = {}

local definitions: { [string]: FlagDefinition } = {}
local values: { [string]: any } = {}
local changedSignals: { [string]: Signal.Signal } = {}
local folder: Instance? = nil

local function changedSignal(name: string): Signal.Signal
	local signal = changedSignals[name]
	if not signal then
		signal = Signal.new()
		changedSignals[name] = signal
	end
	return signal
end

function FeatureFlags.init(defs: { [string]: FlagDefinition })
	assert(isServer, "FeatureFlags.init is server-only")
	definitions = defs
	local container = Instance.new("Folder")
	container.Name = FOLDER_NAME
	for name, def in defs do
		assert(string.match(name, "^[%w_]+$"), "flag names must be snake_case: " .. name)
		values[name] = def.default
		if def.replicate then
			container:SetAttribute(name, def.default)
		end
	end
	container.Parent = ReplicatedStorage
	folder = container
end

function FeatureFlags.get(name: string): any
	if isServer then
		if definitions[name] == nil then
			warn("[FeatureFlags] unknown flag " .. name)
		end
		return values[name]
	end
	local container = folder or ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	folder = container
	return if container then container:GetAttribute(name) else nil
end

-- Server only. The value must have the same type as the default. Returns ok, reason.
function FeatureFlags.set(name: string, value: any): (boolean, string?)
	if not isServer then
		return false, "server only"
	end
	local def = definitions[name]
	if not def then
		return false, "unknown flag"
	end
	if typeof(value) ~= typeof(def.default) then
		return false, "expected " .. typeof(def.default)
	end
	values[name] = value
	if def.replicate and folder then
		folder:SetAttribute(name, value)
	end
	changedSignal(name):Fire(value)
	return true, nil
end

function FeatureFlags.onChanged(name: string, fn: (any) -> ()): Signal.Connection
	if not isServer then
		local container = ReplicatedStorage:WaitForChild(FOLDER_NAME)
		return (container:GetAttributeChangedSignal(name):Connect(function()
			fn(container:GetAttribute(name))
		end) :: any)
	end
	return changedSignal(name):Connect(fn)
end

-- Server: every flag with its current value, sorted by name.
function FeatureFlags.list(): { { name: string, value: any, default: any, description: string } }
	local out = {}
	for name, def in definitions do
		table.insert(out, { name = name, value = values[name], default = def.default, description = def.description })
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

return FeatureFlags
