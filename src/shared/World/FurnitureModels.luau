--!strict
--[[
	FurnitureModels: placeable furniture drawn from Parts (docs/Buildings.md §8). Shared, so the
	server builds the real piece and the client builds the placement ghost from the same code.

		FurnitureModels.build(shape, color) -> Model   pivot = the floor point under its centre
		FurnitureModels.info(shape) -> { parts, footprint: Vector3, light: boolean }

	Shapes match ItemDef.data.furniture. Every part is Anchored with CanTouch off; rugs don't
	collide. The lantern carries a PointLight (Enabled; the housing budget caps lanterns per house).
]]

type Piece = { size: Vector3, at: CFrame, color: Color3?, material: Enum.Material?, shape: Enum.PartType?, collide: boolean?, light: boolean? }
type Shape = { footprint: Vector3, pieces: { Piece } }

local WOOD = Enum.Material.Wood

local SHAPES: { [string]: Shape } = {
	stool = {
		footprint = Vector3.new(1.6, 1.8, 1.6),
		pieces = {
			{ size = Vector3.new(1.6, 0.3, 1.6), at = CFrame.new(0, 1.65, 0) },
			{ size = Vector3.new(0.5, 1.5, 0.5), at = CFrame.new(0, 0.75, 0) },
		},
	},
	table = {
		footprint = Vector3.new(4.2, 3.2, 3.2),
		pieces = {
			{ size = Vector3.new(4.2, 0.4, 3.2), at = CFrame.new(0, 3, 0) },
			{ size = Vector3.new(0.5, 2.8, 0.5), at = CFrame.new(-1.7, 1.4, -1.2) },
			{ size = Vector3.new(0.5, 2.8, 0.5), at = CFrame.new(1.7, 1.4, -1.2) },
			{ size = Vector3.new(0.5, 2.8, 0.5), at = CFrame.new(-1.7, 1.4, 1.2) },
			{ size = Vector3.new(0.5, 2.8, 0.5), at = CFrame.new(1.7, 1.4, 1.2) },
		},
	},
	rug = {
		footprint = Vector3.new(6, 0.1, 4),
		pieces = {
			{ size = Vector3.new(6, 0.1, 4), at = CFrame.new(0, 0.05, 0), material = Enum.Material.Fabric, collide = false },
			{ size = Vector3.new(5, 0.11, 3), at = CFrame.new(0, 0.06, 0), material = Enum.Material.Fabric, collide = false, color = Color3.fromRGB(220, 190, 120) },
		},
	},
	bookcase = {
		footprint = Vector3.new(3.6, 6, 1.2),
		pieces = {
			{ size = Vector3.new(3.6, 6, 1.2), at = CFrame.new(0, 3, 0) },
			{ size = Vector3.new(3.2, 1.2, 0.2), at = CFrame.new(0, 4.4, -0.55), material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(150, 60, 52), collide = false },
			{ size = Vector3.new(3.2, 1.2, 0.2), at = CFrame.new(0, 2.2, -0.55), material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(60, 90, 140), collide = false },
		},
	},
	fern = {
		footprint = Vector3.new(1.6, 2.6, 1.6),
		pieces = {
			{ size = Vector3.new(1.2, 1.2, 1.2), at = CFrame.new(0, 0.6, 0), material = Enum.Material.Slate, color = Color3.fromRGB(150, 90, 60), shape = Enum.PartType.Cylinder },
			{ size = Vector3.new(1.8, 1.8, 1.8), at = CFrame.new(0, 1.8, 0), material = Enum.Material.Grass, shape = Enum.PartType.Ball, collide = false },
		},
	},
	lantern = {
		footprint = Vector3.new(1, 5, 1),
		pieces = {
			{ size = Vector3.new(0.3, 4.2, 0.3), at = CFrame.new(0, 2.1, 0), material = Enum.Material.Metal, color = Color3.fromRGB(60, 62, 68) },
			{ size = Vector3.new(0.9, 1, 0.9), at = CFrame.new(0, 4.6, 0), material = Enum.Material.Neon, light = true },
		},
	},
}

local FurnitureModels = {}

function FurnitureModels.has(shape: string): boolean
	return SHAPES[shape] ~= nil
end

function FurnitureModels.info(shape: string): { parts: number, footprint: Vector3, light: boolean }
	local s = SHAPES[shape]
	if not s then
		return { parts = 0, footprint = Vector3.zero, light = false }
	end
	local light = false
	for _, p in s.pieces do
		light = light or p.light == true
	end
	return { parts = #s.pieces, footprint = s.footprint, light = light }
end

function FurnitureModels.build(shape: string, color: Color3): Model
	local s = SHAPES[shape]
	assert(s, "FurnitureModels: unknown shape " .. tostring(shape))
	local model = Instance.new("Model")
	model.Name = shape
	for i, piece in s.pieces do
		local p = Instance.new("Part")
		p.Name = shape .. i
		p.Anchored = true
		p.CanTouch = false
		p.CanCollide = piece.collide ~= false
		p.Size = piece.size
		p.CFrame = piece.at
		p.Material = piece.material or WOOD
		p.Color = piece.color or color
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if piece.shape then
			p.Shape = piece.shape
			if piece.shape == Enum.PartType.Cylinder then
				p.CFrame = piece.at * CFrame.Angles(0, 0, math.pi / 2)
				p.Size = Vector3.new(piece.size.Y, piece.size.X, piece.size.Z)
			end
		end
		if piece.light then
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 200, 130)
			light.Range = 16
			light.Brightness = 1.2
			light.Shadows = false
			light.Parent = p
		end
		p.Parent = model
		if i == 1 then
			model.PrimaryPart = p
		end
	end
	model.WorldPivot = CFrame.identity
	return model
end

return FurnitureModels
