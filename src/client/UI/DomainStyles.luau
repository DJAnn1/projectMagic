--!strict
--[[
	DomainStyles: how each domain looks and sounds in the interface. Pure data; Theme reads it.

	Colour is never the only cue. Every domain badge also shows:
		monogram  two letters, unique per domain (readable with no colour at all)
		shape     from the domain's rarity: Common circle, Uncommon square, Rare diamond, Mythic ring
	so the High contrast palette (no colour) loses nothing.

	signature  the domain's own colour, picked from Data/Domains feel.palette and lifted where
	           needed to stay readable on the dark parchment background
	safe       the colour-safe palette: anchored on Okabe-Ito / Paul Tol hues and spread in lightness,
	           so neighbouring domains stay apart under protanopia, deuteranopia and tritanopia
	motif      the brief for the icon artist (docs/UI.md §6 asset checklist)
	sound      key into Theme.sounds for the domain's UI cue (select, awaken)
	icon       rbxassetid of the domain icon; "" = draw the monogram badge instead
]]

export type DomainStyle = {
	monogram: string,
	signature: Color3,
	safe: Color3,
	motif: string,
	sound: string,
	icon: string,
}

local rgb = Color3.fromRGB

local DomainStyles: { [string]: DomainStyle } = {
	energy = { monogram = "En", signature = rgb(255, 140, 40), safe = rgb(230, 159, 0), motif = "Radiating spark: a point with uneven rays.", sound = "domain_energy", icon = "" },
	earth = { monogram = "Ea", signature = rgb(176, 140, 100), safe = rgb(166, 118, 29), motif = "Stacked strata: three heavy horizontal bands.", sound = "domain_earth", icon = "" },
	water = { monogram = "Wa", signature = rgb(70, 150, 235), safe = rgb(58, 143, 214), motif = "Falling drop over a single ripple line.", sound = "domain_water", icon = "" },
	air = { monogram = "Ai", signature = rgb(220, 235, 245), safe = rgb(154, 208, 236), motif = "Three curling gust strokes.", sound = "domain_air", icon = "" },
	life = { monogram = "Li", signature = rgb(90, 200, 90), safe = rgb(0, 158, 115), motif = "A sprout with two leaves and a root.", sound = "domain_life", icon = "" },
	mind = { monogram = "Mi", signature = rgb(200, 120, 255), safe = rgb(204, 121, 167), motif = "An open eye inside concentric waves.", sound = "domain_mind", icon = "" },
	spirit = { monogram = "Sp", signature = rgb(160, 230, 255), safe = rgb(240, 228, 66), motif = "A wisp rising from a small flame-shaped sigil.", sound = "domain_spirit", icon = "" },
	void = { monogram = "Vo", signature = rgb(130, 105, 175), safe = rgb(142, 124, 195), motif = "A ring whose inner edge spirals inward.", sound = "domain_void", icon = "" },
	space = { monogram = "Sc", signature = rgb(150, 160, 255), safe = rgb(110, 110, 232), motif = "A folded square with one star in the crease.", sound = "domain_space", icon = "" },
	time = { monogram = "Ti", signature = rgb(230, 200, 120), safe = rgb(216, 198, 144), motif = "An hourglass split by a crack.", sound = "domain_time", icon = "" },
	gravity = { monogram = "Gr", signature = rgb(160, 130, 210), safe = rgb(176, 90, 122), motif = "Three orbits collapsing to a heavy dot.", sound = "domain_gravity", icon = "" },
	reality = { monogram = "Re", signature = rgb(255, 80, 200), safe = rgb(255, 255, 255), motif = "A square drawn twice, misaligned by a few degrees.", sound = "domain_reality", icon = "" },
}

return table.freeze(DomainStyles)
