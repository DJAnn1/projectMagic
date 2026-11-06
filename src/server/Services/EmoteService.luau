--!strict
--[[
	EmoteService: gestures and flourishes (docs/Social.md §5). Data in Shared/Social/Data/Emotes.

		EmoteIntent(id | "stop")   the server checks you're alive and not busy, and the cooldown
		EmoteCue { u, id, on, hide? }  sent to everyone in range when it starts, and to the same people
		                           when it ends. Each client draws poses and flourishes itself.
		hide       this viewer has blocked you, or set Settings › Emotes from others to exclude you.
		           The cue still goes out only so that client can also stop the replicated clip;
		           it draws nothing.

	Emotes are purely cosmetic: no XP, no regen, no status and no effect on hitboxes. An emote ends
	when you move, when your body gets busy (casting, blocking, a hit reaction), when you die, or at
	its time limit. So nobody can stand inside a pose to dodge anything, and there's nothing to farm.

	Budget: cues only when emotes start and stop, limited by the cooldown (and the remote's rate);
	a 4 Hz check runs only over players currently emoting.

	Admin: emote.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Emotes = require(Shared.Social.Data.Emotes)

local ActionState = require(script.Parent.Parent.Magic.Cast.ActionState)

local CHECK_HZ = 4

type Active = {
	id: string,
	expires: number,
	at: Vector3,
	viewers: { Player },
}

local EmoteService = {
	name = "EmoteService",
	dependencies = { "NetService", "PartyService", "SocialSafetyService", "AdminService" },
}

local flags: any = nil
local parties: any = nil
local safety: any = nil

local active: { [Player]: Active } = {}
local readyAt: { [Player]: number } = {}

local function rootOf(player: Player): BasePart?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function stop(player: Player)
	local entry = active[player]
	if not entry then
		return
	end
	active[player] = nil
	local cue = { u = player.UserId, id = entry.id, on = false }
	for _, viewer in entry.viewers do
		if viewer.Parent then
			Net.fire("EmoteCue", viewer, cue)
		end
	end
end

-- Starts an emote for `player`. Returns a refusal reason, or nil. `force` skips the cooldown (admin).
local function begin(player: Player, id: string, force: boolean?): string?
	local def = Emotes.byId[id]
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = rootOf(player)
	if not def or not character or not humanoid or humanoid.Health <= 0 or not root then
		return "NOT_NOW"
	end
	if flags.get("emotes_enabled") == false then
		return "OFF"
	end
	if ActionState.get(character) ~= "idle" then
		return "BUSY"
	end
	local t = os.clock()
	if not force and t < (readyAt[player] or 0) then
		return "COOLDOWN"
	end
	readyAt[player] = t + def.cooldown
	stop(player)

	local viewers: { Player } = {}
	for _, viewer in Players:GetPlayers() do
		local viewerRoot = rootOf(viewer)
		if viewer == player or (viewerRoot and (viewerRoot.Position - root.Position).Magnitude <= Emotes.range) then
			table.insert(viewers, viewer)
			local visible = safety:emoteVisible(viewer, player, parties:sameParty(viewer.UserId, player.UserId))
			Net.fire("EmoteCue", viewer, { u = player.UserId, id = id, on = true, hide = if visible then nil else true })
		end
	end
	active[player] = { id = id, expires = t + def.seconds, at = root.Position, viewers = viewers }
	return nil
end

local function check()
	local t = os.clock()
	for player, entry in active do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = rootOf(player)
		local flat = if root then Vector3.new(root.Position.X - entry.at.X, 0, root.Position.Z - entry.at.Z).Magnitude else math.huge
		if t >= entry.expires
			or not character
			or not humanoid
			or humanoid.Health <= 0
			or flat > Emotes.moveLimit
			or ActionState.get(character) ~= "idle"
		then
			stop(player)
		end
	end
end

function EmoteService.init(_self: any, ctx: any)
	flags = ctx.flags
	parties = ctx.get("PartyService")
	safety = ctx.get("SocialSafetyService")
	Net.on("EmoteIntent", function(player: Player, id: string)
		if id == "stop" then
			stop(player)
			return
		end
		local reason = begin(player, id)
		if reason == "BUSY" then
			Net.fire("Notify", player, "You can't do that right now.")
		end
	end)
	local ids: { string } = {}
	for _, def in Emotes.list do
		table.insert(ids, def.id)
	end
	ctx.get("AdminService"):Register({
		name = "emote",
		category = "Social",
		description = "Make a player do an emote (no cooldown)",
		args = {
			{ name = "id", type = "enum", options = ids },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local reason = begin(a.player, a.id, true)
			return if reason then "Refused: " .. reason else a.player.Name .. " does " .. a.id
		end,
	})
end

function EmoteService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		stop(player)
		readyAt[player] = nil
	end)
	while true do
		task.wait(1 / CHECK_HZ)
		if next(active) then
			check()
		end
	end
end

return EmoteService
