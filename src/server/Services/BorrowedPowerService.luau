--!strict
--[[
	BorrowedPowerService: a relic gives anyone a minute of mythic magic (docs/Moments.md).
	Data: Shared/Magic/Data/BorrowedPowers. Items: time_relic, gravity_relic (ItemUse's "borrow" effect).

	The spells are real: they go through CastService with knowledge and tier waived (castBorrowed), at
	the relic's tier, free and with no backlash. But it isn't yours, so it teaches nothing: no XP, no
	discoveries, no spellbook, and no mythic notoriety, so the Quiet Hand doesn't come for a farmer who
	once held a stopped clock.

	BorrowedCast(index, aim, target?)   an ability, by its place in the relic's list
	Player attributes BorrowedPower (relic id), BorrowedUntil. A flight you took ends with the minute. A
	mark or a stored moment you made runs its own course.

	Flag: borrowed_powers_enabled. Admin: borrowed <time | gravity | end> [player].
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Data = require(Shared.Magic.Data.BorrowedPowers)

local Server = script.Parent.Parent
local GravityRuntime = require(Server.Magic.Cast.GravityRuntime)

local BorrowedPowerService = {
	name = "BorrowedPowerService",
	dependencies = { "NetService", "AdminService", "CastService", "EffectRunner" },
}

type Active = { relic: Data.Relic, expires: number }

local log: any = nil
local cast: any = nil
local runner: any = nil
local active: { [Player]: Active } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

function BorrowedPowerService.isActive(_self: any, player: Player): boolean
	return active[player] ~= nil
end

-- Starts a relic's minute. Returns why not, or nil.
function BorrowedPowerService.begin(_self: any, player: Player, relicId: string): string?
	local relic = Data.relics[relicId]
	if not relic then
		return "UNKNOWN_EFFECT"
	end
	if FeatureFlags.get("borrowed_powers_enabled") ~= true then
		return "NOTHING_TO_DO"
	end
	if active[player] then
		return "ALREADY_BORROWING"
	end
	local expires = now() + relic.seconds
	active[player] = { relic = relic, expires = expires }
	player:SetAttribute("BorrowedUntil", expires)
	player:SetAttribute("BorrowedPower", relic.id)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		runner:cue("surge", { fx = "borrow", domain = relic.domain, caster = player.UserId }, root.Position, true)
	end
	Net.fire("Notify", player, relic.line)
	log:info("borrowed_power", { userId = player.UserId, relic = relic.id })
	return nil
end

local function finish(player: Player)
	if not active[player] then
		return
	end
	active[player] = nil
	player:SetAttribute("BorrowedPower", nil)
	player:SetAttribute("BorrowedUntil", nil)
	GravityRuntime.endBorrowedFlight(player)
	if player.Parent then
		Net.fire("Notify", player, "The power leaves you. It was never really yours.")
	end
end

local function onCast(player: Player, index: number, aim: Vector3, target: Model?)
	local entry = active[player]
	if not entry or now() >= entry.expires then
		return
	end
	local ability = entry.relic.abilities[index]
	if ability then
		cast:castBorrowed(player, ability.recipe, aim, target, entry.relic.tier)
	end
end

function BorrowedPowerService.init(_self: any, ctx: any)
	log = ctx.log
	cast = ctx.get("CastService")
	runner = ctx.get("EffectRunner")
	Net.on("BorrowedCast", onCast :: any)
	ctx.get("AdminService"):Register({
		name = "borrowed",
		category = "Spells",
		description = "Give a player a relic's minute of mythic power, with no relic, or end it",
		args = {
			{ name = "relic", type = "enum", options = { "time", "gravity", "end" } },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			if a.relic == "end" then
				finish(a.player)
				return "ended"
			end
			local reason = BorrowedPowerService:begin(a.player, a.relic)
			return reason or (a.relic .. " for a minute")
		end,
	})
end

function BorrowedPowerService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		active[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			local t = now()
			for player, entry in table.clone(active) do
				if t >= entry.expires then
					finish(player)
				end
			end
		end
	end)
end

return BorrowedPowerService
