--!strict
--[[
	WeaponClient: the client half of item-weapon combat (docs/Items.md §10). Input, aim and
	prediction only; Services/WeaponService decides everything.

	INPUT    CastClient routes attack input here whenever no spell is readied (CastClient.weapon):
	           primary (left mouse, gamepad R1, the touch Cast button)
	             melee weapon  swing
	             bow           hold to draw, release to loose
	             crossbow      shoot (then it reloads)
	             bandolier     throw a knife
	           melee (F, gamepad B, the touch Slash button)   swing a melee weapon
	         The guard input (right mouse, L1, touch Block) blocks with a weapon that can
	         (CastClient.raiseGuard asks canBlock()).
	AIM      AimController.sample() when the attack is sent; the body turns to the aim for a
	         swing and follows it while a bow is drawn.
	PREDICT  the swing, draw and release clips play at once; WeaponResult refusals undo them and
	         say why. A press too early in a combo is buffered until the window opens. The draw
	         meter is the HUD's cast bar (WeaponClient.drawing).
	CHECKS   before sending: a weapon, not broken, stamina (the Player's Stamina attribute), ammo
	         in the grid, reload elapsed. The server re-checks all of them.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local ActionRules = require(Shared.Magic.ActionRules)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local WeaponRules = require(Shared.Items.WeaponRules)

local Kit = require(script.Parent.Parent:WaitForChild("UI").Kit)

local TURN_RATE = 14
local AIM_HZ = 15

local REASONS: { [string]: string } = {
	TIRED = "You're out of breath.",
	NO_AMMO = "You're out of ammunition.",
	RELOADING = "Still reloading.",
	UNDERDRAWN = "Draw the string further.",
	BROKEN = "Your weapon is broken. Repair it first.",
	STAGGERED = "You're knocked off your feet.",
	INTERRUPTED = "Your draw was broken.",
	SPELL_READY = "Put the spell away (Q) to use your weapon.",
}

local AMMO_NAMES: { [string]: string } = { arrow = "arrows", bolt = "bolts", thrown_knife = "knives" }

export type Drawing = { started: number, maxHold: number }

local WeaponClient = {
	name = "WeaponClient",
	dependencies = { "CastClient", "AnimationController", "AimController", "ItemStateController", "MagicStateController" },
}

-- The bow being drawn (the HUD shows it on the cast bar), or nil.
WeaponClient.drawing = Kit.value(nil :: Drawing?)

local castClient: any = nil
local animation: any = nil
local aimer: any = nil
local items: any = nil
local magic: any = nil

local swingLast: { index: number, started: number, speed: number }? = nil
local swingBuffered = false
local readyAt = 0 -- our estimate of the server's reload

local function feedback(text: string, tone: string)
	magic.events:Fire({ kind = "castFeedback", text = text, tone = tone })
end

local function mainHand(): (ItemTypes.Record?, ItemTypes.ItemDef?, string?, any)
	local view = items:find("e:mainHand")
	local rec = view and view.rec
	local def = rec and ItemDatabase.get(rec.i)
	local class, kind = WeaponRules.classify(def)
	return rec, def, class, kind
end

-- The main-hand item and how it fights (the HUD's draw meter reads it).
function WeaponClient.mainHand(_self: any): (ItemTypes.Record?, ItemTypes.ItemDef?, string?, any)
	return mainHand()
end

local function ammoCount(tag: string): number
	local view = items.view:get()
	local total = 0
	for _, item in (if view then view.items else {}) :: { ItemTypes.ItemView } do
		if string.sub(item.ref, 1, 1) == "s" then
			local def = ItemDatabase.get(item.rec.i)
			if def and table.find(def.tags, tag) then
				total += ItemInstance.count(item.rec)
			end
		end
	end
	return total
end

local function staminaNow(): number
	local value = Players.LocalPlayer:GetAttribute("Stamina")
	return if typeof(value) == "number" then value else math.huge
end

local function bodyAllows(action: string): boolean
	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	return ActionRules.allows(ActionRules.effective(ActionRules.read(character), workspace:GetServerTimeNow()), action)
end

local function rootOf(): BasePart?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function turnToward(point: Vector3, alpha: number)
	local root = rootOf()
	if not root then
		return
	end
	local flat = Vector3.new(point.X - root.Position.X, 0, point.Z - root.Position.Z)
	if flat.Magnitude < 0.5 then
		return
	end
	local goal = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	root.CFrame = if alpha >= 1 then goal else root.CFrame:Lerp(goal, alpha)
end

-- ─── Melee ──────────────────────────────────────────────────────────────────

local function swing(weapon: ItemTypes.WeaponDef, kind: any)
	if not bodyAllows("slash") then
		return
	end
	local speedAttr = Players.LocalPlayer:GetAttribute("WeaponSpeed")
	local speed = if typeof(speedAttr) == "number" then speedAttr else WeaponRules.speed(weapon, 0)
	local last = swingLast
	local index, wait = WeaponRules.nextIndex(kind, if last then last.index else nil, if last then os.clock() - last.started else 0, if last then last.speed else speed)
	if not index then
		if not swingBuffered then
			swingBuffered = true
			task.delay(wait + 0.04, function()
				swingBuffered = false
				local _, def, class, again = mainHand()
				if class == "melee" and def and def.weapon then
					swing(def.weapon, again)
				end
			end)
		end
		return
	end
	local step = WeaponRules.swing(kind, index)
	if staminaNow() < WeaponRules.swingStamina(weapon, step) then
		feedback(REASONS.TIRED, "dim")
		return
	end
	local point = aimer:sample()
	turnToward(point, 1) -- swing where you're looking
	swingLast = { index = index, started = os.clock(), speed = speed }
	animation:predict("slashing", step.duration / speed, nil, step.clip)
	Net.send("WeaponIntent", "swing", point)
end

-- ─── Ranged ─────────────────────────────────────────────────────────────────

local function readyToShoot(weapon: ItemTypes.WeaponDef): boolean
	local tag = weapon.ammo or ""
	if ammoCount(tag) <= 0 then
		feedback(string.format("No %s left.", AMMO_NAMES[tag] or "ammunition"), "warn")
		return false
	end
	if os.clock() < readyAt then
		return false
	end
	if staminaNow() < weapon.stamina then
		feedback(REASONS.TIRED, "dim")
		return false
	end
	return bodyAllows("cast")
end

local function shoot(weapon: ItemTypes.WeaponDef, ranged: any)
	local point = aimer:sample()
	turnToward(point, 1)
	readyAt = os.clock() + WeaponRules.reload(weapon, ranged)
	animation:predict("casting", 0.3)
	Net.send("WeaponIntent", "release", point)
end

local function startDraw(weapon: ItemTypes.WeaponDef, ranged: any)
	if WeaponClient.drawing:get() or not readyToShoot(weapon) then
		return
	end
	local maxHold = ranged.draw.holdMax + 3
	WeaponClient.drawing:set({ started = os.clock(), maxHold = maxHold })
	animation:predict("charging", maxHold)
	Net.send("WeaponIntent", "draw")
end

local function loose()
	local drawing = WeaponClient.drawing:get()
	if not drawing then
		return
	end
	WeaponClient.drawing:set(nil)
	local _, def, class, ranged = mainHand()
	if class ~= "ranged" or not def or not def.weapon then
		Net.send("WeaponIntent", "cancel")
		animation:predict("idle")
		return
	end
	if WeaponRules.drawShare(ranged, os.clock() - drawing.started) == nil then
		-- Let go too soon: the arrow stays on the string.
		Net.send("WeaponIntent", "cancel")
		animation:predict("idle")
		feedback(REASONS.UNDERDRAWN, "dim")
		return
	end
	shoot(def.weapon, ranged)
end

-- ─── Hooks (called by CastClient) ───────────────────────────────────────────

local function press(source: string)
	local rec, def, class, kind = mainHand()
	if not rec or not def or not def.weapon or not class then
		return -- bare hands: nothing to swing
	end
	if ItemInstance.isBroken(rec) then
		feedback(REASONS.BROKEN, "warn")
		return
	end
	if class == "melee" then
		swing(def.weapon, kind)
	elseif class == "ranged" and source == "primary" then
		if kind.draw then
			startDraw(def.weapon, kind)
		elseif readyToShoot(def.weapon) then
			shoot(def.weapon, kind)
		end
	end
end

local function canBlock(): boolean
	local rec, def = mainHand()
	return rec ~= nil and not ItemInstance.isBroken(rec) and WeaponRules.canBlock(def)
end

local function onResult(result: any)
	if typeof(result) ~= "table" then
		return
	end
	if result.ok == false then
		swingLast = nil
		if WeaponClient.drawing:get() then
			WeaponClient.drawing:set(nil)
		end
		readyAt = 0
		animation:predict("idle")
		local text = REASONS[result.reason or ""]
		if text then
			feedback(text, "dim")
		end
	elseif result.hit then
		animation:hitStop(0.05)
	elseif result.fired and typeof(result.ammo) == "number" and result.ammo <= 10 then
		feedback(string.format("%d left", result.ammo), if result.ammo == 0 then "warn" else "dim")
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function WeaponClient.init(_self: any, ctx: any)
	castClient = ctx.get("CastClient")
	animation = ctx.get("AnimationController")
	aimer = ctx.get("AimController")
	items = ctx.get("ItemStateController")
	magic = ctx.get("MagicStateController")
	castClient.weapon.press = press
	castClient.weapon.release = loose
	castClient.weapon.canBlock = canBlock
end

function WeaponClient.start(_self: any, _ctx: any)
	Net.listen("WeaponResult", onResult)

	-- While a bow is drawn the body follows the aim.
	local aimElapsed = 0
	local aimPoint: Vector3? = nil
	RunService.RenderStepped:Connect(function(dt)
		if not WeaponClient.drawing:get() then
			aimPoint = nil
			return
		end
		aimElapsed += dt
		if aimElapsed >= 1 / AIM_HZ or not aimPoint then
			aimElapsed = 0
			aimPoint = aimer:sample()
		end
		turnToward(aimPoint :: Vector3, math.clamp(dt * TURN_RATE, 0, 1))
	end)

	-- Readying a spell, a new body or a weapon change drops a draw.
	local function dropDraw()
		if WeaponClient.drawing:get() then
			WeaponClient.drawing:set(nil)
			Net.send("WeaponIntent", "cancel")
		end
	end
	castClient.attuned:observe(function(held)
		if held then
			dropDraw()
		end
	end)
	items.view:observe(function()
		local _, _, class = mainHand()
		if class ~= "ranged" then
			dropDraw()
		end
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		WeaponClient.drawing:set(nil)
		swingLast = nil
		readyAt = 0
	end)
end

return WeaponClient
