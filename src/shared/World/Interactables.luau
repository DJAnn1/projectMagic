--!strict
--[[
	Interactables: every kind of thing in the world a player can use, as data
	(docs/Buildings.md §3). Generators tag a part "Interactable" and set its attribute
	Interactable = <kind>; Services/InteractionService gives it a ProximityPrompt from this
	table and routes the trigger to the kind's handler.

		action / object   the prompt's ActionText / ObjectText (some handlers rewrite them live)
		hold              HoldDuration (seconds); 0 = a press
		distance          MaxActivationDistance (studs)
		handler           what happens (InteractionService):
		                    door      open / close / unlock (Interact/Doors)
		                    seat      sit: "bed" rests, "mat" meditates (the part is a Seat)
		                    container ContainerService (chests, barrels, crates, wardrobes)
		                    station   CraftingService (forge, workbench, loom, hearth, alchemy, enchanting)
		                    light     lamps and fireplaces (Interact/Lamps): toggle; lit at dusk when occupied
		                    book      read a seeded book: study XP or lore (Interact/Data/Books)
		                    notice    the local notice board: opens the Journal's quests
		                    drink     a well: a drink heals and puts out burning
		                    dummy     a training dummy: resets its damage readout
		                    ward      a ward stone: a Ward for 5 minutes (10 min cooldown)
		                    insight   a focus-crystal pedestal: a one-time insight (study XP)
		                    deed      a house for sale / your house (HousingService)
		                    decor     placed furniture: the owner picks it up (HousingService)
		container         { slots, loot }: grid size and the ContainerLoot table its contents roll from
		station           { id }: the station id recipes ask for (Data/Recipes); the part's
		                  StationTier attribute (default 1) says how good it is
		key               prompt key when it shares a spot with another prompt ("F")
		los               false: no line-of-sight check (the prompt sits inside other geometry)

	Shared so the client can name things consistently. Adding a kind: an entry here + a
	generator calling interact(b, part, "<kind>") + (for a new handler) a branch in
	InteractionService.
]]

export type Def = {
	action: string,
	object: string,
	hold: number,
	distance: number,
	handler: string,
	container: { slots: number, loot: string }?,
	station: { id: string }?,
	key: string?,
	los: boolean?,
}

local Interactables: { [string]: Def } = {
	-- Doors and furniture
	door = { action = "Open", object = "Door", hold = 0, distance = 7, handler = "door" },
	bed = { action = "Rest", object = "Bed", hold = 0.4, distance = 7, handler = "seat", los = false },
	mat = { action = "Meditate", object = "Meditation mat", hold = 0.4, distance = 7, handler = "seat", los = false },

	-- Storage
	chest = { action = "Open", object = "Chest", hold = 0.3, distance = 8, handler = "container", container = { slots = 16, loot = "household" } },
	barrel = { action = "Search", object = "Barrel", hold = 0.5, distance = 8, handler = "container", container = { slots = 8, loot = "provisions" } },
	crate = { action = "Search", object = "Crate", hold = 0.5, distance = 8, handler = "container", container = { slots = 8, loot = "workshop" } },
	wardrobe = { action = "Open", object = "Wardrobe", hold = 0.3, distance = 8, handler = "container", container = { slots = 10, loot = "clothes" } },

	-- Crafting stations
	forge = { action = "Use", object = "Forge", hold = 0, distance = 9, handler = "station", station = { id = "forge" } },
	workbench = { action = "Use", object = "Workbench", hold = 0, distance = 8, handler = "station", station = { id = "workbench" } },
	loom = { action = "Weave", object = "Loom", hold = 0, distance = 8, handler = "station", station = { id = "loom" } },
	hearth = { action = "Cook", object = "Hearth", hold = 0, distance = 8, handler = "station", station = { id = "hearth" } },
	alchemy_table = { action = "Brew", object = "Alchemy table", hold = 0, distance = 8, handler = "station", station = { id = "alchemy" } },
	enchanting_desk = { action = "Scribe", object = "Enchanting desk", hold = 0, distance = 8, handler = "station", station = { id = "enchanting" } },

	-- Lights
	lamp = { action = "Light", object = "Lamp", hold = 0, distance = 12, handler = "light", los = false },
	fireplace = { action = "Light fire", object = "Fireplace", hold = 0.3, distance = 8, handler = "light", key = "F" },

	-- Knowledge, town life, magic
	bookshelf = { action = "Browse", object = "Bookshelf", hold = 0.6, distance = 8, handler = "book" },
	notice_board = { action = "Read", object = "Notice board", hold = 0, distance = 9, handler = "notice" },
	well = { action = "Drink", object = "Well", hold = 0.5, distance = 8, handler = "drink", los = false },
	dummy = { action = "Reset", object = "Training dummy", hold = 0, distance = 10, handler = "dummy" },
	ward_stone = { action = "Attune", object = "Ward stone", hold = 1, distance = 8, handler = "ward" },
	pedestal = { action = "Study", object = "Focus crystal", hold = 1.5, distance = 8, handler = "insight" },

	-- Housing
	deed = { action = "Buy", object = "House for sale", hold = 0.8, distance = 9, handler = "deed" },
	decor = { action = "Pick up", object = "Furniture", hold = 0.5, distance = 8, handler = "decor", los = false },
}

return table.freeze(Interactables)
