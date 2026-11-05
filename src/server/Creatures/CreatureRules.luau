--!strict
--[[
	CreatureRules: the pure decisions, so Tests/Creatures.spec can run them without a world.

		decide(def, view) -> "wander" | "chase" | "flee" | "return"
		clampToLeash(den, goal, leash) -> Vector3      a goal inside the creature's range
		rewardFactor(killsThisHour) -> number          the anti-grind curve (1 .. towards 0)
		rollLoot(def, rng, factor) -> (items, coins)   always consumes the same rolls per def
		strongAgainst(domain) -> { creature id }       who this domain's magic is good against
		planDens(worldSeed, towns, sample, seaLevel) -> { Den }
]]

local Seed = require(game:GetService("ReplicatedStorage").Shared.Magic.Seed)
local Creatures = require(script.Parent.Data.Creatures)

local T = Creatures.tuning

export type View = {
	distanceToDen: number,
	returning: boolean, -- was already going home
	hasAttacker: boolean, -- someone hit it recently and is still around
	nearestPlayer: number?, -- studs to the nearest living player
	playerToDen: number?, -- studs from the den to the player nearest it
}

export type Town = { id: string, x: number, z: number, radius: number, biome: string }

export type Den = {
	id: string,
	type: string,
	settlementId: string,
	x: number,
	z: number,
	count: number,
}

-- sample(x, z) -> (ground height, slope)
export type Sampler = (number, number) -> (number, number)

local CreatureRules = {}

function CreatureRules.decide(def: Creatures.Def, view: View): string
	-- Past the leash: home, and stay on the way home until it gets there (it heals on arrival).
	if view.distanceToDen > def.leash or (view.returning and view.distanceToDen > T.denRadius) then
		return "return"
	end
	local behaviour = def.behaviour
	local nearest = view.nearestPlayer
	if behaviour == "flee" then
		if view.hasAttacker or (nearest and nearest <= (def.fleeRadius or 0)) then
			return "flee"
		end
	elseif not def.bite then
		-- Nothing to fight with: being hit can only mean running.
		if view.hasAttacker then
			return "flee"
		end
	elseif behaviour == "swarm" then
		if view.hasAttacker or (nearest and nearest <= (def.aggroRadius or 0)) then
			return "chase"
		end
	elseif behaviour == "defend" then
		if view.hasAttacker or (view.playerToDen and view.playerToDen <= (def.defendRadius or 0)) then
			return "chase"
		end
	elseif view.hasAttacker then -- wander
		return if def.fightsBack == false then "flee" else "chase"
	end
	return "wander"
end

function CreatureRules.clampToLeash(den: Vector3, goal: Vector3, leash: number): Vector3
	local offset = goal - den
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local limit = leash * 0.9
	if flat.Magnitude <= limit then
		return goal
	end
	local clamped = den + flat.Unit * limit
	return Vector3.new(clamped.X, goal.Y, clamped.Z)
end

function CreatureRules.rewardFactor(killsThisHour: number): number
	return 1 / (1 + math.max(0, killsThisHour) / T.decayScale)
end

function CreatureRules.rollLoot(def: Creatures.Def, rng: Random, factor: number): ({ { item: string, n: number } }, number)
	local items: { { item: string, n: number } } = {}
	for _, entry in def.loot do
		local roll, amount = rng:NextNumber(), rng:NextInteger(entry.min, entry.max)
		if roll < entry.chance * factor then
			table.insert(items, { item = entry.item, n = amount })
		end
	end
	local coins = 0
	local c = def.coins
	if c then
		local roll, amount = rng:NextNumber(), rng:NextInteger(c.min, c.max)
		if roll < c.chance * factor then
			coins = amount
		end
	end
	return items, coins
end

function CreatureRules.strongAgainst(domain: string): { string }
	local out: { string } = {}
	for _, id in Creatures.ids do
		local resist = Creatures.defs[id].resist[domain]
		if resist and resist <= T.weakAt then
			table.insert(out, id)
		end
	end
	return out
end

-- This town's creature types, without repeats, weighted by how well each suits its biome.
local function pickTypes(biome: string, n: number, rng: Random): { string }
	local pool = table.clone(Creatures.ids) :: { string }
	local picked: { string } = {}
	while #picked < n and #pool > 0 do
		local total = 0
		for _, id in pool do
			total += Creatures.defs[id].biomes[biome] or Creatures.anyBiome
		end
		local roll = rng:NextNumber() * total
		local index = #pool
		for i, id in pool do
			roll -= Creatures.defs[id].biomes[biome] or Creatures.anyBiome
			if roll <= 0 then
				index = i
				break
			end
		end
		table.insert(picked, pool[index])
		table.remove(pool, index)
	end
	return picked
end

--[[
	Where the dens are. Deterministic: Seed.random(worldSeed, "settlement:<id>", "creatures"), in the
	towns' given (stable) order. A den is on dry, gentle ground, in a ring outside its town, outside
	every other town and clear of other dens. A town may get fewer dens when it's boxed in by sea.
]]
function CreatureRules.planDens(worldSeed: number, towns: { Town }, sample: Sampler, seaLevel: number): { Den }
	local dens: { Den } = {}
	local function clear(x: number, z: number): boolean
		for _, town in towns do
			local keep = town.radius + T.townMargin
			if (town.x - x) ^ 2 + (town.z - z) ^ 2 < keep * keep then
				return false
			end
		end
		for _, den in dens do
			if (den.x - x) ^ 2 + (den.z - z) ^ 2 < T.denSpacing * T.denSpacing then
				return false
			end
		end
		return true
	end
	for _, town in towns do
		local rng = Seed.random(worldSeed, "settlement:" .. town.id, "creatures")
		for index, typeId in pickTypes(town.biome, T.densPerTown, rng) do
			local def = Creatures.defs[typeId]
			for _ = 1, T.tries do
				local angle = rng:NextNumber() * 2 * math.pi
				local distance = town.radius + T.ringMin + rng:NextNumber() * (T.ringMax - T.ringMin)
				local x, z = town.x + math.cos(angle) * distance, town.z + math.sin(angle) * distance
				local height, slope = sample(x, z)
				if height >= seaLevel + T.minAboveSea and slope <= T.maxSlope and clear(x, z) then
					table.insert(dens, {
						id = town.id .. ":den" .. index,
						type = typeId,
						settlementId = town.id,
						x = x,
						z = z,
						count = rng:NextInteger(def.pack.min, def.pack.max),
					})
					break
				end
			end
		end
	end
	return dens
end

return CreatureRules
