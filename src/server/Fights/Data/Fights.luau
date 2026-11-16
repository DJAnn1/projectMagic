--!strict
--[[
	Fights: NPCs fighting each other (docs/NpcFights.md). Numbers for Fights/FightRules and
	Services/NpcFightService, and what people say.

	BRAWL (two people of the same town who can't stand each other)
		checkEvery      real seconds between looks for a brawl in each town a player can see
		hours           { from, to } game hours (over 24 = after midnight): evenings, when tempers and
		                drink are up
		meet            studs: they have to be this close already (nobody walks across town to start one)
		grudgeAt        FightRules.grudge at or above this: they might come to blows
		chance          per check, for the worst pair in sight (seeded per pair and game hour)
		words           real seconds of words first, facing each other
		floor           share of max health: nobody goes below it (a brawl doesn't kill)
		maxPower        their bolts are held to this power
		lasts           real seconds before they've had enough of it
		apart           studs: one ran this far, it's over
		guardReach      studs: a guard (not busy) this close walks over to break it up
		breakAt         studs: the guard is this close, it's broken up
		sealAt          studs: a guard whose best magic is Space seals both from this far instead of walking
		                in (docs/Space.md: "guards with Space seal brawlers instead of fighting them")
		sealSeconds     how long the brawlers stand sealed (they can't move, cast or be hurt)
		pairCooldown    game days before the same two can come to blows again
		npcCooldown     game days before either starts another with anyone
		watchReach      studs: bystanders this close remember it (and talk about it)
	RAID (a feuding town's fighters come over; Services/AgendaService starts it, live only)
		count           { min, max } raiders
		spread          studs between raiders where they come in
		reach           studs from the building they mean to burn: close enough to set it alight
		lasts           real seconds before they give up and go home
		defend          studs: a guard or hunter of the town this close to a raider turns on them
		answer          studs: a raider this close to a defender who's fighting turns on them
		walkStep        studs: how far ahead each raider's walk target moves per check
	LINES (NPC/Data/Barks shape, AmbientLifeService:lineFor): brawl_words_a/_b, brawl_won,
	brawl_lost, brawl_broken (the guard), brawl_sealed (a Space guard, sealing them), brawl_watch (a bystander), raid_arrive (a raider),
	raid_fire (a raider at the fire), raid_flee (a raider giving up), raid_beaten (a defender).
	Vars: {name} the other one, {town}, {other}. No digits.
]]

local Barks = require(script.Parent.Parent.Parent.NPC.Data.Barks)

local Fights = {}

Fights.tuning = {
	brawl = {
		checkEvery = 20,
		hours = { 16, 25 },
		meet = 30,
		grudgeAt = 0.45,
		chance = 0.3,
		words = 4,
		floor = 0.35,
		maxPower = 2,
		lasts = 40,
		apart = 45,
		guardReach = 90,
		breakAt = 9,
		sealAt = 35,
		sealSeconds = 5,
		pairCooldown = 1,
		npcCooldown = 0.5,
		watchReach = 40,
	},
	raid = {
		count = { 3, 5 },
		spread = 6,
		reach = 10,
		lasts = 180,
		defend = 140,
		answer = 45,
		walkStep = 20,
	},
}

Fights.lines = {
	{ cat = "brawl_words_a", text = "Say that again. Go on." },
	{ cat = "brawl_words_a", text = "I've had it with you, {name}." },
	{ cat = "brawl_words_a", text = "You've been asking for this a long time." },
	{ cat = "brawl_words_a", text = "Don't you walk away from me, {name}." },
	{ cat = "brawl_words_a", text = "Everyone knows what you did. Everyone." },
	{ cat = "brawl_words_b", text = "Or what? What are you going to do?" },
	{ cat = "brawl_words_b", text = "Back off, {name}. I mean it." },
	{ cat = "brawl_words_b", text = "You want to do this here? Fine." },
	{ cat = "brawl_words_b", text = "Not this again." },
	{ cat = "brawl_won", text = "Stay down. And stay out of my way." },
	{ cat = "brawl_won", text = "That's the end of it, {name}." },
	{ cat = "brawl_won", text = "Hah. Next time think before you open your mouth." },
	{ cat = "brawl_lost", text = "Fine. Fine! You win." },
	{ cat = "brawl_lost", text = "This isn't over, {name}." },
	{ cat = "brawl_lost", text = "Enough. I'm done." },
	{ cat = "brawl_broken", text = "Enough! Both of you, enough!" },
	{ cat = "brawl_broken", text = "Break it up. Now. Before someone gets hurt." },
	{ cat = "brawl_broken", text = "Not in my streets. Go home, the pair of you." },
	{ cat = "brawl_sealed", text = "Stay there and cool off. Both of you." },
	{ cat = "brawl_sealed", text = "That's enough. You can think about it in there." },
	{ cat = "brawl_sealed", text = "Hold still. Nobody's hitting anybody now." },
	{ cat = "brawl_watch", text = "Here we go again." },
	{ cat = "brawl_watch", text = "Someone get a guard!" },
	{ cat = "brawl_watch", text = "Those two. Every time." },
	{ cat = "brawl_watch", text = "Ten years they've hated each other, and it's still this." },
	{ cat = "raid_arrive", text = "{town} had this coming." },
	{ cat = "raid_arrive", text = "For {other}! Burn it!" },
	{ cat = "raid_arrive", text = "Quick and quiet. In and out." },
	{ cat = "raid_fire", text = "That'll teach them." },
	{ cat = "raid_fire", text = "It's going up! Back, back!" },
	{ cat = "raid_flee", text = "Too many of them. Fall back!" },
	{ cat = "raid_flee", text = "Leave it! Home, now!" },
	{ cat = "raid_beaten", text = "And tell {other} not to come back!" },
	{ cat = "raid_beaten", text = "That's the last of them. Everyone all right?" },
} :: { Barks.Line }

return Fights
