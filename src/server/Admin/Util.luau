--!strict
--[[
	Util: helpers shared by the admin command modules (Server/Admin/Commands/*).
	Nothing here is reachable by players: only AdminService handlers call it.
]]

local Players = game:GetService("Players")

local Util = {}

function Util.rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

function Util.humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function Util.fmt(v: Vector3): string
	return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z)
end

-- Where the player is looking, `distance` studs ahead at ground level (the default "at").
function Util.ahead(player: Player, world: any, distance: number): Vector3?
	local root = Util.rootOf(player)
	if not root then
		return nil
	end
	local p = root.Position + root.CFrame.LookVector * distance
	return Vector3.new(p.X, world:surfaceHeight(p.X, p.Z), p.Z)
end

--[[
	Moves a player's character to a position. `snap` puts them on the ground near (x, z) (dry land
	within 64 studs); without it the exact point is used (tp up/down, coordinates with a height).
	Builds the terrain there first (up to 6 s), asks streaming for the area, then pivots.
]]
function Util.teleport(player: Player, world: any, target: Vector3, snap: boolean): (boolean, string)
	local character = player.Character
	if not character then
		return false, "no character"
	end
	local destination = target
	if snap then
		local x, y, z = world:findDryLand(target.X, target.Z, 64)
		destination = Vector3.new(x, y + 4, z)
	end
	world:requestArea(destination.X, destination.Z, 1)
	local waited = 0
	while not world:isChunkBuilt(destination.X, destination.Z) and waited < 6 do
		task.wait(0.25)
		waited += 0.25
	end
	pcall(function()
		player:RequestStreamAroundAsync(destination, 5)
	end)
	if not player.Parent or player.Character ~= character then
		return false, "character changed while teleporting"
	end
	character:PivotTo(CFrame.new(destination))
	local root = Util.rootOf(player)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
	end
	return true, "teleported to " .. Util.fmt(destination)
end

function Util.findPlayerByUserId(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end

-- "a,b c" -> { "a", "b", "c" } (commas or spaces).
function Util.splitList(text: string?): { string }
	local out = {}
	for word in string.gmatch(text or "", "[^,%s]+") do
		table.insert(out, word)
	end
	return out
end

return Util
