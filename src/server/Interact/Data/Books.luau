--!strict
--[[
	Books: what's on the shelves (docs/Buildings.md §3.4). A bookshelf shows one seeded book
	(world seed + its InteractId). Reading it is a study (ProgressionService:awardStudy, source
	"book", once per shelf): study XP in the branch if you've unlocked it, otherwise the lore is
	recorded (knowledge you can unlock it with later). Every book also records its own lore id.

	Magic schools carry the whole list; homes only the common primers (`common = true`).
]]

local Registry = require(game:GetService("ReplicatedStorage").Shared.Magic.Registry)

export type Book = { id: string, title: string, branch: string, common: boolean? }

local list: { Book } = {
	{ id = "book_sparks", title = "Sparks and Where They Go", branch = "energy", common = true },
	{ id = "book_stone_listens", title = "The Stone Listens", branch = "earth", common = true },
	{ id = "book_river_manners", title = "On the Manners of Rivers", branch = "water", common = true },
	{ id = "book_kite_season", title = "A Kite-Maker's Season", branch = "air", common = true },
	{ id = "book_green_hands", title = "Green Hands: A Gardener's Almanac", branch = "life", common = true },
	{ id = "book_quiet_minds", title = "Quiet Minds, Loud Rooms", branch = "mind", common = true },
	{ id = "book_lanterns_dead", title = "Lanterns for the Dead", branch = "spirit", common = true },
	{ id = "book_heat_ledger", title = "The Heat Ledger", branch = "thermal" },
	{ id = "book_candlemakers", title = "Notes of the Candlemakers' Guild", branch = "luminous" },
	{ id = "book_fire_climbs", title = "Why Fire Climbs", branch = "pyromancy" },
	{ id = "book_bending_hot", title = "Bending Hot Things Cold", branch = "calefaction" },
	{ id = "book_quarry_songs", title = "Quarry Songs", branch = "geomancy" },
	{ id = "book_fault_lines", title = "A Short History of Fault Lines", branch = "seismic" },
	{ id = "book_iron_memory", title = "Iron Has a Memory", branch = "metallurgy" },
	{ id = "book_tides_tables", title = "Tide Tables and Their Liars", branch = "tidal" },
	{ id = "book_wells_springs", title = "Of Wells and Springs", branch = "hydromancy" },
	{ id = "book_storm_glass", title = "Reading the Storm Glass", branch = "weathercraft" },
	{ id = "book_menders", title = "The Menders' Handbook", branch = "restoration" },
	{ id = "book_walls_unseen", title = "Walls You Cannot See", branch = "warding" },
	{ id = "book_borrowed_faces", title = "Borrowed Faces", branch = "illusion" },
}

local common: { Book } = {}
for _, book in list do
	assert(Registry.branches[book.branch], "Books: unknown branch " .. book.branch)
	if book.common then
		table.insert(common, book)
	end
end

return table.freeze({
	list = list,
	common = common,
})
