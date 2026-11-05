--!strict
--[[
	StatusEffects: timed conditions on any Humanoid (players and NPCs). Data-driven: DEFS below
	says what each status does; spells pick a status by id (Data/EffectLibrary params).

	What a status can do:
		walk / jump      multiply WalkSpeed / jump (the product of every active status, from a saved base)
		dot              take `magnitude` damage per second (through Damage, so wards and hexes apply)
		absorb           `magnitude` points of incoming damage are soaked up first (Ward)
		damageTaken      multiplies incoming damage (Hex)
		noCast           CastService refuses casts (Silence)
		backfireMult     multiplies the caster's backfire chance (Fortune, Dazed)
		critTaken        added to the crit chance of hits taken (Jinxed)
		animSpeed        NPC animation tracks play at this speed (time fields)
		anchorNpc        NPC root anchored while active (Stasis); players get walk/jump 0 instead
		transparency     character parts fade to at least this (Veil)
		client           the affected player's client gets a WorldEffect { kind = "status" } cue
		harmful          dispel/cleanse classification
	Every active status also sets a Humanoid attribute "Status_<id>" = expiry (server time), the
	hook NPC brains read (fear -> flee, charm -> won't attack, calm, blinded, veiled -> can't see).

	Caveat: WalkSpeed is owned by this module while any walk/jump status is active. Other systems
	that change WalkSpeed (sprinting) should set the "MagicBaseWalk" attribute instead. Stances
	that slow you (an attuned spell) use setWalkMultiplier, which stacks with statuses.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)

export type StatusDef = {
	name: string,
	walk: number?,
	jump: number?,
	dot: boolean?,
	absorb: boolean?,
	damageTaken: number?,
	noCast: boolean?,
	backfireMult: number?,
	animSpeed: number?,
	anchorNpc: boolean?,
	transparency: number?,
	client: boolean?,
	harmful: boolean?,
	knockdown: boolean?, -- NPCs fall (PlatformStand); players fall on their own client (status cue)
	critTaken: number?, -- added to the crit chance of hits against this humanoid (Jinxed)
}

local DEFS: { [string]: StatusDef } = {
	slow = { name = "Slowed", walk = 0.55, harmful = true },
	haste = { name = "Hastened", walk = 1.45 },
	root = { name = "Rooted", walk = 0, jump = 0, harmful = true },
	stasis = { name = "Stasis", walk = 0, jump = 0, anchorNpc = true, animSpeed = 0, client = true, harmful = true },
	ward = { name = "Warded", absorb = true },
	evading = { name = "Evading" }, -- a dash's moment of damage resistance (opts.resist; MovementService)
	hexed = { name = "Hexed", damageTaken = 1.25, dot = true, harmful = true },
	poison = { name = "Poisoned", dot = true, harmful = true },
	rot = { name = "Rotting", dot = true, walk = 0.85, harmful = true },
	burning = { name = "Burning", dot = true, harmful = true, client = true },
	silence = { name = "Silenced", noCast = true, client = true, harmful = true },
	fear = { name = "Afraid", walk = 1.1, client = true, harmful = true },
	charm = { name = "Charmed", harmful = true },
	calm = { name = "Calm" },
	blind = { name = "Blinded", client = true, harmful = true },
	veiled = { name = "Veiled", transparency = 0.85 },
	lucky = { name = "Lucky", backfireMult = 0.5 },
	time_slow = { name = "Slowed time", walk = 0.35, animSpeed = 0.35, client = true, harmful = true },
	time_haste = { name = "Quickened time", walk = 1.5, animSpeed = 1.5, client = true },
	knockdown = { name = "Knocked down", walk = 0, jump = 0, knockdown = true, client = true, harmful = true },
	-- Domain strike riders (Shared/Magic/Data/Strikes).
	dazed = { name = "Dazed", walk = 0.85, backfireMult = 1.5, client = true, harmful = true },
	jinxed = { name = "Jinxed", critTaken = 0.15, harmful = true },
}

type Active = { expires: number, magnitude: number, source: number?, resist: { [string]: number }? }

local StatusEffects = {}
StatusEffects.defs = DEFS
-- hook(humanoid, id, duration, sourceUserId?) for a NEW status (not a refresh), set by EffectRunner:
-- Topics.StatusApplied and the floating status word nearby clients see.
StatusEffects.onApplied = nil :: ((Humanoid, string, number, number?) -> ())?

local active: { [Humanoid]: { [string]: Active } } = {}
local fadedParts: { [Humanoid]: { [BasePart]: number } } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function playerOf(humanoid: Humanoid): Player?
	local model = humanoid.Parent
	return if model and model:IsA("Model") then Players:GetPlayerFromCharacter(model) else nil
end

local function cueClient(humanoid: Humanoid, id: string, on: boolean, duration: number)
	local player = playerOf(humanoid)
	if player and DEFS[id].client then
		Net.fire("WorldEffect", player, { kind = "status", status = id, active = on, duration = duration })
	end
end

-- Re-derives movement, anchoring and transparency from every status the humanoid has.
-- Walk multipliers from outside the status system (a stance, e.g. an attuned spell), by source.
-- They stack with statuses through the same saved base. Weak keys: dead humanoids drop out.
local walkMults: { [Humanoid]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any

local function recompute(humanoid: Humanoid)
	local statuses: { [string]: Active } = active[humanoid] or {}
	local walk, jump, anchored, fade, down = 1, 1, false, 0, false
	for _, mult in (walkMults[humanoid] or {}) :: { [string]: number } do
		walk *= mult
	end
	for id in statuses do
		local def = DEFS[id]
		down = down or def.knockdown == true
		walk *= def.walk or 1
		jump *= def.jump or 1
		anchored = anchored or def.anchorNpc == true
		fade = math.max(fade, def.transparency or 0)
	end

	-- Movement, from saved bases so stacking and expiry never drift.
	if humanoid:GetAttribute("MagicBaseWalk") == nil then
		humanoid:SetAttribute("MagicBaseWalk", humanoid.WalkSpeed)
		humanoid:SetAttribute("MagicBaseJump", if humanoid.UseJumpPower then humanoid.JumpPower else humanoid.JumpHeight)
	end
	local baseWalk = humanoid:GetAttribute("MagicBaseWalk") :: number
	local baseJump = humanoid:GetAttribute("MagicBaseJump") :: number
	humanoid.WalkSpeed = baseWalk * walk
	if humanoid.UseJumpPower then
		humanoid.JumpPower = baseJump * jump
	else
		humanoid.JumpHeight = baseJump * jump
	end
	if next(statuses) == nil and walkMults[humanoid] == nil then
		humanoid:SetAttribute("MagicBaseWalk", nil)
		humanoid:SetAttribute("MagicBaseJump", nil)
	end

	-- Stasis anchors NPCs only (anchoring a client-owned character fights its physics).
	local character = humanoid.Parent
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and not playerOf(humanoid) then
		root.Anchored = anchored
	end

	-- Knockdown: an NPC falls limp and gets back up when it ends (players do this on their client).
	if not playerOf(humanoid) then
		local wasDown = humanoid:GetAttribute("KnockedDown") == true
		if down ~= wasDown then
			humanoid:SetAttribute("KnockedDown", if down then true else nil)
			humanoid.PlatformStand = down
			if not down and humanoid.Health > 0 then
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end
	end

	-- Veil: fade every part to at least `fade`, remembering the original transparency.
	local faded = fadedParts[humanoid]
	if fade > 0 and character then
		faded = faded or {}
		fadedParts[humanoid] = faded
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				if faded[part] == nil then
					faded[part] = part.Transparency
				end
				part.Transparency = math.max(faded[part], fade)
			end
		end
	elseif faded then
		for part, original in faded do
			if part.Parent then
				part.Transparency = original
			end
		end
		fadedParts[humanoid] = nil
	end
end

-- ─── API ────────────────────────────────────────────────────────────────────

-- `resist`: resistance keys this status grants while active (Cast/Resistances, e.g. a Ward).
export type ApplyOptions = { duration: number, magnitude: number?, source: number?, resist: { [string]: number }? }

-- Applies or refreshes a status (longest duration and strongest magnitude win).
function StatusEffects.apply(humanoid: Humanoid, id: string, opts: ApplyOptions): boolean
	local def = DEFS[id]
	if not def or humanoid.Health <= 0 then
		return false
	end
	local statuses = active[humanoid]
	if not statuses then
		statuses = {}
		active[humanoid] = statuses
	end
	local t = now()
	local existing = statuses[id]
	local expires = t + opts.duration
	if existing then
		existing.expires = math.max(existing.expires, expires)
		existing.magnitude = math.max(existing.magnitude, opts.magnitude or 0)
		existing.source = opts.source or existing.source
		if opts.resist then
			-- A refresh keeps the strongest value per key.
			local merged = existing.resist or {}
			for key, v in opts.resist do
				merged[key] = math.max(merged[key] or 0, v)
			end
			existing.resist = merged
		end
	else
		statuses[id] = { expires = expires, magnitude = opts.magnitude or 0, source = opts.source, resist = if opts.resist then table.clone(opts.resist) else nil }
		cueClient(humanoid, id, true, opts.duration)
		local hook = StatusEffects.onApplied
		if hook then
			hook(humanoid, id, opts.duration, opts.source)
		end
	end
	humanoid:SetAttribute("Status_" .. id, statuses[id].expires)
	recompute(humanoid)
	return true
end

-- The resistance keys every active status grants together (Cast/Resistances' "ward" source).
function StatusEffects.resistOf(humanoid: Humanoid): { [string]: number }?
	local statuses = active[humanoid]
	if not statuses then
		return nil
	end
	local out: { [string]: number }? = nil
	local t = now()
	for _, s in statuses do
		if s.resist and s.expires > t then
			local m = out or {}
			for key, v in s.resist do
				m[key] = (m[key] or 0) + v
			end
			out = m
		end
	end
	return out
end

function StatusEffects.remove(humanoid: Humanoid, id: string)
	local statuses = active[humanoid]
	if statuses and statuses[id] then
		statuses[id] = nil
		humanoid:SetAttribute("Status_" .. id, nil)
		cueClient(humanoid, id, false, 0)
		if next(statuses) == nil then
			active[humanoid] = nil
		end
		recompute(humanoid)
	end
end

-- Sets (or, with nil, removes) a walk multiplier from `source`, e.g. ("attuned", 0.85).
function StatusEffects.setWalkMultiplier(humanoid: Humanoid, source: string, mult: number?)
	local mults = walkMults[humanoid] or {}
	mults[source] = mult
	walkMults[humanoid] = if next(mults) then mults else nil
	recompute(humanoid)
end

function StatusEffects.has(humanoid: Humanoid, id: string): boolean
	local statuses = active[humanoid]
	return statuses ~= nil and statuses[id] ~= nil
end

-- Removes the listed statuses; returns how many were removed.
function StatusEffects.cleanse(humanoid: Humanoid, ids: { string }): number
	local removed = 0
	for _, id in ids do
		if StatusEffects.has(humanoid, id) then
			StatusEffects.remove(humanoid, id)
			removed += 1
		end
	end
	return removed
end

-- Removes every status (Dispel). Returns how many.
function StatusEffects.dispel(humanoid: Humanoid): number
	local ids = {}
	for id in (active[humanoid] or {}) :: { [string]: Active } do
		table.insert(ids, id)
	end
	return StatusEffects.cleanse(humanoid, ids)
end

function StatusEffects.blocksCasting(humanoid: Humanoid): boolean
	for id in (active[humanoid] or {}) :: { [string]: Active } do
		if DEFS[id].noCast then
			return true
		end
	end
	return false
end

function StatusEffects.backfireMult(humanoid: Humanoid): number
	local mult = 1
	for id in (active[humanoid] or {}) :: { [string]: Active } do
		mult *= DEFS[id].backfireMult or 1
	end
	return mult
end

function StatusEffects.damageTakenMult(humanoid: Humanoid): number
	local mult = 1
	for id in (active[humanoid] or {}) :: { [string]: Active } do
		mult *= DEFS[id].damageTaken or 1
	end
	return mult
end

-- Extra crit chance against this humanoid (Jinxed), added to the attacker's (DamageModel).
function StatusEffects.critTakenBonus(humanoid: Humanoid): number
	local bonus = 0
	for id in (active[humanoid] or {}) :: { [string]: Active } do
		bonus += DEFS[id].critTaken or 0
	end
	return bonus
end

-- Removes up to `count` beneficial statuses (Void's Unmake), longest-lasting first so it takes
-- the blessing that matters most; ties by id, so the choice is deterministic. Returns how many.
function StatusEffects.stripBeneficial(humanoid: Humanoid, count: number): number
	local candidates: { { id: string, expires: number } } = {}
	for id, s in (active[humanoid] or {}) :: { [string]: Active } do
		if not DEFS[id].harmful then
			table.insert(candidates, { id = id, expires = s.expires })
		end
	end
	table.sort(candidates, function(a, b)
		if a.expires ~= b.expires then
			return a.expires > b.expires
		end
		return a.id < b.id
	end)
	local removed = 0
	for i = 1, math.min(count, #candidates) do
		StatusEffects.remove(humanoid, candidates[i].id)
		removed += 1
	end
	return removed
end

-- Soaks `amount` into any absorb pool (Ward); returns the damage left over.
function StatusEffects.absorb(humanoid: Humanoid, amount: number): number
	local statuses = active[humanoid]
	if not statuses then
		return amount
	end
	for id, s in statuses do
		if DEFS[id].absorb and amount > 0 then
			local soaked = math.min(s.magnitude, amount)
			s.magnitude -= soaked
			amount -= soaked
			if s.magnitude <= 0 then
				StatusEffects.remove(humanoid, id)
			end
		end
	end
	return amount
end

-- Statuses on a humanoid, for admin/debug.
function StatusEffects.list(humanoid: Humanoid): { string }
	local out = {}
	for id, s in (active[humanoid] or {}) :: { [string]: Active } do
		table.insert(out, string.format("%s %.0fs", id, s.expires - now()))
	end
	table.sort(out)
	return out
end

function StatusEffects.count(): number
	local n = 0
	for _, statuses in active do
		for _ in statuses do
			n += 1
		end
	end
	return n
end

--[[
	Advances every status: expiry, damage over time, NPC animation speed.
	`damage(humanoid, amount, sourceUserId, kind)` is Damage.apply (passed in to avoid a cycle).
]]
function StatusEffects.tick(dt: number, damage: (Humanoid, number, number?, string) -> ())
	local t = now()
	for humanoid, statuses in active do
		if not humanoid.Parent or humanoid.Health <= 0 then
			active[humanoid] = nil
			fadedParts[humanoid] = nil
			continue
		end
		local anim = 1
		for id, s in statuses do
			if s.expires <= t then
				StatusEffects.remove(humanoid, id)
				continue
			end
			local def = DEFS[id]
			if def.dot and s.magnitude > 0 then
				damage(humanoid, s.magnitude * dt, s.source, id)
			end
			anim *= def.animSpeed or 1
		end
		-- NPC animations follow time distortion (players' clients do their own from the cue).
		if not playerOf(humanoid) then
			local animator = humanoid:FindFirstChildOfClass("Animator")
			if animator then
				for _, track in animator:GetPlayingAnimationTracks() do
					track:AdjustSpeed(anim)
				end
			end
		end
	end
end

return StatusEffects
