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
		-- Quiet by default: failures print as they happen, then one summary line (yellow when
		-- anything failed). debug_verbose_boot prints every check's details as before.
		local verbose = FeatureFlags.get("debug_verbose_boot") == true
		local specsPassed, specsFailed = require(script.Tests.TestRunner).run(script.Tests, verbose)
		local examplesPassed, examplesFailed = require(script.Tests.MagicExamples)()
		local summary = string.format(
			"Boot checks: specs %d/%d · magic examples %d/%d%s",
			specsPassed,
			specsPassed + specsFailed,
			examplesPassed,
			examplesPassed + examplesFailed,
			if verbose then "" else "  (details: flag debug_verbose_boot)"
		)
		if specsFailed + examplesFailed > 0 then
			warn(summary)
		else
			print(summary)
		end
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
