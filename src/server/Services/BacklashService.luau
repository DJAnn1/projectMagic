--!strict
--[[
	BacklashService: what magic does to a caster who loses control of it.

	Two triggers, both scaled by how badly it went and by temperament (ReservoirState.riskMult,
	from traits.overdrawRisk: Steadfast < 1 < Brittle):

	OVERDRAW   Reservoir.trySpend already computed the consequences (Backlash HP, Burnout,
	           Lockout, Mutation) proportional to how deep below zero the cast went. Here they
	           are APPLIED: backlash damage (internal, so wards don't absorb it), plus the
	           domain's risk effect once burnout or lockout is reached.
	LOSS OF    a backfire on a spell of power >= controlLossPower. Severity =
	CONTROL    (1 + overreach) x riskMult x power factor; the caster takes Impact-scale damage
	           x severity x 0.25 (never below 1 HP from this part alone) and the domain's risk
	           effect. Low-power backfires are just the spell landing on you (resolvers).

	Risk effects (Data: RISK_EFFECTS, keyed by Domains[*].risk.id) give every domain's failure
	its own character: Energy scorches, Earth ossifies, Mind fractures perception, Space
	dislocates you, Time unmoors you...

	Every event sends a "backlash" cue (VFX/SFX near the caster) and is logged.
]]


local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Magic.Types)
local Registry = require(Shared.Magic.Registry)
local Server = script.Parent.Parent
local T = require(Server.Magic.Data.CastTuning)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local Damage = require(Server.Magic.Cast.Damage)

type RiskEffect = {
	status: string?,
	seconds: number?,
	drain: number?, -- share of max reservoir lost
	displace: number?, -- studs thrown in a random direction
	random: { string }?, -- one of these statuses
	text: string,
}

local RISK_EFFECTS: { [string]: RiskEffect } = {
	burnout = { status = "burning", seconds = 4, text = "Your channels scorch." },
	ossification = { status = "slow", seconds = 6, text = "Your joints stiffen like stone." },
	saturation = { status = "slow", seconds = 5, text = "Your lungs fill; you move like you're underwater." },
	breathlessness = { status = "silence", seconds = 3, text = "The air is torn from your lungs; you can't speak a working." },
	withering = { status = "rot", seconds = 6, text = "Your skin greys and withers." },
	fracture = { status = "blind", seconds = 3, text = "Your perception shatters." },
	haunting = { status = "fear", seconds = 5, text = "Something followed the magic back into you." },
	hollowing = { drain = 0.2, text = "The void drinks from your reservoir." },
	dislocation = { displace = 14, text = "Space lets go of you for a moment." },
	unmooring = { status = "time_slow", seconds = 4, text = "You come unstuck from the moment." },
	crush = { status = "root", seconds = 2, text = "Your own weight pins you down." },
	unraveling = { random = { "slow", "blind", "silence", "fear" }, text = "The rules around you fray." },
}

local BacklashService = {
	name = "BacklashService",
	dependencies = { "NetService", "ReservoirService", "EffectRunner" },
}

local log: any = nil
local reservoirs: any = nil
local runner: any = nil
local rng = Random.new()

local function riskOf(stats: Types.SpellStats): string
	return Registry.domains[stats.domains[1]].risk.id
end

local function displace(player: Player, studs: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return
	end
	local angle = rng:NextNumber() * math.pi * 2
	local target = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * studs
	-- Land on something: drop from above onto the surface, never inside it.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local hit = workspace:Raycast(target + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), params)
	if hit then
		character:PivotTo(CFrame.new(hit.Position + Vector3.new(0, 3, 0)) * root.CFrame.Rotation)
	end
end

-- Applies a domain's risk effect to the caster. Returns its line of text.
local function applyRisk(player: Player, humanoid: Humanoid, riskId: string, severity: number): string?
	local effect = RISK_EFFECTS[riskId]
	if not effect then
		return nil
	end
	local seconds = (effect.seconds or 3) * math.clamp(severity, 0.5, 2)
	local status = effect.status
	if effect.random then
		status = effect.random[rng:NextInteger(1, #effect.random)]
	end
	if status then
		StatusEffects.apply(humanoid, status, { duration = seconds, magnitude = 3 * severity })
	end
	if effect.drain then
		local state = reservoirs:get(player)
		if state then
			state.current -= if state.infinite then 0 else state.max * effect.drain * math.clamp(severity, 0.5, 1.5)
			reservoirs:push(player)
		end
	end
	if effect.displace then
		displace(player, effect.displace * math.clamp(severity, 0.5, 2))
	end
	return effect.text
end

local function cue(player: Player, humanoid: Humanoid, riskId: string, severity: number)
	local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		runner:cue("backlash", { caster = player.UserId, risk = riskId, severity = severity }, root.Position, false)
	end
end

--[[
	Overdraw consequences from Reservoir.trySpend. Returns the risk text when a risk effect fired.
]]
function BacklashService.overdraw(_self: any, player: Player, humanoid: Humanoid, stats: Types.SpellStats, consequences: { Types.Consequence }): string?
	if #consequences == 0 then
		return nil
	end
	local riskId = riskOf(stats)
	local severe = false
	for _, c in consequences do
		if c.kind == "Backlash" then
			-- Internal damage: the caster's own channels, so wards don't help.
			Damage.internal(humanoid, c.amount)
		elseif c.kind == "Burnout" or c.kind == "Lockout" then
			severe = true
		elseif c.kind == "Mutation" then
			log:info("mutation_rolled", { userId = player.UserId, domain = c.domain, risk = c.riskId, chance = c.amount })
		end
	end
	cue(player, humanoid, riskId, if severe then 1.5 else 1)
	if severe then
		return applyRisk(player, humanoid, riskId, 1)
	end
	return nil
end

--[[
	Loss of control (a backfire at power >= controlLossPower). Returns (severity, risk text).
]]
function BacklashService.controlLoss(_self: any, player: Player, humanoid: Humanoid, stats: Types.SpellStats): (number, string?)
	local reservoir = reservoirs:get(player)
	local riskMult = if reservoir then reservoir.riskMult else 1
	local powerFactor = 1 + (stats.recipe.power - T.controlLossPower) * 0.25
	local severity = (1 + stats.overreach) * riskMult * powerFactor
	local amount = T.damage.perPower * stats.power ^ T.damage.exponent * 0.25 * severity
	humanoid:TakeDamage(math.min(amount, math.max(0, humanoid.Health - 1)))
	local riskId = riskOf(stats)
	local text = applyRisk(player, humanoid, riskId, severity)
	cue(player, humanoid, riskId, severity)
	log:info("control_lost", { userId = player.UserId, key = stats.key, severity = math.floor(severity * 100) / 100, risk = riskId })
	return severity, text
end

function BacklashService.init(_self: any, ctx: any)
	log = ctx.log
	reservoirs = ctx.get("ReservoirService")
	runner = ctx.get("EffectRunner")
end

return BacklashService
