--!strict
--[[
	AdminService: the server half of the Admin/Developer Panel, and the ONE command registry.

	SECURITY
	  * Only Config/AdminConfig.AdminUserIds (and, in Studio, Studio test players) are admins.
	    Live servers have no panel at all unless AdminConfig.EnableInLiveServers is true.
	  * Non-admins never receive anything: the panel's client code lives in
	    ServerStorage/AdminClient and the two RemoteEvents are created per admin, inside that
	    admin's PlayerGui (which replicates only to its owner). There is no shared admin remote.
	  * Every call is re-checked on the server: sender = the link's owner, still an admin, payload
	    shape, rate limit (AdminConfig.RateLimit), then the command's argument schema is parsed and
	    range-checked HERE. The client only ever sends a command name and string tokens.
	  * Every call is audit-logged to the Output (Logger "admin_command") and pushed to the
	    in-panel log of every connected admin.

	REGISTRY
	  AdminService:Register({
	      name = "tp", aliases = { "teleport" }, category = "Teleport",
	      description = "Teleport to a place",
	      args = {
	          { name = "kind", type = "enum", options = { "settlement", "poi", "coords" } },
	          { name = "target", type = "text", optional = true },
	      },
	      handler = function(ctx, a) return "went to " .. a.target end,
	      ownerOnly = false, studioOnly = false, unavailable = nil,
	  })
	  Handlers get (ctx, args): ctx = { player, isOwner, push(data) }; args has each value by
	  name AND by position. They return a string, or { text = string?, data = table? } for the
	  panel (lists, overlays, client actions). A command with `unavailable = "reason"` is listed
	  greyed out and refuses to run (systems that don't exist yet).

	  AdminService:RegisterType("branch", { parse = fn(raw, ctx) -> (value?, err?), options = fn(ctx) -> { string } })
	  adds an argument type; `options` feeds the panel's dropdowns and autocomplete.

	BUILT-IN TYPES  string (one token) · text (the rest of the line) · number · integer ·
	  boolean (on/off/true/false/1/0) · enum (options) · player (me, name, display name, UserId) ·
	  vector3 ("x,y,z"; the panel turns @cursor into the mouse position)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")
local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Logger = require(Shared.Core.Logger)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local RateLimiter = require(Shared.Core.RateLimiter)
local AdminConfig = require(script.Parent.Parent.Config.AdminConfig)
local InnateProfile = require(ServerScriptService.Server.Magic.InnateProfile)

export type ArgDef = {
	name: string,
	type: string,
	min: number?,
	max: number?,
	default: any?,
	options: { string }?,
	optional: boolean?,
	hint: string?,
	slider: boolean?,
}

export type Context = {
	player: Player,
	isOwner: boolean,
	push: (data: { [string]: any }) -> (),
}

export type CommandDef = {
	name: string,
	aliases: { string }?,
	description: string,
	category: string,
	args: { ArgDef }?,
	handler: (Context, { [any]: any }) -> any,
	ownerOnly: boolean?,
	studioOnly: boolean?,
	unavailable: string?,
	hidden: boolean?,
}

export type TypeDef = {
	parse: (raw: string, ctx: Context) -> (any, string?),
	options: ((ctx: Context) -> { string })?,
}

local CATEGORY_ORDER = {
	"Teleport", "Movement", "Magic", "Profile", "Spells", "World", "Terrain", "Overlays",
	"NPCs", "Population", "Quests & factions", "Items", "Spellbook", "Server",
}
local MAX_ARGS = 16
local MAX_ARG_BYTES = 200
local WORLD_LIMIT = 6000

local AdminService = {
	name = "AdminService",
	dependencies = { "DataService", "PlayerDataService" },
}

local log: any = nil
local dataService: any = nil
local playerData: any = nil
local commands: { [string]: CommandDef } = {}
local lookup: { [string]: CommandDef } = {} -- name and aliases
local types: { [string]: TypeDef } = {}
local links: { [Player]: { folder: ScreenGui, reply: RemoteEvent } } = {}
local limiter = RateLimiter.new(AdminConfig.RateLimit.capacity, AdminConfig.RateLimit.perSecond)
local audit: { { [string]: any } } = {}

-- ─── Access ─────────────────────────────────────────────────────────────────

local function panelAllowedHere(): boolean
	return RunService:IsStudio() or AdminConfig.EnableInLiveServers
end

function AdminService.isAdmin(_self: any, player: Player): boolean
	if not panelAllowedHere() then
		return false
	end
	if table.find(AdminConfig.AdminUserIds, player.UserId) then
		return true
	end
	return RunService:IsStudio() and AdminConfig.StudioTestPlayers and player.UserId <= 0
end

function AdminService.isOwner(self: any, player: Player): boolean
	return self:isAdmin(player) and player.UserId == AdminConfig.OwnerUserId
end

-- ─── Registry ───────────────────────────────────────────────────────────────

function AdminService.Register(_self: any, def: CommandDef)
	assert(typeof(def.name) == "string" and def.name ~= "", "AdminService.Register: name required")
	assert(typeof(def.handler) == "function", "AdminService.Register: handler required for " .. def.name)
	assert(table.find(CATEGORY_ORDER, def.category) or def.hidden, "AdminService.Register: unknown category " .. tostring(def.category))
	local key = string.lower(def.name)
	assert(lookup[key] == nil, "AdminService: duplicate command " .. def.name)
	for i, arg in (def.args or {}) :: { ArgDef } do
		assert(arg.type == "text" and i == #(def.args :: { ArgDef }) or arg.type ~= "text", def.name .. ": a text argument must be last")
		assert(arg.type ~= "enum" or arg.options, def.name .. ": enum argument " .. arg.name .. " needs options")
	end
	commands[key] = def
	lookup[key] = def
	for _, alias in (def.aliases or {}) :: { string } do
		local a = string.lower(alias)
		assert(lookup[a] == nil, "AdminService: alias " .. alias .. " already taken")
		lookup[a] = def
	end
end

function AdminService.RegisterType(_self: any, name: string, def: TypeDef)
	assert(types[name] == nil, "AdminService: duplicate type " .. name)
	types[name] = def
end

-- Case-insensitive exact match, else a unique prefix match.
local function matchOption(raw: string, options: { string }): (string?, string?)
	local lower = string.lower(raw)
	local prefixed: { string } = {}
	for _, option in options do
		local o = string.lower(option)
		if o == lower then
			return option, nil
		end
		if string.sub(o, 1, #lower) == lower then
			table.insert(prefixed, option)
		end
	end
	if #prefixed == 1 then
		return prefixed[1], nil
	elseif #prefixed > 1 then
		table.sort(prefixed)
		return nil, string.format("'%s' is ambiguous: %s", raw, table.concat(prefixed, ", ", 1, math.min(#prefixed, 8)))
	end
	return nil, string.format("'%s' is not one of: %s%s", raw, table.concat(options, ", ", 1, math.min(#options, 12)), if #options > 12 then ", ..." else "")
end
AdminService.matchOption = matchOption

local function findPlayer(raw: string, caller: Player): Player?
	if string.lower(raw) == "me" then
		return caller
	end
	local id = tonumber(raw)
	local lower = string.lower(raw)
	local partial: Player? = nil
	for _, p in Players:GetPlayers() do
		if p.UserId == id or string.lower(p.Name) == lower or string.lower(p.DisplayName) == lower then
			return p
		end
		if string.sub(string.lower(p.Name), 1, #lower) == lower or string.sub(string.lower(p.DisplayName), 1, #lower) == lower then
			partial = p
		end
	end
	return partial
end

local function parseValue(arg: ArgDef, raw: string, ctx: Context): (any, string?)
	local t = arg.type
	if t == "string" or t == "text" then
		return raw, nil
	elseif t == "number" or t == "integer" then
		local n = tonumber(raw)
		if not n or n ~= n or n == math.huge or n == -math.huge then
			return nil, string.format("%s must be a number", arg.name)
		end
		if t == "integer" and n % 1 ~= 0 then
			return nil, string.format("%s must be a whole number", arg.name)
		end
		if (arg.min and n < arg.min) or (arg.max and n > arg.max) then
			return nil, string.format("%s must be between %s and %s", arg.name, tostring(arg.min or "-inf"), tostring(arg.max or "inf"))
		end
		return n, nil
	elseif t == "boolean" then
		local l = string.lower(raw)
		if l == "on" or l == "true" or l == "1" or l == "yes" then
			return true, nil
		elseif l == "off" or l == "false" or l == "0" or l == "no" then
			return false, nil
		end
		return nil, arg.name .. " must be on or off"
	elseif t == "enum" then
		return matchOption(raw, arg.options :: { string })
	elseif t == "vector3" then
		local parts = string.split(raw, ",")
		local x, y, z = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
		if not x or not y or not z or x ~= x or y ~= y or z ~= z then
			return nil, arg.name .. " must be x,y,z"
		end
		if math.abs(x) > WORLD_LIMIT or math.abs(z) > WORLD_LIMIT or y < -1000 or y > 4000 then
			return nil, arg.name .. " is outside the world"
		end
		return Vector3.new(x, y, z), nil
	end
	local custom = types[t]
	if not custom then
		return nil, "unknown argument type " .. t
	end
	return custom.parse(raw, ctx)
end

local function usageOf(def: CommandDef): string
	local parts = { def.name }
	for _, arg in (def.args or {}) :: { ArgDef } do
		local label = arg.name .. ":" .. arg.type
		table.insert(parts, if arg.optional or arg.default ~= nil then "[" .. label .. "]" else "<" .. label .. ">")
	end
	return table.concat(parts, " ")
end
AdminService.usageOf = usageOf

-- Parses string tokens against a command's schema. Returns (args, nil) or (nil, error).
local function parseArgs(def: CommandDef, tokens: { string }, ctx: Context): ({ [any]: any }?, string?)
	local out: { [any]: any } = {}
	local schema = def.args or {}
	for i, arg in schema do
		local raw: string? = tokens[i]
		if arg.type == "text" and #tokens > i then
			raw = table.concat(tokens, " ", i)
		end
		if raw == nil or raw == "" then
			if arg.default ~= nil then
				out[arg.name], out[i] = arg.default, arg.default
				continue
			elseif arg.optional then
				continue
			end
			return nil, "missing " .. arg.name .. "\nusage: " .. usageOf(def)
		end
		local value, err = parseValue(arg, raw :: string, ctx)
		if err or value == nil then
			return nil, (err or ("bad " .. arg.name)) .. "\nusage: " .. usageOf(def)
		end
		out[arg.name], out[i] = value, value
	end
	if #tokens > #schema and not (schema[#schema] and schema[#schema].type == "text") then
		return nil, "too many arguments\nusage: " .. usageOf(def)
	end
	return out, nil
end

-- ─── Audit log ──────────────────────────────────────────────────────────────

local function pushTo(player: Player, data: { [string]: any })
	local link = links[player]
	if link then
		link.reply:FireClient(player, data)
	end
end

local function recordAudit(entry: { [string]: any })
	table.insert(audit, entry)
	while #audit > AdminConfig.LogCapacity do
		table.remove(audit, 1)
	end
	log:info("admin_command", entry)
	for admin in links do
		pushTo(admin, { kind = "audit", entry = entry })
	end
end

-- ─── Execution ──────────────────────────────────────────────────────────────

local function run(player: Player, name: string, tokens: { string }): (boolean, string, any)
	-- Clients can send stray whitespace ("\rquestgen" after the console refocuses on Enter).
	name = (string.gsub(name, "%s", ""))
	local def = lookup[string.lower(name)]
	if not def then
		return false, "unknown command '" .. name .. "' (try help)", nil
	end
	local ctx: Context = {
		player = player,
		isOwner = AdminService:isOwner(player),
		push = function(data)
			pushTo(player, data)
		end,
	}
	if def.unavailable then
		return false, def.name .. " is not available yet: " .. def.unavailable, nil
	end
	if def.ownerOnly and not ctx.isOwner then
		return false, def.name .. " is owner-only", nil
	end
	if def.studioOnly and not RunService:IsStudio() then
		return false, def.name .. " only runs in Studio", nil
	end
	local args, err = parseArgs(def, tokens, ctx)
	if not args then
		return false, err or "bad arguments", nil
	end
	local ok, result = pcall(def.handler, ctx, args)
	if not ok then
		return false, "error: " .. tostring(result), nil
	end
	if typeof(result) == "table" then
		return true, if typeof(result.text) == "string" then result.text else "", result.data
	end
	return true, if result == nil then "ok" else tostring(result), nil
end

-- Server-side helper for other services (e.g. scripted tests): runs as that admin.
function AdminService.run(_self: any, player: Player, name: string, tokens: { string }): (boolean, string, any)
	return run(player, name, tokens)
end

local function validPayload(requestId: any, name: any, tokens: any): boolean
	if typeof(requestId) ~= "number" or requestId ~= requestId or requestId % 1 ~= 0 or requestId < 0 or requestId > 1e9 then
		return false
	end
	if typeof(name) ~= "string" or #name < 1 or #name > 40 then
		return false
	end
	if typeof(tokens) ~= "table" or #tokens > MAX_ARGS then
		return false
	end
	local count = 0
	for k, v in tokens do
		count += 1
		if typeof(k) ~= "number" or typeof(v) ~= "string" or #v > MAX_ARG_BYTES then
			return false
		end
	end
	return count == #tokens
end

-- Tokens for the audit log; a blank (defaulted) argument shows as "_" so positions stay readable.
local function auditArgs(tokens: { string }): string
	local shown = {}
	for i, t in tokens do
		shown[i] = if t == "" then "_" else t
	end
	return table.concat(shown, " ")
end

local function onCommand(owner: Player, sender: Player, requestId: any, name: any, tokens: any)
	if sender ~= owner or not AdminService:isAdmin(sender) then
		log:warn("admin_denied", { userId = sender.UserId, command = tostring(name) })
		return
	end
	if not validPayload(requestId, name, tokens) then
		log:warn("admin_bad_payload", { userId = sender.UserId })
		return
	end
	if not limiter:take(sender.UserId) then
		pushTo(sender, { kind = "reply", id = requestId, ok = false, text = "rate limited: slow down" })
		return
	end
	local started = os.clock()
	local ok, text, data = run(sender, name, tokens)
	local def = lookup[string.lower(name)]
	if not (def and def.hidden) then
		recordAudit({
			t = os.time(),
			userId = sender.UserId,
			who = sender.Name,
			command = name,
			args = auditArgs(tokens),
			ok = ok,
			ms = math.floor((os.clock() - started) * 1000),
		})
	end
	pushTo(sender, { kind = "reply", id = requestId, ok = ok, text = text, data = data })
end

-- ─── Per-admin link ─────────────────────────────────────────────────────────

local function createLink(player: Player)
	if links[player] or not AdminService:isAdmin(player) then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui", 30)
	local template = ServerStorage:FindFirstChild("AdminClient")
	if not playerGui or not player.Parent then
		return
	end
	if not template then
		log:error("admin_client_missing", { path = "ServerStorage.AdminClient" })
		return
	end
	-- A ScreenGui with ResetOnSpawn off, NOT a Folder: on respawn Roblox clears everything in
	-- PlayerGui except such ScreenGuis, which would delete the remotes and the panel's script.
	local folder = Instance.new("ScreenGui")
	folder.Name = "AdminLink"
	folder.ResetOnSpawn = false
	folder.Enabled = false -- holds no UI; the panel draws its own ScreenGui
	local command = Instance.new("RemoteEvent")
	command.Name = "Command"
	command.Parent = folder
	local reply = Instance.new("RemoteEvent")
	reply.Name = "Reply"
	reply.Parent = folder
	command.OnServerEvent:Connect(function(sender: Player, requestId: any, name: any, tokens: any)
		onCommand(player, sender, requestId, name, tokens)
	end)
	folder.Parent = playerGui
	links[player] = { folder = folder, reply = reply }
	-- The client code goes in last (inside the link, so it survives respawns too), after the
	-- remotes exist.
	local client = template:Clone()
	client.Parent = folder
	log:info("admin_linked", { userId = player.UserId })
end

-- ─── Built-ins ──────────────────────────────────────────────────────────────

local function stat(name: string): number
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and typeof(value) == "number" then value else -1
end

local function budget(kind: Enum.DataStoreRequestType): number
	local ok, value = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, kind)
	return if ok then value else -1
end

local function perfReport(): string
	local counts = Logger.counts()
	return table.concat({
		string.format("players %d | heartbeat %.2f ms | physics step %.2f ms | physics %.0f fps",
			#Players:GetPlayers(), stat("HeartbeatTimeMs"), stat("PhysicsStepTimeMs"), workspace:GetRealPhysicsFPS()),
		string.format("memory %.0f MB (scripts %.0f, physics %.0f) | instances %d | moving parts %d",
			Stats:GetTotalMemoryUsageMb(),
			Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Script),
			Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.PhysicsCollision),
			stat("InstanceCount"), stat("MovingPrimitivesCount")),
		string.format("network in %.1f KB/s | out %.1f KB/s", stat("DataReceiveKbps"), stat("DataSendKbps")),
		string.format("datastore budget get %d | update %d | set %d | sessions %d%s",
			budget(Enum.DataStoreRequestType.GetAsync), budget(Enum.DataStoreRequestType.UpdateAsync),
			budget(Enum.DataStoreRequestType.SetIncrementAsync), dataService:activeSessionCount(),
			if dataService:isMock() then " (mock)" else ""),
		string.format("logs since boot: %d warn, %d error", counts.warn, counts.error),
	}, "\n")
end

-- What the panel needs to build itself: commands (no handlers), dynamic types, config, log.
local function catalog(ctx: Context): { [string]: any }
	local list = {}
	for _, def in commands do
		if def.hidden then
			continue
		end
		local args = {}
		for _, a in (def.args or {}) :: { ArgDef } do
			table.insert(args, {
				name = a.name, type = a.type, min = a.min, max = a.max, default = a.default,
				options = a.options, optional = a.optional, hint = a.hint, slider = a.slider,
				dynamic = types[a.type] ~= nil and types[a.type].options ~= nil,
			})
		end
		table.insert(list, {
			name = def.name,
			aliases = def.aliases or {},
			description = def.description,
			category = def.category,
			args = args,
			usage = usageOf(def),
			unavailable = def.unavailable,
			ownerOnly = def.ownerOnly == true,
			locked = (def.ownerOnly == true and not ctx.isOwner) or (def.studioOnly == true and not RunService:IsStudio()),
		})
	end
	table.sort(list, function(a, b)
		local ca, cb = table.find(CATEGORY_ORDER, a.category) or 99, table.find(CATEGORY_ORDER, b.category) or 99
		if ca ~= cb then
			return ca < cb
		end
		return a.name < b.name
	end)
	return {
		commands = list,
		categories = CATEGORY_ORDER,
		toggleKey = AdminConfig.ToggleKey,
		isOwner = ctx.isOwner,
		studio = RunService:IsStudio(),
		audit = audit,
	}
end

local function registerBuiltins()
	AdminService:Register({
		name = "__catalog", hidden = true, category = "Server", description = "panel bootstrap",
		handler = function(ctx)
			return { text = "", data = { kind = "catalog", catalog = catalog(ctx) } }
		end,
	})

	AdminService:Register({
		name = "__options", hidden = true, category = "Server", description = "dropdown options for a type",
		args = { { name = "type", type = "string" } },
		handler = function(ctx, a)
			local t = types[a.type]
			local options = if t and t.options then t.options(ctx) else {}
			return { text = "", data = { kind = "options", type = a.type, options = options } }
		end,
	})

	AdminService:Register({
		name = "help", aliases = { "?" }, category = "Server",
		description = "List commands, or show one command's usage",
		args = { { name = "command", type = "string", optional = true } },
		handler = function(_, a)
			if a.command then
				local def = lookup[string.lower(a.command)]
				if not def then
					return "no command " .. a.command
				end
				local lines = { usageOf(def), def.description }
				if def.aliases and #def.aliases > 0 then
					table.insert(lines, "aliases: " .. table.concat(def.aliases, ", "))
				end
				for _, arg in (def.args or {}) :: { ArgDef } do
					local range = if arg.min or arg.max then string.format(" %s..%s", tostring(arg.min or ""), tostring(arg.max or "")) else ""
					local options = if arg.options then " (" .. table.concat(arg.options, "|") .. ")" else ""
					table.insert(lines, string.format("  %s: %s%s%s%s", arg.name, arg.type, range, options, if arg.hint then " - " .. arg.hint else ""))
				end
				if def.unavailable then
					table.insert(lines, "NOT AVAILABLE YET: " .. def.unavailable)
				end
				return table.concat(lines, "\n")
			end
			local byCategory: { [string]: { string } } = {}
			for _, def in commands do
				if not def.hidden then
					byCategory[def.category] = byCategory[def.category] or {}
					table.insert(byCategory[def.category], def.name .. (if def.unavailable then "*" else ""))
				end
			end
			local lines = {}
			for _, category in CATEGORY_ORDER do
				local names = byCategory[category]
				if names then
					table.sort(names)
					table.insert(lines, category .. ": " .. table.concat(names, ", "))
				end
			end
			table.insert(lines, "(* = needs a system that doesn't exist yet)  help <command> for details")
			return table.concat(lines, "\n")
		end,
	})

	AdminService:Register({
		name = "perf", category = "Server", description = "Server performance snapshot",
		handler = function()
			return perfReport()
		end,
	})

	AdminService:Register({
		name = "flags", category = "Server", description = "List feature flags (* = changed from default)",
		handler = function()
			local lines = {}
			for _, f in FeatureFlags.list() do
				local marker = if f.value ~= f.default then " *" else ""
				table.insert(lines, string.format("%s = %s%s  (%s)", f.name, tostring(f.value), marker, f.description))
			end
			return table.concat(lines, "\n")
		end,
	})

	AdminService:RegisterType("player", {
		parse = function(raw, ctx)
			local p = findPlayer(raw, ctx.player)
			return p, if p then nil else "no player '" .. raw .. "'"
		end,
		options = function()
			local names = { "me" }
			for _, p in Players:GetPlayers() do
				table.insert(names, p.Name)
			end
			return names
		end,
	})

	AdminService:RegisterType("flag", {
		parse = function(raw)
			for _, f in FeatureFlags.list() do
				if f.name == raw then
					return raw, nil
				end
			end
			return nil, "no flag '" .. raw .. "'"
		end,
		options = function()
			local names = {}
			for _, f in FeatureFlags.list() do
				table.insert(names, f.name)
			end
			table.sort(names)
			return names
		end,
	})

	AdminService:Register({
		name = "flag", category = "Server", description = "Set a feature flag on this server",
		args = { { name = "name", type = "flag" }, { name = "value", type = "string", hint = "true/false/number/text" } },
		handler = function(_, a)
			local raw: string = a.value
			local value: any = raw
			if raw == "true" then
				value = true
			elseif raw == "false" then
				value = false
			elseif tonumber(raw) then
				value = tonumber(raw)
			end
			local ok, why = FeatureFlags.set(a.name, value)
			if ok and a.name == "log_level" then
				Logger.setLevel(value)
			end
			return if ok then string.format("%s = %s", a.name, tostring(value)) else "failed: " .. tostring(why)
		end,
	})

	AdminService:Register({
		name = "log", category = "Server", description = "Recent server log entries",
		args = { { name = "count", type = "integer", min = 1, max = 100, default = 20 } },
		handler = function(_, a)
			local lines = {}
			for _, entry in Logger.recent(a.count) do
				table.insert(lines, Logger.format(entry))
			end
			return if #lines > 0 then table.concat(lines, "\n") else "(no entries)"
		end,
	})

	AdminService:Register({
		name = "players", category = "Server", description = "Loaded players",
		handler = function()
			local lines = {}
			for _, player in Players:GetPlayers() do
				local state = playerData:get(player)
				table.insert(lines, string.format("%s (%d): %s%s", player.Name, player.UserId,
					if state then "loaded, tier " .. InnateProfile.getRarityTier(state.innate, false) else "not loaded",
					if AdminService:isAdmin(player) then " [admin]" else ""))
			end
			return table.concat(lines, "\n")
		end,
	})

	AdminService:Register({
		name = "profile", category = "Profile", description = "What a player knows about themselves (0-3), or the full truth",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "view", type = "enum", options = { "0", "1", "2", "3", "truth" }, default = "3" },
		},
		handler = function(ctx, a)
			local target: Player = if typeof(a.player) == "Instance" then a.player else ctx.player
			local state = playerData:get(target)
			if not state then
				return "player not loaded"
			end
			if a.view == "truth" then
				local p = state.innate
				return string.format("gift %s potential %.3f | true tier %s | manifest %s | temperaments %s | latents %d | growth %s | capacity %.2f regen %.2f",
					p.giftTier, p.potential, InnateProfile.getRarityTier(p, true), table.concat(p.manifest, ","),
					table.concat(p.temperaments, ","), #p.latents, p.growth, p.capacity, p.regen)
			end
			local view = InnateProfile.getVisibleProfile(state.innate, tonumber(a.view) or 3)
			local parts = {}
			for _, d in view.domains do
				table.insert(parts, d.domain .. (if d.value then "=" .. d.value else ""))
			end
			return string.format("level %d | %s | %s", view.knowledgeLevel, table.concat(parts, " "), tostring(view.rarityTier))
		end,
	})

	AdminService:Register({
		name = "save", category = "Server", description = "Force a player save now",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(ctx, a)
			local target: Player = if typeof(a.player) == "Instance" then a.player else ctx.player
			return if playerData:saveNow(target) then "saved" else "save failed (see log)"
		end,
	})

	AdminService:Register({
		name = "auditlog", category = "Server", description = "Every admin command run on this server (newest last)",
		args = { { name = "count", type = "integer", min = 1, max = 200, default = 30 } },
		handler = function(_, a)
			local lines = {}
			for i = math.max(1, #audit - a.count + 1), #audit do
				local e = audit[i]
				table.insert(lines, string.format("%s %s(%d) %s %s -> %s", os.date("!%H:%M:%S", e.t), e.who, e.userId, e.command, e.args, if e.ok then "ok" else "failed"))
			end
			return if #lines > 0 then table.concat(lines, "\n") else "(empty)"
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function AdminService.init(_self: any, ctx: any)
	log = ctx.log
	dataService = ctx.get("DataService")
	playerData = ctx.get("PlayerDataService")
	registerBuiltins()
end

function AdminService.start(_self: any, _ctx: any)
	if not panelAllowedHere() then
		log:info("admin_panel_disabled", { reason = "live server and AdminConfig.EnableInLiveServers is false" })
		return
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(createLink, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		links[player] = nil
		limiter:reset(player.UserId)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(createLink, player)
	end
end

return AdminService
