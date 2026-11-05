--!strict
-- Client entry point: binds Net, then boots every controller in Controllers/ in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bootstrap = require(Shared.Core.Bootstrap)
local Logger = require(Shared.Core.Logger)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)

Logger.setLevel(FeatureFlags.get("log_level") or "Info")
Net.start()

local app = Bootstrap.new("Client")
app:addFolder(script:WaitForChild("Controllers"))
app:run()
