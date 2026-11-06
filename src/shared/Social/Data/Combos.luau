--!strict
--[[
	Combos: magic that only happens between two people (docs/Social.md §4). Shared so the client can
	name and colour a combo; every number is applied on the server (Services/ComboService).

	A combo fires when two DIFFERENT members of a party land spells of its two `roles` close together
	in place and time. Nobody presses a combo button: you find it by playing together, and your partner
	sees a ring where your spell landed if they can finish it. One person alone can never trigger one.

		roles          the two halves: a domain, optionally only some tags (InteractionMatrix.tagsFor)
		window         seconds between the two spells landing
		reach          studs between the two landing points
		share          damage: DamageModel.base(power) x share at the centre, half at the rim
		power          (average recipe power of the two spells) + powerBonus
		radius         radius + radiusPerPower x power, in studs
		status         applied to everyone struck; magnitude is a share of the base damage per second
		cooldown       seconds before this party can trigger this combo again
		firstXp        experimentation XP, once ever, the first time a player is part of it
		excludeVerbs   verbs that don't count (sensing a rock isn't half of an eruption)
]]

export type Role = { domain: string, tags: { string }? }

export type Combo = {
	id: string,
	name: string,
	text: string,
	roles: { Role },
	window: number,
	reach: number,
	share: number,
	powerBonus: number,
	radius: number,
	radiusPerPower: number,
	maxTargets: number,
	property: string,
	domains: { string },
	status: { id: string, seconds: number, dpsShare: number }?,
	cooldown: number,
	firstXp: number,
	excludeVerbs: { string },
	primary: Color3,
	secondary: Color3,
}

local list: { Combo } = {
	{
		id = "earthflare",
		name = "Earthflare",
		text = "Earth broken open and lit from inside: the ground erupts where both spells met.",
		roles = { { domain = "earth" }, { domain = "energy" } },
		window = 3.5,
		reach = 18,
		share = 1.6,
		powerBonus = 1,
		radius = 12,
		radiusPerPower = 1,
		maxTargets = 24,
		property = "temperature",
		domains = { "earth", "energy" },
		status = { id = "burning", seconds = 3, dpsShare = 0.12 },
		cooldown = 12,
		firstXp = 120,
		excludeVerbs = { "sense" },
		primary = Color3.fromRGB(255, 120, 40),
		secondary = Color3.fromRGB(120, 80, 50),
	},
}

local byId: { [string]: Combo } = {}
for _, combo in list do
	byId[combo.id] = combo
end

return table.freeze({ list = list, byId = byId })
