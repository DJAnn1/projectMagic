--!strict
--[[
	NPCMagicLife: every NPC's magical career, simulated coarsely and deterministically.

	The same NPC has the same career on every server and whether or not anyone watched, because
	it's computed from (worldSeed, npcId, chapter), never from what happened in one session.
	Only player-caused turns of fate (a hidden mythic gift awakened) are saved (NPCService).

	BASELINE (before the world's epoch): years of practice (age - 8) build mastery along the path
	from their domain's root toward their ambition's branch:
	    root  = clamp(years x 2 x gift x habit, 1, 75)        gift  = 0.5 + innate potential
	    child = parent x 0.8 - 8, while the parent clears the unlock threshold
	                                                         habit = 0.5 + 0.5 x conscientiousness
	CHAPTERS (one per CHAPTER_DAYS game days since the epoch; the last MAX_CHAPTERS replayed):
	  per NPC  pick a study focus, weighted toward the ambition's path (x3), the profession (x2),
	           innate leaning, and the current focus (x1.5 continuity); gain
	           9 x gift x habit x growth curve x quirk studyMult x mentor/school bonus x (1 - m/105);
	           crossing 55/70/85/100 needs a breakthrough (chance 0.2 + 0.4 x (patience+ambition)/2),
	           otherwise mastery holds just below; locked children unlock once the parent clears
	           Tuning.unlockMastery
	  per settlement, in slot order (seeded per chapter):
	    mentorship  Expert+ teachers with compassion+patience take a younger student of their
	                domain (student gains x1.5 in that domain)
	    schools     a Master+ with ambition and presence founds a named school; same-domain
	                residents may join (x1.2)
	    rivalries   proud peers in the same branch within 10 mastery become rivals; half duel
	                (the loser is injured for 3 days and both remember it)
	    invention   Expert+ open minds invent a named technique (a real, castable recipe)
	    backlash    ambitious, risk-prone casters get hurt (injured, -1 mastery)
	    forbidden   the ruthless and ambitious start studying forbidden branches in secret; after
	                3 chapters they may go ROGUE (leave home, live in the wilds, gossip spreads)
	MYTHIC        a hidden Mythic latent never surfaces on its own. awaken() is called by
	              NPCService when the world or a player provides the moment.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local Types = require(Shared.Magic.Types)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)

local Server = ServerScriptService.Server
local InnateProfile = require(Server.Magic.InnateProfile)
local NpcData = require(script.Parent.Data.NpcData)
local Quirks = require(script.Parent.Data.Quirks)
local MemoryService = require(script.Parent.MemoryService)
local RelationshipGraph = require(script.Parent.RelationshipGraph)

local CHAPTER_DAYS = 7
local MAX_CHAPTERS = 60
local CHAPTER_GAIN = 9
local THRESHOLDS = { 55, 70, 85, 100 }
local HISTORY_CAP = 14

local MYTHIC_EVENTS: { [string]: string } = { time = "stoppedClock", gravity = "starfall", reality = "witnessParadox" }

local ADJECTIVES = { "Quiet", "Iron", "Patient", "Bright", "Hollow", "Second", "Crooked", "Gentle", "Long", "Brass" }
local NOUNS = { "Hand", "Turn", "Breath", "Knot", "Lantern", "Fold", "Answer", "Thread", "Promise", "Weight" }
local SCHOOL_NOUNS = { "Circle", "Hall", "Lodge", "Order", "House", "Academy" }

export type Technique = { name: string, recipe: Types.Recipe }

export type MagicState = {
	mastery: { [string]: number },
	unlocked: { [string]: boolean },
	focus: string?,
	chapter: number,
	techniques: { Technique },
	school: string?,
	mentor: string?,
	students: { string },
	rival: string?,
	injuredUntil: number,
	forbidden: boolean,
	forbiddenSince: number?,
	rogue: boolean,
	history: { { day: number, text: string } },
	hiddenMythic: string?,
	awakened: { domain: string, day: number }?,
	caster: Types.CasterProfile,
}

local NPCMagicLife = {}
NPCMagicLife.CHAPTER_DAYS = CHAPTER_DAYS

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function firstName(npc: any): string
	return string.match(npc.name, "^(%S+)") or npc.name
end

local function note(npc: any, day: number, text: string)
	local history = npc.magic.history
	table.insert(history, { day = day, text = text })
	while #history > HISTORY_CAP do
		table.remove(history, 1)
	end
end

local function isForbidden(branchId: string): boolean
	local b = Registry.branches[branchId]
	return b ~= nil and table.find(b.tags, "forbidden") ~= nil
end

local function domainOK(npc: any, branchId: string, day: number): boolean
	local b = Registry.branches[branchId]
	for _, d in b.domains do
		if not table.find(npc.profile.manifest, d) then
			return false
		end
		if Registry.domains[d].rarity == "Mythic" then
			-- A mythic domain only exists in their study from the day it awakened.
			local a = npc.magic.awakened
			if not a or a.domain ~= d or day < a.day then
				return false
			end
		end
	end
	return true
end

local function quirkStudy(npc: any): number
	local m = 1
	for _, q in npc.quirks do
		m *= Quirks.defs[q].effects.studyMult or 1
	end
	return m
end

local function gift(npc: any): number
	return 0.5 + (npc.profile.potential or 0.3)
end

local function habit(npc: any): number
	return 0.5 + 0.5 * (npc.traits.conscientiousness or 0.5) + 0.15 * ((npc.traits.patience or 0.5) - 0.5)
end

function NPCMagicLife.tierOf(npc: any, branchId: string): number
	local m = npc.magic.mastery[branchId] or 0
	if m <= 0 and npc.magic.unlocked[branchId] then
		return 1
	end
	return MagicCore.tierForMastery(m)
end

-- Their strongest branch: (id, mastery, tier).
function NPCMagicLife.best(npc: any): (string?, number, number)
	local bestId, bestM = nil, -1
	for id, m in npc.magic.mastery do
		if m > bestM then
			bestId, bestM = id, m
		end
	end
	if not bestId then
		return nil, 0, 0
	end
	return bestId, bestM, NPCMagicLife.tierOf(npc, bestId)
end

local function refreshCaster(npc: any)
	npc.magic.caster = InnateProfile.toCasterProfile(npc.profile, {
		mastery = npc.magic.mastery,
		unlocked = npc.magic.unlocked,
		commitments = {},
	})
end

-- Call after editing mastery or the profile directly (admin tools): rebuilds the caster profile.
function NPCMagicLife.refresh(npc: any)
	refreshCaster(npc)
end

-- Path from the domain root down to a branch (root first).
local function pathTo(branchId: string): { string }
	local path = {}
	local node = Registry.branches[branchId]
	while node do
		table.insert(path, 1, node.id)
		node = if node.parent then Registry.branches[node.parent] else nil
	end
	return path
end

-- ─── Baseline career (before the epoch) ─────────────────────────────────────

function NPCMagicLife.init(npc: any)
	local magic: MagicState = {
		mastery = {},
		unlocked = {},
		focus = nil,
		chapter = -1,
		techniques = {},
		students = {},
		injuredUntil = -1,
		forbidden = false,
		rogue = false,
		history = {},
		caster = nil :: any,
	}
	npc.magic = magic
	for _, latent in npc.profile.latents do
		if latent.kind == "Mythic" and not latent.revealed then
			magic.hiddenMythic = latent.target
		end
	end

	local years = math.max(0, npc.age - 8)
	local g, h = gift(npc), habit(npc)
	local target = npc.ambition.branch
	for index, domainId in npc.profile.manifest do
		if Registry.domains[domainId].rarity == "Mythic" then
			continue -- mythic domains only grow once awakened
		end
		local share = if index == 1 then 1 else 0.5
		local m = math.clamp(years * 2 * g * h * share, 1, 75)
		local path = if target and Registry.branches[target] and Registry.branches[target].domains[1] == domainId
			then pathTo(target)
			else { domainId }
		for depth, branchId in path do
			if depth > 1 then
				local parent = path[depth - 1]
				local def = Registry.branches[branchId]
				local needed = Registry.Tuning.unlockMastery[math.min(def.tier, 4)] or 0
				if (magic.mastery[parent] or 0) < needed or isForbidden(branchId) then
					break
				end
				m = magic.mastery[parent] * 0.8 - 8
				if m < 1 then
					break
				end
			end
			magic.unlocked[branchId] = true
			magic.mastery[branchId] = math.floor(m * 10) / 10
		end
	end
	magic.focus = target
	refreshCaster(npc)
end

-- ─── One chapter of study for one NPC ───────────────────────────────────────

local function candidates(npc: any, day: number): { string }
	local list: { string } = {}
	local magic = npc.magic
	for id in magic.unlocked do
		if domainOK(npc, id, day) and (magic.forbidden or not isForbidden(id)) then
			table.insert(list, id)
		end
	end
	-- Children of what they know, once the parent clears the bar.
	for id in magic.unlocked do
		for _, child in Registry.branches[id].children do
			local def = Registry.branches[child]
			local needed = Registry.Tuning.unlockMastery[math.min(def.tier, 4)] or 0
			if not magic.unlocked[child] and (magic.mastery[id] or 0) >= needed and domainOK(npc, child, day)
				and (magic.forbidden or not isForbidden(child)) and not table.find(list, child) then
				table.insert(list, child)
			end
		end
	end
	table.sort(list)
	return list
end

local function studyChapter(npc: any, chapter: number, bonuses: { [string]: number })
	local magic: MagicState = npc.magic
	local day = chapter * CHAPTER_DAYS
	if magic.injuredUntil > day then
		return
	end
	local rng = Seed.random(npc.seed, npc.id, "npc.chapter", chapter)
	local list = candidates(npc, day)
	if #list == 0 then
		return
	end
	local ambitionPath = if npc.ambition.branch then pathTo(npc.ambition.branch) else {}
	local occ = NpcData.occupations[npc.formerOccupation or npc.occupation]
	local total = 0
	local weights: { number } = {}
	for i, id in list do
		local w = 1 + InnateProfile.branchAffinity(npc.profile, id)
		if table.find(ambitionPath, id) then
			w *= 3
		end
		for _, preferred in occ.branches do
			if id == preferred or table.find(pathTo(id), preferred) then
				w *= 2
				break
			end
		end
		if id == magic.focus then
			w *= 1.5
		end
		if (magic.mastery[id] or 0) >= 90 then
			w *= 0.5
		end
		weights[i] = w
		total += w
	end
	local roll = rng:NextNumber() * total
	local focus = list[#list]
	for i, id in list do
		roll -= weights[i]
		if roll <= 0 then
			focus = id
			break
		end
	end
	magic.focus = focus
	if not magic.unlocked[focus] then
		magic.unlocked[focus] = true
		magic.mastery[focus] = math.max(magic.mastery[focus] or 0, 1)
		note(npc, day, "began studying " .. Registry.branches[focus].name)
	end

	local m = magic.mastery[focus] or 0
	local bonus = bonuses[Registry.branches[focus].domains[1]] or 1
	local gain = CHAPTER_GAIN * gift(npc) * habit(npc) * InnateProfile.growthMultiplier(npc.profile, m) * quirkStudy(npc) * bonus * (1 - m / 105)
	local after = math.min(100, m + math.max(0, gain))
	for _, threshold in THRESHOLDS do
		if m < threshold and after >= threshold then
			local chance = 0.2 + 0.4 * ((npc.traits.patience or 0.5) + (npc.traits.ambition or 0.5)) / 2
			if rng:NextNumber() < chance then
				note(npc, day, "broke through in " .. Registry.branches[focus].name)
			else
				after = threshold - 0.5
			end
			break
		end
	end
	magic.mastery[focus] = math.floor(after * 10) / 10
end

-- ─── Settlement events ──────────────────────────────────────────────────────

local function byId(npcs: { any }): { [string]: any }
	local map = {}
	for _, n in npcs do
		map[n.id] = n
	end
	return map
end

local function events(npcs: { any }, chapter: number, now: number)
	local day = chapter * CHAPTER_DAYS
	local rng = Seed.random(npcs[1].seed, npcs[1].settlementId, "npc.events", chapter)
	local lookup = byId(npcs)

	for _, npc in npcs do
		local magic: MagicState = npc.magic
		local t = npc.traits
		local best, bestM, tier = NPCMagicLife.best(npc)
		if not best then
			continue
		end
		local bestDomain = Registry.branches[best].domains[1]

		-- Mentorship.
		if tier >= 5 and #magic.students < 2 and ((t.compassion or 0.5) + (t.patience or 0.5)) / 2 > 0.45 and rng:NextNumber() < 0.35 then
			for _, other in npcs do
				if other ~= npc and not other.magic.mentor and other.age < npc.age and table.find(other.profile.manifest, bestDomain)
					and (other.magic.mastery[best] or 0) < bestM - 25 then
					other.magic.mentor = npc.id
					table.insert(magic.students, other.id)
					RelationshipGraph.setBond(npc.id, other.id, "student")
					RelationshipGraph.setBond(other.id, npc.id, "mentor")
					RelationshipGraph.adjust(other.id, npc.id, 0.3, 0.3)
					MemoryService.add(other, "became_student", npc.id, now, { intensity = 0.6 })
					note(npc, day, "took " .. other.name .. " as a student")
					note(other, day, "became " .. npc.name .. "'s student")
					break
				end
			end
		end

		-- Founding a school.
		if tier >= 6 and not magic.school and ((t.ambition or 0.5) > 0.6 and (t.extraversion or 0.5) > 0.45 or npc.ambition.kind == "school") and rng:NextNumber() < 0.25 then
			local taken = false
			for _, other in npcs do
				if other.magic.school then
					taken = true
					break
				end
			end
			if not taken then
				local name = string.format("The %s %s of %s", ADJECTIVES[rng:NextInteger(1, #ADJECTIVES)], SCHOOL_NOUNS[rng:NextInteger(1, #SCHOOL_NOUNS)], Registry.branches[best].name)
				magic.school = name
				note(npc, day, "founded " .. name)
				MemoryService.add(npc, "school_founded", npc.id, now, { intensity = 0.8, note = name })
				for _, other in npcs do
					if other ~= npc and (table.find(magic.students, other.id) or (table.find(other.profile.manifest, bestDomain) and rng:NextNumber() < 0.3)) then
						other.magic.school = name
						note(other, day, "joined " .. name)
					end
				end
			end
		end

		-- Rivalry and duels.
		if not magic.rival and magic.focus and (t.pride or 0.5) > 0.55 then
			for _, other in npcs do
				if other ~= npc and not other.magic.rival and other.magic.focus == magic.focus
					and math.abs((other.magic.mastery[magic.focus] or 0) - (magic.mastery[magic.focus] or 0)) < 10
					and ((t.pride or 0.5) + (other.traits.pride or 0.5)) / 2 > 0.55 and rng:NextNumber() < 0.2 then
					magic.rival, other.magic.rival = other.id, npc.id
					RelationshipGraph.setBond(npc.id, other.id, "rival")
					RelationshipGraph.setBond(other.id, npc.id, "rival")
					RelationshipGraph.adjust(npc.id, other.id, -0.2, -0.1, 0.5)
					RelationshipGraph.adjust(other.id, npc.id, -0.2, -0.1, 0.5)
					note(npc, day, "became rivals with " .. other.name)
					note(other, day, "became rivals with " .. npc.name)
					break
				end
			end
		end
		local rival = magic.rival and lookup[magic.rival]
		if rival and rng:NextNumber() < 0.25 and magic.injuredUntil <= day and rival.magic.injuredUntil <= day then
			local branch = magic.focus or best
			local mine = (magic.mastery[branch] or 0) + rng:NextNumber() * 15
			local theirs = (rival.magic.mastery[branch] or 0) + rng:NextNumber() * 15
			local winner, loser = if mine >= theirs then npc else rival, if mine >= theirs then rival else npc
			loser.magic.injuredUntil = day + 3
			MemoryService.add(winner, "duel_won", loser.id, now, { intensity = 0.6 })
			MemoryService.add(loser, "duel_lost", winner.id, now, { intensity = 0.7 })
			RelationshipGraph.adjust(loser.id, winner.id, -0.1, 0, 0.1)
			note(winner, day, "beat " .. loser.name .. " in a duel")
			note(loser, day, "lost a duel to " .. winner.name)
		end

		-- Invention.
		local inventChance = if npc.ambition.kind == "invention" then 0.18 else 0.12
		if tier >= 5 and (t.openness or 0.5) > 0.55 and #magic.techniques < 3 and rng:NextNumber() < inventChance then
			local templates = MagicCore.listAvailableRecipes(magic.caster, { branch = best, limit = 40 })
			if #templates > 0 then
				local pick = templates[rng:NextInteger(1, #templates)]
				local recipe: Types.Recipe = {
					v = Registry.Tuning.RECIPE_VERSION,
					branch = pick.branch,
					property = pick.property,
					verb = pick.verb,
					form = pick.form,
					modifiers = {},
					power = math.max(1, math.floor(pick.comfortPower)),
					costProfile = Registry.Tuning.DEFAULT_COST_PROFILE,
				}
				local name = string.format("%s's %s %s", firstName(npc), ADJECTIVES[rng:NextInteger(1, #ADJECTIVES)], NOUNS[rng:NextInteger(1, #NOUNS)])
				table.insert(magic.techniques, { name = name, recipe = recipe })
				MemoryService.add(npc, "invention", npc.id, now, { intensity = 0.7, note = name })
				note(npc, day, "invented " .. name)
			end
		end

		-- Backlash.
		local risk = InnateProfile.traits(npc.profile).overdrawRisk
		if rng:NextNumber() < 0.03 * risk * (0.5 + (t.ambition or 0.5)) * (0.5 + (t.pride or 0.5)) then
			magic.injuredUntil = math.max(magic.injuredUntil, day + 2)
			magic.mastery[best] = math.max(1, bestM - 1)
			MemoryService.add(npc, "backlash", npc.id, now, { intensity = 0.7 })
			note(npc, day, "was hurt by backlash")
		end

		-- Forbidden study, and going rogue.
		local ruthless = npc.ambition.kind == "forbidden"
			or ((t.ambition or 0.5) > 0.75 and (t.compassion or 0.5) < 0.35 and ((t.greed or 0.5) > 0.6 or (t.pride or 0.5) > 0.65))
		if ruthless and not magic.forbidden then
			for id in magic.unlocked do
				local reachable = false
				for _, child in Registry.branches[id].children do
					if isForbidden(child) then
						reachable = true
					end
				end
				if reachable and rng:NextNumber() < 0.2 then
					magic.forbidden, magic.forbiddenSince = true, chapter
					note(npc, day, "began studying a forbidden art in secret")
					break
				end
			end
		elseif magic.forbidden and not magic.rogue and magic.forbiddenSince and chapter - magic.forbiddenSince >= 3 and rng:NextNumber() < 0.3 then
			magic.rogue = true
			note(npc, day, "left town under a cloud")
			for _, other in npcs do
				if other ~= npc then
					MemoryService.add(other, "went_rogue", npc.id, now, { intensity = 0.5 })
					RelationshipGraph.adjust(other.id, npc.id, -0.3, -0.3)
				end
			end
		end
	end
end

-- ─── Public: advancing a settlement ─────────────────────────────────────────

--[[
	Brings every NPC of one settlement up to `toChapter` (inclusive). Called at boot (replays the
	last MAX_CHAPTERS) and whenever a new chapter starts. `checkpoint` yields to the Scheduler.
]]
function NPCMagicLife.advance(npcs: { any }, toChapter: number, now: number, checkpoint: (() -> ())?)
	if #npcs == 0 then
		return
	end
	local from = npcs[1].magic.chapter + 1
	from = math.max(from, toChapter - MAX_CHAPTERS + 1, 0)
	for chapter = from, toChapter do
		for _, npc in npcs do
			local bonuses: { [string]: number } = {}
			local mentor = npc.magic.mentor
			if mentor and string.sub(mentor, 1, 2) == "u:" then
				-- A player mentor (made through the admin panel's apprentice bond) helps every domain.
				for _, d in npc.profile.manifest do
					bonuses[d] = 1.5
				end
			elseif mentor then
				for _, other in npcs do
					if other.id == mentor then
						local mb = NPCMagicLife.best(other)
						if mb then
							bonuses[Registry.branches[mb].domains[1]] = 1.5
						end
					end
				end
			end
			if npc.magic.school then
				for _, d in npc.profile.manifest do
					bonuses[d] = (bonuses[d] or 1) * 1.2
				end
			end
			studyChapter(npc, chapter, bonuses)
		end
		events(npcs, chapter, now)
		for _, npc in npcs do
			npc.magic.chapter = chapter
		end
		if checkpoint then
			checkpoint()
		end
	end
	for _, npc in npcs do
		refreshCaster(npc)
	end
end

-- ─── Hidden mythic potential ────────────────────────────────────────────────

--[[
	The moment a hidden mythic gift surfaces. Tries the real awakening event first (it validates
	and applies affinity gains exactly as for players); falls back to revealing the latent directly
	when the event's own requirements (facts) don't apply to an NPC. Returns true when it happened.
]]
function NPCMagicLife.awaken(npc: any, day: number, cause: string): boolean
	local magic: MagicState = npc.magic
	local domain = magic.hiddenMythic
	if not domain or magic.awakened then
		return false
	end
	local eventId = MYTHIC_EVENTS[domain]
	local result = InnateProfile.applyAwakening(npc.profile, eventId, { now = os.time() })
	if not result.ok then
		for _, latent in npc.profile.latents do
			if latent.kind == "Mythic" and latent.target == domain then
				latent.revealed = true
			end
		end
		if not table.find(npc.profile.manifest, domain) then
			table.insert(npc.profile.manifest, domain)
		end
		npc.profile.domains[domain] = math.max(npc.profile.domains[domain] or 0, 0.35)
	end
	magic.hiddenMythic = nil
	magic.awakened = { domain = domain, day = day }
	magic.unlocked[domain] = true
	magic.mastery[domain] = math.max(magic.mastery[domain] or 0, 1)
	note(npc, day, string.format("awakened to %s (%s)", Registry.domains[domain].name, cause))
	MemoryService.add(npc, "awakened", npc.id, day, { intensity = 1, note = domain })
	refreshCaster(npc)
	return true
end

-- ─── Precise magic near players ─────────────────────────────────────────────

--[[
	The spell an NPC casts while working, if they can: their profession's recipe (Data/NpcData),
	only when they actually know the branch, aren't injured, and it isn't their no-magic day.
	Power is clamped to what they can hold. Returns (stats, flourish) or nil (works by hand).
]]
function NPCMagicLife.workCast(npc: any, day: number, weekday: number): (Types.SpellStats?, string?)
	local occ = NpcData.occupations[npc.occupation]
	local work = occ.work
	local magic: MagicState = npc.magic
	if not work or magic.injuredUntil > day or not magic.unlocked[work.branch] then
		return nil, nil
	end
	local flourish: string? = nil
	for _, q in npc.quirks do
		local e = Quirks.defs[q].effects
		if e.noMagicWeekday == weekday then
			return nil, nil
		end
		flourish = flourish or e.castFlourish
	end
	local cap = MagicCore.powerCap(magic.caster, work.branch)
	if cap < 1 then
		return nil, nil
	end
	local recipe = table.clone(work) :: any
	recipe.power = math.clamp(work.power, 1, cap)
	local stats = MagicCore.computeStats(recipe, magic.caster, nil)
	return stats, flourish
end

return NPCMagicLife
