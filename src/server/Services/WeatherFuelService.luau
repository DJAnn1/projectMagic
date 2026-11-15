--!strict
--[[
	WeatherFuelService: you notice the weather in your magic (docs/WeatherFuel.md).

	The numbers live in MagicCore (Shared/Magic/WeatherFuel applies Data/WeatherFuel to every cast's
	power). This service only does the TELLING, the world-over-game way: no toast, no stat line. The
	first time a kind of weather noticeably feeds or starves one of your spells (|factor - 1| >=
	noticeAt, and the spell actually worked), you write a first-person line about it in your Journal.
	Once per rule, ever, so the save holds at most #rules entries.

	Admin: `weatherfuel [player]` reads the sky where they stand: the facts and every rule's strength.
	`weathernotes [player] [clear]` lists (or forgets) the Journal lines already written.

	Log: `weather_noticed` { userId, rule, factor }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local WeatherFuel = require(Shared.Magic.WeatherFuel)
local Data = require(Shared.Magic.Data.WeatherFuel)

local WeatherFuelService = {
	name = "WeatherFuelService",
	dependencies = { "AdminService", "JournalService", "PlayerDataService", "WorldStateService" },
}

local log: any = nil
local journal: any = nil
local playerData: any = nil
local world: any = nil

-- The save record (reconcile fills old saves; this guards a save loaded before that ran).
local function recordOf(player: Player): { noted: { [string]: number } }?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local data = state.data
	data.weather = data.weather or { noted = {} }
	data.weather.noted = data.weather.noted or {}
	return data.weather
end

local function onSpell(payload: any)
	if FeatureFlags.get("weather_fuel_enabled") ~= true then
		return
	end
	local ruleId = payload.weatherRule
	local factor = payload.weatherFactor
	if not ruleId or typeof(factor) ~= "number" or math.abs(factor - 1) < Data.noticeAt then
		return
	end
	if not payload.effective or payload.backfired then
		return -- a spell that fizzled teaches you nothing about the sky
	end
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	local rule = WeatherFuel.rule(ruleId)
	local record = player and recordOf(player)
	if not player or not rule or not record or record.noted[ruleId] then
		return
	end
	record.noted[ruleId] = os.time()
	journal:log(player, "weather", rule.journal, { rule = ruleId, quiet = true })
	log:info("weather_noticed", { userId = player.UserId, rule = ruleId, factor = factor })
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "weatherfuel",
		category = "Magic",
		description = "Read the sky where a player stands: storm charge, moisture, temperature, and how strongly each weather rule would feed or starve magic there",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local character = a.player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root then
				return "they have no body right now"
			end
			local env = world:environmentAt(root.Position, 32)
			local lines = {
				string.format(
					"stormCharge %.2f · moisture %.2f · temperature %.2f · flag %s",
					env.stormCharge or 0,
					env.moisture or 0,
					env.temperature or 0,
					tostring(FeatureFlags.get("weather_fuel_enabled"))
				),
			}
			for _, rule in Data.rules do
				local value = env[rule.fact] or 0
				local strength = WeatherFuel.strength(rule, value)
				if strength > 0 then
					table.insert(lines, string.format("  %s: %+d%% (%.0f%% of full)", rule.id, math.round(rule.bonus * strength * 100), strength * 100))
				end
			end
			if #lines == 1 then
				table.insert(lines, "  the weather here is neutral to every kind of magic")
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "weathernotes",
		category = "Magic",
		description = "List the weather Journal lines a player has already written (once per kind of weather), or clear them so they can be written again",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "clear", type = "string", default = "" },
		},
		handler = function(_ctx: any, a: any)
			local record = recordOf(a.player)
			if not record then
				return "no data for them yet"
			end
			if a.clear == "clear" then
				table.clear(record.noted)
				return "cleared"
			end
			local ids = {}
			for id in record.noted do
				table.insert(ids, id)
			end
			table.sort(ids)
			return if #ids == 0 then "none yet" else table.concat(ids, ", ")
		end,
	})
end

function WeatherFuelService.init(_self: any, ctx: any)
	log = ctx.log
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	world = ctx.get("WorldStateService")
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	registerAdmin(ctx.get("AdminService"))
end

function WeatherFuelService.start(_self: any, _ctx: any) end

return WeatherFuelService
