--!strict
--[[
	Innate profile tools. They rewrite the player's REAL innate profile (it is save data).

	affinity <domain|all> <0..1> [awaken]   awaken (default on): >0 joins the manifest, 0 leaves it
	capacity <x> · regen <x>                innate reservoir capacity / regen multipliers
	temperament <add|remove|clear> [id]     conflicting temperaments are replaced, as in play
	growth <curve>                          early | steady | late | breakthrough
	signature <primary|secondary|accent|random> [hex]
	reroll [seed]                           a new profile ("player:<id>#<seed>"); progression kept
	forcerarity <tier> [mythic domain]      rerolls until the TRUE rarity matches (Mythic: forced)
	awaken <event> [domain]                 the awakening event now, its triggers and cooldown waived
	revealall                               every hidden latent revealed
]]

local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Temperaments = require(Shared.Magic.Data.Temperaments)
local Server = script.Parent.Parent.Parent
local InnateProfile = require(Server.Magic.InnateProfile)
local ProfileGenerator = require(Server.Magic.ProfileGenerator)
local ProfileTuning = require(Server.Magic.Data.ProfileTuning)
local AwakeningEvents = require(Server.Magic.Data.AwakeningEvents)

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }
local MAX_REROLLS = 20000

return function(admin: any, deps: any)
	local playerData = deps.playerData
	local progression = deps.progression
	local worldService = deps.worldService

	local function needState(player: Player): any
		local state = playerData:get(player)
		if not state then
			error(player.Name .. "'s data isn't loaded", 0)
		end
		return state
	end

	local function sortManifest(innate: any)
		table.sort(innate.manifest, function(x, y)
			local vx, vy = innate.domains[x] or 0, innate.domains[y] or 0
			if vx ~= vy then
				return vx > vy
			end
			return x < y
		end)
	end

	-- After any profile change: caster, reservoir, roots for new domains, signature attribute, client.
	local function applied(player: Player, state: any)
		sortManifest(state.innate)
		state.data.profile = state.innate
		player:SetAttribute("MagicSignature", HttpService:JSONEncode(state.innate.signature))
		progression:syncInnate(player)
		deps.refreshPlayer(player, { { kind = "fact", fact = "admin", id = "profile" } })
	end

	admin:Register({
		name = "affinity", category = "Profile", description = "Set innate affinity for a domain (or all)",
		args = {
			{ name = "domain", type = "string", hint = "a domain id or all" },
			{ name = "value", type = "number", min = 0, max = 1, slider = true },
			{ name = "awaken", type = "boolean", default = true, hint = "add to / remove from the manifest" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local innate = state.innate
			local list: { string } = if string.lower(a.domain) == "all" then Registry.domainIds else { string.lower(a.domain) }
			for _, d in list do
				if not Registry.domains[d] then
					return "no domain '" .. d .. "'"
				end
				innate.domains[d] = a.value
				if a.awaken then
					local i = table.find(innate.manifest, d)
					if a.value > 0 and not i then
						table.insert(innate.manifest, d)
					elseif a.value <= 0 and i then
						table.remove(innate.manifest, i)
					end
				end
			end
			applied(a.player, state)
			return string.format("affinity %s = %.2f; manifest: %s", a.domain, a.value, table.concat(innate.manifest, ", "))
		end,
	})

	admin:Register({
		name = "capacity", category = "Profile", description = "Innate reservoir capacity multiplier (1 = average)",
		args = { { name = "value", type = "number", min = 0.1, max = 20, slider = true }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			state.innate.capacity = a.value
			applied(a.player, state)
			return string.format("capacity x%.2f (reservoir multiplier with temperaments: x%.2f)", a.value, InnateProfile.traits(state.innate).capacity)
		end,
	})

	admin:Register({
		name = "regen", category = "Profile", description = "Innate reservoir regeneration multiplier (1 = average)",
		args = { { name = "value", type = "number", min = 0, max = 50, slider = true }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			state.innate.regen = a.value
			applied(a.player, state)
			return string.format("regen x%.2f (with temperaments: x%.2f)", a.value, InnateProfile.traits(state.innate).regen)
		end,
	})

	admin:Register({
		name = "temperament", category = "Profile", description = "Add, remove or clear temperaments (conflicts are replaced)",
		args = {
			{ name = "action", type = "enum", options = { "add", "remove", "clear", "list" } },
			{ name = "id", type = "temperament", optional = true },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local list = state.innate.temperaments
			if a.action == "list" then
				return "temperaments: " .. (if #list > 0 then table.concat(list, ", ") else "none")
			elseif a.action == "clear" then
				table.clear(list)
			elseif not a.id then
				return "temperament " .. a.action .. " needs an id"
			elseif a.action == "remove" then
				local i = table.find(list, a.id)
				if i then
					table.remove(list, i)
				end
			elseif not table.find(list, a.id) then
				for i = #list, 1, -1 do
					if ProfileGenerator.temperamentsConflict(list[i], a.id) then
						table.remove(list, i)
					end
				end
				table.insert(list, a.id)
			end
			applied(a.player, state)
			return "temperaments: " .. (if #list > 0 then table.concat(list, ", ") else "none") .. (if a.id and Temperaments[a.id] then " | " .. Temperaments[a.id].description else "")
		end,
	})

	admin:Register({
		name = "growth", category = "Profile", description = "Set the growth curve (how mastery gain changes with mastery)",
		args = { { name = "curve", type = "growth" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			state.innate.growth = a.curve
			applied(a.player, state)
			return "growth curve " .. a.curve
		end,
	})

	admin:Register({
		name = "signature", category = "Profile", description = "Set your magic's signature colours (hex like #ff8800), or random",
		args = {
			{ name = "slot", type = "enum", options = { "primary", "secondary", "accent", "random" } },
			{ name = "hex", type = "string", optional = true, hint = "#rrggbb" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local sig = state.innate.signature
			if a.slot == "random" then
				local rng = Random.new()
				for _, slot in { "primary", "secondary", "accent" } do
					sig[slot] = Color3.fromHSV(rng:NextNumber(), rng:NextNumber(0.4, 1), rng:NextNumber(0.6, 1)):ToHex()
				end
			else
				local hex = string.gsub(a.hex or "", "#", "")
				local ok = #hex == 6 and pcall(Color3.fromHex, hex)
				if not ok then
					return "hex must be 6 hex digits, like #ff8800"
				end
				sig[a.slot] = string.lower(hex)
			end
			applied(a.player, state)
			return string.format("signature #%s / #%s / #%s", sig.primary, sig.secondary, sig.accent)
		end,
	})

	local function replaceProfile(player: Player, state: any, profile: any)
		state.innate = profile
		applied(player, state)
	end

	admin:Register({
		name = "reroll", category = "Profile", description = "Generate a new innate profile (optional seed); progression is kept",
		args = { { name = "seed", type = "integer", min = 0, max = 2 ^ 31, optional = true }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			local seed = a.seed or Random.new():NextInteger(1, 2 ^ 30)
			local profile = ProfileGenerator.generate(worldService:getSeed(), "player:" .. a.player.UserId .. "#" .. seed, { kind = "Player" })
			replaceProfile(a.player, state, profile)
			return string.format("rerolled with seed %d: gift %s, true rarity %s, manifest %s, temperaments %s",
				seed, profile.giftTier, InnateProfile.getRarityTier(profile, true), table.concat(profile.manifest, ","), table.concat(profile.temperaments, ","))
		end,
	})

	admin:Register({
		name = "forcerarity", category = "Profile", description = "Reroll until your TRUE rarity is this tier (Mythic carries a hidden mythic latent)",
		args = {
			{ name = "tier", type = "enum", options = RARITIES },
			{ name = "mythic", type = "mythic", optional = true, hint = "for Mythic: which domain (default random)" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local worldSeed = worldService:getSeed()
			local base = "player:" .. a.player.UserId .. "#r"
			local start = Random.new():NextInteger(1, 1e8)
			local context: any = { kind = "Player" }
			if a.tier == "Mythic" then
				local mythics = {}
				for _, d in ProfileTuning.mythic.domains do
					table.insert(mythics, d.id)
				end
				context.forceMythic = a.mythic or mythics[Random.new():NextInteger(1, #mythics)]
			end
			for i = 0, MAX_REROLLS do
				local profile = ProfileGenerator.generate(worldSeed, base .. (start + i), context)
				if InnateProfile.getRarityTier(profile, true) == a.tier then
					replaceProfile(a.player, state, profile)
					return string.format("found a %s profile after %d rerolls: gift %s, manifest %s%s", a.tier, i + 1, profile.giftTier,
						table.concat(profile.manifest, ","), if context.forceMythic then " (hidden " .. context.forceMythic .. " latent: awaken it or revealall)" else "")
				end
				if i % 400 == 399 then
					task.wait() -- let the server breathe
				end
			end
			return string.format("no %s profile in %d rerolls; try again", a.tier, MAX_REROLLS)
		end,
	})

	admin:Register({
		name = "awaken", category = "Profile", description = "Trigger an awakening event on yourself now (requirements and cooldown waived)",
		args = {
			{ name = "event", type = "awakening" },
			{ name = "domain", type = "domain", optional = true, hint = "for events that take the domain from context" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local def: any = AwakeningEvents[a.event]
			-- Facts that satisfy every requirement (the server measures these in play).
			local facts = {}
			for fact, bound in (def.requires or {}) :: { [string]: any } do
				facts[fact] = if bound.min ~= nil then bound.min elseif bound.max ~= nil then bound.max else 1
			end
			state.innate.awakenings[a.event] = nil
			local result = InnateProfile.applyAwakening(state.innate, a.event, { now = os.time(), domain = a.domain, facts = facts })
			if not result.ok then
				return "awakening refused: " .. tostring(result.reason)
			end
			applied(a.player, state)
			return string.format("%s: %s", def.name, if #result.changes > 0 then table.concat(result.changes, ", ") else "nothing hidden was reachable")
		end,
	})

	admin:Register({
		name = "revealall", category = "Profile", description = "Reveal every hidden latent potential now",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			local changes = {}
			for _, latent in state.innate.latents do
				if not latent.revealed then
					for _, c in InnateProfile.revealLatent(state.innate, latent.id) do
						table.insert(changes, c)
					end
				end
			end
			applied(a.player, state)
			return if #changes > 0 then "revealed: " .. table.concat(changes, ", ") else "nothing was hidden"
		end,
	})
end
