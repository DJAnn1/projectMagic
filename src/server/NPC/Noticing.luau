--!strict
--[[
	Noticing: the rules for people noticing what you just did with magic (docs/Noticing.md, idea #38
	"People noticed that"). Pure: no Instances, no clocks of its own, so Tests/Noticing.spec runs it
	directly. Services/NoticeService does the world part (who's near, the delay, the bubble).

	Two ways to be noticed:
		SEEN    someone within `seeRadius` of you or of where it landed says something about it,
		        a moment later. At most one person per cast.
		HEARD   a big spell (power 6+, the land changed, someone killed, a mythic domain) carries to
		        towns within `hearReach`. Later, someone there who didn't see it asks you about it
		        instead of greeting you, with the direction it came from.

		Noticing.read(payload, mythic, kind) -> Seen        what the cast did, from Topics.MagicWitnessed
		Noticing.big(seen) -> boolean                         heard from afar?
		Noticing.categories(seen, opts) -> { string }         NoticedLines categories, best first
		Noticing.heardCategories(seen) -> { string }
		Noticing.chance(seen, extraversion, child) -> number  0..1 that the best witness says anything
		Noticing.score(extraversion, child, distance, roll) -> number   who speaks: the highest
		Noticing.outclassed(power, npcTier) -> boolean        a real mage watching a small spell
		Noticing.fresh(seenAt, key, clock, big) -> boolean    the same spell again so soon isn't news
]]

local Noticing = {}

Noticing.Tuning = table.freeze({
	seeRadius = 36, -- studs from the caster or the landing spot
	scareRadius = 12, -- a harmful spell landing this close to someone frightens them
	playerGap = 20, -- seconds: at most one comment per player this often
	bigPlayerGap = 6, -- ...or this often when it's something big
	npcGap = 240, -- the same person comments to the same player at most this often
	repeatGap = 600, -- the same spell again within this is old news (unless big)
	reactDelay = { 0.5, 1.1 }, -- seconds before they speak: people take a moment
	facing = 2.5, -- seconds they stop and look
	bigPower = 6,
	hearReach = 420, -- studs from a town's centre at which a big spell is heard there
	heardKeep = 1200, -- real seconds a heard spell stays worth asking about
	heardAskers = 3, -- at most this many people in a town ask about one spell
	askChance = 0.6, -- of each eligible person when you walk up
	heardPerTown = 4, -- big spells a town keeps in mind at once
	outclassTier = 4, -- a mage of this tier...
	outclassPower = 2, -- ...isn't impressed by a spell of this power or less
	speakRadius = 28,
})

export type Seen = {
	domains: { string },
	power: number,
	harmful: boolean,
	kind: string?, -- RouteSummaries kind: attack, heal, protect, boost, control, move, land, sense, utility, none
	form: string?,
	key: string?,
	effective: boolean,
	backfire: boolean,
	practice: boolean, -- only practice dummies were hit
	hurt: boolean, -- a person or creature (not a dummy) was hurt
	killed: boolean,
	changedLand: boolean,
	mythic: boolean,
}

local function bool(value: any): boolean
	return value == true
end

-- `mythic`: whether any of its domains is Mythic (the service asks Registry). `kind`: SpellOutcome's.
function Noticing.read(payload: { [string]: any }, mythic: boolean, kind: string?): Seen
	return {
		domains = if typeof(payload.domains) == "table" then payload.domains else {},
		power = tonumber(payload.power) or 1,
		harmful = bool(payload.harmful),
		kind = kind,
		form = payload.form,
		key = payload.key,
		-- A combo or other publisher that doesn't say counts as having worked.
		effective = payload.effective ~= false,
		backfire = bool(payload.backfire),
		practice = bool(payload.practice),
		hurt = bool(payload.hurt),
		killed = bool(payload.killed),
		changedLand = bool(payload.changedLand),
		mythic = mythic,
	}
end

function Noticing.big(seen: Seen): boolean
	return seen.power >= Noticing.Tuning.bigPower or seen.changedLand or seen.killed or seen.mythic
end

--[[
	Categories for a witness, most specific first. NoticeService tries each until a line fits, so a
	category with no line for this person (say, no adult line in noticed_dummy) falls through.
	opts.scared: it landed near them and was harmful. opts.outclassed: Noticing.outclassed.
]]
function Noticing.categories(seen: Seen, opts: { scared: boolean?, outclassed: boolean? }): { string }
	local out: { string } = {}
	local function add(category: string)
		table.insert(out, category)
	end
	if seen.backfire then
		add("noticed_backfire")
	end
	if seen.killed then
		add("noticed_killed")
	end
	if seen.hurt then
		add("noticed_hurt")
	end
	if opts.scared then
		add("noticed_scared")
	end
	if seen.mythic then
		add("noticed_mythic")
	end
	if seen.changedLand then
		add("noticed_land")
	end
	if not seen.effective or seen.kind == "none" then
		add("noticed_dud")
	end
	if seen.power >= Noticing.Tuning.bigPower then
		add("noticed_big")
	end
	if opts.outclassed then
		add("noticed_weak")
	end
	if seen.practice then
		add("noticed_dummy")
	end
	if seen.kind and seen.kind ~= "attack" and seen.kind ~= "none" then
		add("noticed_" .. seen.kind)
	end
	if seen.domains[1] then
		add("noticed_" .. seen.domains[1])
	end
	add("noticed_any")
	return out
end

function Noticing.heardCategories(seen: Seen): { string }
	local out: { string } = {}
	if seen.killed then
		table.insert(out, "heard_killed")
	end
	if seen.mythic then
		table.insert(out, "heard_mythic")
	end
	if seen.changedLand then
		table.insert(out, "heard_land")
	end
	if seen.domains[1] then
		table.insert(out, "heard_" .. seen.domains[1])
	end
	table.insert(out, "heard_any")
	return out
end

-- Something alarming always gets a reaction; ordinary magic only from people inclined to say so.
function Noticing.chance(seen: Seen, extraversion: number, child: boolean): number
	if seen.backfire or seen.hurt or seen.killed or Noticing.big(seen) then
		return 1
	end
	return math.clamp(0.3 + extraversion * 0.4 + (if child then 0.25 else 0), 0, 0.95)
end

-- The witness most likely to speak up: outgoing, young, close. `roll` is 0..1 from a seeded rng.
function Noticing.score(extraversion: number, child: boolean, distance: number, roll: number): number
	local near = 1 - math.clamp(distance / Noticing.Tuning.seeRadius, 0, 1)
	return extraversion + (if child then 0.5 else 0) + near * 0.6 + roll * 0.4
end

function Noticing.outclassed(power: number, npcTier: number): boolean
	return npcTier >= Noticing.Tuning.outclassTier and power <= Noticing.Tuning.outclassPower
end

function Noticing.fresh(seenAt: { [string]: number }, key: string?, clock: number, big: boolean): boolean
	if big or not key then
		return true
	end
	local last = seenAt[key]
	return last == nil or clock - last >= Noticing.Tuning.repeatGap
end

return Noticing
