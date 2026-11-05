--!strict
--[[
	MovementClient: running and the dash, client side (docs/Combat.md §15). Rules and numbers come
	from Shared/Magic/Movement + Data/MovementTuning; keys from Shared/UI/Controls. The server
	(Services/MovementService) decides everything: this only sends intents and predicts.

	RUN     keyboard: Left Ctrl toggles running (RunIntent). Gamepad: no toggle, you run while the
	        left stick is pushed far (Movement.gamepadRun). Touch: the HUD's Run button
	        (toggleRun). The server applies it only when allowed and sets the character attribute
	        Running; while that's on and you're moving, the Run clip plays over Roblox's default
	        walk (which still plays when you walk).
	DASH    R / click the left stick / the HUD's Dash button. Checked locally first (alive, input
	        free, the action state allows "dash", a charge on the DashCharges attribute, the
	        cooldown), then predicted at once: the Dash clip and, for impulse styles, a
	        LinearVelocity on your own body (you own its physics) for the dash's duration. Blink
	        and rewind wait for the server to move you. A refusal (DashResult) stops the push,
	        cancels the clip and says why.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local Movement = require(Shared.Magic.Movement)
local ActionRules = require(Shared.Magic.ActionRules)
local Kit = require(script.Parent.Parent:WaitForChild("UI").Kit)

local T = Movement.tuning

local MovementClient = {
	name = "MovementClient",
	dependencies = { "InterfaceController", "MagicStateController", "AnimationController" },
}

local REFUSALS: { [string]: string } = {
	NO_CHARGES = "No dash left: it refills in a moment.",
	TOO_SOON = "Too soon to dash again.",
	WINDED = "Too winded to dash.",
	BUSY = "You can't dash right now.",
	REWIND_TOO_FAR = "Nowhere to rewind to.",
}

local interface: any = nil
local magic: any = nil
local animation: any = nil
local localPlayer = Players.LocalPlayer

MovementClient.wantsRun = Kit.value(false) -- the toggle (HUD shows it)
local gamepadRunning = false
local runClipOn = false
local lastDash = -math.huge
local push: LinearVelocity? = nil
local pushAttachment: Attachment? = nil

local function body(): (Model?, Humanoid?, BasePart?)
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

-- ─── Running ────────────────────────────────────────────────────────────────

local function setWantsRun(on: boolean)
	if MovementClient.wantsRun:get() == on then
		return
	end
	MovementClient.wantsRun:set(on)
	Net.fire("RunIntent", on)
end

function MovementClient.toggleRun(_self: any)
	setWantsRun(not MovementClient.wantsRun:get())
end

-- The Run clip: on while the server says Running and you're actually moving on the ground.
local function updateRunClip()
	local character, humanoid = body()
	local want = character ~= nil
		and humanoid ~= nil
		and character:GetAttribute("Running") == true
		and humanoid.MoveDirection.Magnitude > 0.1
		and humanoid:GetState() == Enum.HumanoidStateType.Running
	if want and not runClipOn then
		runClipOn = animation:play("Run") ~= nil
	elseif not want and runClipOn then
		runClipOn = false
		animation:stop("Run", 0.2)
	end
end

-- ─── Dash ───────────────────────────────────────────────────────────────────

local function stopPush()
	if push then
		push:Destroy()
		push = nil
	end
	if pushAttachment then
		pushAttachment:Destroy()
		pushAttachment = nil
	end
end

local function startPush(root: BasePart, dash: Movement.Dash, dir: Vector3)
	stopPush()
	local attachment = Instance.new("Attachment")
	attachment.Name = "DashPush"
	attachment.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.VectorVelocity = dir * dash.speed + Vector3.new(0, dash.lift, 0)
	if dash.lift > 0 then
		lv.MaxForce = 1e5
	else
		-- Horizontal only: gravity and the ground keep working on Y.
		lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
		lv.MaxAxesForce = Vector3.new(1e5, 0, 1e5)
	end
	lv.Parent = root
	push, pushAttachment = lv, attachment
	task.delay(dash.duration, function()
		if push == lv then
			stopPush()
		end
	end)
end

function MovementClient.dash(_self: any)
	if interface:isInputBlocked() then
		return
	end
	local character, humanoid, root = body()
	if not character or not humanoid or not root then
		return
	end
	local t = os.clock()
	if t - lastDash < T.dash.cooldown then
		return
	end
	local charges = localPlayer:GetAttribute("DashCharges")
	if typeof(charges) == "number" and charges < 1 then
		magic.events:Fire({ kind = "notify", text = REFUSALS.NO_CHARGES })
		return
	end
	local snapshot = ActionRules.read(character)
	if not ActionRules.allows(ActionRules.effective(snapshot, workspace:GetServerTimeNow()), "dash") then
		return
	end
	lastDash = t
	local domain = character:GetAttribute("AttunedDomain")
	local dash = Movement.dashFor(if typeof(domain) == "string" then domain else nil, 0)
	local dir = Movement.direction(humanoid.MoveDirection, root.CFrame.LookVector)
	animation:predict("dashing", nil, if typeof(domain) == "string" then domain else nil)
	if dash.kind == "impulse" then
		startPush(root, dash, dir)
	end
	Net.fire("DashIntent", dir)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function MovementClient.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	animation = ctx.get("AnimationController")
end

function MovementClient.start(self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or interface:isInputBlocked() then
			return
		end
		if Controls.matches("run", input) then
			self:toggleRun()
		elseif Controls.matches("dash", input) then
			self:dash()
		end
	end)
	-- Gamepad: run while the left stick is pushed far.
	UserInputService.InputChanged:Connect(function(input)
		if input.KeyCode ~= Enum.KeyCode.Thumbstick1 then
			return
		end
		local tilt = Vector2.new(input.Position.X, input.Position.Y).Magnitude
		local running = Movement.gamepadRun(gamepadRunning, tilt)
		if running ~= gamepadRunning then
			gamepadRunning = running
			setWantsRun(running)
		end
	end)

	Net.listen("DashResult", function(result: any)
		if typeof(result) ~= "table" or result.ok then
			return
		end
		stopPush()
		animation:cancelPrediction()
		local text = REFUSALS[tostring(result.reason)]
		if text then
			magic.events:Fire({ kind = "notify", text = text })
		end
	end)

	-- A new body starts walking (the server resets too) and drops any leftover push.
	localPlayer.CharacterAdded:Connect(function()
		stopPush()
		runClipOn = false
		gamepadRunning = false
		setWantsRun(false) -- tells the server too, so client and server agree
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		updateRunClip()
	end)
end

return MovementClient
