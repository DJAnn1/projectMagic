--!strict
--[[
	PreferencesService: reads and writes the player's interface settings (PlayerData.settings).

	The allowed settings and values live in Shared/UI/Settings, which the client also uses to
	build its Settings screen. Only ids declared there are readable or writable from a client;
	anything else in `settings` (consoleKey) is server-managed.

		RequestSettings()            -> { [id]: value }
		SetSetting(id, value)        -> (true, value) | (false, reason)
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local UISettings = require(Shared.UI.Settings)

local PreferencesService = {
	name = "PreferencesService",
	dependencies = { "NetService", "PlayerDataService" },
}

local playerData: any = nil

-- Every client-visible setting, with the default where the save has no (or an invalid) value.
local function viewFor(settings: { [string]: any }): { [string]: any }
	local view: { [string]: any } = {}
	for id, def in UISettings do
		local value = settings[id]
		view[id] = if table.find(def.options, value) then value else def.default
	end
	return view
end

function PreferencesService.get(_self: any, player: Player, id: string): any
	local state = playerData:get(player)
	local def = UISettings[id]
	if not state or not def then
		return def and def.default
	end
	return viewFor(state.data.settings)[id]
end

function PreferencesService.init(_self: any, ctx: any)
	playerData = ctx.get("PlayerDataService")

	Net.handle("RequestSettings", function(player: Player)
		local state = playerData:get(player)
		if not state then
			return nil
		end
		return viewFor(state.data.settings)
	end)

	Net.handle("SetSetting", function(player: Player, id: string, value: any)
		local state = playerData:get(player)
		if not state then
			return false, "NOT_LOADED"
		end
		local def = UISettings[id]
		if not def then
			return false, "UNKNOWN_SETTING"
		end
		if not table.find(def.options, value) then
			return false, "BAD_VALUE"
		end
		state.data.settings[id] = value
		return true, value
	end)
end

return PreferencesService
