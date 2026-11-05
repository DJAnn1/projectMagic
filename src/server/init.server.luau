--!strict
-- Server entry point: flags and logging, data validation, then every service in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Core = ReplicatedStorage.Shared.Core
local FeatureFlags = require(Core.FeatureFlags)
local Logger = require(Core.Logger)
local Bootstrap = require(Core.Bootstrap)

FeatureFlags.init(require(script.Config.Flags))
Logger.setLevel(FeatureFlags.get("log_level"))

-- Requiring these validates all magic data; bad data stops the server here, loudly.
require(ReplicatedStorage.Shared.Magic.Registry)
require(script.Magic.InnateProfile)

local app = Bootstrap.new("Server")
app:addFolder(script.Services)
app:run()

if RunService:IsStudio() then
	if FeatureFlags.get("debug_run_tests") then
		require(script.Tests.TestRunner).run(script.Tests)
		require(script.Tests.MagicExamples)()
	end
	task.spawn(function()
		if FeatureFlags.get("debug_profile_stats") then
			require(script.Tests.ProfileStats)()
		end
		if FeatureFlags.get("debug_journey_sim") then
			require(script.Tests.JourneySim)()
		end
	end)
end
