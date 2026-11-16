--!strict
--[[
	Omens data: strange signs before big events (docs/Omens.md). Nothing announces an omen. The
	world shows it, people talk about it, and the Journal remembers it.

	SIGNS: what you notice. Each draws with one client style (Controllers/OmenController):
		birds   flocks flying hard away from the place, over your head
		smoke   dark columns rising at the place, seen from far off
		tremor  the ground shivers under you now and then (a small camera shake)
		tint    the light changes colour around you (the sky darkens, reddens, yellows, sickens)
		star    a new light in the sky above the place, brighter as it nears
		motes   glowing motes rising out of the ground at the place
	  journal  first-person line the first time you see this sign (once ever, data.omens.signs)
	  rumor    what a townsperson near it says when asked for news; {dir} = the direction from them

	SOURCES: what an omen comes before, and how. `signs` lists one or two signs. `lead` is how many
	seconds before the event it begins (strength grows from 0 to 1 over the lead). `seen` is how
	far (studs) from the place you can notice it; math.huge = anywhere. `after` is the line you
	write when the event arrives, if you saw its omen (once ever per source, data.omens.after).
	  titan_<kind>    before each Titan wades ashore (TitanService schedule), at its landing point
	  shared_<type>   before each shared event (SharedEventService schedule), at its town
	  rift            before a Rift opens (RiftService schedule), at its town
	  world_<type>    a world event the EventDirector rolled waits `lead` seconds before it starts
	                  (foreshadowed); every EventDefs type has one
]]

export type Sign = { style: string, color: Color3, journal: string, rumor: string }
export type Source = { signs: { string }, lead: number, seen: number, after: string }

local Omens = {}

Omens.styles = { "birds", "smoke", "tremor", "tint", "star", "motes" }

Omens.signs = {
	birds = {
		style = "birds",
		color = Color3.fromRGB(30, 28, 26),
		journal = "Every bird in the sky went the same way at once, low and fast and silent. I've never seen birds flee like that. Something over there frightened them.",
		rumor = "The birds left all at once this morning, every one of them flying away from the {dir}. My grandmother said that means something's coming.",
	},
	smoke = {
		style = "smoke",
		color = Color3.fromRGB(58, 52, 50),
		journal = "Smoke stood up on the horizon in great dark columns, and nobody I asked knew what was burning.",
		rumor = "There's smoke rising off to the {dir}. Not chimney smoke. Too much of it, and too dark.",
	},
	tremor = {
		style = "tremor",
		color = Color3.fromRGB(120, 100, 80),
		journal = "The ground keeps shivering under my feet, just for a breath at a time, like something huge is shifting a long way off.",
		rumor = "Did you feel that? The ground's been twitching all day. The cups on my shelf walk to the edge on their own.",
	},
	dark_sky = {
		style = "tint",
		color = Color3.fromRGB(110, 120, 150),
		journal = "The light went thin and grey in the middle of the day, though there wasn't a cloud I could point to.",
		rumor = "The sky's gone heavy over the {dir}, and the light's turned the colour of slate. I'd keep a roof close.",
	},
	red_sky = {
		style = "tint",
		color = Color3.fromRGB(230, 120, 90),
		journal = "The whole sky turned red, as if the sun were setting everywhere at once. It made my skin crawl.",
		rumor = "Red sky all day, off to the {dir}. Not sunset red. Wrong red.",
	},
	dry_haze = {
		style = "tint",
		color = Color3.fromRGB(235, 205, 130),
		journal = "A dry yellow haze hung over everything. My lips cracked and the leaves curled while I watched.",
		rumor = "The air's gone dry and yellow, and the well rope comes up shorter every day. Something's drinking the land to the {dir}.",
	},
	sick_air = {
		style = "tint",
		color = Color3.fromRGB(165, 190, 130),
		journal = "The air turned sour and greenish, and every dog I passed was whining. I didn't want to breathe too deep.",
		rumor = "Something's wrong with the air. The dogs won't stop whining and the milk turns by noon.",
	},
	new_star = {
		style = "star",
		color = Color3.fromRGB(255, 236, 190),
		journal = "There's a new star in the sky, and it's getting brighter. It wasn't there last night.",
		rumor = "Have you seen the new star, low over the {dir}? It wasn't there last night, and it's brighter every time I look.",
	},
	motes = {
		style = "motes",
		color = Color3.fromRGB(170, 140, 255),
		journal = "Little lights were rising out of the ground like sparks going the wrong way. The magic there felt stretched thin, like a held breath.",
		rumor = "Lights have been coming up out of the ground to the {dir}. Pretty, but my hair stands on end when I go near.",
	},
} :: { [string]: Sign }

Omens.sources = {
	-- Titans (TitanService): at the landing point, 15 minutes ahead.
	titan_ashwalker = { signs = { "smoke", "tremor" }, lead = 900, seen = 1100, after = "So that was what the smoke and the shaking were: a Titan, walking out of the sea in a cloak of fire." },
	titan_stonefather = { signs = { "tremor", "birds" }, lead = 900, seen = 1100, after = "The trembling ground and the fleeing birds were for this: a Titan of stone, walking ashore." },
	titan_stormcrown = { signs = { "dark_sky", "birds" }, lead = 900, seen = 1100, after = "The grey sky and the birds were its herald. A Titan crowned with storm came out of the sea." },
	-- Shared events (SharedEventService): at the town, 10 minutes ahead.
	shared_elemental = { signs = { "motes" }, lead = 600, seen = 700, after = "The rising lights were raw magic gathering. It took a body and came for the town." },
	shared_storm = { signs = { "dark_sky", "birds" }, lead = 600, seen = 800, after = "The heavy sky broke into a storm of magic, just as the birds had known it would." },
	agenda_siege = { signs = { "smoke", "birds" }, lead = 300, seen = 900, after = "The smoke and the birds were for this: Wildborn, walking on the town." }, -- Services/AgendaService
	shared_siege = { signs = { "smoke" }, lead = 600, seen = 900, after = "The smoke on the horizon was their campfires. They came for the town." },
	shared_comet = { signs = { "new_star" }, lead = 600, seen = math.huge, after = "The new star fell. It wasn't a star at all." },
	-- Rifts (RiftService): at the town, 5 minutes ahead.
	rift = { signs = { "motes", "birds" }, lead = 300, seen = 600, after = "The lights rising out of the ground were the world thinning. It tore, and a Rift opened." },
	-- World events (EventDirector): rolled, then foreshadowed for `lead` seconds before they start.
	world_drought = { signs = { "dry_haze" }, lead = 240, seen = 900, after = "The yellow haze settled into a drought. The wells are failing." },
	world_wildfire = { signs = { "smoke" }, lead = 180, seen = 900, after = "The smoke became fire, running through the trees." },
	world_magic_storm = { signs = { "motes", "dark_sky" }, lead = 180, seen = 800, after = "The rising lights and the heavy sky became a storm of raw magic." },
	world_tempest = { signs = { "dark_sky", "birds" }, lead = 240, seen = 900, after = "The birds were right to flee. The grey sky broke into a tempest." },
	world_volcanic_unrest = { signs = { "tremor", "smoke" }, lead = 240, seen = 1000, after = "The shivering ground and the smoke were the vents waking up." },
	world_monster_migration = { signs = { "birds" }, lead = 180, seen = 900, after = "The birds fled first. Then the herds came, and the things that hunt them." },
	world_plague = { signs = { "sick_air" }, lead = 240, seen = 600, after = "The sour air was sickness coming. It's in the town now." },
	world_ley_surge = { signs = { "motes" }, lead = 180, seen = 500, after = "The lights rising from the ground were the nexus filling to overflowing." },
	world_eclipse = { signs = { "red_sky" }, lead = 180, seen = math.huge, after = "The red sky came before the dark. The sun went out." },
	world_starfall = { signs = { "new_star" }, lead = 240, seen = math.huge, after = "The new star wasn't new. It was falling." },
} :: { [string]: Source }

Omens.tick = 2 -- seconds between omen updates (OmenService)
Omens.noticeAt = 0.25 -- strength from which an omen can be noticed (Journal, rumours)
Omens.noticeRange = 450 -- studs from the place within which you notice a sign that isn't seen-anywhere
Omens.rumorRange = 1200 -- townspeople within this many studs of an omen talk about it
Omens.linger = 20 -- seconds an omen keeps showing after its event begins (then the event's own sights take over)

return Omens
