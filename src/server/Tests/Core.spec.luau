--!strict
-- Unit specs for the engineering foundation. Run by TestRunner in Studio.

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Signal = require(Shared.Core.Signal)
local Logger = require(Shared.Core.Logger)
local SignalBus = require(Shared.Core.SignalBus)
local Topics = require(Shared.Core.Topics)
local RateLimiter = require(Shared.Core.RateLimiter)
local Bootstrap = require(Shared.Core.Bootstrap)
local Net = require(Shared.Net)
local MagicCore = require(Shared.Magic.MagicCore)
local Server = ServerScriptService.Server
local Codec = require(Server.Persistence.Codec)
local Schemas = require(Server.Persistence.Schemas)
local MockDataStore = require(Server.Persistence.MockDataStore)
local DataService = require(Server.Services.DataService)

local S = Net.Schema

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("RateLimiter", function()
		local now = 0
		local limiter = RateLimiter.new(3, 1, function()
			return now
		end)
		it("allows a burst up to capacity", function()
			expect(limiter:take("a")).toBe(true)
			expect(limiter:take("a")).toBe(true)
			expect(limiter:take("a")).toBe(true)
			expect(limiter:take("a")).toBe(false)
		end)
		it("refills over time", function()
			now += 1
			expect(limiter:take("a")).toBe(true)
			expect(limiter:take("a")).toBe(false)
		end)
		it("keeps keys independent and resets", function()
			expect(limiter:take("b")).toBe(true)
			limiter:reset("a")
			expect(limiter:peek("a")).toBe(3)
		end)
	end)

	describe("Schema", function()
		local shape = S.struct({ name = S.string(1, 8), power = S.integer(1, 10), tags = S.optional(S.array(S.string(1, 4), 2)) })
		it("accepts a valid table", function()
			expect((shape({ name = "bolt", power = 3 }))).toBe(true)
		end)
		it("rejects unknown keys", function()
			expect((shape({ name = "bolt", power = 3, admin = true }))).toBe(false)
		end)
		it("rejects NaN, infinity and fractions", function()
			expect((shape({ name = "bolt", power = 0 / 0 }))).toBe(false)
			expect((shape({ name = "bolt", power = math.huge }))).toBe(false)
			expect((shape({ name = "bolt", power = 2.5 }))).toBe(false)
		end)
		it("rejects arrays with holes or overflow", function()
			expect((shape({ name = "bolt", power = 1, tags = { [1] = "a", [3] = "c" } }))).toBe(false)
			expect((shape({ name = "bolt", power = 1, tags = { "a", "b", "c" } }))).toBe(false)
		end)
		it("rejects non-finite vectors", function()
			expect((S.vector3(100)(Vector3.new(0 / 0, 0, 0)))).toBe(false)
			expect((S.vector3(100)(Vector3.new(1000, 0, 0)))).toBe(false)
		end)
	end)

	describe("Net", function()
		it("estimates deep tables as oversized", function()
			local deep: any = {}
			local node = deep
			for _ = 1, 10 do
				node.x = {}
				node = node.x
			end
			expect(Net.estimateSize(deep, 1000, 0) > 1000).toBe(true)
		end)
	end)

	describe("Signal", function()
		it("fires, disconnects and fires once", function()
			local signal = Signal.new()
			local total = 0
			local conn = signal:Connect(function(x)
				total += x
			end)
			signal:Once(function(x)
				total += x * 10
			end)
			signal:Fire(1)
			expect(total).toBe(11)
			conn:Disconnect()
			signal:Fire(1)
			expect(total).toBe(11)
		end)
		it("rejects unknown bus topics", function()
			local bus = SignalBus.new()
			expect(function()
				bus:publish("NoSuchTopic", {})
			end).toThrow("unknown topic")
			bus:publish(Topics.FlagChanged, { name = "x", value = 1 }) -- a declared topic must not error
		end)
	end)

	describe("Bootstrap", function()
		local previousHook = Signal.onHandlerError
		it("initialises in dependency order", function()
			local order = {}
			local app = Bootstrap.new("Spec")
			local function module(name: string, deps: { string })
				return {
					name = name,
					dependencies = deps,
					init = function()
						table.insert(order, name)
					end,
				}
			end
			app:add(module("C", { "B" }))
			app:add(module("A", {}))
			app:add(module("B", { "A" }))
			app:run()
			expect(table.concat(order, ",")).toBe("A,B,C")
		end)
		it("detects cycles", function()
			local app = Bootstrap.new("Spec")
			app:add({ name = "A", dependencies = { "B" } })
			app:add({ name = "B", dependencies = { "A" } })
			expect(function()
				app:run()
			end).toThrow("cycle")
		end)
		it("forbids yielding in init", function()
			local app = Bootstrap.new("Spec")
			app:add({ name = "Slow", init = function()
				task.wait()
			end })
			expect(function()
				app:run()
			end).toThrow("yielded")
		end)
		it("forbids undeclared ctx.get", function()
			local app = Bootstrap.new("Spec")
			app:add({ name = "A" })
			app:add({ name = "B", init = function(_, ctx)
				ctx.get("A")
			end })
			expect(function()
				app:run()
			end).toThrow("without declaring")
		end)
		Signal.onHandlerError = previousHook
	end)

	describe("Codec", function()
		it("round-trips small values uncompressed", function()
			local encoded = Codec.encode({ a = 1, b = { "x" } })
			expect(string.sub(encoded, 1, 3)).toBe("J1:")
			expect(Codec.decode(encoded)).toEqual({ a = 1, b = { "x" } })
		end)
		it("round-trips large values (compressed when available)", function()
			local big = {}
			for i = 1, 500 do
				big["recipe_" .. i] = 1793600000 + i
			end
			local encoded = Codec.encode(big)
			expect(string.sub(encoded, 1, 3)).toBe(if Codec.isCompressionAvailable() then "Z1:" else "J1:")
			expect(Codec.decode(encoded)).toEqual(big)
		end)
	end)

	describe("Player schema migration v1 -> v2", function()
		it("turns the spellbook array into a keyed map and quarantines invalid recipes", function()
			local valid = { branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1 }
			local invalid = { branch = "energy", property = "temperature", verb = "sense", form = "projectile", power = 1 }
			local migrated = Schemas.Player.migrations[1]({ spellbook = { valid, invalid } })
			local _, _, normalized = MagicCore.validateRecipe(valid)
			local key = MagicCore.recipeKey(normalized :: any)
			expect(migrated.spellbook[key] ~= nil).toBe(true)
			expect(migrated.spellbook[key].favorite).toBe(false)
			expect(#migrated.spellbookQuarantine).toBe(1)
		end)
	end)

	if not DataService:isMock() then
		t.log("  (DataService session specs skipped: not in mock mode)")
		return
	end

	describe("DataService sessions (mock)", function()
		local config = {
			name = "SpecLocks",
			version = 1,
			template = function()
				return { count = 0 }
			end,
			migrations = {},
		}
		local store = DataService:openSessionStore(config)
		local raw = MockDataStore.get("SpecLocks/global") :: any
		-- Fresh keys per run: the lock-theft test leaves its key locked by "another-server",
		-- so reusing keys would make a second run wait on that lock.
		local run = string.sub(HttpService:GenerateGUID(false), 1, 8)
		local K1, K2, K3, PLAYER = "k1_" .. run, "k2_" .. run, "k3_" .. run, "player_spec_" .. run
		local function setRecord(key: string, record: any)
			raw._values[key] = HttpService:JSONEncode(record)
		end
		local function getRecord(key: string): any
			return HttpService:JSONDecode(raw._values[key])
		end

		local session: any = nil
		it("loads a new key with the template and saves", function()
			session = store:load(K1)
			expect(session ~= nil).toBe(true)
			expect(session.data.count).toBe(0)
			session.data.count = 5
			expect(session:save()).toBe(true)
			expect(getRecord(K1).data.count).toBe(5)
		end)
		it("refuses a second load in the same server", function()
			local again, why = store:load(K1)
			expect(again).toBe(nil)
			expect(why).toBe("ALREADY_LOADED")
		end)
		it("ends the session when another server takes the lock", function()
			local record = getRecord(K1)
			record.meta.lock.jobId = "another-server"
			setRecord(K1, record)
			-- The lock_lost error is the behaviour under test: keep it out of the Output.
			Logger.expecting("lock_lost", function()
				expect(session:save()).toBe(false)
			end)
			expect(session:isActive()).toBe(false)
		end)
		it("takes over a stale lock left by a crashed server", function()
			setRecord(K2, { schema = 1, meta = { lock = { jobId = "dead-server", at = os.time() - 1000 } }, data = { count = 7 } })
			local s = store:load(K2)
			expect(s and s.data.count).toBe(7)
			if s then
				s:release()
				expect(getRecord(K2).meta.lock).toBe(nil)
			end
		end)
		it("refuses records written by a newer schema", function()
			setRecord(K3, { schema = 99, meta = {}, data = {} })
			local s, why = store:load(K3)
			expect(s).toBe(nil)
			expect(why).toBe("NEWER_SCHEMA")
		end)
		it("migrates a v1 player record end to end", function()
			local playerStore = DataService:openSessionStore(Schemas.Player)
			local playerRaw = MockDataStore.get("PlayerData/global") :: any
			playerRaw._values[PLAYER] = HttpService:JSONEncode({
				schema = 1,
				meta = {},
				data = {
					spellbook = { { branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1 } },
					progression = { mastery = { energy = 12 } },
				},
			})
			local s = playerStore:load(PLAYER)
			expect(s ~= nil).toBe(true)
			if s then
				expect(s.data.progression.mastery.energy).toBe(12)
				expect(s.data.progression.records ~= nil).toBe(true) -- filled from the v3 template
				expect(s.data.settings ~= nil).toBe(true) -- filled from the v2 template
				expect(next(s.data.spellbook) ~= nil).toBe(true)
				s:release()
				expect(HttpService:JSONDecode(playerRaw._values[PLAYER]).schema).toBe(Schemas.Player.version)
				expect(s.data.progression.unlocked.energy).toBe(true) -- v2 -> v3: mastery implies unlocked
				expect(s.data.progression.xp.energy ~= nil).toBe(true)
			end
		end)
	end)
end
