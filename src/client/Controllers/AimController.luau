--!strict
--[[
	AimController: where the player is aiming, and soft lock-on (docs/Casting.md §7).
	Never authority: the server re-checks range, sight and the target (CastService, Shared/Magic/Aim).

	AIM      a ray from the camera through the mouse (keyboard) or the screen centre (gamepad,
	         touch). It ignores your own character, spell effects (MagicFx) and the reticle.
	         sample() casts a fresh ray (used when a cast is sent); current() is the last sample,
	         refreshed at SAMPLE_HZ (one ray; the reticle and turning to face the aim use it).
	LOCK-ON  keyboard: Left Alt or the middle mouse button: press to lock, press again to let go
	         (setting lockOnMode = "hold" makes it hold-to-lock); gamepad: click the right stick (R3)
	         to toggle. Picks the living character (player or NPC) nearest the cursor on screen,
	         inside LOCK_SCREEN_SHARE of the screen height and LOCK_RANGE studs. While locked, the
	         aim is the target's chest and the cast names it as the target. The lock breaks when
	         the target dies, leaves, goes past BREAK_RANGE, or is out of sight for BREAK_HIDDEN s.
	Values: locked (Model?).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Aim = require(Shared.Magic.Aim)

local Client = script.Parent.Parent
local Kit = require(Client:WaitForChild("UI").Kit)

local AIM_DISTANCE = 1000
local SAMPLE_HZ = 30
local LOCK_SCREEN_SHARE = 0.18 -- lock-on cone: this share of the screen height around the cursor
local LOCK_RANGE = 220
local BREAK_RANGE = 300
local BREAK_HIDDEN = 1.0

local AimController = {
	name = "AimController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

AimController.locked = Kit.value(nil :: Model?)

local interface: any = nil
local localPlayer = Players.LocalPlayer
local lastPoint = Vector3.zero
local lastTarget: Model? = nil
local hiddenSince: number? = nil
local holdingLock = false
local magic: any = nil

local function screenPoint(): Vector2
	local camera = workspace.CurrentCamera
	return if interface.inputMode:get() == "Keyboard" then UserInputService:GetMouseLocation() else camera.ViewportSize / 2
end

local function ignoreList(): { Instance }
	local list: { Instance } = {}
	local character = localPlayer.Character
	if character then
		table.insert(list, character)
	end
	for _, name in { "MagicFx", "AimReticle" } do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(list, folder)
		end
	end
	return list
end

local function aliveRoot(model: Model?): BasePart?
	if not model or not model.Parent then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- A fresh aim: (point, target?). The locked target wins while the lock holds.
function AimController.sample(_self: any): (Vector3, Model?)
	local locked = AimController.locked:get()
	local lockedRoot = aliveRoot(locked)
	if locked and lockedRoot then
		lastPoint, lastTarget = lockedRoot.Position, locked
		return lastPoint, locked
	end
	local camera = workspace.CurrentCamera
	local point = screenPoint()
	local ray = camera:ViewportPointToRay(point.X, point.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList()
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_DISTANCE, params)
	if not hit then
		lastPoint, lastTarget = ray.Origin + ray.Direction * AIM_DISTANCE, nil
		return lastPoint, nil
	end
	local model = hit.Instance:FindFirstAncestorOfClass("Model")
	local target = if model and model:FindFirstChildOfClass("Humanoid") then model else nil
	lastPoint, lastTarget = hit.Position, target
	return hit.Position, target
end

-- The last sample (cheap; refreshed at SAMPLE_HZ while attuned).
function AimController.current(_self: any): (Vector3, Model?)
	return lastPoint, lastTarget
end

-- ─── Lock-on ────────────────────────────────────────────────────────────────

local function candidates(): { Model }
	local list: { Model } = {}
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer and player.Character then
			table.insert(list, player.Character)
		end
	end
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		for _, child in npcs:GetChildren() do
			if child:IsA("Model") then
				table.insert(list, child)
			end
		end
	end
	return list
end

function AimController.pickLock(_self: any): Model?
	local camera = workspace.CurrentCamera
	local character = localPlayer.Character
	local myRoot = aliveRoot(character)
	if not camera or not myRoot then
		return nil
	end
	local cursor = screenPoint()
	local maxPixels = camera.ViewportSize.Y * LOCK_SCREEN_SHARE
	local best: Model?, bestPixels = nil, math.huge
	for _, model in candidates() do
		local root = aliveRoot(model)
		if root and (root.Position - myRoot.Position).Magnitude <= LOCK_RANGE then
			local screen, onScreen = camera:WorldToViewportPoint(root.Position)
			if onScreen then
				local pixels = (Vector2.new(screen.X, screen.Y) - cursor).Magnitude
				if pixels <= maxPixels and pixels < bestPixels then
					best, bestPixels = model, pixels
				end
			end
		end
	end
	return best
end

function AimController.lock(self: any)
	local target = self:pickLock()
	hiddenSince = nil
	AimController.locked:set(target)
end

function AimController.unlock(_self: any)
	hiddenSince = nil
	AimController.locked:set(nil)
end

-- Drops a lock that no longer holds (dead, gone, too far, hidden too long).
local function checkLock()
	local locked = AimController.locked:get()
	if not locked then
		return
	end
	local root = aliveRoot(locked)
	local character = localPlayer.Character
	local myRoot = aliveRoot(character)
	if not root or not myRoot or (root.Position - myRoot.Position).Magnitude > BREAK_RANGE then
		AimController:unlock()
		return
	end
	local eye = Aim.eye(character :: Model) or myRoot.Position
	local clear = Aim.lineOfSight(eye, root.Position, { character :: Model, locked })
	if clear then
		hiddenSince = nil
	elseif not hiddenSince then
		hiddenSince = os.clock()
	elseif os.clock() - (hiddenSince :: number) > BREAK_HIDDEN then
		AimController:unlock()
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function isLockInput(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.LeftAlt or input.UserInputType == Enum.UserInputType.MouseButton3
end

-- Settings › Lock-on: "toggle" (the default) or "hold".
local function lockHolds(): boolean
	return magic ~= nil and magic.settings:get().lockOnMode == "hold"
end

function AimController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
end

function AimController.start(self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or interface:isInputBlocked() then
			return
		end
		if isLockInput(input) then
			if lockHolds() then
				holdingLock = true
				self:lock()
			elseif AimController.locked:get() then
				self:unlock()
			else
				self:lock()
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR3 then
			if AimController.locked:get() then
				self:unlock()
			else
				self:lock()
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isLockInput(input) and holdingLock then
			holdingLock = false
			self:unlock()
		end
	end)
	localPlayer.CharacterAdded:Connect(function()
		self:unlock()
	end)

	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed < 1 / SAMPLE_HZ then
			return
		end
		elapsed = 0
		checkLock()
		self:sample()
	end)
end

return AimController
