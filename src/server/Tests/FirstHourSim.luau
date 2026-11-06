--!strict
--[[
	FirstHourSim: a new player's first hour, per domain and gift tier, through the REAL rules
	(Cantrips, MagicCore stats, Reservoir, Progression, Experiment, Creatures).

		FirstHourSim.run(domainId, giftTierId, { minutes, lesson }) -> Result
		FirstHourSim.report(minutes)   prints every domain x tier and checks FirstHour's targets

	WHAT IT CAN AND CAN'T TELL YOU. The rules are real: whether a spell is valid, what it costs, how
	long the reservoir makes you wait, how much XP you get. The PLAYER is a model (BEHAVIOUR below):
	it never gets lost or confused, always hits, and knows where everything is. So this finds rule
	problems: a domain with no affordable attack, a domain slower than Energy, a target the XP curve
	can't reach. It can't tell you whether people understand the game. Services/FirstHourService
	measures that, and the `firsthour` report uses the same targets.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Reservoir = require(Shared.Magic.Reservoir)
local Cantrips = require(Shared.Magic.Cantrips)
local Server = ServerScriptService.Server
local Progression = require(Server.Progression.Progression)
local T = require(Server.Progression.ProgressionTuning)
local Experiment = require(Server.Progression.Experiment)
local FirstHour = require(Server.Progression.FirstHour)
local Schemas = require(Server.Persistence.Schemas)
local ProfileGenerator = require(Server.Magic.ProfileGenerator)
local InnateProfile = require(Server.Magic.InnateProfile)
local DamageModel = require(Server.Magic.Cast.DamageModel)
local Creatures = require(Server.Creatures.Data.Creatures)
local CreatureRules = require(Server.Creatures.CreatureRules)

-- The player model, in seconds. Deliberately simple; replace with live medians as they arrive.
local BEHAVIOUR = table.freeze({
	firstCast = 25, -- reads "Your magic answers", presses 1, clicks: a utility or a miss
	reachYard = 45, -- at the dummies (the yard is just off the plaza)
	reaction = 1.5, -- least time between casts
	patience = 3, -- waiting this long for the reservoir is normal; beyond it, nothing to do
	lessonAt = 170, -- mentor lesson finished. Seen in play: offered 0:49, finished 2:50
	lessonMentorTier = 2, -- a Novice mentor, the lowest that can teach a Sensing player
	huntFrom = 300, -- leaves the yard for the nearest den
	walkToNext = 15, -- between kills
	tryEvery = 180, -- presses "Try something new" and casts the result this often
})

local RANGED: { [string]: boolean } = { projectile = true, beam = true, chain = true } -- as FirstHourService
local STUDIED_TIER = 1 -- the player's tier when the lesson happens (Sensing)
local EPOCH = 1_800_000_000

export type Result = FirstHour.Row & {
	domain: string,
	gift: string,
	minutes: number,
	castsPerMinute: number,
	idleShare: number,
	kills: number,
	xp: number,
}

local function strikeShare(domainId: string): number
	local def: any = Registry.strikes[domainId]
	if def.native == "thermal" then
		return 0.8
	end
	return def.share or 1
end

local function statsFor(recipe: any, caster: any): any?
	local stats = MagicCore.computeStats(recipe, caster)
	if stats and not stats.blockedBy then
		return stats
	end
	return nil
end

local FirstHourSim = {}

function FirstHourSim.run(domainId: string, giftTier: string, options: { minutes: number?, lesson: boolean? }?): Result
	local o: any = options or {}
	local minutes: number = o.minutes or 60
	local lesson = o.lesson ~= false
	local duration = minutes * 60

	-- A fresh player of this gift whose one domain is this one. Personal multipliers are flattened
	-- (as in JourneySim), so differences between rows come from the domain and gift, not a lucky roll.
	local innate: any = ProfileGenerator.generate(1337, "firsthour:" .. domainId .. ":" .. giftTier, { forceGiftTier = giftTier })
	local top = 0
	for _, a in innate.domains do
		top = math.max(top, a)
	end
	innate.manifest = { domainId }
	innate.domains = { [domainId] = top }
	innate.growth = "steady"
	innate.temperaments = {}
	for style in innate.learning do
		innate.learning[style] = 1
	end
	for branchId in innate.leanings do
		innate.leanings[branchId] = 1
	end

	local p: any = Schemas.Player.template().progression
	Progression.ensureRoots(p, innate)
	local runtime = Progression.newRuntime(EPOCH)
	local rng = Random.new(1337)
	local caster: any = InnateProfile.toCasterProfile(innate, p)
	local state = Reservoir.newState(caster)
	local explored: { [string]: any } = {}
	local found = 0
	local recipesSeen: { [string]: boolean } = {}

	local row: any = { domain = domainId, gift = giftTier, minutes = minutes, casts = 0, idle = 0, kills = 0, xp = 0 }

	local function learn(channel: string, amount: number, ctx: any)
		local result = Progression.addExperience(p, innate, domainId, channel, amount, ctx)
		row.xp += result.gained
	end

	-- The innate spells, in hotbar order: strike, utility, thrown strike.
	local spells: { { kind: string, recipe: any, stats: any, ready: number } } = {}
	local function buildSpells()
		local keep: { [string]: number } = {}
		for _, s in spells do
			keep[s.kind] = s.ready
		end
		table.clear(spells)
		for _, spell in Cantrips.forDomain(domainId, caster, Random.new(1)) do
			local stats = statsFor(spell.recipe, caster)
			if stats then
				table.insert(spells, { kind = spell.kind, recipe = spell.recipe, stats = stats, ready = keep[spell.kind] or 0 })
			end
		end
	end
	buildSpells()

	local t: number = BEHAVIOUR.firstCast
	local lastTick = 0
	local nextTry = BEHAVIOUR.tryEvery
	local lessonDone = not lesson
	local turn = 0
	local nextRefresh = 60
	local creatureIndex = 1
	local damageOnCreature = 0
	local killsByType: { [string]: number } = {}
	local pendingTry: any = nil

	local function advance(to: number)
		Reservoir.tick(state, to - lastTick, EPOCH + to, "Normal", 1)
		lastTick = to
		t = to
	end

	while t < duration and #spells > 0 do
		-- The lesson and the quest it completes.
		if not lessonDone and t >= BEHAVIOUR.lessonAt then
			lessonDone = true
			row.quest = row.quest or BEHAVIOUR.lessonAt
			local gap = math.max(1, BEHAVIOUR.lessonMentorTier - STUDIED_TIER)
			learn("study", T.study.mentor.xp * gap, { now = EPOCH + t })
		end

		-- Growing changes costs and ceilings.
		if t >= nextRefresh then
			nextRefresh = t + 60
			caster = InnateProfile.toCasterProfile(innate, p)
			Reservoir.refreshMax(state, caster)
			buildSpells()
		end
		if not row.novice and (Progression.getMasteryTier(p, domainId)) >= FirstHour.NOVICE_TIER then
			row.novice = t
		end

		-- "Try something new", now and then.
		if t >= nextTry and not pendingTry then
			nextTry = t + BEHAVIOUR.tryEvery
			local recipe = Experiment.suggest(caster, explored, rng)
			local stats = recipe and statsFor(recipe, caster)
			if stats then
				pendingTry = { kind = "try", recipe = recipe, stats = stats, ready = 0 }
			end
		end

		-- At the yard or hunting, the attacks matter most; the utility gets a turn now and then.
		turn += 1
		local spell: any = pendingTry
		if not spell then
			spell = spells[(turn - 1) % #spells + 1]
			if spell.ready > t then
				-- On cooldown: use whichever is ready first.
				for _, other in spells do
					if other.ready < spell.ready then
						spell = other
					end
				end
			end
		end
		pendingTry = nil
		local stats = spell.stats
		if spell.ready > t then
			advance(spell.ready)
		end

		-- Pay. Waiting past `patience` is time with nothing to do.
		if state.current < stats.cost then
			local regen = math.max(Reservoir.regenPerSecond(state, "Normal", 1, EPOCH + t), 0.01)
			local wait = (stats.cost - state.current) / regen
			row.idle += math.max(0, wait - BEHAVIOUR.patience)
			advance(math.min(t + wait, duration))
			if t >= duration then
				break
			end
		end
		state.current = math.max(0, state.current - stats.cost)
		row.casts += 1
		spell.ready = t + stats.cooldown

		-- What it did. Before the yard an attack hits nothing; only a utility has an effect.
		local harmful = spell.kind == "strike" or spell.kind == "bolt" or stats.harmful == true
		local effective = not harmful or t >= BEHAVIOUR.reachYard
		runtime.lastActiveAt = EPOCH + t
		learn("practice", Progression.practiceXp(stats.cost), {
			now = EPOCH + t,
			runtime = runtime,
			recipeKey = stats.key,
			power = stats.recipe.power,
			comfort = stats.comfortPower,
			effective = effective,
		})
		if effective then
			local combo = Experiment.comboKey(stats.recipe)
			if not explored[combo] then
				explored[combo] = 1
				learn("experimentation", Experiment.noveltyXp(found), { now = EPOCH + t })
				found += 1
				row.novelty = row.novelty or t
			end
			if stats.recipe.power >= T.experimentation.minPowerForCredit and not recipesSeen[stats.key] then
				recipesSeen[stats.key] = true
				row.recipe = row.recipe or t
				learn("experimentation", T.experimentation.personalFirstBase + T.experimentation.personalFirstPerPower * stats.recipe.power, { now = EPOCH + t })
			end
		end
		if harmful and effective then
			row.damage = row.damage or t
			if RANGED[stats.recipe.form] then
				row.ranged = row.ranged or t
			end
		end

		-- Hunting: hits add up to a kill, which pays through the challenge channel.
		local walk = 0
		if harmful and effective and t >= BEHAVIOUR.huntFrom then
			local def = Creatures.defs[Creatures.ids[creatureIndex]]
			damageOnCreature += DamageModel.base(stats.power) * strikeShare(domainId) * (1 - (def.resist[domainId] or 0))
			if damageOnCreature >= def.health then
				damageOnCreature = 0
				row.kills += 1
				creatureIndex = creatureIndex % #Creatures.ids + 1
				local kills = killsByType[def.id] or 0
				killsByType[def.id] = kills + 1
				learn("challenge", def.xp * CreatureRules.rewardFactor(kills), {
					now = EPOCH + t,
					runtime = runtime,
					recipeKey = "creature:" .. def.id,
					power = def.level,
					comfort = MagicCore.powerCap(caster, domainId),
					effective = true,
				})
				walk = BEHAVIOUR.walkToNext
			end
		end
		-- People aren't metronomes: exact timing would trigger Progression's anti-macro penalty.
		advance(t + math.max(BEHAVIOUR.reaction, stats.castTime) * (0.7 + 0.6 * rng:NextNumber()) + walk)
	end

	row.castsPerMinute = row.casts / minutes
	row.idleShare = row.idle / duration
	return row :: any
end

function FirstHourSim.report(minutes: number?)
	local length = minutes or 60
	local TIERS = { "Modest", "Gifted", "Prodigy" }
	print(string.format("════════ First hour simulation (%d min; the player is a model, see FirstHourSim) ════════", length))
	print("  target: first damage < 2m, first ranged < 10m, Novice < 30m, something new < 20m, no domain 25% slower than Energy")
	print("  domain/gift | damage ranged novice (no lesson) new recipe quest | casts/min idle kills")
	local failures: { string } = {}
	for _, gift in TIERS do
		local energy = FirstHourSim.run("energy", gift, { minutes = length, lesson = false })
		for _, domainId in Registry.domainIds do
			local row: any = FirstHourSim.run(domainId, gift, { minutes = length })
			local plain: any = FirstHourSim.run(domainId, gift, { minutes = length, lesson = false })
			print(string.format(
				"  %s/%s | %s %s %s (%s) %s %s %s | %.1f %d%% %d",
				domainId, gift, FirstHour.format(row.damage), FirstHour.format(row.ranged), FirstHour.format(row.novice), FirstHour.format(plain.novice),
				FirstHour.format(row.novelty), FirstHour.format(row.recipe), FirstHour.format(row.quest),
				row.castsPerMinute, math.floor(row.idleShare * 100 + 0.5), row.kills
			))
			for _, name in FirstHour.misses(row, length * 60) do
				table.insert(failures, string.format("%s/%s missed %s (%s)", domainId, gift, name, FirstHour.format(row[name])))
			end
			if FirstHour.tooSlow(plain.novice, energy.novice) then
				table.insert(failures, string.format("%s/%s reaches Novice over 25%% slower than Energy (%s vs %s, no lesson)", domainId, gift, FirstHour.format(plain.novice), FirstHour.format(energy.novice)))
			end
		end
		task.wait() -- a whole gift tier is the heaviest stretch: let the server breathe
	end
	if #failures == 0 then
		print("  every target met")
	else
		print(string.format("  %d missed:", #failures))
		for _, line in failures do
			print("    " .. line)
		end
	end
	print("════════ end of simulation ════════")
	return failures
end

return FirstHourSim
