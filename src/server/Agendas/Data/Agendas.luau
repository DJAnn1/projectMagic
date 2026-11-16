--!strict
--[[
	Agendas: what towns and their neighbours do without you (docs/LivingHistory.md §8, Living History
	stage 4a). Numbers for Agendas/AgendaRules and Services/AgendaService; what people say about it.

	TUNING
		perDay          most agendas in one game day, world-wide
		chance          per kind, the chance a day has one (rolled in this order: siege, raid, alliance, trade)
		siegeFalls      an unattended siege: the chance the town falls (else the guards hold)
		raidBurns       an unattended raid: the chance it burns something (else it's driven off)
		siegeHaunt      studs: a town can be besieged only with a haunt this close (its theme comes too)
		raidReach       studs: the farthest two feuding towns can be for a raid
		feud / friends  base relation at or below / at or above which two towns raid / ally
		hours           { from, to } game hours a kind may start; over 24 = the small hours after
		lasts           game hours a kind plays out
		retakeDays      { min, max } game days an unattended fallen town stays fallen
		lookBack        game days of plans read at boot to find towns already fallen
		band            { min, max } Wildborn in a siege, and occupation: how many hold a fallen plaza
		liveReach       studs: a player this close to the town's centre sees it play out live (keep it
		                under Wildborn sleepRadius, or a band vanishes as soon as it rises)
		edge            studs beyond a town's radius a siege rises
		newsReach       studs: townspeople this far off have heard about it
		newsKeep        game days news stays news
	LINES (NPC/Data/Barks shape, AmbientLifeService:lineFor): news_<outcome> asked for rumours
	({town} {other} {dir}); shout_raid a townsperson as the fire starts; shout_raid_coming as raiders come in; journal_<outcome> first person.
	No digits. Our own data plus town names.
]]

local Barks = require(script.Parent.Parent.Parent.NPC.Data.Barks)

local Agendas = {}

Agendas.tuning = {
	perDay = 2,
	chance = { siege = 0.3, raid = 0.25, alliance = 0.15, trade = 0.35 },
	siegeFalls = 0.3,
	raidBurns = 0.55,
	siegeHaunt = 900,
	raidReach = 1600,
	feud = -0.25,
	friends = 0.35,
	hours = { siege = { 9, 19 }, raid = { 21, 27 }, alliance = { 10, 16 }, trade = { 8, 18 } },
	lasts = { siege = 3, raid = 1, alliance = 1, trade = 1 },
	retakeDays = { 2, 4 },
	lookBack = 6,
	band = { 3, 5 },
	occupation = 3,
	liveReach = 280, -- under WildbornService's sleepRadius (320), or a band would rise and vanish
	edge = 60,
	newsReach = 1400,
	newsKeep = 3,
}

Agendas.lines = {
	{ cat = "news_held", text = "Wildborn came at {town}, out {dir}. The guards held. Barely, the way I heard it." },
	{ cat = "news_held", text = "{town} had Wildborn at the gates. They're still standing, out {dir}." },
	{ cat = "news_fell", text = "{town}'s fallen. The Wildborn have it. You can see the smoke from the hill, out {dir}." },
	{ cat = "news_fell", text = "Don't go {dir} to {town}. The Wildborn took it. The folk there are shut in their houses." },
	{ cat = "news_fell", text = "{town} fell. Nobody's going to take it back. Who would?", high = { neuroticism = 0.5 } },
	{ cat = "news_retaken", text = "{town}'s free again, out {dir}. The Wildborn are gone and the builders are back on the roofs." },
	{ cat = "news_retaken", text = "Someone took {town} back. Good. I've cousins there." },
	{ cat = "news_burned", text = "Raiders from {other} came over to {town} in the night and set a fire. Out {dir}." },
	{ cat = "news_burned", text = "{other} and {town} are at it again. A barn went up, I heard." },
	{ cat = "news_driven_off", text = "{other} sent men against {town} in the dark. {town} saw them off." },
	{ cat = "news_driven_off", text = "There was trouble between {other} and {town} the other night. Nothing burned, this time." },
	{ cat = "news_sworn", text = "{town} and {other} have sworn friendship. Shared wells, shared watches, all of it." },
	{ cat = "news_sworn", text = "Envoys went between {town} and {other}. They're friends now, they say." },
	{ cat = "news_boom", text = "{town}'s doing well. New roofs, full stalls, out {dir}." },
	{ cat = "news_boom", text = "Everyone's selling to {town} this week. Prices there, you wouldn't believe." },
	{ cat = "news_bust", text = "Hard times in {town}. Nobody's buying, out {dir}." },
	{ cat = "news_bust", text = "{town}'s market's half empty. A bad season for them." },
	{ cat = "shout_raid", text = "Fire! Raiders from {other}!" },
	{ cat = "shout_raid", text = "They came from {other}! Get water!" },
	{ cat = "shout_raid", text = "Raiders! Someone wake the guards!" },
	{ cat = "shout_raid_coming", text = "Raiders! From {other}! Get the guards!" },
	{ cat = "shout_raid_coming", text = "There's people coming over the edge. That's {other}'s lot!" },
	{ cat = "shout_raid_coming", text = "{other}'s here! Inside, everyone!" },
	{ cat = "shout_siege", text = "Wildborn! Get inside!" },
	{ cat = "shout_siege", text = "They're coming in from the {dir}! Inside, all of you!" },
	{ cat = "shout_siege", text = "Guards! Wildborn at the edge of town!" },
} :: { Barks.Line }

Agendas.journal = {
	fell = "I heard {town} fell to the Wildborn.",
	held = "I heard {town} held off the Wildborn.",
	retaken = "I heard {town} is free of the Wildborn again.",
	burned = "I heard raiders from {other} set fire to {town}.",
	driven_off = "I heard {town} drove off raiders from {other}.",
	sworn = "I heard {town} and {other} have sworn friendship.",
	boom = "I heard {town} is doing well.",
	bust = "I heard {town} has fallen on hard times.",
} :: { [string]: string }

return Agendas
