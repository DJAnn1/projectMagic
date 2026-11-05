--!strict
--[[
	Finisher: the spellblade's finisher window (docs/Combat.md §13). A plain module, not a service:
	MeleeService opens the window when a Slash2 lands and CastService consumes it on the next
	client cast. Keeping it here means neither service depends on the other (MeleeService needs
	InventoryService, which needs CastService: a service dependency would be a cycle).
]]

local Players = game:GetService("Players")

local Finisher = {}

local windows: { [Player]: { closesAt: number, mult: number } } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

function Finisher.open(player: Player, seconds: number, mult: number)
	windows[player] = { closesAt = now() + seconds, mult = mult }
end

-- The power multiplier for this cast (1 when no window is open). Using it closes the window.
function Finisher.consume(player: Player): number
	local w = windows[player]
	windows[player] = nil
	if w and now() <= w.closesAt then
		return w.mult
	end
	return 1
end

Players.PlayerRemoving:Connect(function(player)
	windows[player] = nil
end)

return Finisher
