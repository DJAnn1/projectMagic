--!strict
--[[
	ElementalService: the people side of summoned elementals (docs/SpellOverhaul.md §8, stage 3b).
	The body and the fight live in Cast/Elementals (Cast/Shapes summons them). This service:
		- tells Elementals who is fighting whom among players (Topics.TargetDamaged): whoever a
		  summoner hits, whoever hits a summoner, whoever hits someone's elemental. Non-players
		  (Wildborn, creatures, NPC mages) are caught in Cast/Elementals through Damage.listenAttacked;
		- lets a player's elementals go when they leave;
		- writes the log.

	Admin: `elementals [list|clear] [player]`, `elementalfor <branch> [power] [tier]`.
	Log: elemental_summoned, elemental_faded, elemental_killed, elemental_refused.
	Flag: elementals_enabled.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Topics = require(Shared.Core.Topics)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Registry = require(Shared.Magic.Registry)
local Elemental = require(Shared.Magic.Elemental)
local Data = require(Shared.Magic.Data.Elementals)
local Elementals = require(ServerScriptService.Server.Magic.Cast.Elementals)

local ElementalService = {
	name = "ElementalService",
	dependencies = { "AdminService" },
}

local function onDamaged(payload: any)
	local source = payload.sourceUserId
	local model = payload.model
	if typeof(source) ~= "number" or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local sourcePlayer = Players:GetPlayerByUserId(source)
	local sourceCharacter = sourcePlayer and sourcePlayer.Character
	if model == sourceCharacter then
		return -- hurt themselves
	end
	-- The summoner fought someone: their elementals join in.
	Elementals.noteThreat(source, model)
	if not sourceCharacter then
		return
	end
	-- Someone fought a summoner, or a summoner's elemental: it fights them back.
	local victim = Players:GetPlayerFromCharacter(model)
	local owner = if victim then victim.UserId else model:GetAttribute("ElementalOwner")
	if typeof(owner) == "number" and owner ~= source then
		Elementals.noteThreat(owner, sourceCharacter)
	end
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "elementals",
		category = "Magic",
		description = "Summoned elementals (spell overhaul stage 3b): `list` shows each one (summoner, kind, health, seconds left, target); `clear` lets them go (one player's, or everyone's with no player)",
		args = {
			{ name = "action", type = "enum", options = { "list", "clear" }, default = "list" },
			{ name = "player", type = "string", default = "" },
		},
		handler = function(ctx: any, a: any)
			local who: Player? = nil
			if a.player ~= "" then
				local lower = string.lower(a.player)
				for _, p in Players:GetPlayers() do
					if string.lower(p.Name) == lower or (lower == "me" and p == ctx.player) then
						who = p
					end
				end
				if lower == "me" and not who then
					who = ctx.player
				end
			end
			if a.action == "clear" then
				return string.format("let %d go", Elementals.clear(if who then who.UserId else nil))
			end
			local lines = { string.format("%d alive (max %d) · flag %s", Elementals.count(), Data.tuning.maxAlive, tostring(FeatureFlags.get("elementals_enabled"))) }
			local now = os.clock()
			for _, e in Elementals.list() do
				if not who or e.ownerId == who.UserId then
					table.insert(lines, string.format(
						"  #%d %s (%s) of %s · %d/%d hp · %.0f s left · blow share %.2f · %s",
						e.id, e.def.name, e.def.style, e.owner.Name, math.floor(e.humanoid.Health), math.floor(e.humanoid.MaxHealth),
						math.max(0, e.ends - now), e.share, if e.target then "fighting " .. e.target.Name else "following"
					))
				end
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "elementalfor",
		category = "Magic",
		description = "Which elemental a branch's harmful Summon spell gives, and how strong it is at a power and mastery tier (0-8)",
		args = {
			{ name = "branch", type = "string" },
			{ name = "power", type = "number", default = 5 },
			{ name = "tier", type = "number", default = 5 },
		},
		handler = function(_ctx: any, a: any)
			if not Registry.branches[a.branch] then
				return "no branch called " .. tostring(a.branch)
			end
			local power = math.clamp(math.floor(a.power), 1, 10)
			local tier = math.clamp(math.floor(a.tier), 0, 8)
			local def, style = Elemental.forBranch(a.branch)
			return string.format(
				"%s: %s (%s, %s) · health %d · blow share %.2f every %.1f s, reach %.0f · %d at once at tier %d · %d s\n%s",
				a.branch, def.name, def.style, def.material, Elemental.health(def, power, tier), Elemental.share(style, tier),
				style.every, style.reach, Elemental.limit(tier), tier, Data.tuning.seconds, Elemental.words(a.branch)
			)
		end,
	})
end

function ElementalService.init(_self: any, ctx: any)
	local log = ctx.log
	Elementals.onEvent = function(event: string, fields: { [string]: any })
		log:info(event, fields)
	end
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	Players.PlayerRemoving:Connect(function(player: Player)
		Elementals.forget(player.UserId)
	end)
	registerAdmin(ctx.get("AdminService"))
end

function ElementalService.start(_self: any, _ctx: any) end

return ElementalService
