--!strict
--[[
	GuardFxController: the ward in front of anyone guarding, players and NPCs (docs/Combat.md
	§12). Cosmetic and local: the server sets character attributes (Cast/Guard) and every client
	draws from them, so no effect instances replicate.

		Guarding     domain id while raised: the ward's look (earth: a slate plate; water: a
		             rippling glass film; air: a pale shimmer; everything else: a hex-patterned
		             force field), in the caster's Signature colours
		GuardHitAt   a blocked hit: the ward flashes
		ParriedAt    a parry: a bright flash and "Parry!" over the head (a word, not just light)

	BUDGET  at most MAX_WARDS (nearest win; beyond RANGE nothing is drawn); one anchored,
	        non-colliding, non-queryable part each, moved every frame in front of its body.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local SpellFx = require(Client:WaitForChild("Fx").SpellFx)
local Theme = require(Client:WaitForChild("UI").Theme)
local Audio = require(Client:WaitForChild("Audio").Audio)

local MAX_WARDS = 16
local RANGE = 160
local OFFSET = CFrame.new(0, 0.4, -2.3) -- in front of the root, at chest height
local FLASH = 0.18 -- seconds a blocked-hit flash lasts
local PARRY_FLASH = 0.35

local GuardFxController = {
	name = "GuardFxController",
	dependencies = {},
}

type Look = { material: Enum.Material, size: Vector3, transparency: number, tint: Color3? }

local LOOKS: { [string]: Look } = {
	earth = { material = Enum.Material.Slate, size = Vector3.new(4.4, 5.4, 0.6), transparency = 0.1, tint = Color3.fromRGB(120, 100, 80) },
	water = { material = Enum.Material.Glass, size = Vector3.new(5, 6, 0.2), transparency = 0.55 },
	air = { material = Enum.Material.ForceField, size = Vector3.new(5.2, 6, 0.2), transparency = 0.2, tint = Color3.fromRGB(230, 240, 255) },
	-- A weapon block (GuardService: no spell readied): a faint steel glint, not a ward.
	steel = { material = Enum.Material.Glass, size = Vector3.new(3, 4.2, 0.1), transparency = 0.85, tint = Color3.fromRGB(205, 205, 215) },
}
local DEFAULT_LOOK: Look = { material = Enum.Material.ForceField, size = Vector3.new(5, 6, 0.25), transparency = 0 }

type Ward = {
	part: Part,
	root: BasePart,
	base: number, -- resting transparency
	flashUntil: number,
	parryUntil: number,
}

local wards: { [Model]: Ward } = {}
local folder: Folder? = nil

local function wardFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local created = Instance.new("Folder")
	created.Name = "GuardWards"
	created.Parent = workspace
	folder = created
	return created
end

local function styleFor(model: Model, domain: string)
	local player = Players:GetPlayerFromCharacter(model)
	local signature = model:GetAttribute("MagicSignature")
	return SpellFx.styleFor(if player then player.UserId else nil, domain, if typeof(signature) == "string" then signature else nil)
end

local function removeWard(model: Model)
	local ward = wards[model]
	if ward then
		ward.part:Destroy()
		wards[model] = nil
	end
end

local function count(): number
	local n = 0
	for _ in wards do
		n += 1
	end
	return n
end

local function addWard(model: Model, domain: string)
	removeWard(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or count() >= MAX_WARDS then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (root.Position - camera.CFrame.Position).Magnitude > RANGE then
		return
	end
	local look = LOOKS[domain] or DEFAULT_LOOK
	local part = Instance.new("Part")
	part.Name = "Ward"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = look.material
	part.Size = look.size
	part.Color = look.tint or styleFor(model, domain).primary
	part.Transparency = look.transparency
	part.CFrame = root.CFrame * OFFSET
	part.Parent = wardFolder()
	wards[model] = { part = part, root = root, base = look.transparency, flashUntil = 0, parryUntil = 0 }
end

local function parryText(model: Model)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(140, 36)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Adornee = head
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Text = "⛨ Parry!"
	text.TextScaled = true
	text.FontFace = Theme.font.bold
	text.TextColor3 = Theme.color.accent
	text.TextStrokeTransparency = 0.2
	text.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	task.delay(0.8, function()
		gui:Destroy()
	end)
end

local function watch(model: Model)
	local function refresh()
		local domain = model:GetAttribute("Guarding")
		if typeof(domain) == "string" and model.Parent then
			addWard(model, domain)
		else
			removeWard(model)
		end
	end
	model:GetAttributeChangedSignal("Guarding"):Connect(refresh)
	model:GetAttributeChangedSignal("GuardHitAt"):Connect(function()
		local ward = wards[model]
		if ward then
			ward.flashUntil = os.clock() + FLASH
			Audio.play("combat.block", { position = ward.root.Position })
		end
	end)
	model:GetAttributeChangedSignal("ParriedAt"):Connect(function()
		local ward = wards[model]
		if ward then
			ward.parryUntil = os.clock() + PARRY_FLASH
		end
		local root = model:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			Audio.play("combat.parry", { position = root.Position, volume = 1.2 })
		end
		parryText(model)
	end)
	model.AncestryChanged:Connect(function()
		if not model.Parent then
			removeWard(model)
		end
	end)
	refresh()
end

function GuardFxController.start(_self: any, _ctx: any)
	local function watchPlayer(player: Player)
		player.CharacterAdded:Connect(watch)
		if player.Character then
			watch(player.Character)
		end
	end
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	-- NPC rigs come and go with LOD (and are pooled): watch the folder.
	task.spawn(function()
		local npcs = workspace:WaitForChild("NPCs", 60)
		if not npcs then
			return
		end
		local watched: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
		local function onChild(child: Instance)
			if child:IsA("Model") and not watched[child] then
				watched[child] = true
				watch(child)
			end
		end
		npcs.ChildAdded:Connect(onChild)
		for _, child in npcs:GetChildren() do
			onChild(child)
		end
	end)

	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for model, ward in wards do
			if not ward.root.Parent then
				removeWard(model)
				continue
			end
			ward.part.CFrame = ward.root.CFrame * OFFSET
			if t < ward.parryUntil then
				ward.part.Transparency = 0
				ward.part.Material = Enum.Material.Neon
			elseif t < ward.flashUntil then
				ward.part.Transparency = math.max(0, ward.base - 0.3)
			else
				ward.part.Transparency = ward.base
				local domain = model:GetAttribute("Guarding")
				local look = LOOKS[if typeof(domain) == "string" then domain else ""] or DEFAULT_LOOK
				ward.part.Material = look.material
			end
		end
	end)
end

return GuardFxController
