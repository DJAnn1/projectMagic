--!strict
--[[
	HousingController: your house, and placing furniture in it (docs/Buildings.md §8).

	state      HousingState pushes: { lot, name, built, lotCFrame, interiorCFrame, interiorSize,
	           floorY, decor, decorMax, parts, partsMax } or nil when you own nothing
	placement  startPlacement(ref): from the Inventory screen ("Place" on a furniture item, while
	           your house is built on this server). The screen closes and a see-through ghost of the
	           piece follows the mouse (keyboard) or the screen centre (touch, gamepad), snapped to
	           half-stud steps on the floor. Its outline says whether it fits (✓ fits / ✗ won't fit;
	           also in words on the overlay).
	             R / Rotate      turn 15 degrees
	             click / Place   PlaceDecor(ref, x, z, r): the server checks everything again
	             Q, Esc / Cancel stop
	           The overlay (a HUD layer) has the three buttons for every input.
	Placed pieces have a "Pick up" prompt (the server only lets the owner take them).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local FurnitureModels = require(Shared.World.FurnitureModels)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

type Placing = { ref: string, itemId: string, shape: string, r: number, x: number, z: number, fits: boolean }

local HousingController = {
	name = "HousingController",
	dependencies = { "InterfaceController", "MagicStateController", "ItemStateController" },
}

local H = HousingController
H.state = Kit.value(nil :: any)
H.placing = Kit.value(nil :: Placing?)

local interface: any = nil
local magic: any = nil
local items: any = nil
local ghost: Model? = nil
local outline: SelectionBox? = nil
local stepConnection: RBXScriptConnection? = nil
local busy = false

local function stop()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	outline = nil
	H.placing:set(nil)
end

-- Can this piece go here? (The server re-checks: inside the rooms, with a margin of half the footprint.)
local function fits(state: any, pose: CFrame, footprint: Vector3): boolean
	local cf, size = state.interiorCFrame, state.interiorSize
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return false
	end
	local l = cf:PointToObjectSpace(pose.Position)
	local margin = math.max(footprint.X, footprint.Z) / 2
	return math.abs(l.X) <= size.X / 2 - margin and math.abs(l.Z) <= size.Z / 2 - margin and footprint.Y <= size.Y
end

local function aimPoint(): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local screen = if interface.inputMode:get() == "Keyboard" then UserInputService:GetMouseLocation() else camera.ViewportSize / 2
	local ray = camera:ViewportPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	if ghost then
		table.insert(exclude, ghost)
	end
	if Players.LocalPlayer.Character then
		table.insert(exclude, Players.LocalPlayer.Character)
	end
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 200, params)
	return hit and hit.Position
end

local function step()
	local p = H.placing:get()
	local state = H.state:get()
	if not p or not state or not ghost or typeof(state.lotCFrame) ~= "CFrame" then
		return
	end
	local point = aimPoint()
	if not point then
		return
	end
	local lot: CFrame = state.lotCFrame
	local l = lot:PointToObjectSpace(point)
	local x, z = math.floor(l.X * 2 + 0.5) / 2, math.floor(l.Z * 2 + 0.5) / 2
	local flat = lot * CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(p.r * 15), 0)
	local pose = CFrame.new(flat.Position.X, state.floorY, flat.Position.Z) * flat.Rotation
	ghost:PivotTo(pose)
	local ok = fits(state, pose, FurnitureModels.info(p.shape).footprint)
	if outline then
		outline.Color3 = if ok then Theme.color.good else Theme.color.danger
	end
	if x ~= p.x or z ~= p.z or ok ~= p.fits then
		H.placing:set({ ref = p.ref, itemId = p.itemId, shape = p.shape, r = p.r, x = x, z = z, fits = ok })
	end
end

function H.rotate(_self: any)
	local p = H.placing:get()
	if p then
		H.placing:set({ ref = p.ref, itemId = p.itemId, shape = p.shape, r = (p.r + 1) % 24, x = p.x, z = p.z, fits = p.fits })
	end
end

function H.confirm(_self: any)
	local p = H.placing:get()
	if not p or busy then
		return
	end
	if not p.fits then
		magic.events:Fire({ kind = "notify", text = items:reasonText("OUTSIDE") })
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = Net.invoke("PlaceDecor", p.ref, p.x, p.z, p.r)
		busy = false
		if ok and typeof(result) == "table" and result.ok then
			stop()
		else
			magic.events:Fire({ kind = "notify", text = items:reasonText(if typeof(result) == "table" then result.reason else nil) })
		end
	end)
end

function H.cancel(_self: any)
	stop()
end

-- Whether a furniture item can be placed right now (your house is built on this server).
function H.canPlace(_self: any): boolean
	local state = H.state:get()
	return state ~= nil and state.built == true
end

function H.startPlacement(_self: any, ref: string)
	local state = H.state:get()
	local view = items:find(ref)
	local def = view and ItemDatabase.get(view.rec.i)
	local shape = def and def.data and def.data.furniture
	if not state or not state.built or not def or typeof(shape) ~= "string" or not FurnitureModels.has(shape) then
		magic.events:Fire({ kind = "notify", text = items:reasonText(if not state then "NO_HOUSE" else "NOT_FURNITURE") })
		return
	end
	stop()
	interface:close()
	local model = FurnitureModels.build(shape, (def :: any).color)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = 0.5
			d.CanCollide = false
			d.CanQuery = false
		elseif d:IsA("PointLight") then
			d.Enabled = false
		end
	end
	local box = Instance.new("SelectionBox")
	box.Adornee = model
	box.LineThickness = 0.06
	box.Color3 = Theme.color.good
	box.Parent = model
	model.Parent = workspace
	ghost, outline = model, box
	H.placing:set({ ref = ref, itemId = (def :: any).id, shape = shape, r = 0, x = 0, z = 0, fits = false })
	stepConnection = RunService.RenderStepped:Connect(step)
end

-- The overlay: what's being placed, whether it fits, and the three buttons.
local function buildOverlay(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { H.placing, H.state }, function(s)
		local p = H.placing:get()
		if not p then
			return
		end
		local state = H.state:get()
		local def = ItemDatabase.get(p.itemId)
		local panel = C.panel({
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -150),
			Size = UDim2.fromOffset(440, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = Theme.glass,
			Parent = root,
		})
		s:add(panel)
		C.padding(Theme.space.s).Parent = panel
		C.list("y", Theme.space.xs).Parent = panel
		C.text(string.format("Placing %s %s", if def then def.name else p.itemId, if p.fits then "✓ fits here" else "✗ won't fit here"), "label", {
			TextColor3 = if p.fits then Theme.color.good else Theme.color.danger, LayoutOrder = 1, Parent = panel,
		})
		if state then
			C.text(string.format("Furniture %d / %d · parts %d / %d", state.decor or 0, state.decorMax or 0, state.parts or 0, state.partsMax or 0), "caption", {
				TextColor3 = Theme.color.inkDim, LayoutOrder = 2, Parent = panel,
			})
		end
		local row: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 3, Parent = panel })
		C.list("x", Theme.space.s).Parent = row
		local keyboard = interface.inputMode:get() == "Keyboard"
		local buttons: { { text: string, kind: string, run: () -> () } } = {
			{ text = if keyboard then "Rotate [R]" else "Rotate", kind = "secondary", run = function() H:rotate() end },
			{ text = if keyboard then "Place [click]" else "Place", kind = "primary", run = function() H:confirm() end },
			{ text = if keyboard then "Cancel [Q]" else "Cancel", kind = "ghost", run = function() H:cancel() end },
		}
		for i, entry in buttons do
			local b = C.button(entry.text, entry.run, { kind = entry.kind }, { Size = UDim2.fromOffset(130, Theme.minTouch), LayoutOrder = i })
			b.Parent = row
		end
	end)
end

function HousingController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	items = ctx.get("ItemStateController")
	interface:registerLayer({ id = "Placement", build = buildOverlay })
end

function HousingController.start(_self: any, _ctx: any)
	Net.listen("HousingState", function(state)
		if typeof(state) ~= "table" or state.lot == nil then
			H.state:set(nil)
			stop()
			return
		end
		H.state:set(state, true)
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not H.placing:get() or processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			H:rotate()
		elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.Escape then
			H:cancel()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			H:confirm()
		end
	end)
	-- Opening any screen cancels placement (it can't be aimed through a menu).
	interface.openScreen:observe(function(id)
		if id ~= nil then
			stop()
		end
	end)
end

return HousingController
