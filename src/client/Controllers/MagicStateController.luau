--!strict
--[[
	MagicStateController: the client's single source of UI data. Every screen binds to the Values
	here; nothing else in the UI talks to the server.

	Values (Kit.Value; observe them, never write them from outside):
		progression   ProgressionView?      RequestProgression, refreshed after ProgressionChanged
		profile       VisibleProfile?       RequestProfileView (what you know about yourself)
		spellbook     { SpellView }         RequestSpellbook (filtered names only)
		hotbar        { [slot]: recipeKey } RequestSpellbook's second result; SetHotbarSlot
		settings      { [id]: value }       RequestSettings / SetSetting (Shared/UI/Settings)
		region        RegionView?           RegionInfo pushes (biome, density, resonance, settlement)
		reservoir     ReservoirView?        ReservoirState pushes (owner only)
		cooldowns     { [key]: serverTime } from CastResult
		known         KnownCaster.Known?    estimated caster for previews (see UI/KnownCaster)
		focusBranch   string?               the branch that most recently changed (HUD tracker)
		questPins     { QuestPin }          where your open quest objectives are (QuestPins pushes)
		statuses      { ActiveStatus }      your active statuses, soonest to end first (from the
		                                    replicated Humanoid attributes "Status_<id>" = expiry)
		ready         boolean               true once the first full load finished

	events (Signal) fires one table per happening, with `kind`:
		every ProgressionChanged entry as sent (tier, held, unlock, breakthrough, discovery,
		worldFirst, signature, commitment, renounced, fact), plus
		{ kind = "notify", text }   { kind = "cast", result }   { kind = "castSent", key }
		{ kind = "saved", key, name }

	Requests are debounced: bursts of server events cause one refetch, inside the remotes'
	rate limits (0.5/s sustained). Writes are optimistic: the UI updates at once and is corrected
	from the server's answer.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Core.Signal)
local Types = require(Shared.Magic.Types)
local MagicCore = require(Shared.Magic.MagicCore)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local KnownCaster = require(UI.KnownCaster)

export type SpellView = {
	key: string,
	name: string,
	custom: boolean,
	recipe: Types.Recipe,
	favorite: boolean,
	casts: number,
}

export type ActiveStatus = { id: string, expires: number } -- expires: server time
export type QuestPin = { q: string, title: string, text: string, p: Vector3, tracked: boolean, shared: boolean, person: boolean }

export type RegionView = {
	biome: string,
	biomeName: string,
	density: number,
	resonance: { [string]: number },
	settlement: string?,
	event: string?, -- a world event covering where you stand (AudioController: event music)
}

export type ReservoirView = {
	current: number,
	max: number,
	strain: number,
	burnoutUntil: number,
	lockouts: { [string]: number },
}

export type CastResultView = {
	ok: boolean,
	stage: string?, -- "refused" | "accepted" | "resolved" (see Services/CastService)
	key: string?,
	reason: string?,
	detail: string?,
	castTime: number?,
	effective: boolean?,
	hits: number?,
	interrupted: boolean?,
	note: string?,
	cost: number?,
	hpCost: number?,
	cooldownUntil: number?,
	backfired: boolean?,
	consequences: { Types.Consequence }?,
	xp: { branch: string, gained: number }?,
}

local DEBOUNCE = 1.5 -- seconds a burst of changes waits before one refetch
local RETRY_DELAY = 2.5
local LOAD_ATTEMPTS = 30

local MagicStateController = {
	name = "MagicStateController",
	dependencies = {},
}

local M = MagicStateController
M.progression = Kit.value(nil :: KnownCaster.ProgressionView?)
M.profile = Kit.value(nil :: Types.VisibleProfile?)
M.spellbook = Kit.value({} :: { SpellView })
M.hotbar = Kit.value({} :: { [number]: string })
M.settings = Kit.value({} :: { [string]: any })
M.region = Kit.value(nil :: RegionView?)
M.reservoir = Kit.value(nil :: ReservoirView?)
M.cooldowns = Kit.value({} :: { [string]: number })
M.known = Kit.value(nil :: KnownCaster.Known?)
M.focusBranch = Kit.value(nil :: string?)
M.ready = Kit.value(false)
M.statuses = Kit.value({} :: { ActiveStatus })
M.questPins = Kit.value({} :: { QuestPin })
M.events = Signal.new()

local log: any = nil
local spellsByKey: { [string]: SpellView } = {}
local templateCache: { [string]: { Types.RecipeTemplate } } = {}
local templateRevision = -1

-- ─── Fetching ───────────────────────────────────────────────────────────────

-- Server hotbar maps "1".."10" -> key; the client uses numeric slots.
local function toSlots(raw: any): { [number]: string }
	local slots: { [number]: string } = {}
	if typeof(raw) == "table" then
		for slot, key in raw do
			local n = tonumber(slot)
			if n and typeof(key) == "string" then
				slots[n] = key
			end
		end
	end
	return slots
end

local fetchers: { [string]: () -> boolean } = {
	progression = function()
		local ok, view = Net.invoke("RequestProgression")
		if ok and typeof(view) == "table" then
			M.progression:set(view)
			return true
		end
		return false
	end,
	profile = function()
		local ok, view = Net.invoke("RequestProfileView")
		if ok and typeof(view) == "table" then
			M.profile:set(view)
			return true
		end
		return false
	end,
	spellbook = function()
		local ok, list, hotbar = Net.invoke("RequestSpellbook")
		if ok and typeof(list) == "table" then
			M.spellbook:set(list)
			M.hotbar:set(toSlots(hotbar))
			return true
		end
		return false
	end,
	settings = function()
		local ok, settings = Net.invoke("RequestSettings")
		if ok and typeof(settings) == "table" then
			M.settings:set(settings)
			return true
		end
		return false
	end,
}

local pending: { [string]: boolean } = {}

-- Refetches `what` after a short delay; repeated calls inside the delay coalesce into one request.
function M.refresh(_self: any, what: string, delaySeconds: number?)
	if pending[what] then
		return
	end
	pending[what] = true
	task.delay(delaySeconds or DEBOUNCE, function()
		pending[what] = nil
		if not fetchers[what]() then
			-- Usually the client-side rate limit; one retry is enough, the next change refetches anyway.
			task.delay(RETRY_DELAY, fetchers[what])
		end
	end)
end

-- First load: the server answers nil until the player's data is loaded, so keep trying.
local function loadAll()
	for _, what in { "settings", "profile", "progression", "spellbook" } do
		local attempts = 0
		while not fetchers[what]() do
			attempts += 1
			if attempts >= LOAD_ATTEMPTS then
				log:warn("initial_load_failed", { what = what })
				break
			end
			task.wait(1)
		end
	end
	M.ready:set(true)
end

-- ─── Derived data ───────────────────────────────────────────────────────────

local function rebuildKnown()
	local progression = M.progression:get()
	if progression then
		M.known:set(KnownCaster.build(progression, M.profile:get()))
	end
end

function M.spell(_self: any, key: string): SpellView?
	return spellsByKey[key]
end

function M.branchView(_self: any, branchId: string): KnownCaster.BranchView?
	local progression = M.progression:get()
	if progression then
		for _, branch in progression.branches do
			if branch.id == branchId then
				return branch
			end
		end
	end
	return nil
end

-- Every (property, verb, form) the player can build from a branch, with power and modifier limits.
-- Cached per caster revision: listAvailableRecipes is too heavy to run per frame.
function M.templatesFor(_self: any, branchId: string): { Types.RecipeTemplate }
	local known = M.known:get()
	if not known then
		return {}
	end
	if known.revision ~= templateRevision then
		table.clear(templateCache)
		templateRevision = known.revision
	end
	local cached = templateCache[branchId]
	if not cached then
		cached = MagicCore.listAvailableRecipes(known.caster, { branch = branchId })
		templateCache[branchId] = cached
	end
	return cached
end

-- The cast context at the player's current location, as far as the client knows it.
function M.context(_self: any): Types.CastContext
	local region = M.region:get()
	return {
		ambientDensity = if region then region.density else 1,
		ambientBias = if region then region.resonance else nil,
	}
end

-- Estimated stats for a recipe (see UI/KnownCaster). Nil + errors when the recipe is invalid.
function M.preview(_self: any, recipe: any): (Types.SpellStats?, { Types.ValidationError })
	local known = M.known:get()
	if not known then
		return nil, { { code = "NOT_LOADED", message = "Still reading your magic..." } }
	end
	return MagicCore.computeStats(recipe, known.caster, M:context())
end

-- ─── Writes (yield; call from task.spawn or a button handler) ───────────────

-- Returns (true, key, displayName, nameRefusal?) or (false, reason).
function M.saveSpell(_self: any, recipe: Types.Recipe, name: string?): (boolean, string, string?, string?)
	local ok, saved, keyOrReason, displayName, refusal = Net.invoke("SaveSpell", recipe, name)
	if not ok then
		return false, tostring(saved)
	end
	if not saved then
		return false, tostring(keyOrReason)
	end
	local key = keyOrReason :: string
	if not spellsByKey[key] then
		local normalized = MagicCore.normalizeRecipe(recipe)
		local list = table.clone(M.spellbook:get())
		table.insert(list, {
			key = key,
			name = displayName or MagicCore.describe(normalized or recipe),
			custom = name ~= nil and refusal == nil,
			recipe = normalized or recipe,
			favorite = false,
			casts = 0,
		})
		M.spellbook:set(list)
	end
	M:refresh("spellbook")
	M.events:Fire({ kind = "saved", key = key, name = displayName })
	return true, key, displayName, refusal
end

-- Places a spell in a hotbar slot (moving it from any other slot), or empties the slot.
function M.setHotbarSlot(_self: any, slot: number, key: string?): boolean
	local optimistic: { [number]: string? } = table.clone(M.hotbar:get())
	if key then
		for s, k in optimistic do
			if k == key then
				optimistic[s] = nil
			end
		end
	end
	optimistic[slot] = key
	M.hotbar:set(optimistic :: { [number]: string })

	local ok, saved, hotbar = Net.invoke("SetHotbarSlot", slot, key)
	if ok and saved then
		M.hotbar:set(toSlots(hotbar))
		return true
	end
	M:refresh("spellbook", 0)
	return false
end

function M.setSetting(_self: any, id: string, value: any): boolean
	local before = M.settings:get()
	local optimistic = table.clone(before)
	optimistic[id] = value
	M.settings:set(optimistic)
	local ok, saved = Net.invoke("SetSetting", id, value)
	if ok and saved then
		return true
	end
	M.settings:set(before)
	return false
end

-- Returns (true) or (false, checks | reason).
function M.unlockBranch(_self: any, branchId: string): (boolean, any)
	local ok, unlocked, detail = Net.invoke("UnlockBranch", branchId)
	if not ok then
		return false, unlocked
	end
	return unlocked == true, detail
end

function M.attemptBreakthrough(_self: any, branchId: string): (boolean, string?)
	local ok, done, reason = Net.invoke("AttemptBreakthrough", branchId)
	if not ok then
		return false, tostring(done)
	end
	return done == true, reason
end

-- Attunes a hotbar slot's spell (equip mode), or stows with slot 0. YIELDS for the server's
-- answer: (true, key?) or (false, reason) (Services/AttunementService).
function M.attune(_self: any, slot: number): (boolean, string?)
	local ok, done, detail = Net.invoke("AttuneSpell", slot)
	if not ok then
		return false, "NETWORK"
	end
	return done == true, if typeof(detail) == "string" then detail else nil
end

-- Hold-to-cast: "begin" a charge, "cancel" it, or "release" a channelled spell (CastService).
function M.hold(_self: any, kind: string)
	Net.send("CastHold", kind)
end

-- A spellblade swing (Services/MeleeService picks the swing and decides what it hits).
function M.slash(_self: any)
	Net.send("MeleeIntent")
end

-- Raise or lower the guard (Services/GuardService). Refusals arrive as CastResult "refused".
function M.guard(_self: any, kind: string)
	Net.send("GuardIntent", kind)
end

-- Where a held channelled spell is being swept to (unreliable; the server caps the turn rate).
function M.channelAim(_self: any, point: Vector3)
	Net.send("ChannelAim", point)
end

-- Sends a cast intent. The server decides everything; this only records that we asked.
function M.sendCast(_self: any, key: string, aim: Vector3, target: Model?)
	local spell = spellsByKey[key]
	if not spell then
		return
	end
	Net.send("CastIntent", spell.recipe, aim, target)
	M.events:Fire({ kind = "castSent", key = key })
end

-- ─── Server pushes ──────────────────────────────────────────────────────────

local function onCastResult(result: CastResultView)
	if typeof(result) ~= "table" then
		return
	end
	-- The server's cooldown is the truth: accepted, resolved and ON_COOLDOWN refusals all carry it.
	if result.key and result.cooldownUntil and M.cooldowns:get()[result.key] ~= result.cooldownUntil then
		local cooldowns = table.clone(M.cooldowns:get())
		cooldowns[result.key] = result.cooldownUntil
		M.cooldowns:set(cooldowns)
	end
	if result.xp then
		M.focusBranch:set(result.xp.branch)
		M:refresh("progression", 3)
	end
	M.events:Fire({ kind = "cast", result = result })
end

local function onProgressionChanged(list: any)
	if typeof(list) ~= "table" then
		return
	end
	for _, event in list do
		if typeof(event) == "table" and event.kind == "spellbook" then
			M:refresh("spellbook", 0.2) -- the server changed the spellbook/hotbar (test commands)
		elseif typeof(event) == "table" and typeof(event.kind) == "string" then
			if typeof(event.branch) == "string" then
				M.focusBranch:set(event.branch)
			end
			M.events:Fire(event)
		end
	end
	M:refresh("progression")
	-- Knowledge (and so the visible profile) changes through study and awakenings, which arrive here too.
	M:refresh("profile", 4)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function MagicStateController.init(_self: any, ctx: any)
	log = ctx.log
	M.spellbook:observe(function(list)
		table.clear(spellsByKey)
		for _, spell in list do
			spellsByKey[spell.key] = spell
		end
	end)
	M.progression:observe(rebuildKnown)
	M.profile:observe(rebuildKnown)
end

-- Statuses: StatusEffects sets "Status_<id>" = expiry on your Humanoid (replicated), so the HUD
-- reads them straight from your character. Rebinds on every respawn.
local function watchStatuses()
	local bound: RBXScriptConnection? = nil
	local function scan(humanoid: Humanoid)
		local list: { ActiveStatus } = {}
		for name, value in humanoid:GetAttributes() do
			if typeof(value) == "number" and string.sub(name, 1, 7) == "Status_" then
				table.insert(list, { id = string.sub(name, 8), expires = value })
			end
		end
		table.sort(list, function(a, b)
			return a.expires < b.expires
		end)
		M.statuses:set(list)
	end
	local function bind(character: Model)
		if bound then
			bound:Disconnect()
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid or not humanoid:IsA("Humanoid") then
			return
		end
		bound = humanoid.AttributeChanged:Connect(function(name)
			if string.sub(name, 1, 7) == "Status_" then
				scan(humanoid)
			end
		end)
		scan(humanoid)
	end
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(function(character)
		M.statuses:set({})
		task.spawn(bind, character)
	end)
	if player.Character then
		task.spawn(bind, player.Character)
	end
end

function MagicStateController.start(_self: any, _ctx: any)
	Net.listen("ProgressionChanged", onProgressionChanged)
	Net.listen("ProfileChanged", function()
		M:refresh("profile")
	end)
	Net.listen("RegionInfo", function(info)
		if typeof(info) == "table" then
			M.region:set(info)
		end
	end)
	Net.listen("ReservoirState", function(snapshot)
		if typeof(snapshot) == "table" then
			M.reservoir:set(snapshot)
		end
	end)
	Net.listen("CastResult", onCastResult)
	-- Spellblade answers (Services/MeleeService): refusals and "your blade landed".
	Net.listen("MeleeResult", function(result: any)
		if typeof(result) == "table" then
			M.events:Fire({ kind = "melee", result = result })
		end
	end)
	Net.listen("QuestPins", function(pins)
		if typeof(pins) == "table" then
			M.questPins:set(pins)
		end
	end)
	Net.listen("Notify", function(text)
		if typeof(text) == "string" then
			M.events:Fire({ kind = "notify", text = text })
		end
	end)
	watchStatuses()
	loadAll()
end

return MagicStateController
