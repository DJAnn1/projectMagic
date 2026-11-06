--!strict
--[[
	Theme: design tokens. Colours, fonts, text sizes, spacing, sounds, and per-domain styling.

	Screens read the token values when they build. Accessibility settings (text size, palette,
	reduced motion) are applied with Theme.apply(); InterfaceController then rebuilds every
	visible screen, so no label needs its own binding to the settings.

	Status colours are the colour-safe trio (sky blue / orange / vermillion), and every status
	also carries a glyph or a word: ✓ met, ✗ unmet, ! warning.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Magic.Registry)
local DomainStyles = require(script.Parent.DomainStyles)

local rgb = Color3.fromRGB

local Theme = {}

Theme.settings = {
	textScale = 1,
	palette = "signature",
	reducedMotion = false,
	reducedEffects = false,
	damageNumbers = true,
	questMarkers = true,
}

-- ─── Colour ─────────────────────────────────────────────────────────────────

Theme.color = {
	backdrop = rgb(8, 7, 12),
	bg = rgb(16, 14, 22), -- screen background (the book's cover)
	panel = rgb(30, 27, 38), -- pages and cards
	panelRaised = rgb(42, 38, 52), -- hovered / selected cards
	line = rgb(88, 81, 104), -- borders and dividers
	-- Text tokens are tuned for WCAG AA on `panel` and `panelRaised`: ink ≈ 14:1, inkDim ≈ 9:1,
	-- inkFaint ≈ 5:1. Never render text with TextTransparency to "dim" it: that blends it into
	-- whatever is behind and the contrast collapses. Use these tokens instead.
	ink = rgb(242, 236, 222), -- primary text (warm parchment white)
	inkDim = rgb(200, 192, 178), -- secondary text
	inkFaint = rgb(156, 149, 138), -- hints, disabled text, silhouettes
	disabled = rgb(40, 37, 49), -- opaque fill for disabled buttons (never a see-through accent)
	accent = rgb(214, 178, 94), -- gold: selection, focus, primary actions
	good = rgb(86, 180, 233), -- ✓ met / ready (sky blue, never green-vs-red)
	warn = rgb(230, 159, 0), -- ! caution (orange)
	danger = rgb(213, 94, 0), -- ✗ backlash, overdraw (vermillion)
	reservoir = rgb(120, 170, 255),
	strain = rgb(230, 159, 0),
}

-- Background transparency for HUD and floating panels drawn over the 3D world. Kept near-opaque:
-- at 0.15–0.2 a bright sky or snow showed through and washed out the secondary text.
Theme.glass = 0.06

-- The base text colours, so the high-contrast palette can be switched off again.
local BASE_INK = { ink = Theme.color.ink, inkDim = Theme.color.inkDim, inkFaint = Theme.color.inkFaint }
local HIGH_CONTRAST_INK = { ink = rgb(255, 255, 255), inkDim = rgb(232, 228, 220), inkFaint = rgb(196, 190, 180) }

-- ─── Type ───────────────────────────────────────────────────────────────────

Theme.font = {
	body = Font.fromEnum(Enum.Font.BuilderSans),
	medium = Font.fromEnum(Enum.Font.BuilderSansMedium),
	bold = Font.fromEnum(Enum.Font.BuilderSansBold),
	title = Font.fromEnum(Enum.Font.Fondamento), -- headings only; never body text
	mono = Font.fromEnum(Enum.Font.RobotoMono), -- numbers that change (cooldowns, reservoir)
}

local TEXT_SIZES: { [string]: number } = {
	caption = 13,
	body = 16,
	label = 17,
	heading = 21,
	title = 28,
	display = 40,
}

-- Text size in pixels for a role, with the player's text-scale setting applied.
function Theme.text(role: string): number
	return math.floor((TEXT_SIZES[role] or TEXT_SIZES.body) * Theme.settings.textScale + 0.5)
end

-- ─── Spacing ────────────────────────────────────────────────────────────────

Theme.space = { xs = 4, s = 8, m = 12, l = 16, xl = 24 }
Theme.radius = { s = 4, m = 8, l = 14 }
Theme.minTouch = 44 -- minimum touch target (pixels, before UIScale)

-- ─── Motion ─────────────────────────────────────────────────────────────────

Theme.motion = {
	fast = 0.12,
	normal = 0.22,
	slow = 0.45,
}

-- Zero when the player asked for reduced motion: tweens then apply instantly.
function Theme.duration(kind: string): number
	if Theme.settings.reducedMotion then
		return 0
	end
	return (Theme.motion :: any)[kind] or Theme.motion.normal
end

-- ─── Sound ──────────────────────────────────────────────────────────────────
-- Key -> a role in Shared/Audio/AudioLibrary (licensed Creator Store audio), played by C.sound
-- through the UI sound group. "" = silent.

Theme.sounds = {
	open = "ui.open",
	close = "ui.close",
	select = "ui.click",
	confirm = "ui.confirm",
	deny = "ui.error",
	tierUp = "sting.tierUp",
	breakthrough = "sting.breakthrough",
	discovery = "sting.discovery",
	first = "sting.first",
	questDone = "sting.questDone",
	awaken = "sting.awakening",
	backlash = "spell.backfire",
	lowReservoir = "ui.notify",
	castFail = "ui.error",
	domain_energy = "energy.cast",
	domain_earth = "earth.cast",
	domain_water = "water.cast",
	domain_air = "air.cast",
	domain_life = "life.cast",
	domain_mind = "mind.cast",
	domain_spirit = "spirit.cast",
	domain_void = "void.cast",
	domain_space = "space.cast",
	domain_time = "time.cast",
	domain_gravity = "gravity.cast",
	domain_reality = "reality.cast",
} :: { [string]: string }

-- ─── Domains ────────────────────────────────────────────────────────────────

local SHAPE_BY_RARITY: { [string]: string } = {
	Common = "circle",
	Uncommon = "square",
	Rare = "diamond",
	Mythic = "ring",
}

function Theme.domainColor(domainId: string): Color3
	local style = DomainStyles[domainId]
	if not style or Theme.settings.palette == "highContrast" then
		return Theme.color.ink
	end
	return if Theme.settings.palette == "colorSafe" then style.safe else style.signature
end

function Theme.domainShape(domainId: string): string
	local def = Registry.domains[domainId]
	return if def then SHAPE_BY_RARITY[def.rarity] or "circle" else "circle"
end

function Theme.domainStyle(domainId: string): DomainStyles.DomainStyle?
	return DomainStyles[domainId]
end

-- First domain of a branch (hybrids use their first domain for colour; badges show all).
function Theme.branchColor(branchId: string): Color3
	local branch = Registry.branches[branchId]
	return if branch then Theme.domainColor(branch.domains[1]) else Theme.color.inkDim
end

function Theme.apply(settings: { [string]: any })
	for key, value in settings do
		if (Theme.settings :: any)[key] ~= nil then
			(Theme.settings :: any)[key] = value
		end
	end
	-- High contrast also lifts every text tier, not just the domain colours.
	local ink = if Theme.settings.palette == "highContrast" then HIGH_CONTRAST_INK else BASE_INK
	for key, color in ink do
		(Theme.color :: any)[key] = color
	end
end

return Theme
