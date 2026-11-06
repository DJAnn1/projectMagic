--!strict
--[[
	DuelService: consent-based duels (docs/Social.md §6). The rules are in Shared/Social/Data/DuelRules
	and Social/DuelModel; this file does the challenge flow and everything that touches real bodies.

		DuelAction(op, userId?, rule?) -> { ok, reason? }   challenge | accept | decline | cancel | yield
		DuelState (to the fighters)  { phase, ... }:
			none
			incoming   { from, name, rule, expires }             someone challenged you
			outgoing   { to, name, rule, expires }               you're waiting for an answer
			countdown  { opponent, name, rule, center, radius, fightAt, endsAt }
			fight      the same fields
			ended      { opponent, name, result = won|lost|draw, reason, recap }

	CONSENT     Nothing happens until the other player presses Accept. Blocks and Settings › Duel
	            challenges apply. A "no" stops the same challenger for a while.
	SAFE        Nobody can die to a duel: Cast/Damage holds both fighters at the rule's HealthFloor.
	            Afterwards each fighter gets back to at least the health they started with and their
	            harmful statuses are cleared. So a duel costs nothing but reservoir and pride.
	ISOLATED    While it runs, only the two can hurt each other, and nobody else can hurt or heal them
	            (PvpRules). Spectators are safe; so is everyone a stray spell passes.
	NO ESCAPE   You can't start a duel within recentHitSeconds of being hit, so it can't be used to
	            get out of a real fight. Something else bringing a fighter to the floor ends the duel
	            with no winner, and the floor stops protecting them.
	NOT A CRIME Hits between duellists don't count as harming someone (Cast/Damage's `practice`
	            flag, read by CastService's settlement law). Towns that ban a domain outright still
	            judge the cast itself.
	RING        A ring where the duel began. Leave it for ringOutSeconds and you forfeit. The ring's
	            anchor is one invisible part per duel (tagged DuelRing, attributes A, B, Rule,
	            Radius); each client draws it, so streaming and late joiners just work.

	Budget: at most maxConcurrent duels; one 5 Hz loop that does nothing with no duels running.
	Admin: duels, duelforce, duelend.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local DuelRules = require(Shared.Social.Data.DuelRules)

local Server = script.Parent.Parent
local DuelModel = require(Server.Social.DuelModel)
local PvpRules = require(Server.Magic.Cast.PvpRules)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)

local L = DuelRules.limits

type Pending = { from: number, to: number, rule: string, expires: number }

type Live = {
	duel: DuelModel.Duel,
	bodies: { [number]: Humanoid },
	startHealth: { [number]: number },
	ring: BasePart,
}

local DuelService = {
	name = "DuelService",
	dependencies = { "NetService", "SocialSafetyService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local safety: any = nil

local pendingTo: { [number]: Pending } = {} -- challenged player -> challenge
local pendingFrom: { [number]: Pending } = {} -- challenger -> challenge
local cooldowns: { [string]: number } = {} -- "from|to" -> os.clock() it ends
local liveByUser: { [number]: Live } = {}
local liveCount = 0
local duelCounter = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function nameOf(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	return if player then player.DisplayName else "Someone"
end

local function send(userId: number, view: { [string]: any })
	local player = Players:GetPlayerByUserId(userId)
	if player then
		Net.fire("DuelState", player, view)
	end
end

local function bodyOf(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

-- Why these two can't start a duel right now, or nil.
local function blocker(a: Player, b: Player): string?
	if a == b then
		return "SELF"
	end
	if liveByUser[a.UserId] or liveByUser[b.UserId] then
		return "IN_DUEL"
	end
	local humanoidA, rootA = bodyOf(a)
	local humanoidB, rootB = bodyOf(b)
	if not humanoidA or not humanoidB or not rootA or not rootB then
		return "NOT_NOW"
	end
	if (rootA.Position - rootB.Position).Magnitude > L.challengeRange then
		return "TOO_FAR"
	end
	local t = now()
	for _, humanoid in { humanoidA, humanoidB } do
		local hitAt = humanoid:GetAttribute("LastMagicHitAt")
		if typeof(hitAt) == "number" and t - hitAt < L.recentHitSeconds then
			return "IN_COMBAT"
		end
	end
	return nil
end

-- ─── Challenges ─────────────────────────────────────────────────────────────

local function clearPending(p: Pending)
	if pendingTo[p.to] == p then
		pendingTo[p.to] = nil
	end
	if pendingFrom[p.from] == p then
		pendingFrom[p.from] = nil
	end
end

local function dropPending(p: Pending)
	clearPending(p)
	send(p.from, { phase = "none" })
	send(p.to, { phase = "none" })
end

local function challenge(player: Player, targetId: number?, ruleId: string?): { [string]: any }
	local target = targetId and Players:GetPlayerByUserId(targetId)
	if not target then
		return { ok = false, reason = "GONE" }
	end
	local rule = DuelRules.rules[ruleId or DuelRules.default]
	if not rule then
		return { ok = false, reason = "NO_RULE" }
	end
	local reason = blocker(player, target)
	if reason then
		return { ok = false, reason = reason }
	end
	if pendingFrom[player.UserId] or pendingTo[player.UserId] then
		return { ok = false, reason = "PENDING" }
	end
	if pendingTo[target.UserId] or pendingFrom[target.UserId] then
		return { ok = false, reason = "NOT_ACCEPTING" }
	end
	if os.clock() < (cooldowns[player.UserId .. "|" .. target.UserId] or 0) then
		return { ok = false, reason = "COOLDOWN" }
	end
	if not safety:allows("duelChallenges", player, target) then
		return { ok = false, reason = "NOT_ACCEPTING" }
	end
	-- `allows` can yield (the friends check): the world may have moved on, so look again.
	if not target.Parent or pendingTo[target.UserId] or pendingFrom[player.UserId] then
		return { ok = false, reason = "NOT_ACCEPTING" }
	end
	local p: Pending = { from = player.UserId, to = target.UserId, rule = rule.id, expires = now() + L.challengeSeconds }
	pendingTo[p.to] = p
	pendingFrom[p.from] = p
	send(p.to, { phase = "incoming", from = p.from, name = player.DisplayName, rule = rule.id, expires = p.expires })
	send(p.from, { phase = "outgoing", to = p.to, name = target.DisplayName, rule = rule.id, expires = p.expires })
	log:info("duel_challenge", { from = p.from, to = p.to, rule = rule.id })
	return { ok = true }
end

-- ─── Starting and ending ────────────────────────────────────────────────────

local function viewFor(live: Live, userId: number): { [string]: any }
	local duel = live.duel
	local opponent = DuelModel.opponent(duel, userId)
	return {
		phase = duel.phase,
		opponent = opponent,
		name = nameOf(opponent),
		rule = duel.rule.id,
		center = duel.center,
		radius = duel.radius,
		fightAt = duel.fightAt,
		endsAt = duel.endsAt,
	}
end

local function makeRing(duel: DuelModel.Duel, a: Player, b: Player): BasePart
	local ring = Instance.new("Part")
	ring.Name = "DuelRing_" .. duel.id
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Transparency = 1
	ring.Size = Vector3.one
	ring.Position = duel.center
	ring:SetAttribute("A", a.DisplayName)
	ring:SetAttribute("B", b.DisplayName)
	ring:SetAttribute("Rule", duel.rule.id)
	ring:SetAttribute("Radius", duel.radius)
	CollectionService:AddTag(ring, "DuelRing")
	ring.Parent = workspace
	return ring
end

local function start(a: Player, b: Player, ruleId: string): (boolean, string?)
	if liveCount >= L.maxConcurrent then
		return false, "FULL"
	end
	local humanoidA, rootA = bodyOf(a)
	local humanoidB, rootB = bodyOf(b)
	if not humanoidA or not humanoidB or not rootA or not rootB then
		return false, "NOT_NOW"
	end
	duelCounter += 1
	local center = rootA.Position:Lerp(rootB.Position, 0.5)
	local duel = DuelModel.new("duel" .. duelCounter, a.UserId, b.UserId, ruleId, center, now())
	local live: Live = {
		duel = duel,
		bodies = { [a.UserId] = humanoidA, [b.UserId] = humanoidB },
		startHealth = { [a.UserId] = humanoidA.Health, [b.UserId] = humanoidB.Health },
		ring = makeRing(duel, a, b),
	}
	liveByUser[a.UserId] = live
	liveByUser[b.UserId] = live
	liveCount += 1
	for userId, humanoid in live.bodies do
		PvpRules.setDuel(userId, duel.id, false)
		humanoid:SetAttribute("DuelId", duel.id)
		humanoid:SetAttribute("HealthFloor", DuelModel.floorOf(duel, humanoid.MaxHealth))
		send(userId, viewFor(live, userId))
	end
	log:info("duel_started", { duel = duel.id, a = a.UserId, b = b.UserId, rule = duel.rule.id })
	return true
end

local HARMFUL: { string } = {}
for id, def in StatusEffects.defs do
	if def.harmful then
		table.insert(HARMFUL, id)
	end
end

local function finish(live: Live, outcome: DuelModel.Outcome)
	local duel = live.duel
	if duel.phase == "ended" then
		return
	end
	duel.phase = "ended"
	local recap = DuelModel.recap(duel, outcome, now())

	for userId, humanoid in live.bodies do
		liveByUser[userId] = nil
		PvpRules.setDuel(userId, nil)
		humanoid:SetAttribute("DuelId", nil)
		humanoid:SetAttribute("HealthFloor", nil)
		-- Back to where you started. Never lower: a potion you drank mid-duel stays drunk.
		-- Interrupted duels skip this: whatever interrupted it is real, and this isn't a free heal.
		if humanoid.Parent and humanoid.Health > 0 and outcome.reason ~= "interrupted" then
			StatusEffects.cleanse(humanoid, HARMFUL)
			humanoid.Health = math.min(humanoid.MaxHealth, math.max(humanoid.Health, live.startHealth[userId]))
		end
	end
	PvpRules.setGrace(duel.a, duel.b, L.graceSeconds)
	live.ring:Destroy()
	liveCount -= 1

	for _, userId in { duel.a, duel.b } do
		local opponent = DuelModel.opponent(duel, userId)
		send(userId, {
			phase = "ended",
			opponent = opponent,
			name = nameOf(opponent),
			result = if outcome.winner == nil then "draw" elseif outcome.winner == userId then "won" else "lost",
			reason = outcome.reason,
			rule = duel.rule.id,
			recap = recap,
		})
	end

	-- Whoever was watching hears how it ended.
	local line = if outcome.winner
		then string.format("%s won a duel against %s.", nameOf(outcome.winner), nameOf(DuelModel.opponent(duel, outcome.winner)))
		else string.format("The duel between %s and %s ended without a winner.", nameOf(duel.a), nameOf(duel.b))
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if player.UserId ~= duel.a and player.UserId ~= duel.b and root and root:IsA("BasePart") and (root.Position - duel.center).Magnitude <= L.spectatorRange then
			Net.fire("Notify", player, line)
		end
	end

	bus:publish(Topics.DuelEnded, { id = duel.id, a = duel.a, b = duel.b, winner = outcome.winner, reason = outcome.reason, rule = duel.rule.id })
	log:info("duel_ended", { duel = duel.id, winner = outcome.winner, reason = outcome.reason, seconds = recap.seconds, hits = recap.hits })
end

-- ─── Actions ────────────────────────────────────────────────────────────────

local function onAction(player: Player, op: string, target: number?, rule: string?): { [string]: any }
	if flags.get("duels_enabled") == false then
		return { ok = false, reason = "OFF" }
	end
	local userId = player.UserId
	if op == "challenge" then
		return challenge(player, target, rule)
	elseif op == "accept" then
		local p = pendingTo[userId]
		if not p or now() >= p.expires then
			if p then
				dropPending(p)
			end
			return { ok = false, reason = "EXPIRED" }
		end
		local challenger = Players:GetPlayerByUserId(p.from)
		if not challenger then
			dropPending(p)
			return { ok = false, reason = "GONE" }
		end
		local reason = blocker(challenger, player)
		if reason then
			dropPending(p)
			return { ok = false, reason = reason }
		end
		clearPending(p)
		local ok, why = start(challenger, player, p.rule)
		if not ok then
			send(p.from, { phase = "none" })
			send(p.to, { phase = "none" })
			return { ok = false, reason = why }
		end
		return { ok = true }
	elseif op == "decline" then
		local p = pendingTo[userId]
		if p then
			cooldowns[p.from .. "|" .. p.to] = os.clock() + L.challengeCooldown
			dropPending(p)
			local challenger = Players:GetPlayerByUserId(p.from)
			if challenger then
				Net.fire("Notify", challenger, player.DisplayName .. " declined the duel.")
			end
		end
		return { ok = true }
	elseif op == "cancel" then
		local p = pendingFrom[userId]
		if p then
			dropPending(p)
		end
		return { ok = true }
	elseif op == "yield" then
		local live = liveByUser[userId]
		if not live or live.duel.phase ~= "fight" then
			return { ok = false, reason = "NOT_FIGHTING" }
		end
		finish(live, { winner = DuelModel.opponent(live.duel, userId), reason = "yielded" })
		return { ok = true }
	end
	return { ok = false }
end

-- ─── The fight ──────────────────────────────────────────────────────────────

local function onDamaged(payload: any)
	local model = payload.model
	if not model or not model:IsA("Model") then
		return
	end
	local victim = Players:GetPlayerFromCharacter(model)
	local live = victim and liveByUser[victim.UserId]
	if not victim or not live then
		return
	end
	local humanoid: Humanoid = payload.humanoid
	local outcome = DuelModel.noteHit(live.duel, payload.sourceUserId, victim.UserId, payload.amount, humanoid.Health, humanoid.MaxHealth, {
		kind = payload.kind,
		domain = payload.domain,
		crit = payload.crit == true,
	}, now())
	if outcome then
		finish(live, outcome)
	end
end

local function tick(dt: number)
	local t = now()
	local seen: { [Live]: boolean } = {}
	for _, live in liveByUser do
		if seen[live] then
			continue
		end
		seen[live] = true
		local duel = live.duel
		if duel.phase == "countdown" and t >= duel.fightAt then
			duel.phase = "fight"
			for userId in live.bodies do
				PvpRules.setDuel(userId, duel.id, true)
				send(userId, viewFor(live, userId))
			end
		end
		local bodies: { [number]: DuelModel.Body } = {}
		for userId, humanoid in live.bodies do
			local player = Players:GetPlayerByUserId(userId)
			local root = humanoid.RootPart
			local alive = player ~= nil and humanoid.Parent ~= nil and player.Character == humanoid.Parent and humanoid.Health > 0 and root ~= nil
			local distance = 0
			if root then
				distance = Vector3.new(root.Position.X - duel.center.X, 0, root.Position.Z - duel.center.Z).Magnitude
			end
			bodies[userId] = { alive = alive, share = humanoid.Health / math.max(1, humanoid.MaxHealth), distance = distance }
		end
		if duel.phase == "countdown" and (not bodies[duel.a].alive or not bodies[duel.b].alive) then
			finish(live, { winner = nil, reason = "interrupted" })
			continue
		end
		local outcome = DuelModel.tick(duel, dt, t, bodies)
		if outcome then
			finish(live, outcome)
		end
	end
	-- Open challenges run out.
	for _, p in pendingTo do
		if t >= p.expires then
			dropPending(p)
		end
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	local ruleIds: { string } = {}
	for _, rule in DuelRules.ordered do
		table.insert(ruleIds, rule.id)
	end
	admin:Register({
		name = "duels",
		category = "Social",
		description = "Duels running and challenges open on this server",
		handler = function(_ctx: any, _a: any)
			local lines: { string } = {}
			local seen: { [Live]: boolean } = {}
			for _, live in liveByUser do
				if not seen[live] then
					seen[live] = true
					local d = live.duel
					table.insert(lines, string.format("%s: %s vs %s, %s, %s, %d hits", d.id, nameOf(d.a), nameOf(d.b), d.rule.id, d.phase, d.fighters[d.a].hits + d.fighters[d.b].hits))
				end
			end
			for _, p in pendingTo do
				table.insert(lines, string.format("challenge: %s to %s, %s", nameOf(p.from), nameOf(p.to), p.rule))
			end
			return if #lines > 0 then table.concat(lines, "\n") else "No duels"
		end,
	})
	admin:Register({
		name = "duelforce",
		category = "Social",
		description = "Start a duel between two players with no challenge (testing: skips consent and the combat check)",
		args = {
			{ name = "a", type = "player" },
			{ name = "b", type = "player" },
			{ name = "rule", type = "enum", options = ruleIds, default = DuelRules.default },
		},
		handler = function(ctx: any, a: any)
			if a.a == a.b or liveByUser[a.a.UserId] or liveByUser[a.b.UserId] then
				return "Those two can't duel right now"
			end
			local ok, reason = start(a.a, a.b, a.rule)
			log:info("duel_forced", { by = ctx.player.UserId, a = a.a.UserId, b = a.b.UserId })
			return if ok then "Duel started" else "Refused: " .. tostring(reason)
		end,
	})
	admin:Register({
		name = "duelend",
		category = "Social",
		description = "End a player's duel with no winner",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local live = liveByUser[a.player.UserId]
			if not live then
				return a.player.Name .. " isn't in a duel"
			end
			finish(live, { winner = nil, reason = "time" })
			return "Ended"
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function DuelService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	safety = ctx.get("SocialSafetyService")
	Net.handle("DuelAction", onAction)
	bus:subscribe(Topics.TargetDamaged, onDamaged)
	registerAdmin(ctx.get("AdminService"))
end

function DuelService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		local to, from = pendingTo[userId], pendingFrom[userId]
		if to then
			dropPending(to)
		end
		if from then
			dropPending(from)
		end
		local live = liveByUser[userId]
		if live then
			finish(live, { winner = DuelModel.opponent(live.duel, userId), reason = "left" })
		end
	end)
	local last = os.clock()
	while true do
		task.wait(1 / L.tickRate)
		local t = os.clock()
		tick(t - last)
		last = t
	end
end

return DuelService
