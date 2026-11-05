--!strict
--[[
	Controls: every input binding in the game, declared once (docs/UI.md §Controls).

	The Controls screen (Client/Controllers/ControlsController) is built from this table, and the
	main controllers read their keys from it (Controls.keys / Controls.matches), so the panel and
	the code can't drift apart. Tests/Controls.spec checks every id is unique, every key name is a
	real KeyCode or mouse input, and no two actions share a key on the same device in contexts that
	can be active at once (unless one lists the other in `shares`, with the reason in `note`).

	Key names
		keyboard / gamepad   Enum.KeyCode names ("Q", "ButtonL1", "DPadDown") or mouse inputs
		                     ("MouseButton1", "MouseButton2", "MouseButton3", "MouseWheel"),
		                     plus "Thumbstick1"/"Thumbstick2" for the sticks
		touch                plain words for the on-screen control ("Cast button (hold to charge)")
	Contexts (when the binding is live)
		always     normal play
		equip      the "equip" cast mode (Settings › castMode)    quick      the "quick" cast mode
		attuned    holding a readied spell (equip mode)           unattuned  not holding one
		placing    placing furniture (blocks all other play input)
		menu       a screen is open                                prompt     a ProximityPrompt is
		admin      admins only (hidden from everyone else)                    in range (Roblox gives
		                                                                      it the key first)
	owner     the controller or script that handles it ("Roblox" = the default player scripts)
	flag      a replicated feature flag; when it's off the row shows greyed out
]]

export type Action = {
	id: string,
	label: string,
	group: string,
	order: number,
	keyboard: { string }?,
	gamepad: { string }?,
	touch: string?,
	contexts: { string },
	owner: string,
	note: string?,
	shares: { string }?,
	flag: string?,
}

local Controls = {}

Controls.groups = {
	{ id = "movement", label = "Movement" },
	{ id = "casting", label = "Casting" },
	{ id = "combat", label = "Combat" },
	{ id = "items", label = "Items and the world" },
	{ id = "menus", label = "Menus" },
	{ id = "housing", label = "Placing furniture" },
	{ id = "admin", label = "Admin" },
}

Controls.contexts = {
	always = "Always",
	equip = "Equip mode",
	quick = "Quick mode",
	attuned = "While a spell is readied",
	unattuned = "With no spell readied",
	placing = "While placing furniture",
	menu = "In menus",
	prompt = "Near something you can use",
	admin = "Admins only",
}

local list: { Action } = {
	-- ─── Movement ──────────────────────────────────────────────────────────────
	{ id = "move", label = "Move", group = "movement", order = 1, keyboard = { "W", "A", "S", "D" }, gamepad = { "Thumbstick1" }, touch = "Thumbstick (left side of the screen)", contexts = { "always" }, owner = "Roblox" },
	{ id = "jump", label = "Jump", group = "movement", order = 2, keyboard = { "Space" }, gamepad = { "ButtonA" }, touch = "Jump button", contexts = { "always" }, owner = "Roblox" },
	{
		id = "camera", label = "Turn the camera", group = "movement", order = 3,
		keyboard = { "MouseButton2" }, gamepad = { "Thumbstick2" }, touch = "Drag on the right side of the screen",
		contexts = { "always" }, owner = "Roblox", shares = { "guard" },
		note = "Hold right mouse and drag. Holding right mouse also raises your guard.",
	},
	{
		id = "run", label = "Run (toggle)", group = "movement", order = 3.5,
		keyboard = { "LeftControl" }, touch = "Run button", contexts = { "always" }, owner = "MovementClient",
		note = "Press once to run, again to walk. Gamepad: push the left stick all the way. Running pauses while a spell is readied.",
	},
	{
		id = "dash", label = "Dash", group = "movement", order = 3.6,
		keyboard = { "R" }, gamepad = { "ButtonL3" }, touch = "Dash button", contexts = { "always" }, owner = "MovementClient",
		note = "Where you're moving (or back, standing still). Two charges that refill; you take less damage mid-dash. A readied spell changes it: Energy flashsteps, Earth slides, Air gusts, Time rewinds, Gravity vaults.",
	},
	{
		id = "zoom", label = "Zoom", group = "movement", order = 4,
		keyboard = { "MouseWheel" }, touch = "Pinch", contexts = { "always" }, owner = "Roblox", shares = { "swap_spell" },
		note = "While a spell is readied, the wheel swaps spells instead.",
	},

	-- ─── Casting ───────────────────────────────────────────────────────────────
	{
		id = "hotbar", label = "Spell slots", group = "casting", order = 1,
		keyboard = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight" },
		gamepad = { "DPadLeft", "DPadRight" }, touch = "Tap a hotbar slot",
		contexts = { "always" }, owner = "CastClient", flag = "magic_casting_enabled",
		note = "Equip mode: ready the spell in that slot. Quick mode: cast it at once. Gamepad: pick the slot (swaps the readied spell).",
	},
	{
		id = "ready", label = "Ready the selected spell", group = "casting", order = 2,
		gamepad = { "ButtonL2" }, contexts = { "equip" }, owner = "CastClient", flag = "magic_casting_enabled",
		note = "On keyboard, press the slot's number.",
	},
	{
		id = "cast", label = "Cast the readied spell", group = "casting", order = 3,
		keyboard = { "MouseButton1" }, gamepad = { "ButtonR2" }, touch = "Cast button",
		contexts = { "attuned" }, owner = "CastClient", flag = "magic_casting_enabled",
		note = "Hold to charge (or channel); release to cast.",
	},
	{
		id = "quick_cast", label = "Cast the selected spell", group = "casting", order = 4,
		gamepad = { "ButtonR2" }, contexts = { "quick" }, owner = "CastClient", flag = "magic_casting_enabled",
		note = "On keyboard, press the slot's number.",
	},
	{
		id = "swap_spell", label = "Swap the readied spell", group = "casting", order = 5,
		keyboard = { "MouseWheel" }, contexts = { "attuned" }, owner = "CastClient", shares = { "zoom" },
		note = "Gamepad: the D-pad (Spell slots).",
	},
	{
		id = "stow", label = "Lower your spell", group = "casting", order = 6,
		keyboard = { "Q" }, touch = "Stow button", contexts = { "attuned" }, owner = "CastClient",
	},
	{
		id = "lock_on", label = "Lock on to a target", group = "casting", order = 7,
		keyboard = { "LeftAlt", "MouseButton3" }, gamepad = { "ButtonR3" },
		contexts = { "always" }, owner = "AimController",
		note = "Press to lock, press again to let go (Settings › Lock-on can make it hold-to-lock). Gamepad: click the right stick.",
	},

	-- ─── Combat ────────────────────────────────────────────────────────────────
	{
		id = "weapon_attack", label = "Attack with your weapon", group = "combat", order = 1,
		keyboard = { "MouseButton1" }, gamepad = { "ButtonR1" }, touch = "Cast button",
		contexts = { "unattuned" }, owner = "WeaponClient",
		note = "Combos with melee weapons; hold to draw a bow.",
	},
	{
		id = "guard", label = "Block", group = "combat", order = 2,
		keyboard = { "MouseButton2" }, gamepad = { "ButtonL1" }, touch = "Block button",
		contexts = { "always" }, owner = "CastClient", shares = { "camera" },
		note = "With a readied spell (a ward; time it to parry) or a weapon (costs stamina).",
	},
	{
		id = "slash", label = "Spellblade slash", group = "combat", order = 3,
		keyboard = { "F" }, gamepad = { "ButtonB" }, touch = "Slash button",
		contexts = { "attuned" }, owner = "CastClient",
		note = "Press again in rhythm for the second swing.",
	},

	-- ─── Items and the world ───────────────────────────────────────────────────
	{
		id = "quick_items", label = "Use a quick item", group = "items", order = 1,
		keyboard = { "Z", "X", "V", "B" }, gamepad = { "DPadDown" }, touch = "Tap a quickbar slot",
		contexts = { "always" }, owner = "InventoryController", flag = "items_enabled",
		note = "Gamepad: tap D-pad down to use the selected item, hold it to select the next.",
	},
	{
		id = "interact", label = "Use / talk", group = "items", order = 2,
		keyboard = { "E" }, gamepad = { "ButtonX" }, touch = "Tap the prompt",
		contexts = { "prompt" }, owner = "Roblox",
		note = "Doors, beds, chests, stations, people. Some prompts are held.",
	},
	{
		id = "interact_alt", label = "Second action", group = "items", order = 3,
		keyboard = { "F" }, gamepad = { "ButtonY" }, touch = "Tap the prompt",
		contexts = { "prompt" }, owner = "Roblox",
		note = "On some objects, such as lighting a fireplace.",
	},
	{
		id = "interact_modifier", label = "Take the whole stack", group = "items", order = 4,
		keyboard = { "LeftShift", "RightShift" }, contexts = { "menu" }, owner = "InteractionController",
		note = "Hold while moving items in a chest or station.",
	},

	-- ─── Menus ─────────────────────────────────────────────────────────────────
	{ id = "open_grimoire", label = "Grimoire", group = "menus", order = 1, keyboard = { "G" }, gamepad = { "ButtonY" }, touch = "Menu button", contexts = { "always" }, owner = "GrimoireController" },
	{ id = "open_composer", label = "Spell Composer", group = "menus", order = 2, keyboard = { "C" }, gamepad = { "ButtonX" }, touch = "Menu button", contexts = { "always" }, owner = "ComposerController" },
	{ id = "open_journal", label = "Journal", group = "menus", order = 3, keyboard = { "J" }, touch = "Menu button", contexts = { "always" }, owner = "JournalController" },
	{ id = "open_inventory", label = "Inventory", group = "menus", order = 4, keyboard = { "I" }, gamepad = { "DPadUp" }, touch = "Menu button", contexts = { "always" }, owner = "InventoryController", flag = "items_enabled" },
	{ id = "open_controls", label = "Controls (this screen)", group = "menus", order = 5, keyboard = { "H" }, touch = "Menu button", contexts = { "always" }, owner = "ControlsController" },
	{ id = "close_menu", label = "Close", group = "menus", order = 6, gamepad = { "ButtonB" }, touch = "✕ button", contexts = { "menu" }, owner = "InterfaceController", note = "Keyboard: press the screen's key again, or click ✕." },

	-- ─── Placing furniture ─────────────────────────────────────────────────────
	{ id = "place", label = "Place", group = "housing", order = 1, keyboard = { "MouseButton1" }, contexts = { "placing" }, owner = "HousingController" },
	{ id = "rotate", label = "Rotate", group = "housing", order = 2, keyboard = { "R" }, contexts = { "placing" }, owner = "HousingController" },
	{ id = "cancel_place", label = "Cancel", group = "housing", order = 3, keyboard = { "Q", "Escape" }, contexts = { "placing" }, owner = "HousingController" },

	-- ─── Admin ─────────────────────────────────────────────────────────────────
	{ id = "admin_panel", label = "Admin panel", group = "admin", order = 1, keyboard = { "F2" }, contexts = { "admin" }, owner = "AdminPanel" },
	{ id = "admin_history", label = "Console history", group = "admin", order = 2, keyboard = { "Up", "Down" }, contexts = { "admin" }, owner = "AdminPanel" },
	{ id = "admin_fly", label = "Fly up / down (fly mode)", group = "admin", order = 3, keyboard = { "Space", "LeftControl" }, contexts = { "admin" }, owner = "AdminClient/Movement" },
}

Controls.list = list

local byId: { [string]: Action } = {}
for _, action in list do
	byId[action.id] = action
end
Controls.byId = byId

-- ─── Lookups for controllers ───────────────────────────────────────────────

local MOUSE: { [string]: Enum.UserInputType } = {
	MouseButton1 = Enum.UserInputType.MouseButton1,
	MouseButton2 = Enum.UserInputType.MouseButton2,
	MouseButton3 = Enum.UserInputType.MouseButton3,
	MouseWheel = Enum.UserInputType.MouseWheel,
}
local STICKS: { [string]: boolean } = { Thumbstick1 = true, Thumbstick2 = true }

-- True if `name` is a key name this module understands (a KeyCode, a mouse input or a stick).
function Controls.isKnownName(name: string): boolean
	if MOUSE[name] or STICKS[name] then
		return true
	end
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	return ok and code ~= nil
end

-- The KeyCodes bound to an action on a device ("keyboard" | "gamepad"), in order. Mouse inputs
-- are left out (use Controls.matches for those).
function Controls.keys(id: string, device: string): { Enum.KeyCode }
	local action = byId[id]
	assert(action, "Controls: unknown action " .. id)
	local names = if device == "gamepad" then action.gamepad else action.keyboard
	local out: { Enum.KeyCode } = {}
	for _, name in (names or {}) :: { string } do
		if not MOUSE[name] and not STICKS[name] then
			table.insert(out, (Enum.KeyCode :: any)[name])
		end
	end
	return out
end

-- The first KeyCode of an action on a device, or nil.
function Controls.key(id: string, device: string): Enum.KeyCode?
	return Controls.keys(id, device)[1]
end

-- Does this input trigger the action (on either device)?
function Controls.matches(id: string, input: InputObject): boolean
	local action = byId[id]
	if not action then
		return false
	end
	for _, names in { action.keyboard or {}, action.gamepad or {} } :: { { string } } do
		for _, name in names do
			local mouse = MOUSE[name]
			if mouse then
				if input.UserInputType == mouse then
					return true
				end
			elseif not STICKS[name] and input.KeyCode.Name == name then
				return true
			end
		end
	end
	return false
end

-- ─── Display ───────────────────────────────────────────────────────────────

local DISPLAY: { [string]: string } = {
	MouseButton1 = "Left mouse", MouseButton2 = "Right mouse", MouseButton3 = "Middle mouse", MouseWheel = "Mouse wheel",
	Thumbstick1 = "Left stick", Thumbstick2 = "Right stick",
	LeftAlt = "Left Alt", LeftShift = "Shift", RightShift = "Right Shift", LeftControl = "Left Ctrl", Escape = "Esc",
	One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
	ButtonA = "A", ButtonB = "B", ButtonX = "X", ButtonY = "Y", ButtonL1 = "L1", ButtonL2 = "L2", ButtonR1 = "R1", ButtonR2 = "R2",
	ButtonL3 = "L3 (left stick click)", ButtonR3 = "R3 (right stick click)",
	DPadLeft = "D-pad left", DPadRight = "D-pad right", DPadUp = "D-pad up", DPadDown = "D-pad down",
	Up = "Up arrow", Down = "Down arrow",
}

-- How a key name is shown to players ("MouseButton1" -> "Left mouse", "One" -> "1").
function Controls.display(name: string): string
	return DISPLAY[name] or name
end

-- ─── Conflict rules (used by Tests/Controls.spec) ──────────────────────────

-- Contexts that never coexist with gameplay input (Roblox or our InterfaceController gives
-- them the input first), so they're only compared with themselves.
local ISOLATED: { [string]: boolean } = { menu = true, prompt = true, admin = true, placing = true }
-- Pairs that can't be true at the same time.
local EXCLUSIVE: { [string]: { [string]: boolean } } = {
	equip = { quick = true },
	quick = { equip = true, attuned = true },
	attuned = { unattuned = true, quick = true },
	unattuned = { attuned = true },
}

function Controls.contextsOverlap(a: string, b: string): boolean
	if a == b then
		return true
	end
	if ISOLATED[a] or ISOLATED[b] then
		return false
	end
	if a == "always" or b == "always" then
		return true
	end
	return not (EXCLUSIVE[a] and EXCLUSIVE[a][b])
end

return Controls
