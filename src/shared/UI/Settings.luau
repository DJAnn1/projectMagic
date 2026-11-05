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
