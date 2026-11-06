--!strict
--[[
	HudController: the always-on layer.

		Reservoir     bar (current / max), overdraw depth, strain, burnout and domain lockouts,
		              low-reservoir warning (text + pulse; no pulse with reduced motion)
		Region        biome / settlement, ambient density (word + pips), resonance for your domains
		Hotbar        8 slots (keyboard 1-8; gamepad D-pad selects, R2 casts; touch: 2 pages of 4)
		              per slot: domain badge, name, estimated cost, cooldown sweep, ! when the cast
		              would overdraw, × when its domain is locked out; the attuned slot (equip mode)
		              is outlined with a ✋. Touch with a spell attuned: Cast (press and hold to
		              charge, lift to cast) and Stow buttons.
		Spellblade    touch: a Slash button beside Cast and Block (keyboard F, gamepad B)
		Guard         a thin ⛨ meter under the cast bar while guarding or while it refills (the
		              word "Broken" when it shattered); touch: a Block button (press and hold)
		Charge        while charging (hold to cast), the cast bar fills over the whole hold with a
		              tick per stage and the stage named above it (· Quick, ◆ Charged, ◆◆ Full,
		              ⚠ Overcharged)
		Cast feedback refusals and backlash in words; consequences named by the domain's risk
		Statuses      chips above the reservoir: ▼ harmful / ▲ helpful, name, seconds left, drain bar
		Mastery       the branch that changed most recently: tier and progress to the next one
		Toasts        tier-ups, unlocks, discoveries, oaths, server notices
		Awakening     a full-screen moment when a domain awakens (the core onboarding beat)

	Server-authoritative: casting input, aim and prediction live in CastClient; the HUD only draws
	the hotbar, the cast bar (CastClient.casting) and feedback. Cooldowns, costs and affordability
	shown here are estimates; the server decides.

	Layout (docs/UI.md §7): Wide puts the hotbar bottom-centre; Compact (phones) puts a 2x2 hotbar
	left of the jump button, the reservoir at the top, and hides the mastery tracker.
]]

local RunService = game:GetService("RunService")

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Charge = require(Shared.Magic.Charge)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

type Scope = Kit.Scope

local SLOT_COUNT = 8
local SLOT_SIZE = 64
local TOAST_SECONDS = 5
local FEEDBACK_SECONDS = 2.5
local LOW_RESERVOIR = 0.2 -- share of max that triggers the low warning
local OVERDRAW_LIMIT = Registry.Tuning.Reservoir.overdrawLimit


-- Refusal codes from CastResult, in the player's words. Unknown codes fall back to a generic line.
local REASONS: { [string]: string } = {
	INSUFFICIENT_RESERVOIR = "Your reservoir can't pay for that, even by overdrawing.",
	BURNED_OUT = "Burned out: you can't overdraw until your channels recover.",
	DOMAIN_LOCKED = "That domain is locked out after your last backlash.",
	ON_COOLDOWN = "Not ready yet.",
	OUT_OF_RANGE = "Too far away.",
	NO_LINE_OF_SIGHT = "You can't see the target.",
	NO_TARGET = "This spell needs a target.",
	ENVIRONMENT_BLOCKED = "The world here can't support that spell.",
	CASTING_DISABLED = "Magic is stilled on this server.",
	NOT_LOADED = "Still gathering yourself...",
	BUSY = "You're still casting.",
	DEAD = "You can't cast now.",
	NOTHING_STORED = "You have no stored charge of that to release.",
	WORLD_STRAINED = "The world is already straining under great magic. Wait a moment.",
	TOO_WEAK = "Paying that with your life would kill you.",
	BRANCH_LOCKED = "You haven't learned that branch.",
	POWER_OVER_CAP = "That's more power than you can reach yet.",
	SILENCED = "You can't speak a working while silenced.",
	STAGGERED = "You're knocked off your feet.",
	NOT_ATTUNED = "Ready that spell first (its hotbar key), then click to cast.",
	GUARD_BROKEN = "Your guard is broken. Give it a moment.",
	GUARD_SPENT = "Your guard is spent. Let it recover.",
	ACTION_LOCKED = "You can't cast in the middle of that.",
	BAD_AIM = "You can't aim there.",
}

local DENSITY_WORDS = {
	{ max = 0.25, word = "Dead zone" },
	{ max = 0.75, word = "Thin" },
	{ max = 1.5, word = "Steady" },
	{ max = 2.25, word = "Rich" },
	{ max = math.huge, word = "Nexus" },
}

local HudController = {
	name = "HudController",
	dependencies = { "InterfaceController", "MagicStateController", "CastClient", "WeaponClient", "MovementClient" },
}

type Toast = { id: number, text: string, color: Color3, at: number }

type SlotWidget = {
	key: string?,
	frame: GuiObject,
	cooldown: Frame,
	cooldownText: TextLabel,
	marker: TextLabel,
	cost: number,
	total: number,
	domains: { string },
}

local interface: any = nil
local magic: any = nil
local castClient: any = nil
local movement: any = nil -- MovementClient (touch Dash / Run)
local weaponClient: any = nil

-- State that survives HUD rebuilds.
local toasts = Kit.value({} :: { Toast })
local feedback = Kit.value(nil :: { text: string, color: Color3 }?)
local awakening = Kit.value(nil :: string?)
local page = Kit.value(0) -- compact hotbar page: 0 = slots 1-4, 1 = slots 5-8
local nextToastId = 0
local widgets: { [number]: SlotWidget } = {}
local wasLow = false

local riskNames: { [string]: string } = {}
for _, domain in Registry.domains do
	riskNames[domain.risk.id] = domain.risk.name
end

local function now(): number
	return workspace:GetServerTimeNow()
end

-- ─── Toasts and feedback ────────────────────────────────────────────────────

local function toast(text: string, color: Color3?)
	nextToastId += 1
	local id = nextToastId
	local list = table.clone(toasts:get())
	table.insert(list, 1, { id = id, text = text, color = color or Theme.color.accent, at = os.clock() })
	while #list > 4 do
		table.remove(list)
	end
	toasts:set(list)
	task.delay(TOAST_SECONDS, function()
		local current = toasts:get()
		for i, t in current do
			if t.id == id then
				local trimmed = table.clone(current)
				table.remove(trimmed, i)
				toasts:set(trimmed)
				break
			end
		end
	end)
end

local feedbackId = 0
local function showFeedback(text: string, color: Color3?)
	feedbackId += 1
	local id = feedbackId
	feedback:set({ text = text, color = color or Theme.color.ink })
	task.delay(FEEDBACK_SECONDS, function()
		if feedbackId == id then
			feedback:set(nil)
		end
	end)
end

local function branchName(branchId: string): string
	local branch = Registry.branches[branchId]
	return if branch then branch.name else branchId
end

-- "1|energy|luminosity|generate|touch|1|reservoir|" -> readable description (see MagicCore.recipeKey).
local function describeKey(key: string): string
	local parts = string.split(key, "|")
	if #parts < 7 then
		return "a new spell"
	end
	return MagicCore.describe({
		v = tonumber(parts[1]) or 1,
		branch = parts[2],
		property = parts[3],
		verb = parts[4],
		form = parts[5],
		power = tonumber(parts[6]) or 1,
		costProfile = parts[7],
		modifiers = if parts[8] and parts[8] ~= "" then string.split(parts[8], ",") else {},
	})
end

local function onEvent(event: any)
	local kind = event.kind
	if kind == "tier" then
		C.sound("tierUp")
		toast(string.format("%s: %s", branchName(event.branch), tostring(event.name)), Theme.branchColor(event.branch))
	elseif kind == "held" then
		toast(branchName(event.branch) .. ": your growth is held. A breakthrough awaits.", Theme.color.warn)
	elseif kind == "unlock" then
		local branch = Registry.branches[event.branch]
		if branch and branch.isRoot then
			awakening:set(branch.domains[1])
		else
			C.sound("discovery")
			toast("New branch opened: " .. branchName(event.branch), Theme.branchColor(event.branch))
		end
	elseif kind == "breakthrough" then
		C.sound("breakthrough")
		toast("Breakthrough in " .. branchName(event.branch) .. "!", Theme.branchColor(event.branch))
	elseif kind == "discovery" then
		C.sound("discovery")
		toast("Discovered: " .. describeKey(event.key))
	elseif kind == "first" then
		-- One toast and one stinger, however many firsts one moment held (DiscoveryLog merges them).
		local parts: { string } = {}
		if event.damage then
			table.insert(parts, "a blow that lands")
		end
		local verb = Registry.verbs[event.verb]
		if verb then
			table.insert(parts, verb.name)
		end
		local form = Registry.forms[event.form]
		if form then
			table.insert(parts, form.name)
		end
		if #parts > 0 then
			C.sound("first")
			toast("First time: " .. table.concat(parts, " · "), Theme.color.accent)
		end
	elseif kind == "novelty" then
		toast("Something new: " .. describeKey(event.key))
	elseif kind == "reaction" then
		C.sound("discovery")
		toast("You discovered: " .. tostring(event.text), Theme.color.accent)
	elseif kind == "worldFirst" then
		C.sound("discovery")
		toast("World first! No one has cast this before you.", Theme.color.accent)
	elseif kind == "signature" then
		toast("Signature spell declared: " .. tostring(event.name))
	elseif kind == "commitment" or kind == "renounced" then
		local spec = Registry.specializations[event.id]
		toast((if kind == "commitment" then "Oath sworn: " else "Oath renounced: ") .. (if spec then spec.name else tostring(event.id)))
	elseif kind == "notify" then
		toast(event.text, Theme.color.inkDim)
	elseif kind == "saved" then
		toast("Saved: " .. tostring(event.name))
	elseif kind == "castFeedback" then
		if event.tone == "warn" then
			C.sound("deny")
		end
		showFeedback(event.text, if event.tone == "warn" then Theme.color.warn else Theme.color.inkDim)
	elseif kind == "cast" then
		local result = event.result
		if not result.ok then
			C.sound("castFail")
			showFeedback(REASONS[result.reason or ""] or ("The spell fails (" .. tostring(result.reason) .. ")."), Theme.color.warn)
			return
		end
		if result.riskNote then
			toast(result.riskNote, Theme.color.danger)
		end
		for _, consequence in (result.consequences or {}) :: { any } do
			local risk = riskNames[consequence.riskId] or "Backlash"
			if consequence.kind == "Backlash" then
				C.sound("backlash")
				showFeedback(string.format("✗ Backlash: %s  (-%d HP)", risk, math.floor(consequence.amount + 0.5)), Theme.color.danger)
			elseif consequence.kind == "Burnout" then
				toast(string.format("Burnout: %s. No regeneration for %ds.", risk, math.ceil(consequence.duration)), Theme.color.danger)
			elseif consequence.kind == "Lockout" then
				local domain = Registry.domains[consequence.domain or ""]
				toast(string.format("%s locked out for %ds.", if domain then domain.name else "A domain", math.ceil(consequence.duration)), Theme.color.danger)
			elseif consequence.kind == "Mutation" then
				toast("Something in you has changed...", Theme.color.danger)
			end
		end
		if result.interrupted then
			showFeedback("Your casting was broken.", Theme.color.inkDim)
		elseif result.backfired then
			showFeedback("! The spell twisted out of your control." .. (if result.note then " " .. result.note else ""), Theme.color.warn)
		elseif result.note then
			showFeedback(result.note, Theme.color.ink)
		end
	end
end

-- ─── Builders ───────────────────────────────────────────────────────────────

local function chip(text: string, color: Color3): TextLabel
	local label = C.text(text, "caption", {
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = Theme.glass,
		BackgroundColor3 = Theme.color.bg,
		TextColor3 = color,
		FontFace = Theme.font.bold,
		TextWrapped = false,
	})
	C.corner(Theme.radius.s).Parent = label
	C.padding(3, 8).Parent = label
	return label
end

--[[
	Status bar: one chip per active status, above the reservoir. ▼ + warm colour for harmful, ▲ +
	cool colour for helpful; the name, the seconds left, and a thin bar that drains. The set is
	re-rendered when statuses change (MagicStateController.statuses); the countdown ticks at 4 Hz
	without re-rendering.
]]
local function buildStatuses(scope: Scope, cluster: Frame, compact: boolean)
	local row: Frame = Kit.create(nil, "Frame", {
		Name = "Statuses",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 0,
		Parent = cluster,
	})
	C.list("x", Theme.space.xs, { Wraps = true, HorizontalAlignment = Enum.HorizontalAlignment.Center }).Parent = row

	Kit.dynamic(scope, { magic.statuses }, function(s)
		type Live = { expires: number, total: number, time: TextLabel, fill: Frame }
		local live: { Live } = {}
		local serverNow = workspace:GetServerTimeNow()
		for index, status in magic.statuses:get() do
			local info = StatusInfo[status.id]
			local harmful = if info then info.harmful else true
			local color = if harmful then Theme.color.warn else Theme.color.good
			local remaining = math.max(0, status.expires - serverNow)
			local chipFrame = C.panel({
				Name = status.id,
				BackgroundTransparency = Theme.glass,
				BackgroundColor3 = Theme.color.bg,
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				LayoutOrder = index,
				Parent = row,
			})
			s:add(chipFrame)
			C.stroke(color, 1, 0.3).Parent = chipFrame
			C.padding(3, 7).Parent = chipFrame
			C.list("y", 2).Parent = chipFrame
			local top: Frame = Kit.create(nil, "Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				LayoutOrder = 1,
				Parent = chipFrame,
			})
			C.list("x", 4, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = top
			local label = (if harmful then "▼ " else "▲ ") .. (if info then info.name else status.id)
			C.text(label, "caption", {
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				TextColor3 = color,
				FontFace = Theme.font.bold,
				TextWrapped = false,
				LayoutOrder = 1,
				Parent = top,
			})
			local time = C.text(string.format("%ds", math.ceil(remaining)), "caption", {
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				TextColor3 = Theme.color.inkDim,
				FontFace = Theme.font.mono,
				TextWrapped = false,
				Visible = not compact,
				LayoutOrder = 2,
				Parent = top,
			})
			local track: Frame = Kit.create(nil, "Frame", {
				BackgroundColor3 = Theme.color.line,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 2),
				LayoutOrder = 2,
				Parent = chipFrame,
			})
			local fill: Frame = Kit.create(nil, "Frame", {
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(1, 1),
				Parent = track,
			})
			-- The bar drains over what was left when the status was (re)applied or first seen.
			table.insert(live, { expires = status.expires, total = math.max(0.5, remaining), time = time, fill = fill })
		end
		if #live == 0 then
			return
		end
		local acc = 0
		s:add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.25 then
				return
			end
			acc = 0
			local t = workspace:GetServerTimeNow()
			for _, entry in live do
				local left = math.max(0, entry.expires - t)
				entry.time.Text = string.format("%ds", math.ceil(left))
				entry.fill.Size = UDim2.fromScale(math.clamp(left / entry.total, 0, 1), 1)
			end
		end))
	end)
end

local function buildReservoir(scope: Scope, root: Frame, compact: boolean)
	local width = if compact then 300 else SLOT_COUNT * SLOT_SIZE + (SLOT_COUNT - 1) * Theme.space.s
	local cluster: Frame = Kit.create(nil, "Frame", {
		Name = "Reservoir",
		BackgroundTransparency = 1,
		AnchorPoint = if compact then Vector2.new(0.5, 0) else Vector2.new(0.5, 1),
		Position = if compact then UDim2.new(0.5, 0, 0, Theme.space.s) else UDim2.new(0.5, 0, 1, -(SLOT_SIZE + Theme.space.xl)),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.xs).Parent = cluster
	buildStatuses(scope, cluster, compact)

	local status: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = cluster,
	})
	C.list("x", Theme.space.xs, { Wraps = true, HorizontalAlignment = Enum.HorizontalAlignment.Center }).Parent = status

	local strainFill = Kit.value(0)
	local strainBar = C.bar(scope, strainFill, Theme.color.strain, 4)
	strainBar.LayoutOrder = 2
	strainBar.Parent = cluster

	local mainFill = Kit.value(1)
	local mainBar = C.bar(scope, mainFill, Theme.color.reservoir, if compact then 10 else 14)
	mainBar.LayoutOrder = 3
	mainBar.Parent = cluster
	local mainStroke = mainBar:FindFirstChildOfClass("UIStroke") :: UIStroke

	local overdrawFill = Kit.value(0)
	local overdrawBar = C.bar(scope, overdrawFill, Theme.color.danger, 6)
	overdrawBar.LayoutOrder = 4
	overdrawBar.Parent = cluster

	local label = C.text("", "caption", {
		LayoutOrder = 5,
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = Theme.font.mono,
		Parent = cluster,
	})

	local statusSignature = ""
	local function update()
		local r = magic.reservoir:get()
		cluster.Visible = r ~= nil
		if not r or r.max <= 0 then
			return
		end
		local t = now()
		local share = r.current / r.max
		mainFill:set(share)
		strainFill:set(r.strain / 100)
		strainBar.Visible = r.strain > 0
		overdrawBar.Visible = r.current < 0
		overdrawFill:set(-r.current / (OVERDRAW_LIMIT * r.max))

		local low = share < LOW_RESERVOIR
		if low and not wasLow then
			C.sound("lowReservoir")
		end
		wasLow = low
		mainStroke.Color = if low then Theme.color.warn else Theme.color.line
		mainStroke.Thickness = if low and not Theme.settings.reducedMotion then 1 + (math.sin(os.clock() * 6) + 1) else (if low then 2 else 1)

		local text = string.format("Reservoir %d / %d", r.current, r.max)
		if r.current < 0 then
			text ..= "   OVERDRAWN"
		elseif low then
			text ..= "   ! low"
		end
		if r.strain > 0 then
			text ..= string.format("   strain %d", r.strain)
		end
		label.Text = text
		label.TextColor3 = if r.current < 0 then Theme.color.danger elseif low then Theme.color.warn else Theme.color.inkDim

		-- Status chips only rebuild when their visible text would change (about once a second at most).
		local parts: { string } = { tostring(math.max(0, math.ceil(r.burnoutUntil - t))) }
		for domainId, untilTime in r.lockouts do
			table.insert(parts, domainId .. math.max(0, math.ceil(untilTime - t)))
		end
		table.sort(parts)
		local signature = table.concat(parts, ",")
		if signature == statusSignature then
			return
		end
		statusSignature = signature
		for _, child in status:GetChildren() do
			if child:IsA("TextLabel") or (child:IsA("Frame") and child.Name == "Lock") then
				child:Destroy()
			end
		end
		if r.burnoutUntil > t then
			chip(string.format("✗ BURNOUT %ds: no regen, no overdraw", math.ceil(r.burnoutUntil - t)), Theme.color.danger).Parent = status
		end
		for domainId, untilTime in r.lockouts do
			if untilTime > t then
				local lock: Frame = Kit.create(nil, "Frame", {
					Name = "Lock",
					BackgroundTransparency = 1,
					AutomaticSize = Enum.AutomaticSize.XY,
					Size = UDim2.fromOffset(0, 0),
					Parent = status,
				})
				C.list("x", 4, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = lock
				C.badge(domainId, 22).Parent = lock
				chip(string.format("× %ds", math.ceil(untilTime - t)), Theme.color.danger).Parent = lock
			end
		end
	end

	scope:add(magic.reservoir:observe(update))

	-- Stamina (StaminaService: Player attributes Stamina / StaminaMax). Shown only while it isn't
	-- full, so it stays out of the way until you fight; the word and number carry it, not colour.
	local staminaFill = Kit.value(1)
	local staminaBar = C.bar(scope, staminaFill, Theme.color.good, if compact then 5 else 6)
	staminaBar.LayoutOrder = 6
	staminaBar.Visible = false
	staminaBar.Parent = cluster
	local staminaLabel = C.text("", "caption", {
		LayoutOrder = 7,
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = Theme.font.mono,
		Visible = false,
		Parent = cluster,
	})
	local function updateStamina()
		local player = Players.LocalPlayer
		local current, max = player:GetAttribute("Stamina"), player:GetAttribute("StaminaMax")
		if typeof(current) ~= "number" or typeof(max) ~= "number" or max <= 0 then
			return
		end
		local show = current < max
		staminaBar.Visible = show
		staminaLabel.Visible = show
		staminaFill:set(current / max)
		local low = current < max * 0.2
		staminaLabel.Text = string.format("Stamina %d / %d%s", current, max, if low then "   ! winded" else "")
		staminaLabel.TextColor3 = if low then Theme.color.warn else Theme.color.inkDim
	end
	scope:add(Players.LocalPlayer:GetAttributeChangedSignal("Stamina"):Connect(updateStamina))
	scope:add(Players.LocalPlayer:GetAttributeChangedSignal("StaminaMax"):Connect(updateStamina))
	updateStamina()

	-- Dash charges (MovementService: Player attributes DashCharges / DashMax). Like stamina, shown
	-- only while one is spent: ◆ ready, ◇ refilling, plus the word.
	local dashLabel = C.text("", "caption", {
		LayoutOrder = 8,
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = Theme.font.mono,
		Visible = false,
		Parent = cluster,
	})
	local function updateDash()
		local player = Players.LocalPlayer
		local charges, max = player:GetAttribute("DashCharges"), player:GetAttribute("DashMax")
		if typeof(charges) ~= "number" or typeof(max) ~= "number" or max <= 0 then
			return
		end
		dashLabel.Visible = charges < max
		dashLabel.Text = "Dash " .. string.rep("◆", charges) .. string.rep("◇", max - charges)
		dashLabel.TextColor3 = if charges == 0 then Theme.color.warn else Theme.color.inkDim
	end
	scope:add(Players.LocalPlayer:GetAttributeChangedSignal("DashCharges"):Connect(updateDash))
	scope:add(Players.LocalPlayer:GetAttributeChangedSignal("DashMax"):Connect(updateDash))
	updateDash()

	-- Countdown chips and the low pulse need time to pass, not just new snapshots.
	local elapsed = 0
	scope:add(RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= 0.25 then
			elapsed = 0
			update()
		end
	end))
	update()
end

local function buildRegion(scope: Scope, root: Frame, compact: boolean)
	local box = C.panel({
		Name = "Region",
		BackgroundTransparency = Theme.glass,
		Position = UDim2.fromOffset(Theme.space.m, Theme.space.m),
		Size = UDim2.fromOffset(if compact then 200 else 260, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.padding(Theme.space.s).Parent = box
	C.list("y", 2).Parent = box

	Kit.dynamic(scope, { magic.region, magic.known }, function(s)
		local region = magic.region:get()
		box.Visible = region ~= nil
		if not region then
			return
		end
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = box,
		})
		s:add(holder)
		C.list("y", 2).Parent = holder

		C.text(if region.settlement then string.format("%s · %s", region.settlement, region.biomeName) else region.biomeName, "label", { LayoutOrder = 1 }).Parent = holder

		local word = DENSITY_WORDS[#DENSITY_WORDS].word
		for _, band in DENSITY_WORDS do
			if region.density <= band.max then
				word = band.word
				break
			end
		end
		local pips = math.clamp(math.floor(region.density + 0.5), 0, 3)
		C.text(string.format("Ambient: %s  %s%s", word, string.rep("●", pips), string.rep("○", 3 - pips)), "caption", { LayoutOrder = 2 }).Parent = holder

		-- Resonance for the domains you have: ▲ stronger here, ▼ weaker.
		local known = magic.known:get()
		if known and not compact then
			local row: Frame = Kit.create(nil, "Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 3,
				Parent = holder,
			})
			C.list("x", Theme.space.xs, { Wraps = true, VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = row
			for domainId in known.caster.awakened do
				local bias = region.resonance[domainId] or 1
				if bias >= 1.15 or bias <= 0.9 then
					C.badge(domainId, 20).Parent = row
					chip(if bias > 1 then "▲" else "▼", if bias > 1 then Theme.color.good else Theme.color.warn).Parent = row
				end
			end
		end
	end)
end

local function buildTracker(scope: Scope, root: Frame)
	local box = C.panel({
		Name = "Mastery",
		BackgroundTransparency = Theme.glass,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Theme.space.m, 0, Theme.space.m),
		Size = UDim2.fromOffset(280, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.padding(Theme.space.s).Parent = box

	Kit.dynamic(scope, { magic.progression, magic.focusBranch }, function(s)
		local progression = magic.progression:get()
		box.Visible = progression ~= nil and #progression.branches > 0
		if not progression or #progression.branches == 0 then
			return
		end
		local view = magic:branchView(magic.focusBranch:get() or "") or progression.branches[1]
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = box,
		})
		s:add(holder)
		C.list("y", 4).Parent = holder

		C.text(view.name, "label", { LayoutOrder = 1, TextColor3 = Theme.branchColor(view.id) }).Parent = holder
		local fraction = 1
		if view.xpForNext then
			local start = MasteryTiers.xpScale * MagicCore.tierDef(view.tier).minMastery ^ MasteryTiers.xpExponent
			fraction = (view.xp - start) / math.max(1, view.xpForNext - start)
		end
		local bar = C.bar(nil, fraction, Theme.branchColor(view.id), 8)
		bar.LayoutOrder = 2
		bar.Parent = holder
		local nextTier = MagicCore.tierDef(view.tier + 1)
		local status = if view.held
			then "! Held: a breakthrough is needed"
			elseif view.xpForNext then string.format("%s · next: %s", view.tierName, nextTier.name)
			else view.tierName
		C.text(status, "caption", { LayoutOrder = 3, TextColor3 = if view.held then Theme.color.warn else Theme.color.inkDim }).Parent = holder
	end)
end

local function buildSlot(index: number, slot: number, size: number): SlotWidget
	local key = magic.hotbar:get()[slot]
	local spell = key and magic:spell(key)
	local gamepad = interface.inputMode:get() == "Gamepad"
	local held = castClient.attuned:get()
	local attuned = held ~= nil and held.slot == slot
	local selected = attuned or (gamepad and castClient.selectedSlot:get() == slot)

	local button = C.button("", function()
		castClient:pressSlot(slot)
	end, { kind = "ghost", selected = selected, sound = "confirm" }, {
		Name = "Slot" .. slot,
		Size = UDim2.fromOffset(size, size),
		LayoutOrder = index,
		BackgroundTransparency = Theme.glass,
	})
	-- Right-click opens the spell in the Composer for editing.
	button.MouseButton2Click:Connect(function()
		interface:open("Composer", if spell then { recipe = spell.recipe, key = spell.key } else nil)
	end)

	local widget: SlotWidget = {
		key = key,
		frame = button,
		cooldown = nil :: any,
		cooldownText = nil :: any,
		marker = nil :: any,
		cost = 0,
		total = 0,
		domains = {},
	}

	if spell then
		local branch = Registry.branches[spell.recipe.branch]
		widget.domains = if branch then branch.domains else {}
		local badge = C.badge(widget.domains[1] or "energy", math.floor(size * 0.45))
		badge.AnchorPoint = Vector2.new(0.5, 0)
		badge.Position = UDim2.new(0.5, 0, 0, 4)
		badge.Parent = button
		C.text(spell.name, "caption", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -2),
			Size = UDim2.new(1, -4, 0, 14),
			AutomaticSize = Enum.AutomaticSize.None,
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = Theme.color.ink,
			Parent = button,
		})
		local stats = magic:preview(spell.recipe)
		if stats then
			widget.cost = stats.costBreakdown.reservoir
			widget.total = stats.cooldown
		end
	else
		C.text("+", "heading", {
			Size = UDim2.fromScale(1, 1),
			AutomaticSize = Enum.AutomaticSize.None,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			TextColor3 = Theme.color.inkFaint,
			Parent = button,
		})
	end

	-- The attuned slot: an accent outline (selected) and a hand glyph, so colour isn't the only cue.
	if attuned then
		C.text("✋", "label", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 3, 1, -16),
			Size = UDim2.fromOffset(16, 16),
			AutomaticSize = Enum.AutomaticSize.None,
			TextColor3 = Theme.color.accent,
			ZIndex = 6,
			Parent = button,
		})
	end

	if interface.inputMode:get() == "Keyboard" and castClient.SLOT_KEYS[slot] then
		local hint = C.keyHint(interface:keyName(castClient.SLOT_KEYS[slot]))
		if hint then
			hint.Position = UDim2.fromOffset(2, 2)
			hint.ZIndex = 3
			hint.Parent = button
		end
	end

	widget.cooldown = Kit.create(nil, "Frame", {
		Name = "Cooldown",
		BackgroundColor3 = Theme.color.backdrop,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		ZIndex = 4,
		Parent = button,
	})
	widget.cooldownText = C.text("", "label", {
		Size = UDim2.fromScale(1, 1),
		AutomaticSize = Enum.AutomaticSize.None,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		FontFace = Theme.font.mono,
		ZIndex = 5,
		Parent = button,
	})
	widget.marker = C.text("", "label", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -3, 0, 1),
		Size = UDim2.fromOffset(16, 16),
		AutomaticSize = Enum.AutomaticSize.None,
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Theme.font.bold,
		ZIndex = 6,
		Parent = button,
	})
	return widget
end

-- Cooldown sweeps, overdraw (!) and lockout (×) markers. ~15 Hz is smooth enough for a sweep.
local function updateSlots()
	local t = now()
	local cooldowns = magic.cooldowns:get()
	local r = magic.reservoir:get()
	for _, widget in widgets do
		local key = widget.key
		if not key then
			continue
		end
		local remaining = math.max(0, (cooldowns[key] or 0) - t)
		local total = math.max(widget.total, remaining, 0.001)
		widget.cooldown.Size = UDim2.fromScale(1, remaining / total)
		widget.cooldownText.Text = if remaining <= 0 then "" elseif remaining < 10 then string.format("%.1f", remaining) else tostring(math.ceil(remaining))

		local locked = false
		if r then
			for _, d in widget.domains do
				if (r.lockouts[d] or 0) > t then
					locked = true
				end
			end
		end
		if locked then
			widget.marker.Text = "×"
			widget.marker.TextColor3 = Theme.color.danger
		elseif r and widget.cost > r.current then
			widget.marker.Text = "!"
			widget.marker.TextColor3 = Theme.color.warn
		else
			widget.marker.Text = ""
		end
	end
end

local function buildHotbar(scope: Scope, root: Frame, compact: boolean)
	local bar: Frame = Kit.create(nil, "Frame", {
		Name = "Hotbar",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		AnchorPoint = Vector2.new(if compact then 1 else 0.5, 1),
		-- Compact: left of the touch jump button, in thumb reach.
		Position = if compact then UDim2.new(1, -150, 1, -Theme.space.l) else UDim2.new(0.5, 0, 1, -Theme.space.m),
		Parent = root,
	})

	Kit.dynamic(scope, { magic.hotbar, magic.spellbook, magic.known, magic.region, castClient.selectedSlot, castClient.attuned, page, movement.wantsRun }, function(s)
		table.clear(widgets)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			Parent = bar,
		})
		s:add(holder)
		if compact then
			local grid = C.grid(SLOT_SIZE, SLOT_SIZE, Theme.space.s)
			grid.FillDirectionMaxCells = 2
			grid.Parent = holder
			for i = 1, 4 do
				local slot = page:get() * 4 + i
				local widget = buildSlot(i, slot, SLOT_SIZE)
				widget.frame.Parent = holder
				widgets[slot] = widget
			end
			local pager = C.button(if page:get() == 0 then "5-8 ›" else "‹ 1-4", function()
				page:set(1 - page:get())
			end, { kind = "ghost" }, {
				Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
				LayoutOrder = 99,
			})
			pager.Parent = holder
			-- Touch: Dash and the Run toggle, always (MovementClient).
			C.button("Dash", function()
				movement:dash()
			end, { kind = "secondary" }, {
				Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
				LayoutOrder = 99.2,
			}).Parent = holder
			C.button(if movement.wantsRun:get() then "Walk" else "Run", function()
				movement:toggleRun()
			end, { kind = "ghost", selected = movement.wantsRun:get() }, {
				Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
				LayoutOrder = 99.4,
			}).Parent = holder
			-- Touch, equip mode: with a spell attuned, Cast (at the screen centre) and Stow.
			if castClient.attuned:get() then
				-- Press and hold to charge (or to keep a channel going); lift to cast.
				local castButton = C.button("Cast", function() end, { kind = "primary" }, {
					Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
					LayoutOrder = 100,
				})
				castButton.MouseButton1Down:Connect(function()
					castClient:pressCast()
				end)
				castButton.MouseButton1Up:Connect(function()
					castClient:releaseCast()
				end)
				castButton.MouseLeave:Connect(function()
					castClient:releaseCast() -- a thumb sliding off still releases
				end)
				castButton.Parent = holder
				local blockButton = C.button("Block", function() end, { kind = "secondary" }, {
					Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
					LayoutOrder = 100.5,
				})
				blockButton.MouseButton1Down:Connect(function()
					castClient:raiseGuard()
				end)
				blockButton.MouseButton1Up:Connect(function()
					castClient:lowerGuard()
				end)
				blockButton.MouseLeave:Connect(function()
					castClient:lowerGuard()
				end)
				blockButton.Parent = holder
				C.button("Slash", function()
					castClient:pressSlash()
				end, { kind = "secondary" }, {
					Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
					LayoutOrder = 100.7,
				}).Parent = holder
				C.button("Stow", function()
					castClient:stow()
				end, { kind = "ghost" }, {
					Size = UDim2.fromOffset(SLOT_SIZE, Theme.minTouch),
					LayoutOrder = 101,
				}).Parent = holder
			end
		else
			C.list("x", Theme.space.s).Parent = holder
			for slot = 1, SLOT_COUNT do
				local widget = buildSlot(slot, slot, SLOT_SIZE)
				widget.frame.Parent = holder
				widgets[slot] = widget
			end
		end
		updateSlots()
	end)

	local elapsed = 0
	scope:add(RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= 1 / 15 then
			elapsed = 0
			updateSlots()
		end
	end))
	scope:add(function()
		table.clear(widgets)
	end)
end

local function buildMenu(_scope: Scope, root: Frame, compact: boolean)
	local menu: Frame = Kit.create(nil, "Frame", {
		Name = "Menu",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		AnchorPoint = if compact then Vector2.new(1, 0) else Vector2.new(0, 1),
		Position = if compact then UDim2.new(1, -Theme.space.s, 0, Theme.space.s) else UDim2.new(0, Theme.space.m, 1, -Theme.space.m),
		Parent = root,
	})
	C.list(if compact then "x" else "y", Theme.space.s).Parent = menu

	for index, entry in { { "Grimoire", "Grimoire" }, { "Composer", "Composer" }, { "Inventory", "Inventory" }, { "Controls", "Controls" }, { "Settings", "⚙" } } do
		local id, label = entry[1], entry[2]
		local hint = interface:hint(id)
		local text = if compact then label elseif hint ~= "" then string.format("%s  [%s]", label, hint) else label
		local button = C.button(text, function()
			interface:open(id)
		end, { kind = "ghost" }, {
			Size = UDim2.fromOffset(if compact then 0 else 170, Theme.minTouch),
			AutomaticSize = if compact then Enum.AutomaticSize.X else Enum.AutomaticSize.None,
			LayoutOrder = index,
			BackgroundTransparency = Theme.glass,
		})
		C.padding(0, Theme.space.m).Parent = button
		button.Parent = menu
	end
end

-- Onboarding nudge, in two steps. No text wall: one sentence and one action each.
--   no spells yet      "Something stirs in you." + Reach inward (the Composer)
--   spells, none cast  "Your magic answers." + exactly how to use slot 1 on this input and cast
--                      mode (the awakening's innate spells land on slots 1-3: CantripService),
--                      plus the slot of the first ranged (projectile) spell on the bar
-- Gone after the first cast that goes through.
local castOnce = Kit.value(false)

local function howToCast(name: string): string
	local mode = interface.inputMode:get()
	local equip = (magic.settings:get().castMode or "equip") ~= "quick"
	if mode == "Gamepad" then
		return if equip then string.format("Press L2 to ready %s, then R2 to cast.", name) else string.format("Press R2 to cast %s.", name)
	elseif mode == "Touch" then
		return if equip then string.format("Tap slot 1 to ready %s, then Cast.", name) else string.format("Tap slot 1 to cast %s.", name)
	end
	return if equip then string.format("Press 1 to ready %s, then click to cast.", name) else string.format("Press 1 to cast %s.", name)
end

local function buildFirstSteps(scope: Scope, root: Frame, compact: boolean)
	-- Any spell already cast (a returning player) means the nudge is done.
	scope:add(magic.spellbook:observe(function(book: any)
		for _, view in book do
			if (view.casts or 0) > 0 then
				castOnce:set(true)
			end
		end
	end))
	scope:add(magic.events:Connect(function(event: any)
		if typeof(event) == "table" and event.kind == "cast" and typeof(event.result) == "table" and event.result.ok then
			castOnce:set(true)
		end
	end))
	Kit.dynamic(scope, { magic.ready, magic.spellbook, magic.hotbar, castOnce, interface.inputMode, magic.settings }, function(s)
		if not magic.ready:get() or castOnce:get() then
			return
		end
		local book = magic.spellbook:get()
		local card = C.panel({
			Name = "FirstSteps",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, if compact then 0.42 else 0.62),
			Size = UDim2.fromOffset(340, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = Theme.glass,
			Parent = root,
		})
		s:add(card)
		C.padding(Theme.space.m).Parent = card
		C.list("y", Theme.space.s).Parent = card
		if #book == 0 then
			C.text("Something stirs in you.", "heading", { LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center }).Parent = card
			C.text("Reach for it and see what answers.", "caption", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center }).Parent = card
			local hint = interface:hint("Composer")
			local button = C.button(if hint ~= "" then string.format("Reach inward  [%s]", hint) else "Reach inward", function()
				interface:open("Composer")
			end, { kind = "primary" }, { LayoutOrder = 3 })
			button.Parent = card
			return
		end
		-- The spell in slot 1 (an innate spell), else the first in the book.
		local slotKey = magic.hotbar:get()[1]
		local name = book[1].name
		for _, view in book do
			if view.key == slotKey then
				name = view.name
			end
		end
		C.text("Your magic answers.", "heading", { LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center }).Parent = card
		C.text(howToCast(name), "body", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center }).Parent = card
		-- The first projectile on the bar (the thrown Strike, usually slot 3).
		local hotbar = magic.hotbar:get()
		for slot = 1, 10 do
			local key = hotbar[slot]
			local found = nil
			for _, view in book do
				if key and view.key == key and view.recipe and view.recipe.form == "projectile" then
					found = view
				end
			end
			if found then
				local how = string.format("%s in slot %d throws your magic from afar.", found.name, slot)
				C.text(how,"caption", { LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center }).Parent = card
				break
			end
		end
		C.text("The straw dummies in the practice yard by the plaza are free to strike.", "caption", { LayoutOrder = 4, TextXAlignment = Enum.TextXAlignment.Center }).Parent = card
	end)
end

local function buildFeedback(scope: Scope, root: Frame, compact: boolean)
	local label = C.text("", "heading", {
		Name = "CastFeedback",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = if compact then UDim2.fromScale(0.5, 0.7) else UDim2.new(0.5, 0, 1, -(SLOT_SIZE + 96)),
		Size = UDim2.fromOffset(520, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		Parent = root,
	})
	local function update()
		local current = feedback:get()
		label.Visible = current ~= nil
		if current then
			label.Text = current.text
			label.TextColor3 = current.color
		end
	end
	scope:add(feedback:observe(update))
	update()

	-- Crosshair: touch and gamepad aim at the screen centre.
	local crosshair = C.text("+", "heading", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(24, 24),
		AutomaticSize = Enum.AutomaticSize.None,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextStrokeTransparency = 0.3,
		Visible = interface.inputMode:get() ~= "Keyboard",
		Parent = root,
	})
	scope:add(crosshair)

	-- Cast bar: fills over the cast time (predicted by CastClient, corrected by the server).
	local castBar: Frame = Kit.create(nil, "Frame", {
		Name = "CastBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = if compact then UDim2.fromScale(0.5, 0.76) else UDim2.new(0.5, 0, 1, -(SLOT_SIZE + 70)),
		Size = UDim2.fromOffset(220, 8),
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Visible = false,
		Parent = root,
	})
	C.corner(Theme.radius.s).Parent = castBar
	local castFill: Frame = Kit.create(nil, "Frame", {
		BackgroundColor3 = Theme.color.accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = castBar,
	})
	C.corner(Theme.radius.s).Parent = castFill

	-- Charging: the same bar fills over the whole hold, with a tick at each stage and the stage
	-- named above it (glyph + word; the colour turns to danger only as an extra cue).
	local ticks: { Frame } = {}
	for i = 2, #Charge.data.stages do
		ticks[i] = Kit.create(nil, "Frame", {
			Name = "Tick" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.new(0, 2, 1, 6),
			BackgroundColor3 = Theme.color.ink,
			BorderSizePixel = 0,
			ZIndex = 3,
			Visible = false,
			Parent = castBar,
		})
	end
	local stageLabel: TextLabel = C.text("", "label", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -4),
		Size = UDim2.fromOffset(220, 18),
		AutomaticSize = Enum.AutomaticSize.None,
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = Theme.font.bold,
		Visible = false,
		Parent = castBar,
	})

	-- Guard meter: shown while guarding, refilling, or broken.
	local guardBar: Frame = Kit.create(nil, "Frame", {
		Name = "GuardBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = castBar.Position + UDim2.fromOffset(0, 8), -- just under the cast bar
		Size = UDim2.fromOffset(160, 6),
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Visible = false,
		Parent = root,
	})
	C.corner(Theme.radius.s).Parent = guardBar
	local guardFill: Frame = Kit.create(nil, "Frame", {
		BackgroundColor3 = Theme.color.ink,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = guardBar,
	})
	C.corner(Theme.radius.s).Parent = guardFill
	local guardLabel: TextLabel = C.text("⛨", "caption", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(0, -4, 0.5, 0),
		Size = UDim2.fromOffset(60, 14),
		AutomaticSize = Enum.AutomaticSize.None,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = guardBar,
	})

	local function updateGuard()
		local character = Players.LocalPlayer.Character
		local meter = character and character:GetAttribute("GuardMeter")
		local broken = character and character:GetAttribute("GuardBrokenUntil")
		local isBroken = typeof(broken) == "number" and broken > workspace:GetServerTimeNow()
		local value = if typeof(meter) == "number" then meter else 1
		local show = castClient.guarding:get() or value < 0.999 or isBroken
		guardBar.Visible = show == true
		guardFill.Size = UDim2.fromScale(math.clamp(value, 0, 1), 1)
		guardFill.BackgroundColor3 = if isBroken then Theme.color.danger elseif value < 0.3 then Theme.color.warn else Theme.color.ink
		guardLabel.Text = if isBroken then "⛨ Broken" else "⛨"
	end

	scope:add(RunService.RenderStepped:Connect(function()
		updateGuard()
		local charge = castClient.charging:get()
		if charge then
			local held = os.clock() - charge.started
			local step = Charge.step(charge.castTime)
			local stage = Charge.stage(Charge.stageIndex(held, charge.castTime))
			castBar.Visible = true
			castFill.Size = UDim2.fromScale(math.clamp(held / charge.maxHold, 0, 1), 1)
			castFill.BackgroundColor3 = if stage.overcharge then Theme.color.danger else Theme.color.accent
			for i, tick in ticks do
				tick.Position = UDim2.fromScale(math.clamp(Charge.data.stages[i].at * step / charge.maxHold, 0, 1), 0.5)
				tick.Visible = true
			end
			stageLabel.Text = stage.glyph .. " " .. stage.name
			stageLabel.TextColor3 = if stage.overcharge then Theme.color.danger else Theme.color.ink
			stageLabel.Visible = true
			return
		end
		for _, tick in ticks do
			tick.Visible = false
		end
		-- A drawn bow (WeaponClient): the bar fills to full draw; "full" once it's there.
		local drawing = weaponClient.drawing:get()
		if drawing then
			local _, _, class, ranged = weaponClient:mainHand()
			local draw = class == "ranged" and ranged.draw
			if draw then
				local held = os.clock() - drawing.started
				castBar.Visible = true
				castFill.Size = UDim2.fromScale(math.clamp(held / draw.drawFull, 0, 1), 1)
				castFill.BackgroundColor3 = if held > draw.holdMax then Theme.color.warn else Theme.color.accent
				stageLabel.Text = if held < draw.drawMin then "➶ drawing" elseif held < draw.drawFull then "➶ half" elseif held <= draw.holdMax then "➶ full draw" else "➶ arms shaking"
				stageLabel.TextColor3 = if held > draw.holdMax then Theme.color.warn else Theme.color.ink
				stageLabel.Visible = true
				return
			end
		end
		stageLabel.Visible = false
		castFill.BackgroundColor3 = Theme.color.accent
		local casting = castClient.casting:get()
		castBar.Visible = casting ~= nil and casting.castTime > 0.15
		if casting then
			castFill.Size = UDim2.fromScale(math.clamp((os.clock() - casting.started) / math.max(casting.castTime, 0.01), 0, 1), 1)
		end
	end))
end

local function buildToasts(scope: Scope, root: Frame, compact: boolean)
	local stack: Frame = Kit.create(nil, "Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = if compact then Vector2.new(0.5, 0) else Vector2.new(1, 0),
		Position = if compact then UDim2.new(0.5, 0, 0, 64) else UDim2.new(1, -Theme.space.m, 0, 110),
		Size = UDim2.fromOffset(if compact then 340 else 320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.xs).Parent = stack

	Kit.dynamic(scope, { toasts }, function(s)
		for index, t in toasts:get() do
			if compact and index > 2 then
				break
			end
			local card = C.panel({
				BackgroundTransparency = Theme.glass,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = index,
				Parent = stack,
			})
			s:add(card)
			local stroke = card:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = t.color
			end
			C.padding(Theme.space.s).Parent = card
			C.text(t.text, "body").Parent = card
		end
	end)
end

-- The awakening moment: a domain answers for the first time.
local function buildAwakening(scope: Scope, root: Frame)
	Kit.dynamic(scope, { awakening }, function(s)
		local domainId = awakening:get()
		local domain = domainId and Registry.domains[domainId]
		if not domainId or not domain then
			return
		end
		local style = Theme.domainStyle(domainId)
		C.sound("awaken")
		if style then
			C.sound(style.sound)
		end
		local overlay: TextButton = Kit.create(nil, "TextButton", {
			Name = "Awakening",
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = Theme.color.backdrop,
			BackgroundTransparency = 0.25,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 50,
			Parent = root,
			Activated = function()
				awakening:set(nil)
			end,
		})
		s:add(overlay)
		local column: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(460, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = overlay,
		})
		C.list("y", Theme.space.m, { HorizontalAlignment = Enum.HorizontalAlignment.Center }).Parent = column
		local badge = C.badge(domainId, 96)
		badge.LayoutOrder = 1
		badge.Parent = column
		C.text("Awakening", "caption", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center }).Parent = column
		C.text(domain.name, "display", { LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Theme.domainColor(domainId) }).Parent = column
		C.text(domain.concept, "body", { LayoutOrder = 4, TextXAlignment = Enum.TextXAlignment.Center }).Parent = column
		C.text("It was always yours. Try it.", "caption", { LayoutOrder = 5, TextXAlignment = Enum.TextXAlignment.Center }).Parent = column

		badge.Size = UDim2.fromOffset(24, 24)
		C.tween(badge, "slow", { Size = UDim2.fromOffset(96, 96) })
		task.delay(8, function()
			if awakening:get() == domainId then
				awakening:set(nil)
			end
		end)
	end)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function build(scope: Scope, root: Frame)
	local compact = interface.layout:get() == "Compact"
	-- Full-bleed screens cover the HUD in Compact; hide it so nothing peeks through.
	local function syncVisible()
		root.Visible = not (compact and interface.openScreen:get() ~= nil)
	end
	scope:add(interface.openScreen:observe(syncVisible))
	syncVisible()

	buildReservoir(scope, root, compact)
	buildRegion(scope, root, compact)
	if not compact then
		buildTracker(scope, root)
	end
	buildHotbar(scope, root, compact)
	buildMenu(scope, root, compact)
	buildFeedback(scope, root, compact)
	buildToasts(scope, root, compact)
	buildFirstSteps(scope, root, compact)
	buildAwakening(scope, root)
end

function HudController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	castClient = ctx.get("CastClient")
	movement = ctx.get("MovementClient")
	weaponClient = ctx.get("WeaponClient")
	interface:registerLayer({ id = "HUD", build = build })
	magic.events:Connect(onEvent)
end

return HudController
