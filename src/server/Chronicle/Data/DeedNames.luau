--!strict
--[[
	DeedNames: what a legend leaves behind (docs/LivingHistory.md §6, Living History stage 2).
	Read by Chronicle/HistoryRules; Services/HistoryService uses the results.

	{Root} is the legend's `what` without a leading "the", capitalised ("Ashwalker", "Drought",
	"Tamine"), or `rootByKind` when a deed has no `what`.

		epithets   by group: what an item that took part is called from then on
		places     by group: what a spot in the wilds is called after a legend there
		history    by kind: the item's one line of history ({what} {where}; no names of people)
		monument   by group: the line cut into a town's stone ({what} {where} {who}); `_nameless`
		           when nobody is named, or the name has been taken off
		lines      what townspeople say (NPC/Data/Barks shape, AmbientLifeService:lineFor):
		             item_known   they recognise an item with a past you're carrying ({epithet} {what})
	Rules: our own data only; no digits; short.
]]

local Barks = require(script.Parent.Parent.Parent.NPC.Data.Barks)

local Names = {}

Names.rootByKind = {
	titan_fell = "Titan",
	boss_slain = "Wildborn",
	shared_event_won = "Siege",
	feral_ended = "Wild Spell",
	feral_escaped = "Wild Spell",
	crisis_resolved = "Trouble",
	event_relieved = "Hard Times",
	great_spell = "Storm",
	quake = "Quake",
	tsunami = "Wave",
	npc_awakened = "Waking",
	world_first = "First Light",
	siege_broken = "Siege",
	town_fell = "Fall",
	town_retaken = "Freeing",
} :: { [string]: string }

Names.epithets = {
	feat = { "{Root}'s Bane", "Bane of the {Root}", "The {Root}'s End", "{Root}-ender" },
	disaster = { "{Root}-touched", "Witness of the {Root}", "{Root}caller" },
	wonder = { "{Root}light", "{Root}'s Mark", "The {Root} Gift" },
	loss = { "{Root}'s Sorrow", "Mourner of the {Root}" },
} :: { [string]: { string } }

Names.places = {
	feat = { "{Root}'s Fall", "{Root} Field", "{Root}'s Rest", "The {Root} Stones" },
	disaster = { "{Root} Scar", "The {Root} Break", "{Root} Waste" },
	wonder = { "{Root}light Hollow", "{Root}'s Glade", "The {Root} Ring" },
	loss = { "{Root}'s Grief", "The {Root} Graves" },
} :: { [string]: { string } }

Names.history = {
	titan_fell = "Brought down {what} {where}.",
	boss_slain = "Struck down {what} {where}.",
	shared_event_won = "Held fast through the {what} {where}.",
	feral_ended = "Ended {what} {where}.",
	feral_escaped = "Was there when {what} tore loose {where}.",
	crisis_resolved = "Put right the {what} {where}.",
	event_relieved = "Broke the {what} {where}.",
	great_spell = "Cast {what} {where}.",
	quake = "Shook the ground {where}.",
	tsunami = "Raised the sea {where}.",
	npc_awakened = "Was there when {what} awoke {where}.",
	world_first = "Was first to cast {what}, {where}.",
	siege_broken = "Held {what} against the Wildborn.",
	town_fell = "Was there when {what} fell.",
	town_retaken = "Took {what} back from the Wildborn.",
} :: { [string]: string }

Names.monument = {
	feat = "Cut into the stone: {what}, {where}. And under it a name: {who}.",
	feat_nameless = "Cut into the stone: {what}, {where}. The name under it has worn away.",
	disaster = "Cut into the stone: the day of {what}, {where}. And a name, darker than the rest: {who}.",
	disaster_nameless = "Cut into the stone: the day of {what}, {where}. Nobody carved who.",
	wonder = "Cut into the stone: {what}, {where}. And a name: {who}.",
	wonder_nameless = "Cut into the stone: {what}, {where}.",
	loss = "Cut into the stone: {what}, {where}. Remember {who}.",
	loss_nameless = "Cut into the stone: {what}, {where}. Remember them.",
} :: { [string]: string }

Names.lines = {
	{ cat = "item_known", text = "Is that {epithet}? The one from {what}?" },
	{ cat = "item_known", text = "I know that. Everyone's heard about {what}." },
	{ cat = "item_known", text = "That's the one, isn't it? From {what}. May I look?", high = { openness = 0.5 } },
	{ cat = "item_known", text = "{epithet}. My cousin swore it was bigger.", high = { extraversion = 0.55 } },
	{ cat = "item_known", text = "Careful where you point that. I know what it did.", high = { neuroticism = 0.55 } },
} :: { Barks.Line }

return Names
