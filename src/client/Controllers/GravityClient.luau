--!strict
--[[
	GravityClient: flying (docs/Gravity.md). Players own their characters' physics, so this does the
	flying and the server checks it: it grants flight through character attributes (GravityFlight,
	FlightSpeed, FlightCeiling, FlightMeteor) and drains the reservoir, and it ends flight if speed or
	height go past what it allowed. This never decides anything: it only moves within what it was given.

	CONTROLS  You go where the camera looks. Move keys steer, Space climbs and Shift sinks (Shared/UI
	          Controls), Y lands and U dives. Touch and gamepad get a small panel of buttons.
	LANDING   Touching down with nothing held lands you, after a moment so taking off isn't undone.
	CEILING   A ray down: no climbing past your ceiling, and you're eased back under it.
	MOVING    A LinearVelocity and an AlignOrientation on your root, with the Humanoid in its Physics
	          state so it doesn't fight them. Both go when flight ends.

	Budget: one RenderStepped connection, only while flying; one ray per frame.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local CLIMB_SHARE = 0.75 -- of flight speed, for Space and Shift
local LAND_GRACE = 2.5 -- seconds after taking off before touching down can land you
local LAND_HEIGHT = 3.8 -- studs from the root to the ground that count as touching down
local LAND_AFTER = 0.8 -- seconds touching down before it lands you
local TILT = math.rad(30) -- leaning into the direction you fly

local GravityClient = {
	name = "GravityClient",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local localPlayer = Players.LocalPlayer

GravityClient.flying = Kit.value(false)
GravityClient.canDive = Kit.value(false)

local connection: RBXScriptConnection? = nil
local attachment: Attachment? = nil
local velocity: LinearVelocity? = nil
local orientation: AlignOrientation? = nil
local touchUp = false
local touchDown = false
local startedAt = 0
local lowFor = 0

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local function keysHeld(id: string): boolean
	if UserInputService:GetFocusedTextBox() or interface:isInputBlocked() then
		return false
	end
	for _, key in Controls.keys(id, "keyboard") do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	for _, key in Controls.keys(id, "gamepad") do
		if UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, key) then
			return true
		end
	end
	return false
end

local function stopFlying()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if velocity then
		velocity:Destroy()
		velocity = nil
	end
	if orientation then
		orientation:Destroy()
		orientation = nil
	end
	if attachment then
		attachment:Destroy()
		attachment = nil
	end
	touchUp, touchDown = false, false
	GravityClient.flying:set(false)
	GravityClient.canDive:set(false)
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end

local function step(character: Model, humanoid: Humanoid, root: BasePart, dt: number)
	local camera = workspace.CurrentCamera
	local lv, align = velocity, orientation
	if not camera or not lv or not align then
		return
	end
	local speed = character:GetAttribute("FlightSpeed")
	local ceiling = character:GetAttribute("FlightCeiling")
	if typeof(speed) ~= "number" or typeof(ceiling) ~= "number" then
		return
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end

	-- MoveDirection is flat and camera-relative: turn it into "along the camera, including pitch".
	local look, right = camera.CFrame.LookVector, camera.CFrame.RightVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = if flatLook.Magnitude > 0.01 then flatLook.Unit else root.CFrame.LookVector
	local flatRight = Vector3.new(right.X, 0, right.Z)
	flatRight = if flatRight.Magnitude > 0.01 then flatRight.Unit else root.CFrame.RightVector
	local move = humanoid.MoveDirection
	local forward, strafe = move:Dot(flatLook), move:Dot(flatRight)
	local wanted = (look * forward + right * strafe) * speed

	local up = keysHeld("fly_up") or touchUp
	local down = keysHeld("fly_down") or touchDown
	local climb = (if up then 1 else 0) - (if down then 1 else 0)
	wanted += Vector3.new(0, climb * speed * CLIMB_SHARE, 0)

	-- How high are you? One ray down, up to a little past the ceiling.
	params.FilterDescendantsInstances = { character }
	local result = workspace:Raycast(root.Position, Vector3.new(0, -(ceiling + 40), 0), params)
	local height = if result then result.Distance else math.huge
	if height >= ceiling and wanted.Y > 0 then
		wanted = Vector3.new(wanted.X, 0, wanted.Z)
	end
	if height > ceiling + 2 then
		wanted = Vector3.new(wanted.X, -speed * 0.5, wanted.Z) -- eased back under your ceiling
	end
	lv.VectorVelocity = wanted

	-- Face where you're looking, leaning into the way you're going.
	local lean = if wanted.Magnitude > 1 then CFrame.Angles(-TILT * forward, 0, -TILT * strafe) else CFrame.identity
	align.CFrame = CFrame.lookAt(Vector3.zero, flatLook) * lean

	-- Touching down with nothing held: you've landed.
	if height <= LAND_HEIGHT and not up and os.clock() - startedAt >= LAND_GRACE then
		lowFor += dt
		if lowFor >= LAND_AFTER then
			lowFor = 0
			Net.send("FlightIntent", "land")
		end
	else
		lowFor = 0
	end
end

local function startFlying(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or connection then
		return
	end
	local a = Instance.new("Attachment")
	a.Name = "GravityFlight"
	a.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "GravityFlight"
	lv.Attachment0 = a
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = 1e6
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "GravityFlight"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = a
	align.MaxTorque = 1e6
	align.Responsiveness = 30
	align.CFrame = root.CFrame.Rotation
	align.Parent = root
	attachment, velocity, orientation = a, lv, align

	humanoid.AutoRotate = false
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	startedAt, lowFor = os.clock(), 0
	GravityClient.flying:set(true)
	GravityClient.canDive:set(character:GetAttribute("FlightMeteor") == true)
	connection = RunService.RenderStepped:Connect(function(dt)
		if not root.Parent or humanoid.Health <= 0 then
			stopFlying()
		elseif not root.Anchored then
			step(character, humanoid, root, dt)
		end
	end)
end

local function watchCharacter(character: Model)
	local function changed()
		if character:GetAttribute("GravityFlight") == true then
			startFlying(character)
		elseif connection then
			stopFlying()
		end
	end
	character:GetAttributeChangedSignal("GravityFlight"):Connect(changed)
	changed()
end

-- ─── The panel ──────────────────────────────────────────────────────────────

local function holdButton(parent: Instance, text: string, order: number, set: (boolean) -> ())
	local button = C.button(text, nil, { kind = "ghost" }, { Size = UDim2.fromOffset(Theme.minTouch + 12, Theme.minTouch), LayoutOrder = order })
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			set(true)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			set(false)
		end
	end)
	button.Parent = parent
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { GravityClient.flying, GravityClient.canDive }, function(s)
		if not GravityClient.flying:get() then
			return
		end
		local panel: Frame = Kit.create(nil, "Frame", {
			Name = "FlightPanel",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -Theme.space.m, 1, -(Theme.minTouch * 4)),
			Size = UDim2.fromOffset(Theme.minTouch * 4 + 60, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = root,
		})
		s:add(panel)
		C.list("y", Theme.space.xs).Parent = panel
		local dive = GravityClient.canDive:get()
		C.text(if dive then "Flying · Space up · Shift down · Y land · U dive" else "Flying · Space up · Shift down · Y land", "caption", {
			TextStrokeTransparency = 0.4,
			LayoutOrder = 1,
			Parent = panel,
		})
		-- Keyboards have keys. Touch and gamepad players need the buttons.
		if UserInputService.TouchEnabled or UserInputService.GamepadEnabled then
			local row: Frame = Kit.create(nil, "Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, Theme.minTouch),
				LayoutOrder = 2,
				Parent = panel,
			})
			C.list("x", Theme.space.xs).Parent = row
			holdButton(row, "▲ Up", 1, function(on)
				touchUp = on
			end)
			holdButton(row, "▼ Down", 2, function(on)
				touchDown = on
			end)
			C.button("Land", function()
				Net.send("FlightIntent", "land")
			end, { kind = "ghost" }, { Size = UDim2.fromOffset(Theme.minTouch + 12, Theme.minTouch), LayoutOrder = 3 }).Parent = row
			if dive then
				C.button("Dive", function()
					Net.send("FlightIntent", "dive")
				end, { kind = "primary" }, { Size = UDim2.fromOffset(Theme.minTouch + 12, Theme.minTouch), LayoutOrder = 4 }).Parent = row
			end
		end
	end)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function GravityClient.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	interface:registerLayer({ id = "Flight", build = buildLayer })
end

function GravityClient.start(_self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not GravityClient.flying:get() or interface:isInputBlocked() then
			return
		end
		if Controls.matches("fly_land", input) then
			Net.send("FlightIntent", "land")
		elseif Controls.matches("fly_dive", input) then
			Net.send("FlightIntent", "dive")
		end
	end)
	localPlayer.CharacterAdded:Connect(function(character)
		if connection then
			stopFlying()
		end
		watchCharacter(character)
	end)
	if localPlayer.Character then
		watchCharacter(localPlayer.Character)
	end
end

return GravityClient
