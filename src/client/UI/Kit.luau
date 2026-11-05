--!strict
--[[
	Kit: the whole UI "framework": four ideas in plain Luau, no dependency.

		Kit.value(initial)                 -> Value<T>   a cell: get(), set(v, force?), observe(fn) -> stop()
		Kit.computed(scope, deps, fn)      -> Value<T>   recomputed whenever a dependency changes
		Kit.scope()                        -> Scope      owns cleanup: add(item), child(), destroy()
		Kit.create(scope, class, props)    -> Instance   builds an Instance; Values in props stay bound
		Kit.dynamic(scope, deps, render)                 re-renders a region when dependencies change

	Why not React-Lua or Fusion: see docs/UI.md §2. The names deliberately mirror Fusion
	(Value, Computed, scope) so moving to Fusion later is a mechanical rewrite.

	create(props):
		PropName = value              plain property
		PropName = Value              bound: set now and on every change (the scope owns the binding)
		EventName = function          connected to the instance's event (e.g. Activated, MouseEnter)
		children = { Instance }       parented in order
		Parent = Instance             parented last, after everything else is set

	Value equality: set() ignores a value equal to the current one. After mutating a table in
	place, call set(sameTable, true) to notify anyway.
]]

local Logger = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Core.Logger)

local log = Logger.new("Kit")

export type Value<T> = {
	get: (self: Value<T>) -> T,
	set: (self: Value<T>, value: T, force: boolean?) -> (),
	observe: (self: Value<T>, fn: (T) -> ()) -> () -> (),
}

export type Scope = {
	add: (self: Scope, item: any) -> (),
	child: (self: Scope) -> Scope,
	destroy: (self: Scope) -> (),
}

local Kit = {}

local isValue: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

function Kit.value<T>(initial: T): Value<T>
	local current = initial
	local listeners: { [number]: (T) -> () } = {}
	local nextId = 0
	local value = {} :: any

	function value.get(_self: any): T
		return current
	end

	function value.set(_self: any, newValue: T, force: boolean?)
		if newValue == current and not force then
			return
		end
		current = newValue
		-- Snapshot the ids: an observer may stop itself or add others while we notify.
		local ids: { number } = {}
		for id in listeners do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local fn = listeners[id]
			if fn then
				local ok, err = xpcall(fn, debug.traceback, newValue)
				if not ok then
					log:error("observer_error", { err = err })
				end
			end
		end
	end

	function value.observe(_self: any, fn: (T) -> ()): () -> ()
		nextId += 1
		local id = nextId
		listeners[id] = fn
		return function()
			listeners[id] = nil
		end
	end

	isValue[value] = true
	return value
end

function Kit.isValue(x: any): boolean
	return isValue[x] == true
end

local function cleanup(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		pcall(task.cancel, item)
	elseif kind == "table" then
		if item.destroy then
			item:destroy()
		elseif item.Destroy then
			item:Destroy()
		elseif item.Disconnect then
			item:Disconnect()
		end
	end
end

function Kit.scope(): Scope
	local items: { any } = {}
	local destroyed = false
	local scope = {} :: any

	function scope.add(_self: any, item: any)
		if destroyed then
			cleanup(item) -- adding to a dead scope cleans up at once, so nothing leaks
		else
			table.insert(items, item)
		end
	end

	function scope.child(_self: any): Scope
		local child = Kit.scope()
		scope:add(child)
		return child
	end

	-- Cleans up in reverse order: bindings stop before the instances they point at are destroyed.
	function scope.destroy(_self: any)
		if destroyed then
			return
		end
		destroyed = true
		for i = #items, 1, -1 do
			local ok, err = pcall(cleanup, items[i])
			if not ok then
				log:warn("cleanup_error", { err = err })
			end
		end
		table.clear(items)
	end

	return scope
end

function Kit.computed<T>(scope: Scope, deps: { Value<any> }, fn: () -> T): Value<T>
	local value = Kit.value(fn())
	for _, dep in deps do
		scope:add(dep:observe(function()
			value:set(fn())
		end))
	end
	return value
end

function Kit.create(scope: Scope?, className: string, props: { [string]: any }): any
	local instance = Instance.new(className)
	local children: { Instance }? = nil
	local parent: Instance? = nil
	for key, value in props do
		if key == "children" then
			children = value
		elseif key == "Parent" then
			parent = value
		elseif typeof(value) == "function" then
			-- Connections die with the instance; no scope needed.
			(instance :: any)[key]:Connect(value)
		elseif isValue[value] then
			assert(scope, "Kit.create: binding " .. key .. " needs a scope")
			local bound = value :: Value<any>;
			(instance :: any)[key] = bound:get()
			scope:add(bound:observe(function(newValue)
				(instance :: any)[key] = newValue
			end))
		else
			(instance :: any)[key] = value
		end
	end
	for _, child in (children or {}) :: { Instance } do
		child.Parent = instance
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

--[[
	Renders a region of UI, then re-renders it whenever a dependency changes. Changes in the same
	frame are batched into one re-render (deferred). `render` gets a fresh scope each time, and
	the previous one is destroyed first, so everything it created or bound is cleaned up.
]]
function Kit.dynamic(scope: Scope, deps: { Value<any> }, render: (Scope) -> ())
	local current: Scope? = nil
	local alive = true
	local pending = false

	local function run()
		if current then
			current:destroy()
		end
		local s = Kit.scope()
		current = s
		local ok, err = xpcall(render, debug.traceback, s)
		if not ok then
			log:error("render_error", { err = err })
		end
	end

	local function schedule()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			if alive then
				run()
			end
		end)
	end

	for _, dep in deps do
		scope:add(dep:observe(schedule))
	end
	scope:add(function()
		alive = false
		if current then
			current:destroy()
			current = nil
		end
	end)
	run()
end

return Kit
