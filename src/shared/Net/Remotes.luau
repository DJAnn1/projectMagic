--!strict
--[[
	Remotes: every remote in the game, declared once. Net creates the instances from this list;
	nothing else may create or use a RemoteEvent / RemoteFunction directly.

	kind      "Event" | "Function" | "Unreliable" (UnreliableRemoteEvent: cosmetic, high-frequency)
	from      "Client" (client -> server, validated) | "Server" (server -> client)
	args      validators for each positional argument (Client remotes only). Extra arguments are rejected.
	rate      token bucket per player: capacity (burst) and perSecond (sustained)
	maxBytes  rough upper bound on the argument payload

	Functions are client -> server only. The server never invokes a client: a client can
	refuse to answer and hang the server thread forever.
]]

local S = require(script.Parent.Schema)
local UISettings = require(script.Parent.Parent.UI.Settings)

export type RemoteDef = {
	kind: string,
	from: string,
	args: { S.Validator }?,
	rate: { capacity: number, perSecond: number }?,
	maxBytes: number?,
}

local ID = S.string(1, 48)

-- Loose shape check for spell recipes. MagicCore.validateRecipe does the real grammar checks.
local recipe = S.struct({
	v = S.optional(S.integer(1, 100)),
	branch = ID,
	property = ID,
	verb = ID,
	form = ID,
	power = S.integer(1, 10),
	modifiers = S.optional(S.array(ID, 4)),
	costProfile = S.optional(ID),
})

-- Every value any setting allows. PreferencesService then checks the value against its own setting.
local settingValues: { any } = {}
for _, setting in UISettings do
	for _, option in setting.options do
		if not table.find(settingValues, option) then
			table.insert(settingValues, option)
		end
	end
end

local Remotes: { [string]: RemoteDef } = {
	-- ─── Client -> Server ───────────────────────────────────────────────────
	CastIntent = {
		kind = "Event",
		from = "Client",
		args = { recipe, S.vector3(100000), S.optional(S.instance("Model", workspace)) }, -- recipe, aim point, target
		rate = { capacity = 8, perSecond = 4 },
		maxBytes = 1024,
	},
	-- Hold-to-cast (Casting.md §8). "begin" starts charging the attuned spell (the server times it),
	-- "cancel" drops the charge, "release" ends a channelled spell. The charged cast itself is the
	-- normal CastIntent sent on release.
	CastHold = {
		kind = "Event",
		from = "Client",
		args = { S.literal("begin", "cancel", "release") },
		rate = { capacity = 6, perSecond = 4 },
		maxBytes = 32,
	},
	MeleeIntent = { -- a spellblade swing (Services/MeleeService decides which, and what it hits)
		kind = "Event",
		from = "Client",
		args = {},
		rate = { capacity = 4, perSecond = 4 },
		maxBytes = 16,
	},
	WeaponIntent = { -- a weapon attack (Services/WeaponService): swing | draw | release | cancel, with the aim point
		kind = "Event",
		from = "Client",
		args = { S.literal("swing", "draw", "release", "cancel"), S.optional(S.vector3(100000)) },
		rate = { capacity = 6, perSecond = 5 },
		maxBytes = 64,
	},
	RunIntent = { -- the running toggle on/off (Services/MovementService applies it only when allowed)
		kind = "Event",
		from = "Client",
		args = { S.boolean },
		rate = { capacity = 6, perSecond = 4 },
		maxBytes = 16,
	},
	DashIntent = { -- a dash in this flat direction (Services/MovementService checks everything)
		kind = "Event",
		from = "Client",
		args = { S.vector3(1.5) },
		rate = { capacity = 4, perSecond = 3 },
		maxBytes = 48,
	},
	GuardIntent = { -- raise or lower the guard (equip mode; Services/GuardService)
		kind = "Event",
		from = "Client",
		args = { S.literal("raise", "lower") },
		rate = { capacity = 6, perSecond = 4 },
		maxBytes = 32,
	},
	ChannelAim = { -- where a channelled spell is being swept to (the server caps the turn rate)
		kind = "Unreliable",
		from = "Client",
		args = { S.vector3(100000) },
		rate = { capacity = 20, perSecond = 15 },
		maxBytes = 64,
	},
	AttuneSpell = { -- hotbar slot 1..10 to attune (equip mode), 0 to stow. Returns (ok, key | reason)
		kind = "Function",
		from = "Client",
		args = { S.integer(0, 10) },
		rate = { capacity = 6, perSecond = 3 },
		maxBytes = 32,
	},
	AimUpdate = {
		kind = "Unreliable",
		from = "Client",
		args = { S.vector3(100000) },
		rate = { capacity = 30, perSecond = 20 },
		maxBytes = 64,
	},
	RequestProfileView = {
		kind = "Function",
		from = "Client",
		args = {},
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 16,
	},
	RequestSpellbook = {
		kind = "Function",
		from = "Client",
		args = {},
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 16,
	},
	SaveSpell = { -- recipe, optional name
		kind = "Function",
		from = "Client",
		args = { recipe, S.optional(S.string(1, 128)) },
		rate = { capacity = 5, perSecond = 1 },
		maxBytes = 1024,
	},
	RenameSpell = { -- recipe key, new name (every rename is a text-filter call, so this is slow on purpose)
		kind = "Function",
		from = "Client",
		args = { S.string(1, 200), S.string(1, 128) },
		rate = { capacity = 3, perSecond = 0.2 },
		maxBytes = 512,
	},
	RemoveSpell = {
		kind = "Function",
		from = "Client",
		args = { S.string(1, 200) },
		rate = { capacity = 5, perSecond = 1 },
		maxBytes = 256,
	},
	RequestProgression = {
		kind = "Function",
		from = "Client",
		args = {},
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 16,
	},
	UnlockBranch = {
		kind = "Function",
		from = "Client",
		args = { ID },
		rate = { capacity = 4, perSecond = 1 },
		maxBytes = 128,
	},
	AttemptBreakthrough = {
		kind = "Function",
		from = "Client",
		args = { ID },
		rate = { capacity = 4, perSecond = 1 },
		maxBytes = 128,
	},
	CommitSpecialization = {
		kind = "Function",
		from = "Client",
		args = { ID },
		rate = { capacity = 2, perSecond = 0.2 },
		maxBytes = 128,
	},
	RenounceSpecialization = {
		kind = "Function",
		from = "Client",
		args = { ID },
		rate = { capacity = 2, perSecond = 0.2 },
		maxBytes = 128,
	},
	DeclareSignature = { -- recipe key of a spell in your spellbook
		kind = "Function",
		from = "Client",
		args = { S.string(1, 200) },
		rate = { capacity = 2, perSecond = 0.2 },
		maxBytes = 256,
	},
	SetHotbarSlot = { -- slot 1..10, recipe key (nil empties the slot)
		kind = "Function",
		from = "Client",
		args = { S.integer(1, 10), S.optional(S.string(1, 200)) },
		rate = { capacity = 10, perSecond = 4 },
		maxBytes = 256,
	},
	RequestSettings = {
		kind = "Function",
		from = "Client",
		args = {},
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 16,
	},
	SetSetting = { -- setting id (Shared/UI/Settings), value
		kind = "Function",
		from = "Client",
		args = { ID, S.literal(table.unpack(settingValues)) },
		rate = { capacity = 6, perSecond = 2 },
		maxBytes = 128,
	},
	RequestJournal = { -- tab, page -> { ok, tab, data } (Services/JournalService; docs/UI.md §4.7)
		kind = "Function",
		from = "Client",
		args = { S.literal("quests", "log", "factions"), S.integer(1, 50) },
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 64,
	},
	QuestAction = { -- quest id, action -> { ok, reason? } (Services/QuestDirector)
		kind = "Function",
		from = "Client",
		args = { S.string(1, 200), S.literal("accept", "decline", "abandon", "track") },
		rate = { capacity = 4, perSecond = 1 },
		maxBytes = 256,
	},
	NpcTalk = { -- npc id, topic -> dialogue payload (server checks the player is beside the NPC)
		kind = "Function",
		from = "Client",
		args = { S.string(1, 64), S.literal("greet", "self", "magic", "rumor", "work", "learn", "farewell", "quest") },
		rate = { capacity = 4, perSecond = 1 },
		maxBytes = 160,
	},
	-- Items (Services/InventoryService; docs/Items.md §6). Places are refs: "s12" grid slot,
	-- "e:head" equipment slot, "q2" quickslot (use only). The server re-checks everything.
	RequestInventory = { -- -> InventoryView
		kind = "Function",
		from = "Client",
		args = {},
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 16,
	},
	RequestStatSheet = { -- -> { final, resist, lines, weight, carry, load, focus, buffs }
		kind = "Function",
		from = "Client",
		args = {},
		rate = { capacity = 3, perSecond = 0.5 },
		maxBytes = 16,
	},
	InventoryAction = { -- op, a?, b?, n?, aim? -> { ok, reason? }
		kind = "Function",
		from = "Client",
		args = {
			S.literal("move", "equip", "unequip", "use", "drop", "sort", "favorite", "lock", "quick", "seen", "mend"),
			S.optional(S.string(1, 24)),
			S.optional(S.string(1, 24)),
			S.optional(S.integer(1, 999)),
			S.optional(S.vector3(100000)),
		},
		rate = { capacity = 12, perSecond = 6 }, -- drag-and-drop bursts
		maxBytes = 160,
	},
	-- Buildings (docs/Buildings.md): opened by ProximityPrompts on the server; these move items
	-- and craft. The server re-checks reach and that the container is open for this player.
	ContainerAction = { -- op, container id, ref?, n? -> { ok, reason? } (Services/ContainerService)
		kind = "Function",
		from = "Client",
		args = {
			S.literal("take", "put", "takeall", "coins", "close"),
			S.string(1, 96),
			S.optional(S.string(1, 24)),
			S.optional(S.integer(1, 999)),
		},
		rate = { capacity = 12, perSecond = 6 },
		maxBytes = 200,
	},
	RepairAction = { -- station id, item ref ("s12", "e:head") or "all" -> { ok, reason?, repaired?, coins? } (Services/CraftingService)
		kind = "Function",
		from = "Client",
		args = { S.string(1, 96), S.string(1, 24) },
		rate = { capacity = 6, perSecond = 3 },
		maxBytes = 160,
	},
	CraftAction = { -- station id, recipe id, count -> { ok, reason? } (Services/CraftingService)
		kind = "Function",
		from = "Client",
		args = { S.string(1, 96), S.string(1, 48), S.integer(1, 10) },
		rate = { capacity = 6, perSecond = 3 },
		maxBytes = 200,
	},
	PlaceDecor = { -- grid ref of a furniture item, lot-local x, z, rotation step (x15 deg) -> { ok, reason? } (HousingService)
		kind = "Function",
		from = "Client",
		args = { S.string(1, 24), S.number(-60, 60), S.number(-60, 60), S.integer(0, 23) },
		rate = { capacity = 6, perSecond = 2 },
		maxBytes = 96,
	},
	-- No admin remotes here: the Admin Panel's two RemoteEvents are created per admin inside
	-- that admin's PlayerGui (Services/AdminService), so other clients never see them.

	-- ─── Server -> Client ───────────────────────────────────────────────────
	--[[ CastResult payloads (sent by Services/CastService; read by the HUD). Times are server time.
		refused   { ok = false, stage = "refused", key?, reason, detail?, cooldownUntil? }
		accepted  { ok = true, stage = "accepted", key, cost, hpCost, castTime, cooldownUntil, consequences }
		resolved  { ok = true, stage = "resolved", key, cooldownUntil, effective, hits, backfired,
		            interrupted?, note?, xp? = { branch, gained } } ]]
	CastResult = { kind = "Event", from = "Server" },
	DashResult = { kind = "Event", from = "Server" }, -- { ok = false, reason } | { ok = true, style }; owner only
	MeleeResult = { kind = "Event", from = "Server" }, -- { ok = false, reason } | { hit = true, swing }; owner only
	WeaponResult = { kind = "Event", from = "Server" }, -- { ok = false, reason } | { hit = true } | { fired = true, ammo }; owner only
	ReservoirState = { kind = "Unreliable", from = "Server" }, -- { current, max, strain, burnoutUntil, lockouts }; owner only
	ProfileChanged = { kind = "Event", from = "Server" },
	ProgressionChanged = { kind = "Event", from = "Server" }, -- tier ups, unlocks, breakthroughs, discoveries
	RegionInfo = { kind = "Event", from = "Server" }, -- biome, density, resonance, active events at your location
	WorldEffect = { kind = "Event", from = "Server" }, -- cosmetic cues: camera shake, wave visuals, sky
	PoiMarkers = { kind = "Event", from = "Server" }, -- visible POIs (never hidden/mythic ones)
	Notify = { kind = "Event", from = "Server" },
	NpcSpeech = { kind = "Event", from = "Server" }, -- { npcId, text }: a speech bubble over an NPC (nearby players only)
	JournalChanged = { kind = "Event", from = "Server" }, -- { kind, text, questId? }: a new journal entry (owner only)
	InventoryChanged = { kind = "Event", from = "Server" },
	ContainerView = { kind = "Event", from = "Server" }, -- the container you have open (or { id, closed = true }); viewers only
	StationView = { kind = "Event", from = "Server" },
	HousingState = { kind = "Event", from = "Server" }, -- your house: { lot, name, home, town, built, lotCFrame, interiorCFrame, interiorSize, floorY, decor, decorMax, parts, partsMax } or {}
	OpenScreen = { kind = "Event", from = "Server" }, -- { id } the world asks the client to open a screen (a notice board opens the Journal) -- { id, station, tier, name }: a crafting station you just used -- InventoryView (Shared/Items/ItemTypes): the whole inventory, owner only, once per change
	QuestPins = { kind = "Event", from = "Server" }, -- { { q, title, text, p: Vector3, tracked, shared, person } }: your open objectives (owner only, on change)
}

return Remotes
