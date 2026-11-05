--!strict
--[[
	Rarities: the six item rarities (docs/Items.md §2.3).

	Colours are the colour-safe (Okabe-Ito) set, and every rarity also has a glyph and its word:
	colour is never the only cue.

		affixes   random affixes a variant of this rarity rolls
		band      { lo, hi }: every affix value rolls inside this slice of the affix's own range,
		          so a Legendary "+4-12% power" lands in 8.4-12%, a Rare one in 5.6-9.6%
		baseMult  multiplier on the definition's base stats (an Epic staff is 25% stronger)
		valueMult multiplier on the base coin value
		weight    default drop weight; the loot stage scales it by luck and danger
	Artifacts are authored uniques: no random affixes, their stats are their own.
]]

local ItemTypes = require(script.Parent.Parent.ItemTypes)

local rgb = Color3.fromRGB

local list: { ItemTypes.RarityDef } = {
	{ id = "common", index = 1, name = "Common", glyph = "·", color = rgb(200, 194, 182), affixes = 0, band = { 0, 0.4 }, baseMult = 1, valueMult = 1, weight = 600 },
	{ id = "uncommon", index = 2, name = "Uncommon", glyph = "◇", color = rgb(0, 158, 115), affixes = 1, band = { 0, 0.5 }, baseMult = 1.08, valueMult = 2.5, weight = 260 },
	{ id = "rare", index = 3, name = "Rare", glyph = "◆", color = rgb(86, 180, 233), affixes = 2, band = { 0.2, 0.7 }, baseMult = 1.16, valueMult = 6, weight = 100 },
	{ id = "epic", index = 4, name = "Epic", glyph = "✦", color = rgb(204, 121, 167), affixes = 3, band = { 0.35, 0.85 }, baseMult = 1.25, valueMult = 15, weight = 32 },
	{ id = "legendary", index = 5, name = "Legendary", glyph = "★", color = rgb(230, 159, 0), affixes = 4, band = { 0.55, 1 }, baseMult = 1.36, valueMult = 40, weight = 8 },
	{ id = "artifact", index = 6, name = "Artifact", glyph = "✷", color = rgb(240, 228, 66), affixes = 0, band = { 1, 1 }, baseMult = 1, valueMult = 1, weight = 0 },
}

local byId: { [string]: ItemTypes.RarityDef } = {}
for _, r in list do
	byId[r.id] = r
end

return table.freeze({
	list = list,
	byId = byId,
	COMMON = 1,
	LEGENDARY = 5,
	ARTIFACT = 6,
})
