--!strict
--[[
	Elementals: what a harmful Summon spell gives a body to (docs/SpellOverhaul.md §8, stage 3b;
	owner, 2026-11-13: "player elementals by branch, yes"). Read by Shared/Magic/Elemental (which
	one a recipe gets, how strong, the Composer's words) and Server/Magic/Cast/Elementals (the body
	and the fight).

	A recipe's elemental: the first entry in `byBranch` found walking up from the recipe's branch to
	its root, else its first domain's entry in `domains`. Hybrids list their own ids in byBranch.

	Fields
		name       what people call it, lower case with its article ("a stone golem")
		style      how it fights:
		             strike  walks in and hits whoever it fights (one target)
		             bolt    keeps its distance and throws the spell at them
		             slam    walks in and strikes the ground: everyone it fights nearby is hit
		material   its body (Enum.Material name); `transparency` 0..1 for glass, mist and wind
		tint       palette index (1..3, Data/Domains feel.palette) for the body; `accent` for its
		           glow; `color` overrides the body colour outright
		scale      body size (1 = a person); `walk` studs/s; `health` multiplies the health curve
	Everything else is shared in `tuning`.
	Tuning status: first pass (owner's open questions: lifetime, how many at once, can others hurt
	them; the defaults said to the owner on 2026-11-13 are below).
]]

local rgb = Color3.fromRGB

export type Elemental = {
	name: string,
	style: string,
	material: string,
	transparency: number?,
	tint: number?,
	accent: number?,
	color: Color3?,
	scale: number?,
	walk: number?,
	health: number?,
}

local domains: { [string]: Elemental } = {
	energy = { name = "an ember wight", style = "bolt", material = "CrackedLava", tint = 1, accent = 2, walk = 18 },
	earth = { name = "a stone golem", style = "strike", material = "Slate", tint = 1, accent = 2, scale = 1.25, walk = 13, health = 1.4 },
	water = { name = "a tide spirit", style = "bolt", material = "Glass", transparency = 0.35, tint = 1, accent = 2, walk = 17 },
	air = { name = "a gale spirit", style = "strike", material = "SmoothPlastic", transparency = 0.55, tint = 1, accent = 2, walk = 22, health = 0.8 },
	life = { name = "a thorn walker", style = "strike", material = "LeafyGrass", tint = 1, accent = 2, walk = 16 },
	mind = { name = "a phantom", style = "bolt", material = "Glass", transparency = 0.45, tint = 1, accent = 2, walk = 18, health = 0.85 },
	spirit = { name = "a wraith", style = "bolt", material = "Glass", transparency = 0.5, tint = 1, accent = 2, walk = 18, health = 0.9 },
	void = { name = "a hollow shade", style = "strike", material = "Basalt", color = rgb(18, 14, 26), accent = 1, walk = 19 },
	space = { name = "a fold walker", style = "strike", material = "Glass", transparency = 0.3, tint = 1, accent = 2, walk = 20 },
	time = { name = "a worn sentinel", style = "slam", material = "Sandstone", tint = 1, accent = 2, scale = 1.15, walk = 14, health = 1.2 },
	gravity = { name = "a weighted golem", style = "slam", material = "Basalt", tint = 1, accent = 2, scale = 1.3, walk = 12, health = 1.5 },
	reality = { name = "a conjured knight", style = "strike", material = "Foil", tint = 1, accent = 2, scale = 1.1, walk = 16, health = 1.2 },
}

local byBranch: { [string]: Elemental } = {
	-- Energy
	cryothermy = { name = "a frost wight", style = "slam", material = "Ice", tint = 3, accent = 3, walk = 15, health = 1.1 },
	electric = { name = "a storm wight", style = "bolt", material = "Glass", transparency = 0.25, tint = 3, accent = 2, walk = 20 },
	kinetic = { name = "a force wight", style = "strike", material = "Glass", transparency = 0.3, tint = 2, accent = 1, walk = 20 },
	luminous = { name = "a light wight", style = "bolt", material = "Glass", transparency = 0.3, tint = 2, accent = 2, walk = 18 },
	umbramancy = { name = "a shadow wight", style = "strike", material = "Basalt", color = rgb(24, 20, 30), accent = 1, walk = 20 },
	-- Earth
	metallurgy = { name = "an iron golem", style = "strike", material = "DiamondPlate", color = rgb(120, 122, 128), accent = 2, scale = 1.3, walk = 12, health = 1.6 },
	crystallurgy = { name = "a crystal golem", style = "bolt", material = "Glass", transparency = 0.2, tint = 3, accent = 3, scale = 1.15, walk = 14, health = 1.2 },
	seismic = { name = "a quake golem", style = "slam", material = "Slate", tint = 1, accent = 2, scale = 1.35, walk = 12, health = 1.5 },
	sandshaping = { name = "a sand wight", style = "strike", material = "Sand", tint = 2, accent = 2, walk = 19 },
	magmacraft = { name = "a magma golem", style = "slam", material = "CrackedLava", tint = 1, accent = 2, scale = 1.3, walk = 12, health = 1.5 },
	-- Water
	glaciation = { name = "an ice wight", style = "slam", material = "Ice", tint = 2, accent = 3, walk = 15, health = 1.2 },
	vapor = { name = "a mist wight", style = "strike", material = "SmoothPlastic", transparency = 0.6, tint = 3, accent = 2, walk = 21, health = 0.8 },
	mistweaving = { name = "a mist wight", style = "strike", material = "SmoothPlastic", transparency = 0.6, tint = 3, accent = 2, walk = 21, health = 0.8 },
	tidal = { name = "a wave spirit", style = "slam", material = "Glass", transparency = 0.3, tint = 1, accent = 2, scale = 1.2, walk = 16, health = 1.2 },
	-- Air
	sonics = { name = "an echo spirit", style = "slam", material = "SmoothPlastic", transparency = 0.5, tint = 2, accent = 1, walk = 19 },
	weathercraft = { name = "a storm spirit", style = "bolt", material = "SmoothPlastic", transparency = 0.45, tint = 3, accent = 2, walk = 20 },
	stormcalling = { name = "a storm spirit", style = "bolt", material = "SmoothPlastic", transparency = 0.45, tint = 3, accent = 2, walk = 20 },
	-- Life
	flora = { name = "a treant", style = "slam", material = "Wood", tint = 3, accent = 1, scale = 1.35, walk = 11, health = 1.6 },
	verdancy = { name = "a treant", style = "slam", material = "Wood", tint = 3, accent = 1, scale = 1.35, walk = 11, health = 1.6 },
	mycology = { name = "a spore walker", style = "slam", material = "Pebble", tint = 2, accent = 1, walk = 14 },
	fauna = { name = "a beast spirit", style = "strike", material = "Fabric", tint = 3, accent = 1, walk = 22, health = 0.9 },
	blight = { name = "a blighted husk", style = "strike", material = "Slate", color = rgb(70, 78, 52), accent = 2, walk = 15, health = 1.1 },
	-- Mind
	empathy = { name = "a dread shade", style = "strike", material = "Glass", transparency = 0.45, tint = 2, accent = 1, walk = 19 },
	illusion = { name = "a mirror double", style = "strike", material = "Glass", transparency = 0.2, tint = 3, accent = 1, walk = 19, health = 0.8 },
	-- Spirit
	necrourgy = { name = "a bone servant", style = "strike", material = "Marble", color = rgb(214, 206, 186), accent = 1, walk = 16, health = 1.1 },
	necromancy = { name = "a bone servant", style = "strike", material = "Marble", color = rgb(214, 206, 186), accent = 1, walk = 16, health = 1.1 },
	warding = { name = "a warden spirit", style = "slam", material = "Glass", transparency = 0.35, tint = 2, accent = 1, scale = 1.2, walk = 15, health = 1.3 },
	hexcraft = { name = "a hex wraith", style = "bolt", material = "Glass", transparency = 0.5, tint = 3, accent = 1, walk = 18 },
	-- Void
	absorption = { name = "a hungry shade", style = "strike", material = "Basalt", color = rgb(12, 8, 18), accent = 2, walk = 20 },
	-- Gravity
	attraction = { name = "a well golem", style = "slam", material = "Basalt", tint = 2, accent = 1, scale = 1.3, walk = 12, health = 1.5 },
	-- Reality
	fortune = { name = "a gambler's shade", style = "bolt", material = "Foil", tint = 2, accent = 1, walk = 18 },
}

local styles: { [string]: { reach: number, every: number, share: number, radius: number?, speed: number? } } = {
	-- share: each blow as a share of the spell's base hit (DamageModel.base), before mastery.
	strike = { reach = 5.5, every = 1.2, share = 0.45 },
	bolt = { reach = 34, every = 1.7, share = 0.4, speed = 90 },
	slam = { reach = 6, every = 2.0, share = 0.38, radius = 9 },
}

return table.freeze({
	domains = domains,
	byBranch = byBranch,
	styles = styles,
	tuning = table.freeze({
		seconds = 25, -- how long it lasts, unless killed first (default said to the owner, 2026-11-13)
		perPlayer = 1, -- at once; `perPlayerMaster` from Master (tier index masterTier) up
		perPlayerMaster = 2,
		masterTier = 6,
		maxAlive = 40, -- the whole server
		-- Health: (base + power x perPower + tier x perTier) x the elemental's `health`.
		health = { base = 60, perPower = 20, perTier = 30 },
		-- Each blow's share grows with mastery: x (1 + tier x perTier).
		shareTier = 0.05,
		sight = 40, -- notices Wildborn this close to itself
		leash = 60, -- won't chase anything further than this from its summoner
		follow = 9, -- walks back when further than this from its summoner with nothing to fight
		teleport = 90, -- further than this, it steps back to the summoner's side
		threatSeconds = 12, -- how long it remembers someone who fought its summoner (or it)
		think = 0.25, -- seconds between decisions
	}),
})
