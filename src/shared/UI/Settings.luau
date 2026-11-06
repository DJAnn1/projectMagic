--!strict
--[[
	Settings: the player's interface preferences, declared once.

	Shared on purpose: the server validates every write against `options` (PreferencesService),
	and the client builds the Settings screen from the same table, so adding a setting is one
	entry here and nothing else. Values are saved in PlayerData.settings (filled into old saves
	by reconcile, so no schema bump is needed when a setting is added).

	options  every allowed value; anything else is refused
	labels   what the Settings screen shows for each option (same order as `options`)
	order    position on the Settings screen
	hidden   not shown on the Settings screen (a remembered UI state, still validated and saved)
]]

export type SettingDef = {
	label: string,
	description: string,
	default: any,
	options: { any },
	labels: { string },
	order: number,
	hidden: boolean?,
}

local Settings: { [string]: SettingDef } = {
	textScale = {
		order = 1,
		label = "Text size",
		description = "Scales every piece of interface text. Layout grows with it.",
		default = 1,
		options = { 0.85, 1, 1.15, 1.3, 1.5 },
		labels = { "Small", "Default", "Large", "Larger", "Largest" },
	},
	palette = {
		order = 2,
		label = "Domain colours",
		description = "Signature uses each domain's own colours. Colour-safe is tuned for colour vision deficiency. High contrast drops colour entirely: domains are told apart by letters and shapes, which every mode also shows.",
		default = "signature",
		options = { "signature", "colorSafe", "highContrast" },
		labels = { "Signature", "Colour-safe", "High contrast" },
	},
	reducedMotion = {
		order = 3,
		label = "Reduce motion",
		description = "No pulsing, sliding or scaling in the interface. Changes appear instantly.",
		default = false,
		options = { false, true },
		labels = { "Off", "On" },
	},
	reducedEffects = {
		order = 4,
		label = "Reduce spell effects",
		description = "Fewer particles and no screen shake from spells and world events.",
		default = false,
		options = { false, true },
		labels = { "Off", "On" },
	},
	damageNumbers = {
		order = 6,
		label = "Damage numbers",
		description = "Numbers over whatever your magic hurts or heals, and hit markers at your aim.",
		default = true,
		options = { true, false },
		labels = { "On", "Off" },
	},
	questMarkers = {
		order = 7,
		label = "Quest markers",
		description = "Markers over where your quests lead, and an arrow to the one you're tracking.",
		default = true,
		options = { true, false },
		labels = { "On", "Off" },
	},
	lockOnMode = {
		order = 8.5,
		label = "Lock-on",
		description = "Left Alt (or the middle mouse button) locks your aim onto the target nearest the cursor. Toggle: press once to lock, again to let go. Hold: locked only while held.",
		default = "toggle",
		options = { "toggle", "hold" },
		labels = { "Toggle", "Hold" },
	},
	homeMarker = {
		order = 7.5,
		label = "Home marker",
		description = "A ⌂ marker over your house's door, with the distance. The Journal's \"Show the way\" adds an arrow home.",
		default = true,
		options = { true, false },
		labels = { "On", "Off" },
	},
	castMode = {
		order = 8,
		label = "Casting",
		description = "Equip: a hotbar key readies that spell in your hand and the mouse button casts it; press the key again (or Q) to put it away. Quick: a hotbar key casts at once.",
		default = "equip",
		options = { "equip", "quick" },
		labels = { "Equip", "Quick" },
	},
	aimGuide = {
		order = 9,
		label = "Aim guide",
		description = "While a spell is readied, shows where it will go: a projectile's arc, a beam's line, the ground an area spell covers, a touch's reach, a chain's next hops.",
		default = true,
		options = { true, false },
		labels = { "On", "Off" },
	},
	composerMode = {
		order = 5,
		label = "Spell Composer",
		description = "Guided shows ready-made spells you can tune. Full lets you build any spell part by part.",
		default = "simple",
		options = { "simple", "advanced" },
		labels = { "Guided", "Full" },
	},
	volumeMaster = {
		order = 20,
		label = "Volume: everything",
		description = "All game sound at once.",
		default = 1,
		options = { 0, 0.25, 0.5, 0.75, 1 },
		labels = { "Off", "Low", "Half", "High", "Full" },
	},
	volumeMusic = {
		order = 21,
		label = "Volume: music",
		description = "Background music (changes with where you are and whether you're fighting).",
		default = 0.5,
		options = { 0, 0.25, 0.5, 0.75, 1 },
		labels = { "Off", "Low", "Half", "High", "Full" },
	},
	volumeSpells = {
		order = 22,
		label = "Volume: spells",
		description = "Spells being cast, flying and landing, yours and everyone's.",
		default = 1,
		options = { 0, 0.25, 0.5, 0.75, 1 },
		labels = { "Off", "Low", "Half", "High", "Full" },
	},
	volumeCombat = {
		order = 23,
		label = "Volume: combat",
		description = "Hits, blocks, parries, slashes, dashes, bows.",
		default = 1,
		options = { 0, 0.25, 0.5, 0.75, 1 },
		labels = { "Off", "Low", "Half", "High", "Full" },
	},
	volumeUI = {
		order = 24,
		label = "Volume: menus and fanfares",
		description = "Clicks, pages, and the short fanfares for breakthroughs and discoveries.",
		default = 0.75,
		options = { 0, 0.25, 0.5, 0.75, 1 },
		labels = { "Off", "Low", "Half", "High", "Full" },
	},
	volumeAmbience = {
		order = 25,
		label = "Volume: ambience",
		description = "Birds, waves, crickets, rain, towns: the world around you.",
		default = 0.75,
		options = { 0, 0.25, 0.5, 0.75, 1 },
		labels = { "Off", "Low", "Half", "High", "Full" },
	},
	partyInvites = {
		order = 30,
		label = "Party invites",
		description = "Who can invite you to a party. People you've blocked on Roblox never can.",
		default = "anyone",
		options = { "anyone", "friends", "nobody" },
		labels = { "Anyone", "Friends only", "Nobody" },
	},
	duelChallenges = {
		order = 31,
		label = "Duel challenges",
		description = "Who can challenge you to a duel. A duel never starts until you accept it. People you've blocked on Roblox never can.",
		default = "anyone",
		options = { "anyone", "friends", "nobody" },
		labels = { "Anyone", "Friends only", "Nobody" },
	},
	emotesFrom = {
		order = 32,
		label = "Emotes from others",
		description = "Whose emotes and flourishes you see. You never see those of people you've blocked on Roblox.",
		default = "everyone",
		options = { "everyone", "party", "nobody" },
		labels = { "Everyone", "My party", "Nobody" },
	},
	composerHelpSeen = {
		order = 101,
		hidden = true,
		label = "Composer help seen",
		description = "The Spell Composer's first-time walkthrough has been shown (ComposerController).",
		default = false,
		options = { false, true },
		labels = { "No", "Yes" },
	},
	controlsHintSeen = {
		order = 100,
		hidden = true,
		label = "Controls hint seen",
		description = "The one-time \"Press H for controls\" hint has been shown (ControlsController).",
		default = false,
		options = { false, true },
		labels = { "No", "Yes" },
	},
}

return table.freeze(Settings)
