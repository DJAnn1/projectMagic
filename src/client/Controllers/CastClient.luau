--!strict
--[[
	CastClient: the client half of casting. Input, aim, prediction. Never authority.

	INPUT      setting castMode (Shared/UI/Settings):
	           equip (default)  a hotbar key (1-8, or tapping a slot) attunes that spell: the Equip
	                            clip, then Hold; your character turns to face the aim; the mouse
	                            cursor becomes a crosshair. Left click casts it. The same key, or
	                            Q, stows it; another key swaps. The mouse wheel steps through the
	                            filled slots (it doesn't zoom while attuned). Gamepad: D-pad picks a
	                            slot (swapping if attuned), L2 attunes/stows it, R2 casts (or
	                            attunes when nothing is). Touch: tap a slot to attune; the HUD
	                            shows Cast and Stow buttons.
	           quick            a hotbar key casts at once (gamepad: R2 casts the selected slot).
	           HudController calls pressSlot(slot) for slot taps. Everything is blocked while a
	           screen, the console or a text box has focus.
	SLASH      equip mode, a spell attuned: F (gamepad B, the touch Slash button) swings the
	           spellblade, Slash1 then Slash2 (Shared/Magic/Melee). A press before the combo window
	           is buffered until it opens. Predicted (the clip); MeleeResult refuses or reports the
	           first hit (a short hit-stop). Services/MeleeService decides what it hits.
	GUARD      equip mode, a spell attuned: hold right mouse (gamepad L1, the touch Block button)
	           to raise a ward, release to lower it (GuardIntent; Services/GuardService). Raising
	           drops a charge. Predicted (guarding value, BlockStart clip); a refusal reverts it.
	           With no spell readied, the same input blocks with a blocking main-hand weapon.
	WEAPONS    with no spell readied, left mouse (gamepad R1, the touch Cast button) attacks with
	           the main-hand weapon and F (B, touch Slash) swings it; Controllers/WeaponClient does
	           the rest through CastClient.weapon.
	ATTUNE     predicted (attuned value, Equip clip), confirmed or reverted by AttuneSpell's answer.
	           The server (Services/AttunementService) owns it: only the attuned spell can be cast.
	AIM        Controllers/AimController: the mouse on keyboard, the screen centre on touch and
	           gamepad, or a soft-locked target. Range is checked from the muzzle (Shared/Magic/Aim),
	           exactly as the server does.
	CHECKS     before sending, the client drops casts the server would refuse anyway (cooldown,
	           already casting, silenced, out of the previewed range): instant feedback, and no
	           wasted request against the remote's rate limit. The server re-checks everything.
	PREDICTION the casting glow (Fx/SpellFx.casting, in the caster's own Signature) starts at once
	           and the cast bar fills from the previewed cast time. The server's CastResult then:
	             refused   cancels the glow and the bar, shows the reason
	             accepted  replaces the previewed cast time with the real one
	             resolved  ends the bar
	           The server's own "spell begin" cue for this player is skipped while a prediction is
	           live (isPredicting), so the glow never doubles.

	Values: selectedSlot (gamepad), casting { key, started, castTime }? (the HUD cast bar),
	attuned { slot, key }? (the HUD highlights it).
	Feedback goes out as MagicState events { kind = "castFeedback", text, tone }.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Controls = require(Shared.UI.Controls)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Registry = require(Shared.Magic.Registry)
local ActionRules = require(Shared.Magic.ActionRules)
local Aim = require(Shared.Magic.Aim)
local Charge = require(Shared.Magic.Charge)
local Melee = require(Shared.Magic.Melee)

local Client = script.Parent.Parent
local Kit = require(Client:WaitForChild("UI").Kit)
local SpellFx = require(Client:WaitForChild("Fx").SpellFx)
local FxRecipes = require(Client.Fx.FxRecipes)

local SLOT_COUNT = 8
local PREDICTION_TIMEOUT = 3 -- seconds without any server answer before the prediction is dropped
local MIN_CAST_ANIMATION = 0.35 -- matches CastTuning.minCastAnimation (server-only data)

local SLOT_KEYS = Controls.keys("hotbar", "keyboard") -- 1..8 (Shared/UI/Controls)

local TURN_RATE = 14 -- how fast the body turns to the aim while attuned (higher = snappier)
local CROSSHAIR = "rbxasset://textures/MouseLockedCursor.png"
local SCROLL_ACTION = "AttunedSpellScroll"

local ATTUNE_REASONS: { [string]: string } = {
	QUICK_MODE = "Casting is set to Quick.",
	TOO_FAST = "",
	DEAD = "You can't ready a spell now.",
	BUSY = "Finish what you're doing first.",
	EMPTY_SLOT = "That slot is empty.",
	NO_SUCH_SPELL = "That spell isn't in your spellbook.",
	NETWORK = "The connection hiccuped. Try again.",
}

export type Casting = { key: string, started: number, castTime: number }
export type Attuned = { slot: number, key: string }
export type Charging = { slot: number, key: string, started: number, castTime: number, maxHold: number }

local CHANNEL_AIM_HZ = 10 -- how often a held channel's aim is sent

local CastClient = {
	name = "CastClient",
	dependencies = { "InterfaceController", "MagicStateController", "AnimationController", "AimController" },
}

CastClient.SLOT_KEYS = SLOT_KEYS
CastClient.selectedSlot = Kit.value(1)
CastClient.casting = Kit.value(nil :: Casting?)
CastClient.attuned = Kit.value(nil :: Attuned?)
CastClient.charging = Kit.value(nil :: Charging?)
CastClient.guarding = Kit.value(false)

-- Item weapons (Controllers/WeaponClient fills these in at init). With no spell readied, the
-- attack inputs (left mouse, R1, the touch Cast and Slash buttons, F) and the guard go to the
-- main-hand weapon instead: `primary` = left mouse / R1 / touch Cast, `melee` = F / B / touch Slash.
export type WeaponHooks = {
	press: ((source: string) -> ())?,
	release: (() -> ())?,
	canBlock: (() -> boolean)?,
}
CastClient.weapon = { press = nil, release = nil, canBlock = nil } :: WeaponHooks

local interface: any = nil
local magic: any = nil
local animation: any = nil
local aimer: any = nil
local predicted: { key: string, anchor: Part?, at: number }? = nil
local attuneRequest = 0 -- increments per request: a late answer to an old one is ignored
local channelHeld = false -- a channelled spell we cast is still held down (release ends it)
local swingLast: { index: number, started: number, speed: number }? = nil -- our last spellblade swing
local swingBuffered = false

local MELEE_REASONS: { [string]: string } = {
	INSUFFICIENT_RESERVOIR = "Not enough in your reservoir to edge the blade.",
	NOT_ATTUNED = "Ready a spell first: the blade takes its edge from it.",
	QUICK_MODE = "The spellblade needs Casting set to Equip.",
	STAGGERED = "You're knocked off your feet.",
}

local function feedback(text: string, tone: string)
	magic.events:Fire({ kind = "castFeedback", text = text, tone = tone })
end

local function clearPrediction(cancelFx: boolean)
	local p = predicted
	if p and cancelFx then
		SpellFx.cancel(p.anchor)
		animation:cancelPrediction()
	end
	predicted = nil
	CastClient.casting:set(nil)
end

-- Aim (a fresh sample): AimController owns the ray and soft lock-on.
function CastClient.aim(_self: any): (Vector3, Model?)
	return aimer:sample()
end

-- True while this client's own casting glow is predicted (the server's begin cue is skipped).
function CastClient.isPredicting(_self: any, userId: number): boolean
	local p = predicted
	return userId == Players.LocalPlayer.UserId and p ~= nil and os.clock() - p.at < PREDICTION_TIMEOUT
end

local function equipMode(): boolean
	return magic.settings:get().castMode ~= "quick"
end

-- `heldFor`: seconds a charge was held (equip mode's release), for the predicted time to effect.
function CastClient.cast(_self: any, slot: number, heldFor: number?)
	local key = magic.hotbar:get()[slot]
	if not key then
		interface:open("Composer")
		return
	end
	local held = CastClient.attuned:get()
	if equipMode() and (not held or held.key ~= key) then
		return -- equip mode casts only the attuned spell (the server enforces it too)
	end
	if FeatureFlags.get("magic_casting_enabled") == false then
		feedback("Magic is stilled on this server.", "warn")
		return
	end
	if CastClient.casting:get() then
		feedback("You're still casting.", "dim")
		return
	end
	local readyAt = magic.cooldowns:get()[key]
	local now = workspace:GetServerTimeNow()
	if readyAt and readyAt > now then
		feedback(string.format("Not ready (%.1fs)", readyAt - now), "dim")
		return
	end
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end
	if humanoid:GetAttribute("Status_silence") then
		feedback("You can't speak a working while silenced.", "warn")
		return
	end
	local action = ActionRules.effective(ActionRules.read(character), workspace:GetServerTimeNow())
	if action ~= "casting" and not ActionRules.allows(action, "cast") then
		feedback(if action == "staggered" then "You're knocked off your feet." else "You can't cast in the middle of that.", "dim")
		return
	end

	local spell = magic:spell(key)
	if not spell then
		return
	end
	local stats = magic:preview(spell.recipe)
	local point, target = CastClient:aim()
	if stats and not Aim.tuning.selfCentred[spell.recipe.form] and not Aim.withinRange(Aim.muzzle(root.Position), point, stats.range) then
		feedback("Too far away.", "dim")
		return
	end

	-- Predict: glow and cast bar now; the server corrects or cancels.
	local castTime = if stats then stats.castTime else 0.5
	if equipMode() and stats and not stats.flags.channeled and Charge.chargeable(castTime) then
		local h = heldFor or 0 -- no charge at all = a tap
		castTime = Charge.releaseCastTime(Charge.stageIndex(h, castTime), castTime, h)
	end
	local branch = Registry.branches[spell.recipe.branch]
	local domain = if branch then branch.domains[1] else "energy"
	local style = SpellFx.styleFor(Players.LocalPlayer.UserId, domain)
	local tier = FxRecipes.tiers[math.clamp(if stats then stats.masteryTier else 2, 0, 8)]
	local anchor = SpellFx.casting(root.Position, style, tier, castTime, 2, domain, spell.recipe.power)
	animation:predict("casting", math.max(castTime, MIN_CAST_ANIMATION), domain)
	local prediction = { key = key, anchor = anchor, at = os.clock() }
	predicted = prediction
	CastClient.casting:set({ key = key, started = os.clock(), castTime = castTime })
	magic:sendCast(key, point, target)
	channelHeld = stats ~= nil and stats.flags.channeled == true

	task.delay(PREDICTION_TIMEOUT, function()
		if predicted == prediction then
			clearPrediction(true) -- no answer at all (no CastService, or a dropped packet)
		end
	end)
end

local function onMelee(result: any)
	if result.ok == false then
		swingLast = nil
		animation:predict(if CastClient.attuned:get() then "holding" else "idle")
		local text = MELEE_REASONS[result.reason or ""]
		if text then
			feedback(text, "dim")
		end
	elseif result.hit then
		animation:hitStop(0.06) -- the blade bites: a beat of stillness
	end
end

local function onEvent(event: any)
	if event.kind == "melee" then
		onMelee(event.result)
		return
	end
	if event.kind ~= "cast" then
		return
	end
	local result = event.result
	-- A refused guard (broken, spent, busy): we're not guarding after all.
	if result.stage == "refused" and result.key == nil and CastClient.guarding:get() then
		CastClient.guarding:set(false)
		animation:predict(if CastClient.attuned:get() then "holding" else "idle")
	end
	-- The server refused to start our charge (cooldown, busy, silenced): drop it here too.
	local charge = CastClient.charging:get()
	if result.stage == "refused" and charge and result.key == charge.key then
		CastClient.charging:set(nil)
		animation:predict(if CastClient.attuned:get() then "holding" else "idle")
	end
	local p = predicted
	if not p or result.key ~= p.key and result.key ~= nil then
		if result.stage == "resolved" then
			CastClient.casting:set(nil)
		end
		return
	end
	if result.stage == "refused" then
		clearPrediction(true)
	elseif result.stage == "accepted" then
		local casting = CastClient.casting:get()
		if casting and typeof(result.castTime) == "number" then
			CastClient.casting:set({ key = casting.key, started = casting.started, castTime = result.castTime })
		end
	elseif result.stage == "resolved" then
		clearPrediction(false)
	end
end

-- ─── Hold to charge / channel (Casting.md §8) ───────────────────────────────

local function domainOf(key: string): string
	local spell = magic:spell(key)
	local branch = spell and Registry.branches[spell.recipe.branch]
	return if branch then branch.domains[1] else "energy"
end

-- Press (left mouse, R2, the touch Cast button) in equip mode: a chargeable spell starts
-- charging (released later); a channelled or slow spell is cast at once and held.
function CastClient.pressCast(self: any)
	local held = CastClient.attuned:get()
	if not held then
		local press = CastClient.weapon.press
		if press and not CastClient.guarding:get() then
			press("primary") -- nothing readied: the weapon attacks
		end
		return
	end
	if CastClient.charging:get() or CastClient.guarding:get() then
		return -- lower the guard to cast
	end
	local spell = magic:spell(held.key)
	local stats = spell and magic:preview(spell.recipe)
	if not stats or stats.flags.channeled or not Charge.chargeable(stats.castTime) then
		self:cast(held.slot)
		return
	end
	-- The same quick checks as a cast, so a doomed charge never starts.
	local readyAt = magic.cooldowns:get()[held.key]
	if readyAt and readyAt > workspace:GetServerTimeNow() then
		feedback(string.format("Not ready (%.1fs)", readyAt - workspace:GetServerTimeNow()), "dim")
		return
	end
	if CastClient.casting:get() then
		feedback("You're still casting.", "dim")
		return
	end
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 or humanoid:GetAttribute("Status_silence") then
		return
	end
	local action = ActionRules.effective(ActionRules.read(character), workspace:GetServerTimeNow())
	if not ActionRules.allows(action, "cast") then
		feedback(if action == "staggered" then "You're knocked off your feet." else "You can't cast in the middle of that.", "dim")
		return
	end
	local charge: Charging = {
		slot = held.slot,
		key = held.key,
		started = os.clock(),
		castTime = stats.castTime,
		maxHold = Charge.maxHold(stats.castTime),
	}
	CastClient.charging:set(charge)
	animation:predict("charging", charge.maxHold, domainOf(held.key))
	magic:hold("begin")
	-- Held to the limit: release on its own (the server counts no further anyway).
	task.delay(charge.maxHold, function()
		if CastClient.charging:get() == charge then
			self:releaseCast()
		end
	end)
end

-- Release: a charge is cast at its stage; a held channel ends.
function CastClient.releaseCast(self: any)
	local charge = CastClient.charging:get()
	if charge then
		CastClient.charging:set(nil)
		local before = predicted
		self:cast(charge.slot, os.clock() - charge.started)
		if predicted == before then
			-- The cast stopped here (out of range, nothing aimed): end the server's charge too,
			-- or it would hold the pose and the slowed walk until it timed out.
			magic:hold("cancel")
			animation:predict("holding")
		end
	end
	if channelHeld then
		channelHeld = false
		magic:hold("release")
	end
	local release = CastClient.weapon.release
	if release and not CastClient.attuned:get() then
		release() -- a drawn bow looses (the weapon side ignores it when nothing is drawn)
	end
end

-- Drops a charge without casting (stowing, or the touch Stow button).
function CastClient.cancelCharge(_self: any)
	if not CastClient.charging:get() then
		return
	end
	CastClient.charging:set(nil)
	animation:predict(if CastClient.attuned:get() then "holding" else "idle")
	magic:hold("cancel")
end

-- ─── Spellblade (Combat.md §13) ─────────────────────────────────────────────

function CastClient.pressSlash(self: any)
	local held = CastClient.attuned:get()
	if not held then
		local press = CastClient.weapon.press
		if press and not CastClient.guarding:get() then
			press("melee") -- nothing readied: swing the weapon itself
		end
		return
	end
	if not equipMode() or CastClient.guarding:get() or CastClient.charging:get() then
		return
	end
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local action = ActionRules.effective(ActionRules.read(character), workspace:GetServerTimeNow())
	if not ActionRules.allows(action, "slash") then
		return
	end
	-- The server's last swing speed (weapon) for the timing; 1 before the first swing.
	local speedAttr = Players.LocalPlayer:GetAttribute("MeleeSpeed")
	local speed = if typeof(speedAttr) == "number" then speedAttr else 1
	local last = swingLast
	local index, wait = Melee.nextIndex(if last then last.index else nil, if last then os.clock() - last.started else 0, if last then last.speed else speed)
	if not index then
		-- Too early for the next swing: remember the press and send it when the window opens.
		if not swingBuffered then
			swingBuffered = true
			task.delay(wait + 0.04, function()
				swingBuffered = false
				self:pressSlash()
			end)
		end
		return
	end
	local swing = Melee.swing(index)
	swingLast = { index = index, started = os.clock(), speed = speed }
	animation:predict("slashing", swing.duration / speed, domainOf(held.key), swing.clip)
	magic:slash()
end

-- ─── Guard (Combat.md §12) ──────────────────────────────────────────────────

function CastClient.raiseGuard(_self: any)
	if CastClient.guarding:get() then
		return
	end
	-- A ward needs a readied spell; with nothing readied, a blocking weapon can guard instead.
	local held = CastClient.attuned:get()
	local canBlock = CastClient.weapon.canBlock
	local weaponGuard = not held and canBlock ~= nil and canBlock()
	if not weaponGuard and (not equipMode() or not held) then
		return
	end
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local action = ActionRules.effective(ActionRules.read(character), workspace:GetServerTimeNow())
	if not ActionRules.allows(action, "block") then
		return
	end
	local broken = character:GetAttribute("GuardBrokenUntil")
	if typeof(broken) == "number" and broken > workspace:GetServerTimeNow() then
		feedback("Your guard is broken.", "warn")
		return
	end
	if CastClient.charging:get() then
		CastClient.charging:set(nil) -- the server drops the charge when the guard goes up
	end
	CastClient.guarding:set(true)
	animation:predict("blocking", nil, if weaponGuard then nil else character:GetAttribute("AttunedDomain") :: string?)
	magic:guard("raise")
end

function CastClient.lowerGuard(_self: any)
	if not CastClient.guarding:get() then
		return
	end
	CastClient.guarding:set(false)
	animation:predict(if CastClient.attuned:get() then "holding" else "idle")
	magic:guard("lower")
end

-- ─── Attunement (equip mode) ────────────────────────────────────────────────

-- Asks the server; reverts the prediction if it says no (or a newer request superseded this one).
local function request(slot: number, previous: Attuned?)
	attuneRequest += 1
	local id = attuneRequest
	task.spawn(function()
		local ok, reason = magic:attune(slot)
		if id ~= attuneRequest or ok then
			return
		end
		CastClient.attuned:set(previous)
		animation:cancelPrediction()
		local text = ATTUNE_REASONS[reason or ""] or "You can't ready that now."
		if text ~= "" then
			feedback(text, "dim")
		end
	end)
end

function CastClient.attune(_self: any, slot: number)
	local key = magic.hotbar:get()[slot]
	if not key then
		interface:open("Composer")
		return
	end
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local action = ActionRules.effective(ActionRules.read(character), workspace:GetServerTimeNow())
	if not ActionRules.allows(action, "equip") then
		feedback(if action == "staggered" then "You're knocked off your feet." else "Finish what you're doing first.", "dim")
		return
	end
	local previous = CastClient.attuned:get()
	CastClient:cancelCharge()
	CastClient.attuned:set({ slot = slot, key = key })
	CastClient.selectedSlot:set(slot)
	animation:predict("equipping", nil, domainOf(key))
	request(slot, previous)
end

function CastClient.stow(self: any)
	local previous = CastClient.attuned:get()
	if not previous then
		return
	end
	self:cancelCharge()
	self:lowerGuard()
	CastClient.attuned:set(nil)
	animation:predict("idle")
	request(0, previous)
end

-- A hotbar key or slot tap: casts (quick mode) or attunes / swaps / stows (equip mode).
function CastClient.pressSlot(self: any, slot: number)
	if not equipMode() then
		self:cast(slot)
		return
	end
	local held = CastClient.attuned:get()
	if held and held.slot == slot then
		self:stow()
	else
		self:attune(slot)
	end
end

-- Left click / R2 / the touch Cast button.
function CastClient.castAttuned(self: any)
	self:pressCast()
end

-- The next filled slot after `from` in `step` direction (wrapping), or nil.
local function nextFilled(from: number, step: number): number?
	local hotbar = magic.hotbar:get()
	for i = 1, SLOT_COUNT do
		local slot = (from - 1 + step * i) % SLOT_COUNT + 1
		if hotbar[slot] then
			return slot
		end
	end
	return nil
end

-- While attuned: face the aim, crosshair cursor, the wheel swaps spells instead of zooming.
local function setStance(on: boolean)
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = not on
	end
	UserInputService.MouseIcon = if on then CROSSHAIR else ""
	if on then
		ContextActionService:BindActionAtPriority(SCROLL_ACTION, function(_, inputState, input)
			if inputState ~= Enum.UserInputState.Change or interface:isInputBlocked() then
				return Enum.ContextActionResult.Pass
			end
			local held = CastClient.attuned:get()
			local slot = held and nextFilled(held.slot, if input.Position.Z > 0 then -1 else 1)
			if slot and held and slot ~= held.slot then
				CastClient:attune(slot)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
	else
		ContextActionService:UnbindAction(SCROLL_ACTION)
	end
end

local function faceAim(dt: number)
	if not CastClient.attuned:get() then
		return
	end
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return
	end
	if humanoid.PlatformStand or humanoid.Sit or humanoid:GetAttribute("Status_knockdown") then
		return -- knocked down or seated: don't twist the body
	end
	local point = aimer:current() -- cached at 30 Hz: no extra ray per frame
	local flat = Vector3.new(point.X - root.Position.X, 0, point.Z - root.Position.Z)
	if flat.Magnitude < 0.5 then
		return
	end
	local goal = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	root.CFrame = root.CFrame:Lerp(goal, math.clamp(dt * TURN_RATE, 0, 1))
end

function CastClient.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	animation = ctx.get("AnimationController")
	aimer = ctx.get("AimController")
	magic.events:Connect(onEvent)
end

function CastClient.start(_self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or interface:isInputBlocked() then
			return
		end
		local slot = table.find(SLOT_KEYS, input.KeyCode)
		local selected = CastClient.selectedSlot:get()
		if slot then
			CastClient:pressSlot(slot)
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Quick mode never readies a spell, so there left click only ever swings a weapon.
			if equipMode() or not CastClient.attuned:get() then
				CastClient:pressCast()
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR1 then
			local press = CastClient.weapon.press
			if press and not CastClient.attuned:get() then
				press("primary")
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL1 then
			CastClient:raiseGuard()
		elseif Controls.matches("slash", input) then
			CastClient:pressSlash()
		elseif Controls.matches("stow", input) then
			CastClient:stow()
		elseif input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.DPadRight then
			local nextSlot = if input.KeyCode == Enum.KeyCode.DPadLeft then (selected - 2) % SLOT_COUNT + 1 else selected % SLOT_COUNT + 1
			CastClient.selectedSlot:set(nextSlot)
			if CastClient.attuned:get() and magic.hotbar:get()[nextSlot] then
				CastClient:attune(nextSlot) -- swap while attuned
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
			if equipMode() then
				CastClient:pressSlot(selected)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			if not equipMode() then
				CastClient:cast(selected)
			elseif CastClient.attuned:get() then
				CastClient:pressCast()
			else
				CastClient:attune(selected)
			end
		end
	end)

	-- Releases: the mouse button / R2 ends a charge or a held channel; in quick mode the slot key
	-- ends a held channel. Not gated on `processed`: a release must never get stuck.
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.KeyCode == Enum.KeyCode.ButtonR2
			or input.KeyCode == Enum.KeyCode.ButtonR1
			or table.find(SLOT_KEYS, input.KeyCode)
		then
			CastClient:releaseCast()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL1 then
			CastClient:lowerGuard()
		end
	end)

	-- The server ended our guard (broken, staggered): stop thinking we're guarding.
	animation.stateChanged:Connect(function(state: string, previous: string)
		if previous == "blocking" and state ~= "blocking" and CastClient.guarding:get() then
			local character = Players.LocalPlayer.Character
			if character and character:GetAttribute("Guarding") == nil then
				CastClient.guarding:set(false)
			end
		end
	end)

	-- A held channel steers toward the aim.
	local aimElapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		if not channelHeld then
			return
		end
		aimElapsed += dt
		if aimElapsed >= 1 / CHANNEL_AIM_HZ then
			aimElapsed = 0
			magic:channelAim((aimer:current()))
		end
	end)

	-- Stance on/off follows the attuned value; a new body (respawn) holds nothing.
	CastClient.attuned:observe(function(held)
		setStance(held ~= nil)
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		attuneRequest += 1 -- ignore answers about the old body
		CastClient.attuned:set(nil)
		CastClient.charging:set(nil)
		CastClient.guarding:set(false)
		channelHeld = false
		swingLast = nil
		setStance(false)
	end)
	-- Switching to Quick while holding a spell puts it away.
	magic.settings:observe(function(settings)
		if settings.castMode == "quick" and CastClient.attuned:get() then
			CastClient:stow()
		end
	end)
	RunService.RenderStepped:Connect(faceAim)
end

return CastClient
