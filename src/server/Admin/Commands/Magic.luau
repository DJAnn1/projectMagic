--!strict
--[[
	Magic and progression tools. They write the player's REAL progression (it saves), skipping
	the normal rules; use them on test accounts or in Studio (the mock store forgets).

	setmastery <all|domain|branch|Domain/Branch> <tier 0-8|name> [player]
	    sets XP to just inside the tier, completes the breakthroughs up to it, unlocks the
	    branches and awakens any domain they need (affinity at least 0.5)
	setxp / addxp <branch> <xp>        exact XP (no multipliers), mastery recomputed
	resetbranch <branch> · resetprogression RESET
	unlock <branch|all|hybrids> · lock <branch> (and its sub-branches)
	commit / renounce <specialization>  without the mastery, slot or rite requirements
	mythic <time|gravity|reality> <on|off>
	unlockall [tier]                    every domain awakened, every branch at that tier (default
	                                    8): every verb, form and modifier the grammar allows
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Reservoir = require(Shared.Magic.Reservoir)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local Server = script.Parent.Parent.Parent
local Progression = require(Server.Progression.Progression)
local Schemas = require(Server.Persistence.Schemas)

local MIN_AFFINITY = 0.5

return function(admin: any, deps: any)
	local playerData = deps.playerData
	local progression = deps.progression
	local reservoirs = deps.reservoirs

	local function stateOf(player: Player): any
		return playerData:get(player)
	end

	-- Rebuild the caster, resize the reservoir, tell the client (progression and profile views).
	local function refresh(player: Player, events: { any })
		progression:notify(player, events)
		local state = stateOf(player)
		local reservoir = reservoirs:get(player)
		if state and reservoir then
			Reservoir.refreshMax(reservoir, state.caster)
			reservoirs:push(player)
		end
		local Net = require(Shared.Net)
		Net.fire("ProfileChanged", player)
	end
	deps.refreshPlayer = refresh -- Profile and Spells reuse it

	local function ensureDomain(innate: any, domainId: string)
		innate.domains[domainId] = math.max(innate.domains[domainId] or 0, MIN_AFFINITY)
		if not table.find(innate.manifest, domainId) then
			table.insert(innate.manifest, domainId)
		end
		for _, latent in innate.latents do
			if latent.target == domainId and (latent.kind == "Domain" or latent.kind == "Mythic") then
				latent.revealed = true
			end
		end
	end
	deps.ensureDomain = ensureDomain

	local function branchesFor(target: any): { string }
		if target.kind == "branch" then
			return { target.id }
		end
		local out = {}
		for _, id in Registry.branchIds do
			local b = Registry.branches[id]
			if target.kind == "all" or (not b.isHybrid and b.domains[1] == target.id) then
				table.insert(out, id)
			end
		end
		return out
	end

	local function setTier(state: any, branchId: string, tier: number)
		local p = state.data.progression
		local branch = Registry.branches[branchId]
		for _, d in branch.domains do
			ensureDomain(state.innate, d)
		end
		if tier <= 0 then
			p.xp[branchId], p.mastery[branchId], p.breakthroughs[branchId] = 0, 0, {}
			return
		end
		local def = MasteryTiers.tiers[tier + 1]
		local target = if tier >= 8 then 100 else math.min(100, def.minMastery + 2)
		local xp = Progression.xpForMastery(target)
		p.unlocked[branchId] = true
		p.xp[branchId] = xp
		local done = {}
		for _, t in MasteryTiers.tiers do
			if t.breakthrough and t.index <= tier then
				done[tostring(t.index)] = os.time()
			end
		end
		p.breakthroughs[branchId] = done
		p.mastery[branchId] = math.floor(math.min(Progression.masteryForXp(xp), (Progression.masteryCap(p, branchId))) * 100) / 100
	end

	local function setXp(state: any, branchId: string, xp: number)
		local p = state.data.progression
		p.unlocked[branchId] = true
		p.xp[branchId] = math.max(0, xp)
		p.mastery[branchId] = math.floor(math.min(Progression.masteryForXp(p.xp[branchId]), (Progression.masteryCap(p, branchId))) * 100) / 100
	end

	local function needState(player: Player): any
		local state = stateOf(player)
		if not state then
			error(player.Name .. "'s data isn't loaded", 0)
		end
		return state
	end

	admin:Register({
		name = "setmastery", category = "Magic",
		description = "Set a mastery tier for all branches, a domain's branches, or one branch (e.g. setmastery earth/metallurgy Grandmaster)",
		args = {
			{ name = "target", type = "masterytarget", hint = "all, a domain, a branch, or Domain/Branch" },
			{ name = "tier", type = "tier", slider = true, hint = "0 Untouched .. 8 Transcendent" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local list = branchesFor(a.target)
			for _, id in list do
				setTier(state, id, a.tier)
			end
			refresh(a.player, { { kind = "fact", fact = "admin", id = "setmastery" } })
			return string.format("%s: %d branch(es) set to %s", a.player.Name, #list, MasteryTiers.tiers[a.tier + 1].name)
		end,
	})

	admin:Register({
		name = "setxp", category = "Magic", description = "Set a branch's exact XP (no multipliers; mastery recomputed, breakthrough caps apply)",
		args = {
			{ name = "branch", type = "branch" },
			{ name = "xp", type = "number", min = 0, max = 100000000 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			setXp(state, a.branch, a.xp)
			refresh(a.player, { { kind = "fact", fact = "admin", id = "setxp" } })
			return string.format("%s xp %d -> mastery %.2f", a.branch, a.xp, state.data.progression.mastery[a.branch])
		end,
	})

	admin:Register({
		name = "addxp", category = "Magic", description = "Add raw XP to a branch (no multipliers; use xp for the normal path)",
		args = {
			{ name = "branch", type = "branch" },
			{ name = "amount", type = "number", min = -100000000, max = 100000000 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			setXp(state, a.branch, (state.data.progression.xp[a.branch] or 0) + a.amount)
			refresh(a.player, { { kind = "fact", fact = "admin", id = "addxp" } })
			return string.format("%s now %d xp, mastery %.2f", a.branch, state.data.progression.xp[a.branch], state.data.progression.mastery[a.branch])
		end,
	})

	admin:Register({
		name = "resetbranch", category = "Magic", description = "A branch back to zero XP and no breakthroughs (it stays unlocked)",
		args = { { name = "branch", type = "branch" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			setTier(state, a.branch, 0)
			refresh(a.player, { { kind = "fact", fact = "admin", id = "resetbranch" } })
			return "reset " .. a.branch
		end,
	})

	admin:Register({
		name = "resetprogression", category = "Magic", description = "Wipe ALL progression (XP, unlocks, breakthroughs, commitments, records, lore)",
		args = {
			{ name = "confirm", type = "enum", options = { "RESET" }, hint = "type RESET" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			state.data.progression = Schemas.Player.template().progression
			Progression.ensureRoots(state.data.progression, state.innate)
			refresh(a.player, { { kind = "fact", fact = "admin", id = "resetprogression" } })
			return a.player.Name .. "'s progression wiped (domain roots re-unlocked)"
		end,
	})

	admin:Register({
		name = "unlock", category = "Magic", description = "Unlock a branch (or all, or every hybrid) without its requirements",
		args = {
			{ name = "branch", type = "string", hint = "a branch id, all, or hybrids" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local p = state.data.progression
			local list: { string } = {}
			local which = string.lower(a.branch)
			for _, id in Registry.branchIds do
				local b = Registry.branches[id]
				if which == "all" or (which == "hybrids" and b.isHybrid) or id == which then
					table.insert(list, id)
				end
			end
			if #list == 0 then
				return "no branch '" .. a.branch .. "' (or use all / hybrids)"
			end
			for _, id in list do
				p.unlocked[id] = true
				p.xp[id] = p.xp[id] or 0
				p.mastery[id] = p.mastery[id] or 0
				for _, d in Registry.branches[id].domains do
					ensureDomain(state.innate, d)
				end
			end
			refresh(a.player, { { kind = "unlock", branch = list[1] } })
			return string.format("unlocked %d branch(es)", #list)
		end,
	})

	admin:Register({
		name = "lock", category = "Magic", description = "Lock a branch and every sub-branch under it (XP is kept)",
		args = { { name = "branch", type = "branch" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			local p = state.data.progression
			local count = 0
			local function lockTree(id: string)
				if p.unlocked[id] then
					p.unlocked[id] = nil
					count += 1
				end
				for _, child in Registry.branches[id].children do
					lockTree(child)
				end
			end
			lockTree(a.branch)
			refresh(a.player, { { kind = "fact", fact = "admin", id = "lock" } })
			return string.format("locked %d branch(es)", count)
		end,
	})

	admin:Register({
		name = "commit", category = "Magic", description = "Commit to a specialization oath, skipping its requirements",
		args = { { name = "specialization", type = "specialization" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			state.data.progression.commitments[a.specialization] = os.time()
			refresh(a.player, { { kind = "commitment", id = a.specialization } })
			return "committed to " .. a.specialization
		end,
	})

	admin:Register({
		name = "renounce", category = "Magic", description = "Drop a specialization oath (no rite, no XP loss)",
		args = { { name = "specialization", type = "specialization" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local state = needState(a.player)
			state.data.progression.commitments[a.specialization] = nil
			refresh(a.player, { { kind = "renounced", id = a.specialization } })
			return "renounced " .. a.specialization
		end,
	})

	admin:Register({
		name = "mythic", category = "Magic", description = "Grant or remove a Mythic discipline (Time, Gravity, Reality)",
		args = {
			{ name = "domain", type = "mythic" },
			{ name = "on", type = "boolean", default = true },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			local innate, p = state.innate, state.data.progression
			if a.on then
				ensureDomain(innate, a.domain)
				innate.domains[a.domain] = math.max(innate.domains[a.domain], 0.6)
				p.unlocked[a.domain] = true
				p.xp[a.domain] = p.xp[a.domain] or 0
				p.mastery[a.domain] = p.mastery[a.domain] or 0
			else
				local i = table.find(innate.manifest, a.domain)
				if i then
					table.remove(innate.manifest, i)
				end
				innate.domains[a.domain] = 0
				for _, id in Registry.branchIds do
					if table.find(Registry.branches[id].domains, a.domain) then
						p.unlocked[id] = nil
					end
				end
			end
			refresh(a.player, { { kind = "unlock", branch = a.domain } })
			return string.format("%s %s for %s", a.domain, if a.on then "granted" else "removed", a.player.Name)
		end,
	})

	admin:Register({
		name = "unlockall", category = "Magic",
		description = "Every domain awakened and every branch (hybrids and mythic included) at a tier: every verb, form and modifier opens",
		args = {
			{ name = "tier", type = "tier", default = 8, slider = true },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local state = needState(a.player)
			for _, d in Registry.domainIds do
				ensureDomain(state.innate, d)
			end
			for _, id in Registry.branchIds do
				setTier(state, id, a.tier)
			end
			refresh(a.player, { { kind = "fact", fact = "admin", id = "unlockall" } })
			return string.format("%d domains awakened, %d branches at %s. Use testspells or cast to try recipes.", #Registry.domainIds, #Registry.branchIds, MasteryTiers.tiers[a.tier + 1].name)
		end,
	})
end
