--!strict
--[[
	AttunementService: the spell a player holds ready in equip mode (docs/Casting.md §6).

	EQUIP MODE (setting castMode = "equip", the default): a hotbar key attunes that slot's spell
	(AttuneSpell(slot)); the mouse button casts it; the same key again, or Q, stows it
	(AttuneSpell(0)). While attuned:
	    - CastService refuses any client cast that isn't the attuned spell (NOT_ATTUNED);
	    - the character's action state is "equipping" (Equip clip) then "holding" (Hold loop),
	      and it returns to "holding" after every cast (it would otherwise end at idle);
	    - walk speed is x CastTuning.attunedWalkMult (StatusEffects.setWalkMultiplier);
	    - character attributes AttunedDomain / AttunedForm let every client draw the hand glow
	      (and, later, reticles) without being sent the recipe.
	QUICK MODE: a hotbar key casts at once; nothing here applies and attuning is refused.

	Server-authoritative: the client only names a slot. The key comes from the player's own saved
	hotbar and spellbook; the body must be free to equip (Cast/ActionState: not mid-cast, not
	knocked down, not dashing); swaps are rate-limited (attuneSwapCooldown) on top of the remote's
	own limit. Death, respawn and leaving clear it.

		AttuneSpell(slot) -> (true, key) | (true, nil) for a stow | (false, reason)
		reasons: NOT_LOADED, QUICK_MODE, TOO_FAST, DEAD, BUSY, EMPTY_SLOT, NO_SUCH_SPELL

	API: attunedKey(player) -> string?, allowsCast(player, key) -> boolean, stow(player)
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)

local Magic = script.Parent.Parent.Magic
local T = require(Magic.Data.CastTuning)
local ActionState = require(Magic.Cast.ActionState)
local StatusEffects = require(Magic.Cast.StatusEffects)
local Guard = require(Magic.Cast.Guard)

local AttunementService = {
	name = "AttunementService",
	dependencies = { "NetService", "PlayerDataService", "SpellbookService", "PreferencesService" },
}

type Attuned = {
	key: string,
	slot: number,
	domain: string,
	character: Model,
}

local log: any = nil
local playerData: any = nil
local spellbook: any = nil
local preferences: any = nil

local attuned: { [Player]: Attuned } = {}
local lastRequest: { [Player]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function equipMode(player: Player): boolean
	return preferences:get(player, "castMode") == "equip"
end

local function humanoidOf(character: Model?): Humanoid?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then humanoid else nil
end

local function clearBody(character: Model)
	character:SetAttribute("AttunedDomain", nil)
	character:SetAttribute("AttunedForm", nil)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		StatusEffects.setWalkMultiplier(humanoid, "attuned", nil)
	end
end

function AttunementService.attunedKey(_self: any, player: Player): string?
	local a = attuned[player]
	return if a and a.character == player.Character then a.key else nil
end

function AttunementService.equipMode(_self: any, player: Player): boolean
	return equipMode(player)
end

-- The attuned spell's saved recipe (hold-to-charge reads its cast time), if any.
function AttunementService.attunedRecipe(self: any, player: Player): any?
	local key = self:attunedKey(player)
	return if key then spellbook:recipeOf(player, key) else nil
end

-- May this client cast `key`? Quick mode: anything. Equip mode: only the attuned spell.
function AttunementService.allowsCast(self: any, player: Player, key: string): boolean
	if not equipMode(player) then
		if attuned[player] then
			self:stow(player) -- switched to quick mode while holding a spell
		end
		return true
	end
	return self:attunedKey(player) == key
end

function AttunementService.stow(_self: any, player: Player)
	local a = attuned[player]
	attuned[player] = nil -- first, so the "idle -> holding" rule below doesn't put it back
	if not a then
		return
	end
	clearBody(a.character)
	if Guard.isGuarding(a.character) then
		Guard.lower(a.character) -- the ward goes with the spell
	end
	if a.character.Parent then
		ActionState.clear(a.character, "holding")
		ActionState.clear(a.character, "equipping")
	end
end

local function attune(player: Player, slot: number): (boolean, string?)
	local state = playerData:get(player)
	if not state then
		return false, "NOT_LOADED"
	end
	local t = now()
	if t - (lastRequest[player] or 0) < T.attuneSwapCooldown then
		return false, "TOO_FAST"
	end
	lastRequest[player] = t

	if slot == 0 then
		AttunementService:stow(player)
		return true, nil
	end
	if not equipMode(player) then
		return false, "QUICK_MODE"
	end
	local character = player.Character
	local humanoid = humanoidOf(character)
	if not character or not humanoid then
		return false, "DEAD"
	end
	if not ActionState.can(character, "equip") then
		return false, "BUSY"
	end
	local key = spellbook:hotbarKey(player, slot)
	if not key then
		return false, "EMPTY_SLOT"
	end
	local recipe = spellbook:recipeOf(player, key)
	if not recipe then
		return false, "NO_SUCH_SPELL"
	end

	local previous = attuned[player]
	if previous and previous.character ~= character then
		clearBody(previous.character)
	end
	local branch = Registry.branches[recipe.branch]
	local domain = if branch then branch.domains[1] else "energy"
	attuned[player] = { key = key, slot = slot, domain = domain, character = character }
	character:SetAttribute("AttunedDomain", domain)
	character:SetAttribute("AttunedForm", recipe.form)
	StatusEffects.setWalkMultiplier(humanoid, "attuned", T.attunedWalkMult)
	ActionState.set(character, "equipping", { domain = domain })
	log:debug("attuned", { userId = player.UserId, slot = slot, key = key })
	return true, key
end

-- After any action ends at idle (a cast, a forced stagger wearing off), an attuned player is
-- holding their spell again.
local function onActionChanged(model: Model, state: string)
	if state ~= "idle" then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	local a = player and attuned[player]
	if a and a.character == model and humanoidOf(model) then
		ActionState.set(model, "holding", { domain = a.domain })
	end
end

function AttunementService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	spellbook = ctx.get("SpellbookService")
	preferences = ctx.get("PreferencesService")
	Net.handle("AttuneSpell", attune)
	ActionState.changed:Connect(onActionChanged)
end

function AttunementService.start(_self: any, _ctx: any)
	local function onCharacter(player: Player, character: Model)
		-- A new body holds nothing.
		local a = attuned[player]
		if a and a.character ~= character then
			attuned[player] = nil
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				local current = attuned[player]
				if current and current.character == character then
					AttunementService:stow(player)
				end
			end)
		end
	end
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		attuned[player] = nil
		lastRequest[player] = nil
	end)
end

return AttunementService
