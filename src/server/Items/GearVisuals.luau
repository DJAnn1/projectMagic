--!strict
--[[
	GearVisuals: equipped gear shown on the character, built from generated Parts (no assets
	needed) and welded to the standard body attachments (docs/Items.md §3.4; the same names on R6 and R15).

		GearVisuals.dress(character, slot, rec?)   (re)builds one slot; nil removes it
		GearVisuals.dressAll(character, equip)      every slot (on spawn)

	Each ItemDef.model.shape names a builder below: a list of pieces, each a size, an offset from
	the anchor, an optional part shape and colour. Held items (main hand, off hand) are placed
	from the hand's grip attachment position, pointing forward the way a held tool does; worn
	items use their attachment's full frame.

	All parts are Massless, non-colliding, non-queryable and non-touchable, so gear never changes
	movement, raycasts or hit detection. They live in a "ItemGear" folder in the character and die
	with it. Part counts are 1-5 per item; the torch, orb and hourglass add one PointLight each.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemRules = require(Shared.Items.Data.ItemRules)

type Piece = {
	size: Vector3,
	offset: CFrame,
	shape: Enum.PartType?,
	color: Color3?, -- nil = the item's colour
	material: Enum.Material?,
	transparency: number?,
	light: boolean?, -- carries the item's glow
}

local FOLDER = "ItemGear"
local HELD: { [string]: boolean } = { mainHand = true, offHand = true }

local METAL = Color3.fromRGB(170, 170, 178)
local WOOD = Color3.fromRGB(110, 80, 50)

-- Held pieces are laid out along +Y from the grip; the grip frame then turns +Y forward.
local function along(y: number): CFrame
	return CFrame.new(0, y, 0)
end

local BUILDERS: { [string]: { Piece } } = {
	sword = {
		{ size = Vector3.new(0.25, 1, 0.25), offset = along(0), color = WOOD, material = Enum.Material.Wood },
		{ size = Vector3.new(1, 0.15, 0.3), offset = along(0.55), color = METAL, material = Enum.Material.Metal },
		{ size = Vector3.new(0.3, 3, 0.08), offset = along(2.1) },
	},
	dagger = {
		{ size = Vector3.new(0.2, 0.6, 0.2), offset = along(0) },
		{ size = Vector3.new(0.22, 1.2, 0.06), offset = along(0.9), color = Color3.fromRGB(235, 228, 205) },
	},
	spear = {
		{ size = Vector3.new(0.2, 6, 0.2), offset = along(1.5) },
		{ size = Vector3.new(0.3, 0.9, 0.08), offset = along(4.9), color = METAL, material = Enum.Material.Metal },
	},
	axe = {
		{ size = Vector3.new(0.22, 3, 0.22), offset = along(0.8) },
		{ size = Vector3.new(0.1, 0.8, 1), offset = along(2.1) * CFrame.new(0, 0, -0.4), color = METAL, material = Enum.Material.Metal },
	},
	pickaxe = {
		{ size = Vector3.new(0.22, 3, 0.22), offset = along(0.8), color = WOOD, material = Enum.Material.Wood },
		{ size = Vector3.new(0.18, 0.25, 2.2), offset = along(2.25) },
	},
	sickle = {
		{ size = Vector3.new(0.2, 0.9, 0.2), offset = along(0), color = WOOD, material = Enum.Material.Wood },
		{ size = Vector3.new(0.08, 0.25, 1.2), offset = along(0.7) * CFrame.new(0, 0, -0.45) },
	},
	bow = {
		{ size = Vector3.new(0.15, 4, 0.15), offset = CFrame.Angles(math.rad(90), 0, 0) * CFrame.new(0, 0, 0.1) },
		{ size = Vector3.new(0.03, 3.9, 0.03), offset = CFrame.Angles(math.rad(90), 0, 0) * CFrame.new(0, 0, 0.5), color = Color3.fromRGB(230, 230, 220) },
	},
	crossbow = {
		{ size = Vector3.new(0.3, 2.2, 0.3), offset = along(0.9), color = WOOD, material = Enum.Material.Wood },
		{ size = Vector3.new(2.4, 0.15, 0.15), offset = along(1.8), color = WOOD, material = Enum.Material.Wood },
		{ size = Vector3.new(2.3, 0.03, 0.03), offset = along(1.55), color = Color3.fromRGB(230, 230, 220) },
	},
	rod = {
		{ size = Vector3.new(0.12, 6, 0.12), offset = along(2.5) },
	},
	wand = {
		{ size = Vector3.new(0.12, 1.4, 0.12), offset = along(0.4) },
		{ size = Vector3.new(0.16, 0.2, 0.16), offset = along(1.15), color = Color3.fromRGB(196, 120, 70), material = Enum.Material.Metal },
	},
	staff = {
		-- Held upright: the grip frame for "staff" skips the forward turn (see uprightShapes).
		{ size = Vector3.new(0.25, 6, 0.25), offset = along(1.2) },
		{ size = Vector3.new(0.6, 0.6, 0.6), offset = along(4.4), shape = Enum.PartType.Ball, color = Color3.fromRGB(150, 210, 120), material = Enum.Material.Neon, transparency = 0.3 },
	},
	orb = {
		{ size = Vector3.new(0.9, 0.9, 0.9), offset = along(0.3), shape = Enum.PartType.Ball, material = Enum.Material.Glass, transparency = 0.2, light = true },
	},
	tome = {
		{ size = Vector3.new(0.9, 0.25, 1.2), offset = along(0.3) },
		{ size = Vector3.new(0.85, 0.2, 1.1), offset = along(0.3) * CFrame.new(0.03, 0, 0), color = Color3.fromRGB(235, 225, 200), material = Enum.Material.SmoothPlastic },
	},
	torch = {
		{ size = Vector3.new(0.2, 1.8, 0.2), offset = along(0.3) },
		{ size = Vector3.new(0.35, 0.4, 0.35), offset = along(1.35), color = Color3.fromRGB(255, 160, 60), material = Enum.Material.Neon, light = true },
	},
	hourglass = {
		{ size = Vector3.new(0.7, 0.1, 0.7), offset = along(0), shape = Enum.PartType.Cylinder },
		{ size = Vector3.new(0.5, 0.5, 0.5), offset = along(0.3), shape = Enum.PartType.Ball, material = Enum.Material.Glass, transparency = 0.4, light = true },
		{ size = Vector3.new(0.5, 0.5, 0.5), offset = along(0.75), shape = Enum.PartType.Ball, material = Enum.Material.Glass, transparency = 0.4 },
		{ size = Vector3.new(0.7, 0.1, 0.7), offset = along(1.05), shape = Enum.PartType.Cylinder },
	},

	-- Worn (offsets in the attachment's frame).
	cap = { { size = Vector3.new(1.25, 0.45, 1.25), offset = CFrame.new(0, -0.15, 0) } },
	helm = {
		{ size = Vector3.new(1.35, 0.6, 1.35), offset = CFrame.new(0, -0.2, 0) },
		{ size = Vector3.new(0.1, 0.4, 0.1), offset = CFrame.new(0, 0.3, 0), color = Color3.fromRGB(240, 230, 200), material = Enum.Material.SmoothPlastic },
	},
	plate = { { size = Vector3.new(1.9, 1.5, 0.25), offset = CFrame.new(0, -0.1, -0.05) } },
	robe = { { size = Vector3.new(1.95, 1.6, 0.2), offset = CFrame.new(0, -0.15, -0.05) } },
	apron = { { size = Vector3.new(1.4, 2.4, 0.12), offset = CFrame.new(0, -0.6, -0.05) } },
	cloak = { { size = Vector3.new(2, 3.2, 0.12), offset = CFrame.new(0, -1.1, 0.1) } },
	belt = { { size = Vector3.new(2.05, 0.25, 1.1), offset = CFrame.new(0, 0, 0) } },
	amulet = {
		{ size = Vector3.new(0.3, 0.3, 0.1), offset = CFrame.new(0, -0.5, -0.55), material = Enum.Material.Glass },
	},
	charm = { { size = Vector3.new(0.3, 0.4, 0.15), offset = CFrame.new(0.5, -0.1, 0.1) } },
}

-- Shapes held upright (no forward turn) and how far below the hand they reach.
local uprightShapes: { [string]: boolean } = { staff = true, torch = true, hourglass = true, orb = true, tome = true }

local function holderOf(character: Model): Folder
	local folder = character:FindFirstChild(FOLDER)
	if folder and folder:IsA("Folder") then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER
	f.Parent = character
	return f
end

local function findAttachment(character: Model, name: string): Attachment?
	for _, d in character:GetDescendants() do
		if d.Name == name and d:IsA("Attachment") and d.Parent and d.Parent:IsA("BasePart") and not d:IsDescendantOf(holderOf(character)) then
			return d
		end
	end
	return nil
end

local function build(character: Model, slot: string, def: ItemTypes.ItemDef)
	local model = def.model
	local slotDef = ItemRules.slotById[slot]
	if not model or model.shape == "none" or not slotDef or not slotDef.attach then
		return
	end
	local pieces = BUILDERS[model.shape]
	if not pieces then
		return
	end
	local attachment = findAttachment(character, slotDef.attach)
	if not attachment then
		return
	end
	local anchor = attachment.Parent :: BasePart
	local base: CFrame
	if HELD[slot] then
		-- From the grip point: forward like a held tool, or upright for staffs and lights.
		base = CFrame.new(attachment.Position) * (if uprightShapes[model.shape] then CFrame.new(0, -0.3, 0) else CFrame.Angles(-math.pi / 2, 0, 0))
	else
		base = attachment.CFrame
	end

	local group = Instance.new("Model")
	group.Name = "Gear_" .. slot
	for i, piece in pieces do
		local part = Instance.new("Part")
		part.Name = def.id .. "_" .. i
		part.Size = piece.size
		part.Shape = piece.shape or Enum.PartType.Block
		part.Color = piece.color or model.color or def.color
		part.Material = piece.material or model.material or Enum.Material.SmoothPlastic
		part.Transparency = piece.transparency or 0
		part.Massless = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Anchored = false
		part.CFrame = anchor.CFrame * base * piece.offset
		local weld = Instance.new("Weld")
		weld.Part0 = anchor
		weld.Part1 = part
		weld.C0 = base * piece.offset
		weld.Parent = part
		if piece.light and model.glow then
			local light = Instance.new("PointLight")
			light.Color = model.glow
			light.Range = 14
			light.Brightness = 1.4
			light.Shadows = false
			light.Parent = part
		end
		part.Parent = group
	end
	group.Parent = holderOf(character)
end

local GearVisuals = {}

function GearVisuals.dress(character: Model, slot: string, rec: ItemTypes.Record?)
	local holder = holderOf(character)
	local existing = holder:FindFirstChild("Gear_" .. slot)
	if existing then
		existing:Destroy()
	end
	local def = rec and ItemDatabase.get(rec.i)
	if def then
		build(character, slot, def)
	end
end

function GearVisuals.dressAll(character: Model, equip: { [string]: ItemTypes.Record })
	for _, slot in ItemRules.equipSlots do
		GearVisuals.dress(character, slot.id, equip[slot.id])
	end
end

-- The item id currently shown per slot (to skip rebuilding unchanged slots).
function GearVisuals.shown(character: Model): { [string]: string }
	local out: { [string]: string } = {}
	local holder = character:FindFirstChild(FOLDER)
	if holder then
		for _, group in holder:GetChildren() do
			local slot = string.match(group.Name, "^Gear_(.+)$")
			local first = group:GetChildren()[1]
			if slot and first then
				out[slot] = string.match(first.Name, "^(.+)_%d+$") or ""
			end
		end
	end
	return out
end

return GearVisuals
