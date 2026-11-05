--!strict
--[[
	SignalBus
	Decoupled publish/subscribe between services: DataService doesn't need to know who cares
	that a player's data loaded. Topics must be declared in Core/Topics.

	Use the bus for cross-service notifications. Use direct method calls (via ctx.get) for
	requests that need an answer.
]]

local Signal = require(script.Parent.Signal)
local Topics = require(script.Parent.Topics)

local known: { [string]: boolean } = {}
for _, topic in Topics do
	known[topic] = true
end

local SignalBus = {}
SignalBus.__index = SignalBus

type BusData = { _signals: { [string]: Signal.Signal } }
export type SignalBus = typeof(setmetatable({} :: BusData, SignalBus))

function SignalBus.new(): SignalBus
	return setmetatable({ _signals = {} }, SignalBus)
end

local function signalFor(self: SignalBus, topic: string): Signal.Signal
	if not known[topic] then
		error(string.format("[SignalBus] unknown topic '%s' (declare it in Core/Topics)", tostring(topic)), 3)
	end
	local signal = self._signals[topic]
	if not signal then
		signal = Signal.new()
		self._signals[topic] = signal
	end
	return signal
end

function SignalBus.subscribe(self: SignalBus, topic: string, fn: (any) -> ()): Signal.Connection
	return signalFor(self, topic):Connect(fn)
end

function SignalBus.once(self: SignalBus, topic: string, fn: (any) -> ()): Signal.Connection
	return signalFor(self, topic):Once(fn)
end

function SignalBus.publish(self: SignalBus, topic: string, payload: any)
	signalFor(self, topic):Fire(payload)
end

function SignalBus.wait(self: SignalBus, topic: string): any
	return signalFor(self, topic):Wait()
end

return SignalBus
