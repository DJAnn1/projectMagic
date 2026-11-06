--!strict
--[[
	MovementService: running and the dash, server-authoritative (docs/Combat.md §15). Rules and
	numbers: Shared/Magic/Movement + Data/MovementTuning. Client: Controllers/MovementClient.

	RUN     RunIntent(on) sets what the player WANTS. Every TICK the service applies it only when
	        allowed (Movement.runAllowed: action state idle, no spell readied): a "run" walk
	        multiplier through StatusEffects (so it stacks with slows and hastes) and the
	        character attribute Running (the client's Run clip). Optional stamina drain while
	        moving; running out turns the toggle off.
	DASH    DashIntent(direction). Checks, in order: a live body, the action state allows "dash",
	        a charge, the cooldown, the stamina cost. Then:
	          - the readied spell's domain and its branch mastery pick the dash (Movement.dashFor)
	          - action state "dashing" (the Dash clip; it also breaks a charging spell)
	          - the "evading" status: resist all damage by evade.resist for evade.seconds
	          - the move itself:
	              impulse  the client already pushed its own body (it owns its physics); the
	                       server only checks how far it went afterwards
	              blink    a raycast along the direction (stops short of walls), then PivotTo
	              rewind   back to where the body was `seconds` ago (a 0.1 s position history),
	                       refused if that's further than maxRewindDistance (a teleport, a fall)
	          - a "dash" WorldEffect cue for everyone nearby (Fx/DashFx draws the flavour)
	        Refusals: DashResult { ok = false, reason } to the owner (the client undoes its
	        prediction). After every dash, the distance actually moved is compared with what the
	        dash allows (x slack); more is logged as dash_overshoot, and the character carries
	        MoveAllowanceUntil for the future movement checks (Backend.md §8).
	REPLICATION  Player attributes DashCharges / DashMax; character attribute Running.
	ADMIN   movement [player] (state), dashes <n|inf> [player].
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Movement = require(Shared.Magic.Movement)
local ActionRules = require(Shared.Magic.ActionRules)

local Server = script.Parent.Parent
local ActionState = require(Server.Magic.Cast.ActionState)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local Progression = require(Server.Progression.Progression)

local T = Movement.tuning
local TICK = 0.1
local HISTORY = 30 -- samples (3 s at TICK)

local MovementService = {
	name = "MovementService",
	dependencies = { "NetService", "PlayerDataService", "AttunementService", "StaminaService", "EffectRunner", "AdminService" },
}

type State = {
	wantsRun: boolean,
	running: boolean,
	humanoid: Humanoid?,
	charges: number,
	progress: number,
	infinite: boolean,
	lastDash: number,
	history: { { t: number, p: Vector3 } },
}

local log: any = nil
local playerData: any = nil
local attunement: any = nil
local stamina: any = nil
local runner: any = nil
local states: { [Player]: State } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stateOf(player: Player): State
	local s = states[player]
	if not s then
		s = { wantsRun = false, running = false, humanoid = nil, charges = T.dash.charges, progress = 0, infinite = false, lastDash = -math.huge, history = {} }
		states[player] = s
	end
	return s
end

local function body(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

local function publishCharges(player: Player, s: State)
	if player:GetAttribute("DashCharges") ~= s.charges then
		player:SetAttribute("DashCharges", s.charges)
	end
	if player:GetAttribute("DashMax") ~= T.dash.charges then
		player:SetAttribute("DashMax", T.dash.charges)
	end
end

local function refuse(player: Player, reason: string)
	Net.fire("DashResult", player, { ok = false, reason = reason })
end

-- ─── Running ────────────────────────────────────────────────────────────────

local function applyRun(_player: Player, s: State, character: Model, humanoid: Humanoid, running: boolean)
	if s.humanoid ~= humanoid then
		s.humanoid, s.running = humanoid, false -- a new body starts walking
	end
	if s.running == running then
		return
	end
	s.running = running
	StatusEffects.setWalkMultiplier(humanoid, "run", if running then T.run.speedMult else nil)
	character:SetAttribute("Running", if running then true else nil)
end

local function tickRun(player: Player, s: State, dt: number)
	local character, humanoid = body(player)
	if not character or not humanoid then
		return
	end
	local snapshot = ActionRules.read(character)
	local actionState = ActionRules.effective(snapshot, now())
	local attuned = character:GetAttribute("AttunedDomain") ~= nil
	local running = s.wantsRun and Movement.runAllowed(actionState, attuned)
	applyRun(player, s, character, humanoid, running)
	if running and T.run.staminaPerSecond > 0 and humanoid.MoveDirection.Magnitude > 0.1 then
		if stamina:drain(player, T.run.staminaPerSecond * dt) <= 0 then
			s.wantsRun = false
			applyRun(player, s, character, humanoid, false)
			Net.fire("Notify", player, "Too winded to keep running.")
		end
	end
end

-- ─── Dash ───────────────────────────────────────────────────────────────────

-- The readied spell's domain and its branch's mastery tier (nil, 0 with nothing readied).
local function flavourOf(player: Player, character: Model): (string?, number)
	local domain = character:GetAttribute("AttunedDomain")
	if typeof(domain) ~= "string" then
		return nil, 0
	end
	local recipe = attunement:attunedRecipe(player)
	local state = playerData:get(player)
	local tier = 0
	if recipe and state then
		tier = (Progression.getMasteryTier(state.data.progression, recipe.branch)) -- first value only
	end
	return domain, tier
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- How far a blink can go along `dir` before a wall (stopping a body-width short).
local function blinkTarget(character: Model, root: BasePart, dir: Vector3, distance: number): Vector3
	local ignore: { Instance } = { character }
	local fx = workspace:FindFirstChild("MagicFx")
	if fx then
		table.insert(ignore, fx)
	end
	rayParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(root.Position, dir * (distance + 2.5), rayParams)
	local reach = if hit then math.max(0, hit.Distance - 2.5) else distance
	return root.Position + dir * reach
end

-- Where the body was about `seconds` ago (the oldest sample if history is shorter), or nil.
local function rewindTarget(s: State, seconds: number): Vector3?
	local want = now() - seconds
	local best: Vector3? = nil
	for _, sample in s.history do
		if sample.t <= want then
			best = sample.p -- history is oldest first: keep the latest one at or before `want`
		end
	end
	if not best and #s.history > 0 then
		best = s.history[1].p
	end
	return best
end

local function onDash(player: Player, rawDir: Vector3)
	local s = stateOf(player)
	local character, humanoid, root = body(player)
	if not character or not humanoid or not root then
		return
	end
	local can = ActionState.can(character, "dash")
	if not can then
		return refuse(player, "BUSY")
	end
	local t = now()
	if s.charges < 1 and not s.infinite then
		return refuse(player, "NO_CHARGES")
	end
	if t - s.lastDash < T.dash.cooldown then
		return refuse(player, "TOO_SOON")
	end

	local domain, tier = flavourOf(player, character)
	local dash = Movement.dashFor(domain, tier)
	-- The client's direction, flattened and normalised; a zero vector means "back".
	local dir = Movement.direction(rawDir, root.CFrame.LookVector)
	local start = root.Position
	local target: Vector3
	if dash.kind == "blink" then
		target = blinkTarget(character, root, dir, dash.distance)
	elseif dash.kind == "rewind" then
		local back = rewindTarget(s, dash.seconds)
		if not back or (back - start).Magnitude > T.dash.maxRewindDistance then
			return refuse(player, "REWIND_TOO_FAR")
		end
		target = back
	else
		target = start + dir * dash.distance
	end
	if not stamina:spend(player, T.dash.staminaCost) then
		return refuse(player, "WINDED")
	end

	if not s.infinite then
		s.charges -= 1
	end
	s.lastDash = t
	publishCharges(player, s)
	ActionState.set(character, "dashing", { domain = domain })
	StatusEffects.apply(humanoid, "evading", { duration = T.dash.evade.seconds, resist = { all = T.dash.evade.resist } })
	character:SetAttribute("MoveAllowanceUntil", t + dash.duration + 0.3)
	if dash.kind ~= "impulse" then
		character:PivotTo(root.CFrame + (target - start))
		root.AssemblyLinearVelocity = Vector3.zero
	end
	Net.fire("DashResult", player, { ok = true, style = dash.style })
	runner:cue("dash", {
		caster = player.UserId,
		domain = domain,
		style = dash.style,
		kind = dash.kind,
		from = start,
		to = target,
		duration = dash.duration,
	}, start, false)

	-- Afterwards: did the body move further than this dash allows?
	local allowed = (target - start).Magnitude
	task.delay(dash.duration + 0.25, function()
		local _, _, r = body(player)
		if not r then
			return
		end
		local flat = Vector3.new(r.Position.X - start.X, 0, r.Position.Z - start.Z).Magnitude
		if flat > allowed * T.dash.slack + 4 then
			log:warn("dash_overshoot", { userId = player.UserId, moved = math.floor(flat), allowed = math.floor(allowed), style = dash.style })
		end
	end)
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

-- A Self Timeline saves and restores your dash charges (Cast/TimeRuntime).
function MovementService.chargesOf(_self: any, player: Player): number?
	local s = states[player]
	return if s then s.charges else nil
end

function MovementService.setCharges(_self: any, player: Player, charges: number)
	local s = stateOf(player)
	s.charges = math.clamp(charges, 0, T.dash.charges)
	publishCharges(player, s)
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "movement", category = "Movement", description = "Running and dash state (wants/running, charges, the dash a readied spell gives)",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local player: Player = a.player
			local s = stateOf(player)
			local character = player.Character
			local domain: string?, tier = nil, 0
			if character then
				domain, tier = flavourOf(player, character)
			end
			local dash = Movement.dashFor(domain, tier)
			return string.format("run: wants %s, running %s · dash charges %d/%d%s · next dash: %s (%s, %.1f studs)",
				tostring(s.wantsRun), tostring(s.running), s.charges, T.dash.charges, if s.infinite then " (infinite)" else "",
				dash.word, dash.style, dash.distance)
		end,
	})
	admin:Register({
		name = "dashes", category = "Movement", description = "Set dash charges now, or 'inf' for unlimited (testing)",
		args = {
			{ name = "count", type = "string", hint = "a number, or inf / off" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local player: Player = a.player
			local s = stateOf(player)
			if a.count == "inf" or a.count == "off" then
				s.infinite = a.count == "inf"
				return "infinite dashes " .. (if s.infinite then "on" else "off")
			end
			local n = tonumber(a.count)
			if not n then
				return "count must be a number, inf or off"
			end
			s.charges, s.progress = math.clamp(math.floor(n), 0, T.dash.charges), 0
			publishCharges(player, s)
			return string.format("%s has %d dash charges", player.Name, s.charges)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function MovementService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	attunement = ctx.get("AttunementService")
	stamina = ctx.get("StaminaService")
	runner = ctx.get("EffectRunner")
	Net.on("RunIntent", function(player: Player, on: boolean)
		stateOf(player).wantsRun = on == true
	end)
	Net.on("DashIntent", onDash :: any)
	registerAdmin(ctx.get("AdminService"))
end

function MovementService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < TICK then
			return
		end
		local step = acc
		acc = 0
		local t = now()
		for _, player in Players:GetPlayers() do
			local s = stateOf(player)
			tickRun(player, s, step)
			-- Dash charges refill; the history feeds Time's rewind.
			s.charges, s.progress = Movement.recharge(s.charges, s.progress, step)
			publishCharges(player, s)
			local _, _, root = body(player)
			if root then
				table.insert(s.history, { t = t, p = root.Position })
				if #s.history > HISTORY then
					table.remove(s.history, 1)
				end
			else
				table.clear(s.history) -- a new body starts a new history (no rewinding into death)
			end
		end
	end)
end

return MovementService
