--!strict
--[[
	TravelClient: Domain Travel, from the player's side (docs/Travel.md). Players own their characters'
	physics, so this does the moving and the server checks it (Services/TravelService): it grants a ride
	through the character attributes TravelStyle and TravelSpeed.

	KEYS     Y sets off and stops (while flying, Y lands instead: GravityClient has it). Move keys steer,
	         Space climbs and Shift sinks, within the style's lift. Touch and gamepad get buttons.
	MOVING   A LinearVelocity and an AlignOrientation on your root, with the Humanoid in its Physics state.
	         You keep your hover height over the ground, looking a little ahead so you rise over a slope or
	         a low wall instead of hitting it. Styles that can't cross water stop at the shore.
	EVERYONE Anyone riding gets the look (Fx/TravelFx), from the same attribute.

	Budget: one RenderStepped only while riding, with two rays a frame.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local T = require(Shared.Magic.Data.TravelTuning)
local Rules = require(Shared.Magic.TravelRules)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local TravelFx = require(Client:WaitForChild("Fx"):WaitForChild("TravelFx"))

local ROOT_HEIGHT = 3 -- studs from a standing character's root to the ground
local LOOK_AHEAD = 0.25 -- seconds of travel to check the ground ahead
local RAY_ABOVE = 25 -- studs above you the ground check starts, so low walls count as ground to rise over
local RAY_LENGTH = 260
local TILT = math.rad(22)

local TravelClient = {
	name = "TravelClient",
	dependencies = { "InterfaceController" },
}

local interface: any = nil
local localPlayer = Players.LocalPlayer

local riding = Kit.value("") -- the domain, or "" when not riding

local connection: RBXScriptConnection? = nil
local attachment: Attachment? = nil
local velocity: LinearVelocity? = nil
local orientation: AlignOrientation? = nil
local lift = 0
local touchUp = false
local touchDown = false

local function held(id: string): boolean
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

local function toggle()
	local character = localPlayer.Character
	if not character or character:GetAttribute("GravityFlight") then
		return -- flying: Y is for landing
	end
	Net.send("TravelIntent", riding:get() == "")
end

-- The ground under a point: a surface height, and whether it's water.
local function groundAt(position: Vector3, params: RaycastParams): (number?, boolean)
	local hit = workspace:Raycast(position + Vector3.new(0, RAY_ABOVE, 0), Vector3.new(0, -RAY_LENGTH, 0), params)
	if not hit then
		return nil, false
	end
	return hit.Position.Y, hit.Material == Enum.Material.Water
end

local function stopRiding()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	for _, item in { velocity, orientation, attachment } :: { Instance? } do
		if item then
			item:Destroy()
		end
	end
	velocity, orientation, attachment = nil, nil, nil
	touchUp, touchDown = false, false
	riding:set("")
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end

local function step(character: Model, humanoid: Humanoid, root: BasePart, style: T.Style, params: RaycastParams, dt: number)
	local camera = workspace.CurrentCamera
	local lv, align = velocity, orientation
	local speed = character:GetAttribute("TravelSpeed")
	if not camera or not lv or not align or typeof(speed) ~= "number" then
		return
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end
	local move = humanoid.MoveDirection
	local flat = if move.Magnitude > 0.05 then move.Unit * speed else Vector3.zero

	lift = Rules.nextLift(lift, style.lift, held("fly_up") or touchUp, held("fly_down") or touchDown, dt)

	-- Ground here and a little ahead: rise early for what's coming.
	local position = root.Position
	local here, hereWater = groundAt(position, params)
	local ahead, aheadWater = groundAt(position + flat * LOOK_AHEAD, params)
	if (aheadWater or hereWater) and not style.water then
		flat = Vector3.zero -- this style stops at the shore
	end
	local ground = math.max(here or -math.huge, ahead or -math.huge)
	local vertical = 0
	if ground > -math.huge then
		vertical = Rules.verticalSpeed(position.Y, ground + ROOT_HEIGHT + style.hover + lift, speed)
	else
		vertical = -speed * 0.5 -- nothing under you: come down
	end
	lv.VectorVelocity = flat + Vector3.new(0, vertical, 0)

	-- Face the way you're going, leaning into it. Standing still, you keep facing where you were.
	if flat.Magnitude > 0.1 then
		align.CFrame = CFrame.lookAt(Vector3.zero, flat) * CFrame.Angles(-TILT, 0, 0)
	end
end

local function startRiding(character: Model, domain: string)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local style = T.styles[domain]
	if not humanoid or not root or not root:IsA("BasePart") or not style or connection then
		return
	end
	local a = Instance.new("Attachment")
	a.Name = "DomainTravel"
	a.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "DomainTravel"
	lv.Attachment0 = a
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = 1e6
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "DomainTravel"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = a
	align.MaxTorque = 1e6
	align.Responsiveness = 25
	local look = root.CFrame.LookVector
	align.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(look.X, 0, look.Z))
	align.Parent = root
	attachment, velocity, orientation = a, lv, align

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = false

	humanoid.AutoRotate = false
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	lift = 0
	riding:set(domain)
	connection = RunService.RenderStepped:Connect(function(dt)
		if not root.Parent or humanoid.Health <= 0 then
			stopRiding()
		elseif not root.Anchored then
			step(character, humanoid, root, style, params, dt)
		end
	end)
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
	Kit.dynamic(scope, { riding }, function(s)
		local domain = riding:get()
		local buttons = UserInputService.TouchEnabled or UserInputService.GamepadEnabled
		if domain == "" and not buttons then
			return
		end
		local panel: Frame = Kit.create(nil, "Frame", {
			Name = "TravelPanel",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -Theme.space.m, 1, -(Theme.minTouch * 6)),
			Size = UDim2.fromOffset(Theme.minTouch * 5, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = root,
		})
		s:add(panel)
		C.list("y", Theme.space.xs).Parent = panel
		if domain ~= "" then
			local style = T.styles[domain]
			C.text(string.format("%s · Space up · Shift down · Y stop", if style then style.name else "Travel"), "caption", {
				TextStrokeTransparency = 0.4,
				LayoutOrder = 1,
				Parent = panel,
			})
		end
		if buttons then
			local row: Frame = Kit.create(nil, "Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, Theme.minTouch),
				LayoutOrder = 2,
				Parent = panel,
			})
			C.list("x", Theme.space.xs).Parent = row
			C.button(if domain == "" then "Travel" else "Stop", toggle, { kind = "ghost" }, { Size = UDim2.fromOffset(Theme.minTouch + 24, Theme.minTouch), LayoutOrder = 1 }).Parent = row
			if domain ~= "" then
				holdButton(row, "▲", 2, function(on)
					touchUp = on
				end)
				holdButton(row, "▼", 3, function(on)
					touchDown = on
				end)
			end
		end
	end)
end

-- ─── Everyone riding ────────────────────────────────────────────────────────

local function watchCharacter(character: Model, mine: boolean)
	local function changed()
		local domain = character:GetAttribute("TravelStyle")
		if typeof(domain) == "string" then
			TravelFx.apply(character, domain)
			if mine then
				startRiding(character, domain)
			end
		else
			TravelFx.clear(character)
			if mine and connection then
				stopRiding()
			end
		end
	end
	character:GetAttributeChangedSignal("TravelStyle"):Connect(changed)
	character.Destroying:Connect(function()
		TravelFx.clear(character)
	end)
	changed()
end

local function watchPlayer(player: Player)
	local mine = player == localPlayer
	player.CharacterAdded:Connect(function(character)
		if mine and connection then
			stopRiding()
		end
		watchCharacter(character, mine)
	end)
	if player.Character then
		watchCharacter(player.Character, mine)
	end
end

function TravelClient.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	interface:registerLayer({ id = "Travel", build = buildLayer })
end

function TravelClient.start(_self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and not interface:isInputBlocked() and Controls.matches("travel", input) then
			toggle()
		end
	end)
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return TravelClient
