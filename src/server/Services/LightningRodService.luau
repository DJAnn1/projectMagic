--!strict
--[[
	LightningRodService: the people side of "metal draws lightning" (docs/LightningRods.md).

	The physics lives in Cast/LightningRods (CastService.strike calls it). This service:
		- tells LightningRods how much metal a PLAYER wears: equipped items tagged "metal", by item
		  weight (NPC gear is read there from Gear_<slot> attributes);
		- writes the Journal, once per kind, ever (shared with weather notes in data.weather.noted):
		    rod_metal    your lightning bent into metal and grounded
		    rod_person   your lightning swerved into someone wearing metal
		    rod_drawn    someone else's lightning came to YOU because of what you wear
		  No toast: you saw the bolt jump, the Journal is where you make sense of it.

	Admin: `rods [power] [player]` reads what would draw a bolt landing where they stand.
	Log: `lightning_bent` { userId, kind, onto? }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local LightningRods = require(ServerScriptService.Server.Magic.Cast.LightningRods)
local R = require(ServerScriptService.Server.Magic.Data.LightningRods)

local LightningRodService = {
	name = "LightningRodService",
	dependencies = { "AdminService", "InventoryService", "JournalService", "PlayerDataService" },
}

local LINES: { [string]: string } = {
	rod_metal = "I threw lightning and it never reached where I aimed. It bent sideways into a piece of iron and the metal took all of it. Metal calls to lightning.",
	rod_person = "My lightning swerved off its mark and found the one wearing metal instead. I should remember that before I cast near anyone in armour.",
	rod_drawn = "Someone's lightning was meant for another, and it came to me instead. I think it was what I'm wearing. Metal calls it.",
}

local log: any = nil
local journal: any = nil
local inventory: any = nil
local playerData: any = nil

-- A player's worn metal, by item weight.
local function playerMetal(model: Model): number
	local player = Players:GetPlayerFromCharacter(model)
	local inv = player and inventory:inventoryOf(player)
	if not inv then
		return 0
	end
	local weight = 0
	for _, rec in inv.equip do
		local def = ItemDatabase.get(rec.i)
		if def and table.find(def.tags or {}, "metal") then
			weight += def.weight or 0
		end
	end
	return weight
end

local function note(player: Player, key: string)
	local state = playerData:get(player)
	if not state then
		return
	end
	local data = state.data
	data.weather = data.weather or { noted = {} }
	data.weather.noted = data.weather.noted or {}
	if data.weather.noted[key] then
		return
	end
	data.weather.noted[key] = os.time()
	journal:log(player, "weather", LINES[key], { rule = key })
end

local function onSpell(payload: any)
	local kind = payload.bentTo
	if not kind or FeatureFlags.get("lightning_rods_enabled") ~= true then
		return
	end
	local caster = Players:GetPlayerByUserId(payload.casterUserId)
	local onto: Model? = payload.bentOnto
	local victim = if onto then Players:GetPlayerFromCharacter(onto) else nil
	log:info("lightning_bent", { userId = payload.casterUserId, kind = kind, onto = if onto then onto.Name else nil })
	if caster then
		note(caster, if kind == "metal" then "rod_metal" else "rod_person")
	end
	if victim and victim ~= caster then
		note(victim, "rod_drawn")
	end
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "rods",
		category = "Magic",
		description = "What would draw a lightning bolt landing where a player stands: the reach at that power (and the storm here), their own worn metal, and every rod or armoured person in reach with its pull",
		args = {
			{ name = "power", type = "number", default = 4 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local character = a.player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not character or not root then
				return "they have no body right now"
			end
			local power = math.clamp(tonumber(a.power) or 4, 1, 10)
			local radius = LightningRods.radiusFor(power, 0)
			local lines = {
				string.format(
					"power %d · reach %.1f studs (no storm) · %s wears %.1f metal (pull %.2f) · stay %.2f · flag %s",
					power, radius, a.player.Name, LightningRods.metalWeight(character),
					LightningRods.weightPull(LightningRods.metalWeight(character)), R.stay,
					tostring(FeatureFlags.get("lightning_rods_enabled"))
				),
			}
			local params = OverlapParams.new()
			params.MaxParts = R.maxQueryParts
			local seen: { [Instance]: boolean } = { [character] = true }
			local count = 0
			for _, part in workspace:GetPartBoundsInRadius(root.Position, radius, params) do
				local model = part:FindFirstAncestorOfClass("Model")
				if model and model:FindFirstChildOfClass("Humanoid") then
					if not seen[model] then
						seen[model] = true
						local pull = LightningRods.weightPull(LightningRods.metalWeight(model))
						if pull > 0 then
							local d = (part.Position - root.Position).Magnitude
							table.insert(lines, string.format("  person %s: pull %.2f at %.0f studs → score %.2f", model.Name, pull, d, LightningRods.score(pull, d, radius)))
							count += 1
						end
					end
				elseif part.Material == Enum.Material.Metal or part.Material == Enum.Material.DiamondPlate
					or part.Material == Enum.Material.CorrodedMetal or part.Material == Enum.Material.Foil then
					local pull = LightningRods.partPull(part.Size)
					if pull > 0 then
						local d = (part.Position - root.Position).Magnitude
						table.insert(lines, string.format("  metal %s: pull %.2f at %.0f studs → score %.2f", part:GetFullName(), pull, d, LightningRods.score(pull, d, radius)))
						count += 1
					end
				end
				if count >= 12 then
					table.insert(lines, "  (more not shown)")
					break
				end
			end
			if count == 0 then
				table.insert(lines, "  nothing here would draw it")
			end
			return table.concat(lines, "\n")
		end,
	})
end

function LightningRodService.init(_self: any, ctx: any)
	log = ctx.log
	journal = ctx.get("JournalService")
	inventory = ctx.get("InventoryService")
	playerData = ctx.get("PlayerDataService")
	LightningRods.setMetalProvider(playerMetal)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	registerAdmin(ctx.get("AdminService"))
end

function LightningRodService.start(_self: any, _ctx: any) end

return LightningRodService
