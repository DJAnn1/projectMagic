--!strict
-- Client entry point: binds Net, shows the main menu until a save file is open, then boots every
-- controller in Controllers/ in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bootstrap = require(Shared.Core.Bootstrap)
local Logger = require(Shared.Core.Logger)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)

Logger.setLevel(FeatureFlags.get("log_level") or "Info")
Net.start()

-- The main menu and file select come first (Menu/MainMenu, Services/SaveFileService): every
-- controller below assumes a loaded save, so the client boots only once a file is open.
require(script:WaitForChild("Menu"):WaitForChild("MainMenu")).run()

local app = Bootstrap.new("Client")
app:addFolder(script:WaitForChild("Controllers"))
app:run()
