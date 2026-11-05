--!strict
--[[
	SlashFx: the crescent a melee swing leaves in the air (spellblade and weapon swings alike).
	Purely visual and local: Controllers/SlashFxController calls `arc` when a character's server
	action state becomes "slashing".

	HOW IT'S DRAWN
		A thin invisible Part lies in the SWING PLANE in front of the body (tilted per clip: Slash1
		cuts down from the right, Slash2 back from the left). A SurfaceGui on its top and bottom faces
		holds two ImageLabels with the slash texture: a wide one in the primary colour and a thin
		white-hot one inside it. SurfaceGui (not a particle) because a particle's in-plane rotation
		can't be pinned to the swing; the GUI's can. LightInfluence 0 + Brightness > 1 makes it glow
		(and bloom picks it up). Over ~0.2 s it sweeps through the cut, grows and fades.

	TUNING
		CLIPS          per clip: texture role, plane tilt (degrees, + = right side up), sweep direction
		CANVAS_TURN    in-plane turn so the crescent bulges AWAY from the body. The Kenney slashes
		               bulge toward the image's bottom; if arcs ever curve toward the swinger, change
		               this by 180.
		MAX_LIVE       concurrent arcs on this client; past it a swing draws none.
]]

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

local TEX = DomainFx.textures

local MAX_LIVE = 16
local CANVAS_TURN = 180

type Clip = { texture: string, tilt: number, sweep: number }

local CLIPS: { [string]: Clip } = {
	Slash1 = { texture = TEX.slash1, tilt = 32, sweep = 1 },
	Slash2 = { texture = TEX.slash2, tilt = -28, sweep = -1 },
}
-- Unknown clips alternate between these by swing number.
local FALLBACK: { Clip } = {
	{ texture = TEX.slash3, tilt = 20, sweep = 1 },
	{ texture = TEX.slash4, tilt = -20, sweep = -1 },
}

export type ArcOpts = {
	clip: string?,
	swing: number, -- the state's seq (picks a fallback clip)
	primary: Color3,
	secondary: Color3,
	glow: boolean, -- magic blades glow hard; steel only gleams
	reach: number, -- studs from the body to the edge of the cut
	duration: number, -- how long the arc lingers
}

local SlashFx = {}

local live = 0
local folder: Folder? = nil

local function container(): Folder
	if folder and folder.Parent then
		return folder
	end
	local existing = workspace:FindFirstChild("SlashFx")
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "SlashFx"
	f.Parent = workspace
	folder = f
	return f
end

local function image(parent: Instance, texture: string, color: Color3, scale: number, z: number): ImageLabel
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(scale, scale)
	label.Image = texture
	label.ImageColor3 = color
	label.Rotation = CANVAS_TURN
	label.ZIndex = z
	label.Parent = parent
	return label
end

-- One crescent in front of `root`. Returns false when the budget is spent.
function SlashFx.arc(root: BasePart, opts: ArcOpts): boolean
	if live >= MAX_LIVE then
		return false
	end
	local clip = (if opts.clip then CLIPS[opts.clip] else nil) or FALLBACK[(opts.swing % #FALLBACK) + 1]
	local reduced = Theme.settings.reducedEffects == true

	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis
	local size = opts.reach * 2
	local centre = root.Position + flat * (opts.reach * 0.45) + Vector3.new(0, 0.6, 0)
	-- Facing forward, then rolled around the facing axis: the Top face's normal is the plane's.
	local plane = CFrame.lookAt(centre, centre + flat) * CFrame.Angles(0, 0, math.rad(clip.tilt))

	local part = Instance.new("Part")
	part.Name = "Slash"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(size, 0.05, size)
	part.CFrame = plane

	local labels: { ImageLabel } = {}
	for _, face in { Enum.NormalId.Top, Enum.NormalId.Bottom } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.LightInfluence = 0
		gui.Brightness = if opts.glow then 2.5 else 1.4
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 24
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = part
		table.insert(labels, image(gui, clip.texture, opts.primary, 1, 1))
		if not reduced then
			table.insert(labels, image(gui, clip.texture, FxLayers.whiten(opts.secondary, 0.75), 0.86, 2))
		end
	end
	part.Parent = container()
	live += 1

	local sweep = clip.sweep
	FxLayers.animate(opts.duration, function(t)
		-- Sweeps through the cut (fast, then easing), grows a little, fades from the start's end.
		local eased = 1 - (1 - t) ^ 2
		for i, label in labels do
			local inner = i % 2 == 0
			label.Rotation = CANVAS_TURN + sweep * (-30 + 45 * eased)
			local s = (if inner then 0.86 else 1) * (0.85 + 0.25 * eased)
			label.Size = UDim2.fromScale(s, s)
			label.ImageTransparency = math.clamp(t ^ 1.4 + (if inner then 0.1 else 0), 0, 1)
		end
	end, function()
		live -= 1
		part:Destroy()
	end)
	return true
end

return SlashFx
