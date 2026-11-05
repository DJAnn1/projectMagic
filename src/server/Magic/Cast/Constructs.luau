--!strict
--[[
	Constructs: lifetime and per-player caps for things spells leave in the world (walls, pillars,
	lights). Every construct is tagged "MagicConstruct" with an OwnerUserId attribute, expires
	after its lifetime, and a player never has more than CastTuning.budget.maxConstructsPerPlayer alive:
	making one more removes their oldest.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local T = require(script.Parent.Parent.Data.CastTuning)

local Constructs = {}

local live: { [number]: { Instance } } = {}

function Constructs.track(player: Player, instance: Instance, lifetime: number)
	CollectionService:AddTag(instance, "MagicConstruct")
	instance:SetAttribute("OwnerUserId", player.UserId)
	Debris:AddItem(instance, lifetime)

	local list = live[player.UserId] or {}
	live[player.UserId] = list
	-- Forget expired ones, then make room.
	for i = #list, 1, -1 do
		if not list[i].Parent then
			table.remove(list, i)
		end
	end
	while #list >= T.budget.maxConstructsPerPlayer do
		local oldest = table.remove(list, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	table.insert(list, instance)
end

Players.PlayerRemoving:Connect(function(player)
	live[player.UserId] = nil -- their constructs still expire on their own timers
end)

return Constructs
