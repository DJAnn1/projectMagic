--!strict
--[[
	Earthquake: what happens when a Grandmaster casts Cataclysm (or any Seismic Generate at
	scale). This is the worked example from docs/World.md §9; read it top to bottom.

	1. MEASURE   world:castContext(position) -> density, resonance, environment
	             { seismicStress, groundMass, ... } from WorldState, not from the client.
	2. VALIDATE  MagicCore.computeStats with that context. EnvironmentRules "fault_stress" and
	             "ground_mass" scale power by sqrt(stress / required) or block the cast.
	3. RELEASE   magnitude from spell power AND available stress; the region's stress drops
	             (regenerates over days) and 15% is pushed into neighbouring regions.
	4. DEFORM    along the local fault direction: a fissure, an uplifted ridge on one side, a
	             sunken trough on the other, scattered cracks. Ops run in a Scheduler job and are
	             recorded through world:edit (persistent, replayed by every server).
	5. DAMAGE    structures (Integrity/Robustness attributes; collapse at 0), characters
	             (the caster is always included; others only with pvp_enabled).
	6. RECORD    cosmetic cue to clients, magic pressure for the EventDirector, a chronicle entry
	             for big quakes, and "survived earth:self_collapse" if the caster lived through it.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Types = require(Shared.Magic.Types)
local Scheduler = require(script.Parent.Parent.Parent.Core.Scheduler)
local TerrainDeform = require(script.Parent.Parent.TerrainDeform)
local C = require(script.Parent.Parent.WorldConfig)

export type Report = {
	magnitude: number,
	released: number,
	radius: number,
	ops: number,
	collapsed: number,
	hits: number,
	aftershocks: number,
}

local Earthquake = {}

local MAX_OPS = 150
local AFTERSHOCK_STRESS = 0.45
local MAX_AFTERSHOCKS = 2

-- Unit vector along the local fault (perpendicular to the fault field's gradient).
local function faultDirection(world: any, x: number, z: number, rng: Random): Vector3
	local gen = world:gen()
	local f0 = gen:sample(x, z).fault
	local gx = gen:sample(x + 12, z).fault - f0
	local gz = gen:sample(x, z + 12).fault - f0
	local along = Vector3.new(-gz, 0, gx)
	if along.Magnitude < 1e-4 then
		local angle = rng:NextNumber() * math.pi * 2
		return Vector3.new(math.cos(angle), 0, math.sin(angle))
	end
	return along.Unit
end

--[[
	Resolves a validated earthquake cast. `stats` must come from MagicCore.computeStats with the
	world's castContext at `epicenter`. Yields (runs the deformation as a Scheduler job).
	`seeded` should be the cast's seeded Random (CastService passes it) so the fissure pattern is
	reproducible; admin test casts may omit it.
]]
function Earthquake.resolve(world: any, caster: Player?, stats: Types.SpellStats, epicenter: Vector3, seeded: Random?): Report
	local rng = seeded or Random.new()
	local x, z = epicenter.X, epicenter.Z

	-- 3. Magnitude from power and stress; release a share of the stress.
	local stress = world:stressAt(x, z)
	local magnitude = math.log10(stats.power + 1) * 2 * (0.5 + stress) -- ~6 for a P10 Cataclysm on a loaded fault
	local radius = math.clamp(stats.area, 24, 400)
	local released = world:releaseStress(x, z, stress * math.clamp(stats.power / 600, 0.1, 0.9))

	-- 4. Deformation along the fault (TerrainDeform; budgeted, persistent).
	local along = faultDirection(world, x, z, rng)
	local ops = TerrainDeform.faultRupture(world, epicenter, along, radius, magnitude, rng, MAX_OPS)
	local job = Scheduler.spawn("earthquake", function()
		world:edit("earthquake", ops)
	end, Scheduler.Priority.High)

	-- Clients shake while the ground breaks.
	Net.fireAll("WorldEffect", { kind = "quake", position = epicenter, radius = radius, magnitude = magnitude, duration = 3 + magnitude })
	Scheduler.await(job)

	-- 5. Damage.
	local collapsed = world:damageStructures(epicenter, radius, 25 * magnitude, "earthquake")
	local hits = world:damageCharacters(epicenter, radius * 0.6, 6 * magnitude, caster)
	local hitCount = 0
	for _ in hits do
		hitCount += 1
	end

	-- 6. Record.
	world:noteMagic(epicenter, stats.domains, stats.power)
	local services = world:services()
	if stats.recipe.power >= 8 then
		task.spawn(services.chronicle.recordEvent, services.chronicle, "earthquake", {
			x = math.floor(x), z = math.floor(z), magnitude = math.floor(magnitude * 10) / 10,
		})
	end
	if caster then
		local character = caster.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - epicenter).Magnitude <= radius * 0.6 then
			-- Earth's Master breakthrough: "Survive a collapse you caused yourself."
			task.delay(5, function()
				local humanoid = caster.Character and caster.Character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					services.progression:recordFact(caster, "survived", "earth:self_collapse")
				end
			end)
		end
	end
	local aftershocks = Earthquake.scheduleAftershocks(world, caster, epicenter, magnitude, radius, rng)
	return { magnitude = magnitude, released = released, radius = radius, ops = #ops, collapsed = collapsed, hits = hitCount, aftershocks = aftershocks }
end

--[[
	Stress propagation: releaseStress pushed 15% of the released stress into neighbouring regions.
	Any neighbour (8 directions, 1.5 regions out) now holding at least AFTERSHOCK_STRESS ruptures a
	few seconds later as a smaller quake (half magnitude, half radius, at most MAX_AFTERSHOCKS, no
	further cascade). This is what makes a loaded fault zone dangerous to shake.
]]
function Earthquake.scheduleAftershocks(world: any, caster: Player?, epicenter: Vector3, magnitude: number, radius: number, rng: Random): number
	local candidates: { { position: Vector3, stress: number } } = {}
	local reach = C.REGION_SIZE * 1.5
	for i = 0, 7 do
		local angle = i * math.pi / 4
		local p = epicenter + Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach
		local stress = world:stressAt(p.X, p.Z)
		if stress >= AFTERSHOCK_STRESS then
			table.insert(candidates, { position = p, stress = stress })
		end
	end
	table.sort(candidates, function(a, b)
		return a.stress > b.stress
	end)
	local scheduled = math.min(#candidates, MAX_AFTERSHOCKS)
	for i = 1, scheduled do
		local c = candidates[i]
		local delay = 4 + rng:NextNumber() * 6
		local subMagnitude = magnitude * 0.5 * (0.5 + c.stress)
		local subRadius = radius * 0.5
		task.delay(delay, function()
			world:releaseStress(c.position.X, c.position.Z, c.stress * 0.5)
			local along = faultDirection(world, c.position.X, c.position.Z, rng)
			local ops = TerrainDeform.faultRupture(world, c.position, along, subRadius, subMagnitude, rng, MAX_OPS // 4)
			Net.fireAll("WorldEffect", { kind = "quake", position = c.position, radius = subRadius, magnitude = subMagnitude, duration = 2 + subMagnitude, aftershock = true })
			TerrainDeform.commit(world, "aftershock", ops)
			world:damageStructures(c.position, subRadius, 25 * subMagnitude, "aftershock")
			world:damageCharacters(c.position, subRadius * 0.6, 6 * subMagnitude, caster)
		end)
	end
	return scheduled
end

--[[
	Admin/test entry point (console: `quake [power]`): builds a Grandmaster Cataclysm caster,
	measures the world at your position, validates through MagicCore, then resolves.
	CastService will do the same with the player's real caster profile.
]]
function Earthquake.adminCast(world: any, player: Player, position: Vector3, power: number): string
	local caster: Types.CasterProfile = {
		id = "admin:" .. player.UserId,
		affinities = { earth = 0.9 },
		awakened = { earth = true },
		mastery = { cataclysm = 90 },
		unlocked = { earth = true, seismic = true, faultwork = true, cataclysm = true },
	}
	local technique = Registry.techniques.cataclysm.recipe
	local recipe = table.clone(technique) :: any
	recipe.power = math.clamp(math.floor(power), 1, 10)
	local ctx = world:castContext(position, 150)
	local stats, errors = MagicCore.computeStats(recipe, caster, ctx)
	if not stats then
		return "invalid: " .. (errors[1] and errors[1].code or "?")
	end
	local env = ctx.environment or {}
	if stats.blockedBy then
		return string.format("blocked by %s (stress %.2f, groundMass %.2f)", stats.blockedBy, env.seismicStress or 0, env.groundMass or 0)
	end
	local report = Earthquake.resolve(world, player, stats, position)
	return string.format(
		"quake P%d: magnitude %.1f, radius %.0f, stress %.2f -> released %.2f, env x%.2f, resonance x%.2f | %d terrain ops, %d structures collapsed, %d characters hit",
		recipe.power, report.magnitude, report.radius, env.seismicStress or 0, report.released, stats.environmentFactor, stats.resonance,
		report.ops, report.collapsed, report.hits
	)
end

return Earthquake
