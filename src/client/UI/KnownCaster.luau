--!strict
--[[
	KnownCaster: the CasterProfile the client can assemble from what the player knows about
	themselves, so the Spell Composer and hotbar can preview stats with MagicCore locally.

	Inputs are only what the server already sends this player:
		RequestProgression   unlocked branches, mastery, commitments
		RequestProfileView   visible affinities: none (Untrained), bands (Aware), values (Studied+)

	What it can't know is estimated, never requested:
		affinity with no value   a rough guess per band (deliberately NOT the real band edges,
		                         which are ProfileTuning secrets), or UNKNOWN_AFFINITY with no band
		traits                   neutral (temperament effects stay unknown)
		signatures               none

	So previews are always estimates and the UI shows them with "≈"; `confidence` (the share of
	awakened affinities known by value) only says how rough. The server
	recomputes everything from the real profile on every cast; the client's numbers never matter.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Magic.Types)
local Registry = require(Shared.Magic.Registry)
local Specialization = require(Shared.Magic.Specialization)

export type BranchView = {
	id: string,
	name: string,
	mastery: number,
	xp: number,
	xpForNext: number?,
	tier: number,
	tierName: string,
	held: boolean,
	breakthrough: { tier: number, requirements: { { text: string, met: boolean } } }?,
}

export type CandidateView = {
	id: string,
	name: string,
	ready: boolean,
	checks: { { kind: string, met: boolean, text: string } },
}

export type ProgressionView = {
	branches: { BranchView },
	candidates: { CandidateView },
	commitments: { [string]: number },
	focus: { [string]: number },
	activeLines: number,
	breadthMultiplier: number,
}

export type Known = {
	caster: Types.CasterProfile,
	confidence: number, -- 0..1 share of awakened affinities known by value (bands count half)
	revision: number, -- bumps on every rebuild; caches key off it
}

local KnownCaster = {}

local UNKNOWN_AFFINITY = 0.4
local BAND_GUESS: { [string]: number } = {
	Faint = 0.2,
	Moderate = 0.4,
	Strong = 0.6,
	Formidable = 0.75,
	Exceptional = 0.9,
}

local revision = 0

function KnownCaster.build(progression: ProgressionView, profile: Types.VisibleProfile?): Known
	local unlocked: { [string]: boolean } = {}
	local mastery: { [string]: number } = {}
	local awakened: { [string]: boolean } = {}
	for _, branch in progression.branches do
		unlocked[branch.id] = true
		mastery[branch.id] = branch.mastery
		local def = Registry.branches[branch.id]
		-- A domain's root branch is unlocked exactly when the domain is awakened.
		if def and def.isRoot then
			awakened[def.domains[1]] = true
		end
	end

	local affinities: { [string]: number } = {}
	local known, total = 0, 0
	for domainId in awakened do
		total += 1
		affinities[domainId] = UNKNOWN_AFFINITY
	end
	if profile then
		for _, visible in profile.domains do
			if visible.value then
				affinities[visible.domain] = visible.value
				if awakened[visible.domain] then
					known += 1
				end
			elseif visible.band then
				affinities[visible.domain] = BAND_GUESS[visible.band] or UNKNOWN_AFFINITY
				if awakened[visible.domain] then
					known += 0.5
				end
			end
		end
	end

	revision += 1
	return {
		caster = {
			id = "local",
			affinities = affinities,
			awakened = awakened,
			mastery = mastery,
			branchAffinities = if profile then profile.leanings else nil,
			unlocked = unlocked,
			branchMods = Specialization.branchMods(progression.commitments),
		},
		confidence = if total > 0 then known / total else 0,
		revision = revision,
	}
end

return KnownCaster
