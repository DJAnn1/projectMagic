--!strict
--[[
	GreetingRules: how an NPC treats a player who walks up. Pure.

		GreetingRules.score(input) -> number
		GreetingRules.band(input) -> "fawn" | "warm" | "neutral" | "awe" | "wary" | "avoid"
		GreetingRules.whisper(band) -> "greet_whisper_good" | "greet_whisper_bad" | nil

	input: {
		settlement  your reputation in this town      (ReputationService; about -50..50 and beyond)
		faction     your standing with this NPC's faction, the strongest either way   (-1000..1000)
		opinion     what this NPC personally thinks of you, -1..1   (DialogueEngine.band)
		infamy      0..                                (ReputationService)
		bounty      true if there's a bounty on you here
		notoriety   your highest mythic notoriety      (ReputationService)
		attuned     you have a spell readied: magic visibly in your hand
		agreeable   the NPC's agreeableness, 0..1
		nervous     the NPC's neuroticism, 0..1
		child       the NPC is a child
	}

	SCORE = town + faction / 2 + opinion - infamy + a nudge from personality. Each is scaled so about
	1 is a lot. A bounty can't go above wary. Children never fawn or stay wary for long: they're
	excited or scared. A readied spell makes a neutral stranger stare.
]]

local T = table.freeze({
	settlementScale = 50, -- reputation at which the town counts as a full point
	factionScale = 600, -- Revered
	factionWeight = 0.5,
	infamyScale = 25, -- the bounty threshold
	personality = 0.4,
	fawnAt = 1,
	warmAt = 0.3,
	waryBelow = -0.3,
	avoidBelow = -0.9,
	notorietyWary = 35, -- when the Quiet Hand starts hunting: people have heard
})

export type Input = {
	settlement: number,
	faction: number,
	opinion: number,
	infamy: number,
	bounty: boolean,
	notoriety: number,
	attuned: boolean,
	agreeable: number,
	nervous: number,
	child: boolean,
}

local GreetingRules = {}

function GreetingRules.score(i: Input): number
	return math.clamp(i.settlement / T.settlementScale, -1.5, 1.5)
		+ math.clamp(i.faction / T.factionScale, -1, 1) * T.factionWeight
		+ i.opinion
		- i.infamy / T.infamyScale
		+ (i.agreeable - i.nervous) * T.personality
end

function GreetingRules.band(i: Input): string
	local s = GreetingRules.score(i)
	local band = if s >= T.fawnAt then "fawn"
		elseif s >= T.warmAt then "warm"
		elseif s > T.waryBelow then "neutral"
		elseif s > T.avoidBelow then "wary"
		else "avoid"
	if i.bounty and (band == "fawn" or band == "warm" or band == "neutral") then
		band = "wary"
	end
	if band == "neutral" and i.notoriety >= T.notorietyWary then
		band = "wary"
	end
	if band == "neutral" and i.attuned then
		band = "awe"
	end
	if i.child then
		if band == "fawn" then
			band = "warm"
		elseif band == "wary" and s > (T.waryBelow + T.avoidBelow) / 2 then
			band = "neutral"
		end
	end
	return band
end

-- What people further off say to each other as you pass. Nothing for ordinary strangers.
function GreetingRules.whisper(band: string): string?
	if band == "fawn" then
		return "greet_whisper_good"
	elseif band == "wary" or band == "avoid" then
		return "greet_whisper_bad"
	end
	return nil
end

return GreetingRules
