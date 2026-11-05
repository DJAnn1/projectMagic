--!strict
--[[
	Bootstrap: loads services (server) or controllers (client) in dependency order.

	A module is a table:
		local MyService = {
			name = "MyService",
			dependencies = { "DataService" },  -- names of other modules
		}
		function MyService:init(ctx)  end  -- synchronous setup. MUST NOT YIELD.
		function MyService:start(ctx) end  -- runs after every init, in its own thread. May yield.

	Lifecycle
	1. Topologically sort by `dependencies` (unknown dependencies and cycles error at boot).
	2. Call every init in that order. A yielding init is a boot error: it would stall everything after it.
	3. Spawn every start in the same order.

	Service locator: ctx.get(name) returns another module, but ONLY one listed in
	`dependencies`. That keeps the dependency graph honest and the boot order correct.
]]

local Logger = require(script.Parent.Logger)
local Signal = require(script.Parent.Signal)
local SignalBus = require(script.Parent.SignalBus)
local FeatureFlags = require(script.Parent.FeatureFlags)

export type Context = {
	name: string,
	get: (name: string) -> any,
	bus: SignalBus.SignalBus,
	flags: typeof(FeatureFlags),
	log: Logger.ScopedLogger,
}

export type Module = {
	name: string,
	dependencies: { string }?,
	init: ((self: any, ctx: Context) -> ())?,
	start: ((self: any, ctx: Context) -> ())?,
	[any]: any,
}

local Bootstrap = {}
Bootstrap.__index = Bootstrap

type AppData = {
	label: string,
	bus: SignalBus.SignalBus,
	log: Logger.ScopedLogger,
	_modules: { [string]: Module },
	_order: { Module },
	_ready: Signal.Signal,
	_started: boolean,
}
export type App = typeof(setmetatable({} :: AppData, Bootstrap))

function Bootstrap.new(label: string, bus: SignalBus.SignalBus?): App
	local log = Logger.new(label .. ".Bootstrap")
	Signal.onHandlerError = function(err: string)
		log:error("signal_handler_error", { err = err })
	end
	return setmetatable({
		label = label,
		bus = bus or SignalBus.new(),
		log = log,
		_modules = {},
		_order = {},
		_ready = Signal.new(),
		_started = false,
	}, Bootstrap)
end

function Bootstrap.add(self: App, module: Module)
	assert(typeof(module) == "table" and typeof(module.name) == "string", "Bootstrap: module needs a string `name`")
	assert(not self._started, "Bootstrap: can't add modules after run()")
	assert(self._modules[module.name] == nil, "Bootstrap: duplicate module " .. module.name)
	self._modules[module.name] = module
end

-- Requires every ModuleScript directly inside `folder`, sorted by name for a stable order.
function Bootstrap.addFolder(self: App, folder: Instance)
	local scripts = {}
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(scripts, child)
		end
	end
	table.sort(scripts, function(a, b)
		return a.Name < b.Name
	end)
	for _, moduleScript in scripts do
		self:add((require :: any)(moduleScript))
	end
end

function Bootstrap.get(self: App, name: string): any
	local module = self._modules[name]
	if not module then
		error("Bootstrap: no module named " .. name, 2)
	end
	return module
end

local function sortByDependencies(self: App): { Module }
	local order: { Module } = {}
	local state: { [string]: string } = {} -- nil = unvisited, "visiting", "done"
	local names: { string } = {}
	for name in self._modules do
		table.insert(names, name)
	end
	table.sort(names)

	local function visit(name: string, path: { string })
		if state[name] == "done" then
			return
		end
		if state[name] == "visiting" then
			table.insert(path, name)
			error("Bootstrap: dependency cycle " .. table.concat(path, " -> "), 0)
		end
		local module = self._modules[name]
		if not module then
			error(string.format("Bootstrap: %s depends on unknown module %s", path[#path] or "?", name), 0)
		end
		state[name] = "visiting"
		table.insert(path, name)
		for _, dep in module.dependencies or {} do
			visit(dep, path)
		end
		table.remove(path)
		state[name] = "done"
		table.insert(order, module)
	end

	for _, name in names do
		visit(name, {})
	end
	return order
end

local function contextFor(self: App, module: Module): Context
	local allowed: { [string]: boolean } = {}
	for _, dep in module.dependencies or {} do
		allowed[dep] = true
	end
	return {
		name = module.name,
		get = function(name: string): any
			if not allowed[name] then
				error(string.format("%s used ctx.get('%s') without declaring it in dependencies", module.name, name), 2)
			end
			return self._modules[name]
		end,
		bus = self.bus,
		flags = FeatureFlags,
		log = Logger.new(module.name),
	}
end

function Bootstrap.run(self: App)
	assert(not self._started, "Bootstrap: run() called twice")
	self._order = sortByDependencies(self)
	local contexts: { [Module]: Context } = {}

	for _, module in self._order do
		local ctx = contextFor(self, module)
		contexts[module] = ctx
		local init = module.init
		if init then
			local started = os.clock()
			local thread = coroutine.create(init)
			local ok, err = coroutine.resume(thread, module, ctx)
			if not ok then
				error(string.format("%s:init failed: %s", module.name, debug.traceback(thread, tostring(err))), 0)
			end
			if coroutine.status(thread) ~= "dead" then
				error(module.name .. ":init yielded; move yielding work into :start", 0)
			end
			self.log:debug("init", { module = module.name, ms = math.floor((os.clock() - started) * 1000) })
		end
	end

	for _, module in self._order do
		local start = module.start
		if start then
			task.spawn(function()
				local ok, err = xpcall(start, debug.traceback, module, contexts[module])
				if not ok then
					self.log:error("start_failed", { module = module.name, err = err })
				end
			end)
		end
	end

	self._started = true
	self.log:info("booted", { modules = #self._order })
	self._ready:Fire()
end

-- Yields until run() has finished (returns immediately if it already has).
function Bootstrap.awaitReady(self: App)
	if not self._started then
		self._ready:Wait()
	end
end

return Bootstrap
