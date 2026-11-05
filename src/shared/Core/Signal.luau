--!strict
--[[
	Signal
	A minimal signal: Connect / Once / Fire / Wait / DisconnectAll.
	Each handler runs in its own thread, so one failing or yielding handler can't stop the
	others. Handler errors go to Signal.onHandlerError (Bootstrap points it at the Logger).
]]

type Handler = {
	fn: (...any) -> (),
	connected: boolean,
	once: boolean,
}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

local Signal = {}
Signal.__index = Signal

-- Replaced at boot so handler errors become structured logs.
Signal.onHandlerError = function(err: string)
	warn("[Signal] handler error: " .. err)
end

type SignalData = { _handlers: { Handler } }
export type Signal = typeof(setmetatable({} :: SignalData, Signal))

local function runHandler(fn: (...any) -> (), ...: any)
	local ok, err = xpcall(fn, debug.traceback, ...)
	if not ok then
		Signal.onHandlerError(tostring(err))
	end
end

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal)
end

local function connect(self: Signal, fn: (...any) -> (), once: boolean): Connection
	local handler: Handler = { fn = fn, connected = true, once = once }
	table.insert(self._handlers, handler)
	local connection = { Connected = true } :: any
	function connection.Disconnect(conn: Connection)
		if not handler.connected then
			return
		end
		handler.connected = false
		conn.Connected = false
		local index = table.find(self._handlers, handler)
		if index then
			table.remove(self._handlers, index)
		end
	end
	return connection
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): Connection
	return connect(self, fn, false)
end

function Signal.Once(self: Signal, fn: (...any) -> ()): Connection
	return connect(self, fn, true)
end

function Signal.Fire(self: Signal, ...: any)
	-- Iterate a snapshot so handlers can connect or disconnect while firing.
	for _, handler in table.clone(self._handlers) do
		if handler.connected then
			if handler.once then
				handler.connected = false
				local index = table.find(self._handlers, handler)
				if index then
					table.remove(self._handlers, index)
				end
			end
			task.spawn(runHandler, handler.fn, ...)
		end
	end
end

-- Yields until the next Fire and returns its arguments.
function Signal.Wait(self: Signal): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.DisconnectAll(self: Signal)
	for _, handler in self._handlers do
		handler.connected = false
	end
	table.clear(self._handlers)
end

return Signal
