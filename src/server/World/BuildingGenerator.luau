--!strict
--[[
	BuildingGenerator: builds a complete building from Parts and WedgeParts, seeded. No assets.

		BuildingGenerator.supports(kind) -> boolean
		BuildingGenerator.build(spec) -> (Model?, partCount, error?)
		spec = { kind, cframe, w, d, seed, culture, name, settlementId, lotId, drop?, path?, parent? }
		    cframe  the lot: ground level at its centre, LookVector = the street the front faces
		    w, d    the lot footprint; the building is generated to fit inside it

	KINDS (typical part counts; all under budget)
	  house_small    one room: bed, chest, table, chairs, shelf, rug; chimney by culture (~60)
	  house_medium   a partition with a doorway, two beds, a table for four (~80)
	  house_large    two storeys with stairs, three beds upstairs, chimney (~120)
	  smithy         wide open front, forge with glowing coals (a light) and a stack, anvil,
	                 quench trough, tool rack, ingots (~70)
	  tavern         two storeys, bar, barrels, three tables, hearth, lantern (a light), rooms
	                 upstairs, a hanging sign with a seeded name (SurfaceGui) (~140)
	  market_stall   four posts, sloped canvas, counter with goods, crate, barrel (~16)
	  well           octagonal stone ring, water, posts, crossbeam, bucket, little roof (~18)
	  watchtower     stone pillars, walled base, climbable truss to a hatch, crenellated
	                 platform, roof, brazier (a light) (~45)
	  barn           wide doorway with open double doors, steep roof, stalls, hay, trough (~60)
	  magic_school   tall hall (domed for flat-roof cultures), stone tower with a stepped cap
	                 and a floating crystal (a light), lectern, benches, bookcases, orb (~90)
	  shrine         stepped platform, pillars, gabled roof or dome, altar, bowl, crystal (~20)
	Lights come from a server-wide budget (setLightBudget, default 160). Out of budget, the
	Neon glow stays and only the PointLight is skipped.

	EVERY BUILDING
	  * one Model named <Kind>_<NN>, PrimaryPart = the foundation, ModelStreamingMode = Atomic
	    (it streams in and out whole), every part Anchored, CanTouch off
	  * a collidable Floor slab over the whole footprint (tag "BuildingFloor"), FLOOR_SLAB thick,
	    its top flush with the foundation at FLOOR_Y above the lot's levelled ground. The terrain
	    under it is grass-free stone ending FoundationBuilder.FILL_DROP BELOW the ground level,
	    so it can never reach the slab's bottom (Buildings.spec checks the numbers agree)
	  * a Foundation plinth (the PrimaryPart) showing ~1.75 studs above the ground, reaching
	    down to the lowest ground under the lot on slopes (spec.drop), and door steps of at most
	    STEP_RISE each from the ground up to the threshold, so nobody has to jump
	  * real openings: walls are built as segments around doors and windows (columns, sills,
	    lintels), never one block
	  * a working front door (tags "Door" + "Interactable"): closed and collidable, with its
	    closed/open CFrames, lock state and key id as attributes; Server/Interact/Doors swings it
	  * interactables (tag "Interactable", attribute Interactable = a Shared/World/Interactables
	    kind, InteractId = "<lotId>:<kind><n>", deterministic): beds (a Seat), chests, barrels,
	    crates, the smithy forge. Services/InteractionService gives them prompts and behaviour.
	  * attributes InteriorCFrame / InteriorSize: the room volume above the floor, which
	    SettlementService keeps free of terrain; Access = "private" (houses) or "public";
	    LotCFrame (housing places furniture relative to it)
	  * more interactables (docs/Buildings.md §3): lamps and fireplaces (lights off until dusk:
	    Interact/Lamps), cooking hearths, bookshelves, wardrobes, workbench and loom (barns, large
	    houses), alchemy table, enchanting desk, training dummy, meditation mats and a focus
	    crystal (magic schools), a ward stone and mat (shrines), the well, a notice board (taverns)
	  * Attachments tagged "NPCSeat" on every stool and bench (leisure points for NPC schedules)
	  * culture palette (SettlementStyles) with seeded variation in size, colour and details
	  * CollectionService tags "Building", "Structure" (quakes damage it: WorldStateService) and
	    the kind's tag ("House"); attributes BuildingType, Culture, SettlementId, LotId,
	    OwnerNPCId (filled by the NPC system), Integrity, Robustness
	  * Attachments on the PrimaryPart tagged "NPCHome" (one per bed), "NPCWork" (where the job
	    is done) and "BuildingEntrance" (outside the door), each with a BuildingId attribute
]]

local CollectionService = game:GetService("CollectionService")

local Styles = require(script.Parent.SettlementStyles)

local T = 1 -- wall thickness
local FLOOR_Y = 1.5 -- foundation top above the lot's ground level; the floor top is 0.05 above it
local FLOOR_SLAB = 1.2 -- floor thickness: it sits inside the plinth, its bottom well above the terrain
local STEP_RISE = 0.6 -- door steps: at most this much each (Humanoids walk up it without jumping)
local STEP_DEPTH = 1.2
local GROUND_Y = -0.25 -- the yard's terrain top (FoundationBuilder.FILL_DROP below the lot level)
local DOOR = { w = 4, h = 7.5 }
local WINDOW = { w = 3, bottom = 3.5, top = 7 }
local FABRICS = {
	Color3.fromRGB(150, 60, 52), Color3.fromRGB(60, 90, 140), Color3.fromRGB(90, 120, 70),
	Color3.fromRGB(170, 140, 80), Color3.fromRGB(120, 80, 130), Color3.fromRGB(200, 196, 180),
}

local WOOD_MATERIAL = Enum.Material.Wood

local BuildingGenerator = {}

type Opening = { u: number, w: number, bottom: number, top: number, door: boolean? }

type Builder = {
	model: Model,
	base: CFrame,
	rng: Random,
	style: Styles.Culture,
	parts: number,
	lotId: string,
	drop: number, -- how far the lot's lowest ground lies below its level (plinths reach down)
	counts: { [string]: number }, -- interactables per kind (InteractId numbering)
	seats: { CFrame }, -- lot-local NPC seat points, attached to the primary part at the end
}

-- ─── Primitives ─────────────────────────────────────────────────────────────

local function vary(rng: Random, color: Color3, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.clamp(s + rng:NextNumber(-amount, amount) * 0.5, 0, 1), math.clamp(v + rng:NextNumber(-amount, amount), 0, 1))
end

-- A part at `offset` (lot-local CFrame), sized, styled. Returns it.
local function part(b: Builder, name: string, size: Vector3, offset: CFrame, material: Enum.Material, color: Color3, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local p: BasePart = if o.wedge then Instance.new("WedgePart") else Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	p.Size = size
	p.CFrame = b.base * offset
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if o.collide == false then
		p.CanCollide = false
		p.CanQuery = o.query == true
	end
	if o.transparency then
		p.Transparency = o.transparency
	end
	if o.small then
		p.CastShadow = false
	end
	if o.cylinder then
		(p :: Part).Shape = Enum.PartType.Cylinder -- the axis is local X
	end
	p.Parent = b.model
	b.parts += 1
	return p
end

--[[
	A wall with openings. `center` is the wall's bottom centre (lot-local), `alongX` says whether
	it runs along local X (front/back) or Z (sides); `length` runs along it, openings are given
	by their offset `u` from the centre along it. Builds full-height columns between openings,
	a sill under each window and a lintel over every opening, plus glass in the windows.
]]
local function wall(b: Builder, name: string, center: Vector3, alongX: boolean, length: number, height: number, openings: { Opening }, swatch: Styles.Swatch, color: Color3)
	table.sort(openings, function(x, y)
		return x.u < y.u
	end)
	local function piece(label: string, from: number, to: number, bottom: number, top: number)
		local span, tall = to - from, top - bottom
		if span < 0.05 or tall < 0.05 then
			return
		end
		local mid = (from + to) / 2
		local pos = if alongX then center + Vector3.new(mid, bottom + tall / 2, 0) else center + Vector3.new(0, bottom + tall / 2, mid)
		local size = if alongX then Vector3.new(span, tall, T) else Vector3.new(T, tall, span)
		part(b, name .. label, size, CFrame.new(pos), swatch.material, color)
	end
	local cursor = -length / 2
	for i, o in openings do
		local left, right = o.u - o.w / 2, o.u + o.w / 2
		piece("Column" .. i, cursor, left, 0, height)
		if o.bottom > 0 then
			piece("Sill" .. i, left, right, 0, o.bottom)
		end
		piece("Lintel" .. i, left, right, o.top, height)
		if not o.door then
			local pos = if alongX then center + Vector3.new(o.u, (o.bottom + o.top) / 2, 0) else center + Vector3.new(0, (o.bottom + o.top) / 2, o.u)
			local size = if alongX then Vector3.new(o.w, o.top - o.bottom, 0.2) else Vector3.new(0.2, o.top - o.bottom, o.w)
			part(b, name .. "Glass" .. i, size, CFrame.new(pos), Enum.Material.Glass, b.style.glass, { transparency = 0.45, small = true })
		end
		cursor = right
	end
	piece("Column" .. (#openings + 1), cursor, length / 2, 0, height)
end

-- A gabled roof of two WedgeParts. A WedgePart is full height at its back (+Z) and slopes down
-- to its front (-Z); the front half sits as-is, the back half turned 180 degrees, so both are
-- tallest at the ridge. `frame` is the roof's centre at the wall tops; the ridge runs along its X.
local function gabledRoof(b: Builder, frame: CFrame, length: number, span: number, rise: number, swatch: Styles.Swatch, color: Color3)
	local over = 1
	local half = span / 2 + over
	local size = Vector3.new(length + 1.2, rise, half)
	part(b, "RoofFront", size, frame * CFrame.new(0, rise / 2, -half / 2), swatch.material, color, { wedge = true })
	part(b, "RoofBack", size, frame * CFrame.new(0, rise / 2, half / 2) * CFrame.Angles(0, math.pi, 0), swatch.material, color, { wedge = true })
	part(b, "Ridge", Vector3.new(length + 1.4, 0.5, 0.8), frame * CFrame.new(0, rise + 0.1, 0), b.style.trim.material, vary(b.rng, b.style.trim.color, 0.04), { small = true })
end

local function flatRoof(b: Builder, frame: CFrame, w: number, d: number, swatch: Styles.Swatch, color: Color3)
	part(b, "Roof", Vector3.new(w + 1, 0.8, d + 1), frame * CFrame.new(0, 0.4, 0), swatch.material, color)
	local edge = vary(b.rng, color, 0.05)
	part(b, "ParapetFront", Vector3.new(w + 1, 1.2, 0.6), frame * CFrame.new(0, 1.4, -(d + 1) / 2 + 0.3), swatch.material, edge)
	part(b, "ParapetBack", Vector3.new(w + 1, 1.2, 0.6), frame * CFrame.new(0, 1.4, (d + 1) / 2 - 0.3), swatch.material, edge)
	part(b, "ParapetLeft", Vector3.new(0.6, 1.2, d - 0.2), frame * CFrame.new(-(w + 1) / 2 + 0.3, 1.4, 0), swatch.material, edge)
	part(b, "ParapetRight", Vector3.new(0.6, 1.2, d - 0.2), frame * CFrame.new((w + 1) / 2 - 0.3, 1.4, 0), swatch.material, edge)
end

local function tag(instance: Instance, tags: { string })
	for _, t in tags do
		CollectionService:AddTag(instance, t)
	end
end

local function anchor(b: Builder, primary: BasePart, name: string, tagName: string, localPos: Vector3, lotId: string)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.WorldCFrame = b.base * CFrame.new(localPos)
	attachment.Parent = primary
	attachment:SetAttribute("BuildingId", lotId)
	CollectionService:AddTag(attachment, tagName)
end

-- Marks a part as an interactable of a registry kind (Shared/World/Interactables). Ids number
-- per kind in build order, so the same lot always gives the same ids.
local function interact(b: Builder, target: BasePart, kind: string, attributes: { [string]: any }?)
	local n = (b.counts[kind] or 0) + 1
	b.counts[kind] = n
	target:SetAttribute("Interactable", kind)
	target:SetAttribute("InteractId", string.format("%s:%s%d", b.lotId, kind, n))
	for key, value in (attributes or {}) :: { [string]: any } do
		target:SetAttribute(key, value)
	end
	CollectionService:AddTag(target, "Interactable")
end

-- The ground floor: one collidable slab over the whole footprint (under the walls too, so no
-- seam), its top 0.05 over the foundation top at FLOOR_Y, FLOOR_SLAB thick, overlapping the plinth.
local function floorSlab(b: Builder, w: number, d: number): BasePart
	local top = FLOOR_Y + 0.05
	local slab = part(b, "Floor", Vector3.new(w, FLOOR_SLAB, d), CFrame.new(0, top - FLOOR_SLAB / 2, 0), b.style.floor.material, vary(b.rng, b.style.floor.color, 0.05))
	CollectionService:AddTag(slab, "BuildingFloor")
	return slab
end

-- The plinth: a stone block under the walls (half a stud wider each side), from below the ground
-- up to FLOOR_Y. On a slope it reaches past the lowest ground under the lot, so the downhill
-- side stands on stone (FoundationBuilder terraces the terrain around it) instead of floating.
local function plinth(b: Builder, w: number, d: number, material: Enum.Material?, color: Color3?): BasePart
	local depth = math.max(2, b.drop + 1)
	return part(b, "Foundation", Vector3.new(w + 1, FLOOR_Y + depth, d + 1), CFrame.new(0, (FLOOR_Y - depth) / 2, 0),
		material or b.style.foundation.material, vary(b.rng, color or b.style.foundation.color, 0.04))
end

-- Steps from the yard up to a threshold at `topY`, in front of an opening at `u` on the front
-- face (local Z = `front`), each at most STEP_RISE high. The top step is level with the floor.
-- Returns the local Z of the bottom step's outer edge.
local function doorSteps(b: Builder, u: number, width: number, front: number, topY: number): number
	local rise = topY - GROUND_Y
	local count = math.max(1, math.ceil(rise / STEP_RISE - 1e-3))
	local material, color = b.style.foundation.material, vary(b.rng, b.style.foundation.color, 0.04)
	for i = 1, count do
		local top = topY - (i - 1) * rise / count
		local bottom = GROUND_Y - 0.5 -- sunk a little so uneven ground never shows a gap
		part(b, if i == 1 then "Step" else "Step" .. i, Vector3.new(width, top - bottom, STEP_DEPTH),
			CFrame.new(u, (top + bottom) / 2, front - (i - 0.5) * STEP_DEPTH), material, color)
	end
	return front - count * STEP_DEPTH
end

-- Flagstones from the bottom step out toward the street (spec.path, from SettlementGround), set
-- flush in the yard, slightly jittered: one stone per 1.75 studs down to 2 studs past the lot's
-- front edge (lots stand at least 2 back from the road), at least one (a landing) and at most four.
local function frontPath(b: Builder, spec: any, u: number, fromZ: number)
	if not spec.path then
		return
	end
	local toZ = -spec.d / 2 - 2
	local stones = math.clamp(math.floor((fromZ - toZ) / 1.75), 1, 4)
	local color = b.style.foundation.color
	for i = 1, stones do
		local z = fromZ - 0.7 - (i - 1) * 1.75
		local size = Vector3.new(b.rng:NextNumber(1.6, 2.1), 0.2, b.rng:NextNumber(1.1, 1.4))
		part(b, "Flagstone", size, CFrame.new(u + b.rng:NextNumber(-0.25, 0.25), GROUND_Y + 0.05, z) * CFrame.Angles(0, b.rng:NextNumber(-0.15, 0.15), 0),
			Enum.Material.Slate, vary(b.rng, color, 0.06), { collide = false, small = true })
	end
end

-- The room volume above the ground floor (SettlementService keeps terrain out of it).
local function interior(b: Builder, w: number, d: number, height: number)
	b.model:SetAttribute("InteriorCFrame", b.base * CFrame.new(0, FLOOR_Y + 0.1 + height / 2, 0))
	b.model:SetAttribute("InteriorSize", Vector3.new(w - 2 * T - 0.2, height - 0.2, d - 2 * T - 0.2))
end

--[[
	A working front door in a door opening of the front wall (the local -Z face, depth d). The
	leaf stands closed in the opening and swings 80 degrees inward on its left hinge when opened.
	Houses are locked with a seeded chance (their owners lock up); the key id is the lot id.
]]
local function frontDoor(b: Builder, opening: Opening, d: number, color: Color3, lockChance: number)
	local leafW, leafH = opening.w - 0.3, opening.top - 0.15
	local hinge = CFrame.new(opening.u - opening.w / 2 + 0.15, FLOOR_Y, -d / 2 + T / 2)
	local toCentre = CFrame.new(leafW / 2, leafH / 2, 0)
	local closed = hinge * toCentre
	local open = hinge * CFrame.Angles(0, -math.rad(80), 0) * toCentre
	local leaf = part(b, "Door", Vector3.new(leafW, leafH, 0.35), closed, b.style.trim.material, color)
	local locked = b.rng:NextNumber() < lockChance
	interact(b, leaf, "door", {
		ClosedCFrame = b.base * closed,
		OpenCFrame = b.base * open,
		Locked = locked,
		OwnerLocks = locked, -- relocks whenever it closes again
		LockTier = if locked then b.rng:NextInteger(1, 2) else 1,
		KeyId = b.lotId,
	})
	CollectionService:AddTag(leaf, "Door")
end

-- Fireplace embers: dark until lit (Interact/Lamps: dusk when someone's home, or by hand).
-- A lit fireplace warms its building (attribute Warm) and lets the hearth cook.
local function fireplaceEmbers(b: Builder, at: CFrame)
	local embers = part(b, "Embers", Vector3.new(0.4, 0.5, 1.6), at, Enum.Material.Slate, Color3.fromRGB(60, 50, 45), { collide = false, small = true })
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(255, 140, 60)
	l.Range = 16
	l.Brightness = 1.6
	l.Shadows = false
	l.Enabled = false
	l.Parent = embers
	interact(b, embers, "fireplace", { Lit = false })
end

-- An invisible Seat on a mattress: "Rest" sits the player there (Services/InteractionService).
local function bedSeat(b: Builder, at: CFrame)
	local seat = Instance.new("Seat")
	seat.Name = "BedSeat"
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.CFrame = b.base * at
	seat.Anchored = true
	seat.CanCollide = false
	seat.CanTouch = false -- never auto-seats on touch; only the prompt sits you
	seat.Transparency = 1
	seat.Parent = b.model
	b.parts += 1
	interact(b, seat, "bed")
end

-- A storage chest (a container). `at` is lot-local; the chest stands on floor height y.
local function chest(b: Builder, at: CFrame, y: number)
	local wood = vary(b.rng, Color3.fromRGB(110, 78, 52), 0.08)
	local body = part(b, "Chest", Vector3.new(3, 1.3, 1.6), at * CFrame.new(0, y + 0.65, 0), Enum.Material.Wood, wood)
	part(b, "ChestLid", Vector3.new(3.1, 0.35, 1.7), at * CFrame.new(0, y + 1.47, 0), Enum.Material.WoodPlanks, vary(b.rng, wood, 0.06), { small = true })
	interact(b, body, "chest")
end

-- A hanging lamp. Its light starts off (Interact/Lamps lights it at dusk when someone's home;
-- lamp lights are capped live, not by the static budget).
local function lamp(b: Builder, at: CFrame)
	part(b, "LampChain", Vector3.new(0.15, 1.2, 0.15), at * CFrame.new(0, 0.9, 0), Enum.Material.Metal, Color3.fromRGB(60, 62, 68), { collide = false, small = true })
	local glass = part(b, "Lamp", Vector3.new(0.9, 1, 0.9), at, Enum.Material.Glass, Color3.fromRGB(120, 110, 90), { collide = false, small = true })
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(255, 196, 120)
	l.Range = 18
	l.Brightness = 1.3
	l.Shadows = false
	l.Enabled = false
	l.Parent = glass
	interact(b, glass, "lamp", { Lit = false })
end

-- A bookshelf against a wall: a browsable interactable (Interact/Data/Books).
local function bookshelf(b: Builder, target: BasePart)
	interact(b, target, "bookshelf")
end

-- A tall wardrobe (a container). `at` is lot-local at floor height y; it faces -Z of `at`.
local function wardrobe(b: Builder, at: CFrame, y: number)
	local wood = vary(b.rng, Color3.fromRGB(105, 74, 50), 0.07)
	local body = part(b, "Wardrobe", Vector3.new(3, 6, 1.4), at * CFrame.new(0, y + 3, 0), WOOD_MATERIAL, wood)
	part(b, "WardrobeSeam", Vector3.new(0.1, 5.4, 0.1), at * CFrame.new(0, y + 3, -0.72), WOOD_MATERIAL, vary(b.rng, wood, 0.1), { collide = false, small = true })
	interact(b, body, "wardrobe")
end

-- A workbench (a station). `at` faces -Z: the worker stands on that side.
local function workbench(b: Builder, at: CFrame, y: number)
	local wood = vary(b.rng, Color3.fromRGB(140, 104, 66), 0.07)
	local top = part(b, "Workbench", Vector3.new(4.5, 0.5, 2), at * CFrame.new(0, y + 3, 0), Enum.Material.WoodPlanks, wood)
	part(b, "WorkbenchLegs", Vector3.new(4, 2.75, 1.6), at * CFrame.new(0, y + 1.375, 0.1), WOOD_MATERIAL, vary(b.rng, wood, 0.08))
	part(b, "Vise", Vector3.new(0.6, 0.6, 0.6), at * CFrame.new(1.6, y + 3.55, -0.5), Enum.Material.Metal, Color3.fromRGB(70, 72, 78), { small = true })
	interact(b, top, "workbench")
end

-- A loom (a station).
local function loom(b: Builder, at: CFrame, y: number)
	local wood = vary(b.rng, Color3.fromRGB(150, 112, 72), 0.07)
	local frame = part(b, "Loom", Vector3.new(3.4, 0.4, 2.4), at * CFrame.new(0, y + 2.6, 0), WOOD_MATERIAL, wood)
	for _, sx in { -1, 1 } do
		part(b, "LoomPost", Vector3.new(0.35, 4.6, 0.35), at * CFrame.new(sx * 1.55, y + 2.3, 0.9), WOOD_MATERIAL, wood, { small = true })
	end
	part(b, "LoomBeam", Vector3.new(3.4, 0.35, 0.35), at * CFrame.new(0, y + 4.5, 0.9), WOOD_MATERIAL, wood, { small = true })
	part(b, "LoomWarp", Vector3.new(2.8, 1.9, 0.05), at * CFrame.new(0, y + 3.5, 0.9), Enum.Material.Fabric, FABRICS[b.rng:NextInteger(1, #FABRICS)], { collide = false, small = true })
	interact(b, frame, "loom")
end

-- A meditation mat: a thin rug with an invisible Seat ("Meditate": Reservoir activity Meditating).
local function mat(b: Builder, at: CFrame, y: number)
	part(b, "Mat", Vector3.new(2.6, 0.12, 2.6), at * CFrame.new(0, y + 0.06, 0), Enum.Material.Fabric, FABRICS[b.rng:NextInteger(1, #FABRICS)], { collide = false, small = true })
	local seat = Instance.new("Seat")
	seat.Name = "MatSeat"
	seat.Size = Vector3.new(2, 0.3, 2)
	seat.CFrame = b.base * at * CFrame.new(0, y + 0.3, 0)
	seat.Anchored = true
	seat.CanCollide = false
	seat.CanTouch = false
	seat.Transparency = 1
	seat.Parent = b.model
	b.parts += 1
	interact(b, seat, "mat")
end

-- A training dummy: a Model with a Humanoid and HumanoidRootPart, so spells target and damage it
-- through the normal pipeline (Targeting.characterOf). InteractionService keeps it alive and
-- shows the damage it took.
local function trainingDummy(b: Builder, at: CFrame, y: number)
	local dummy = Instance.new("Model")
	dummy.Name = "TrainingDummy"
	local straw = Color3.fromRGB(205, 175, 100)
	local function piece(name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanTouch = false
		p.Size = size
		p.CFrame = b.base * at * offset
		p.Material = material
		p.Color = color
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = dummy
		b.parts += 1
		return p
	end
	piece("Stand", Vector3.new(2.4, 0.4, 2.4), CFrame.new(0, y + 0.2, 0), Color3.fromRGB(110, 80, 52), WOOD_MATERIAL)
	piece("Post", Vector3.new(0.5, 3, 0.5), CFrame.new(0, y + 1.9, 0), Color3.fromRGB(110, 80, 52), WOOD_MATERIAL)
	local root = piece("HumanoidRootPart", Vector3.new(2, 2.4, 1), CFrame.new(0, y + 4.4, 0), straw, Enum.Material.Fabric)
	piece("Head", Vector3.new(1.4, 1.4, 1.4), CFrame.new(0, y + 6.3, 0), straw, Enum.Material.Fabric)
	piece("Arms", Vector3.new(4.4, 0.6, 0.6), CFrame.new(0, y + 5, 0), Color3.fromRGB(110, 80, 52), WOOD_MATERIAL)
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 1000
	humanoid.Health = 1000
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.Parent = dummy
	dummy.PrimaryPart = root
	dummy.Parent = b.model
	interact(b, root, "dummy")
end


-- ─── House (small) ──────────────────────────────────────────────────────────

local function houseSmall(b: Builder, spec: any): BasePart
	local rng, style = b.rng, b.style
	local w = math.clamp(spec.w - 2 - rng:NextNumber(0, 2), 12, 16)
	local d = math.clamp(spec.d - 2 - rng:NextNumber(0, 2), 10, 14)
	local h = rng:NextNumber(9, 11)
	local wallSwatch = style.walls[rng:NextInteger(1, #style.walls)]
	local wallColor = vary(rng, wallSwatch.color, 0.06)
	local trimColor = vary(rng, style.trim.color, 0.05)
	local top = FLOOR_Y + h

	-- Foundation plinth (sunk at least 2 studs; deeper on slopes) and floor.
	local foundation = plinth(b, w, d)
	floorSlab(b, w, d)
	interior(b, w, d, h)

	-- Front wall: the door off-centre, a window on the wider side (two when there's room).
	local doorU = rng:NextNumber(-w / 4, w / 4)
	local front: { Opening } = { { u = doorU, w = DOOR.w, bottom = 0, top = DOOR.h, door = true } }
	local roomLeft = (doorU - DOOR.w / 2) - (-w / 2 + T)
	local roomRight = (w / 2 - T) - (doorU + DOOR.w / 2)
	local windowsFront = 0
	if roomLeft >= WINDOW.w + 2 then
		table.insert(front, { u = (-w / 2 + T + doorU - DOOR.w / 2) / 2, w = WINDOW.w, bottom = WINDOW.bottom, top = WINDOW.top })
		windowsFront += 1
	end
	if roomRight >= WINDOW.w + 2 and (windowsFront == 0 or rng:NextNumber() < 0.6) then
		table.insert(front, { u = (doorU + DOOR.w / 2 + w / 2 - T) / 2, w = WINDOW.w, bottom = WINDOW.bottom, top = WINDOW.top })
	end
	local doorOpening = front[1] -- wall() sorts the list in place
	local frontOpenings = table.clone(front)
	wall(b, "FrontWall", Vector3.new(0, FLOOR_Y, -d / 2 + T / 2), true, w, h, front, wallSwatch, wallColor)
	wall(b, "BackWall", Vector3.new(0, FLOOR_Y, d / 2 - T / 2), true, w, h, { { u = rng:NextNumber(-w / 5, w / 5), w = WINDOW.w, bottom = WINDOW.bottom, top = WINDOW.top } }, wallSwatch, wallColor)
	local sideLength = d - 2 * T
	wall(b, "LeftWall", Vector3.new(-w / 2 + T / 2, FLOOR_Y, 0), false, sideLength, h, { { u = 0, w = WINDOW.w, bottom = WINDOW.bottom, top = WINDOW.top } }, wallSwatch, wallColor)
	wall(b, "RightWall", Vector3.new(w / 2 - T / 2, FLOOR_Y, 0), false, sideLength, h, { { u = 0, w = WINDOW.w, bottom = WINDOW.bottom, top = WINDOW.top } }, wallSwatch, wallColor)

	-- A working door, closed (Server/Interact/Doors opens it). Half of all homes are locked.
	frontDoor(b, doorOpening, d, trimColor, 0.5)
	frontPath(b, spec, doorU, doorSteps(b, doorU, DOOR.w + 1, -d / 2 - 0.5, FLOOR_Y + 0.05))

	-- Shutters on the front windows (some cultures), timber framing (others).
	if style.shutters then
		for _, o in frontOpenings do
			if not o.door then
				for _, sideSign in { -1, 1 } do
					part(b, "Shutter", Vector3.new(1.4, WINDOW.top - WINDOW.bottom, 0.2), CFrame.new(o.u + sideSign * (WINDOW.w / 2 + 0.75), FLOOR_Y + (WINDOW.bottom + WINDOW.top) / 2, -d / 2 - 0.1),
						style.trim.material, trimColor, { small = true })
				end
			end
		end
	end
	if style.timber then
		for _, corner in { Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, 1) } do
			part(b, "Post", Vector3.new(1.2, h, 1.2), CFrame.new(corner.X * (w / 2 - 0.4), FLOOR_Y + h / 2, corner.Z * (d / 2 - 0.4)), style.trim.material, trimColor)
		end
		part(b, "BeamFront", Vector3.new(w, 0.8, 0.3), CFrame.new(0, top - 0.4, -d / 2 - 0.05), style.trim.material, trimColor, { small = true })
	end

	-- Roof: gabled with the ridge along the longer side, or flat with a parapet.
	local roofSwatch = style.roof[rng:NextInteger(1, #style.roof)]
	local roofColor = vary(rng, roofSwatch.color, 0.05)
	local rise = 0
	if style.roofStyle == "flat" then
		flatRoof(b, CFrame.new(0, top, 0), w, d, roofSwatch, roofColor)
	else
		local alongX = w >= d
		local length, span = if alongX then w else d, if alongX then d else w
		rise = math.clamp(rng:NextNumber(style.pitch[1], style.pitch[2]) * span, 3, 12)
		local frame = CFrame.new(0, top, 0) * (if alongX then CFrame.identity else CFrame.Angles(0, math.pi / 2, 0))
		gabledRoof(b, frame, length, span, rise, roofSwatch, roofColor)
	end

	-- Chimney and hearth (by culture odds), against the right wall in the back half.
	local hasChimney = rng:NextNumber() < style.chimney
	if hasChimney then
		local cx, cz = w / 2 - 2.2, d / 4
		local stack = h + rise + 3
		local stone = style.foundation
		part(b, "Chimney", Vector3.new(2.4, stack, 2.4), CFrame.new(cx, FLOOR_Y + stack / 2, cz), stone.material, vary(rng, stone.color, 0.05))
		part(b, "ChimneyCap", Vector3.new(3, 0.5, 3), CFrame.new(cx, FLOOR_Y + stack + 0.25, cz), stone.material, vary(rng, stone.color, 0.08), { small = true })
		local hearth = part(b, "Hearth", Vector3.new(1.2, 2.6, 2.6), CFrame.new(cx - 1.8, FLOOR_Y + 1.3, cz), stone.material, vary(rng, stone.color, 0.05))
		interact(b, hearth, "hearth")
		fireplaceEmbers(b, CFrame.new(cx - 2.5, FLOOR_Y + 0.35, cz))
	end

	-- Furniture: a bed in the back-left corner, a table with two chairs, a shelf, a rug, a chest.
	local fabric = FABRICS[rng:NextInteger(1, #FABRICS)]
	local wood = Enum.Material.Wood
	local woodColor = vary(rng, Color3.fromRGB(110, 78, 52), 0.08)
	local bx, bz = -w / 2 + T + 2.2, d / 2 - T - 3.6
	part(b, "BedFrame", Vector3.new(3.8, 1.2, 7), CFrame.new(bx, FLOOR_Y + 0.6, bz), wood, woodColor)
	part(b, "Mattress", Vector3.new(3.4, 0.6, 6.2), CFrame.new(bx, FLOOR_Y + 1.5, bz + 0.2), Enum.Material.Fabric, fabric, { small = true })
	part(b, "Pillow", Vector3.new(2.4, 0.5, 1.2), CFrame.new(bx, FLOOR_Y + 2, bz + 2.6), Enum.Material.Fabric, Color3.fromRGB(230, 226, 214), { collide = false, small = true })
	bedSeat(b, CFrame.new(bx, FLOOR_Y + 2, bz))
	-- The chest goes at the foot of the bed when the room is deep enough, else beside the pillow.
	local footZ = bz - 3.5 - 0.9
	local chestAt = if footZ - 0.8 >= -d / 2 + T + 0.3 then CFrame.new(bx, 0, footZ) else CFrame.new(bx + 2.9, 0, bz + 2.4) * CFrame.Angles(0, math.pi / 2, 0)
	chest(b, chestAt, FLOOR_Y)

	local tx, tz = rng:NextNumber(0, w / 6), -rng:NextNumber(0, d / 8)
	part(b, "TableTop", Vector3.new(4, 0.4, 3), CFrame.new(tx, FLOOR_Y + 3, tz), wood, woodColor)
	part(b, "TableLeg", Vector3.new(0.8, 2.8, 0.8), CFrame.new(tx, FLOOR_Y + 1.4, tz), wood, woodColor, { small = true })
	for _, sideSign in { -1, 1 } do
		local chairX = tx + sideSign * 2.8
		part(b, "ChairSeat", Vector3.new(1.6, 0.3, 1.6), CFrame.new(chairX, FLOOR_Y + 1.8, tz), wood, woodColor, { small = true })
		part(b, "ChairLeg", Vector3.new(0.5, 1.65, 0.5), CFrame.new(chairX, FLOOR_Y + 0.83, tz), wood, woodColor, { small = true })
		part(b, "ChairBack", Vector3.new(0.3, 2, 1.6), CFrame.new(chairX + sideSign * 0.65, FLOOR_Y + 2.9, tz), wood, woodColor, { small = true })
	end

	local shelfX = if hasChimney then -w / 6 else w / 4
	bookshelf(b, part(b, "Shelf", Vector3.new(4, 0.3, 1.2), CFrame.new(shelfX, FLOOR_Y + 5, d / 2 - T - 0.6), wood, woodColor, { small = true }))
	for i = 1, 3 do
		part(b, "Book", Vector3.new(0.4, 1.1, 0.9), CFrame.new(shelfX - 1.4 + i * 0.55, FLOOR_Y + 5.7, d / 2 - T - 0.6),
			Enum.Material.SmoothPlastic, FABRICS[rng:NextInteger(1, #FABRICS)], { collide = false, small = true })
	end
	part(b, "Rug", Vector3.new(5, 0.1, 3.6), CFrame.new(tx, FLOOR_Y + 0.25, tz), Enum.Material.Fabric, vary(rng, fabric, 0.1), { collide = false, small = true })

	lamp(b, CFrame.new(0, top - 1.6, 0))
	table.insert(b.seats, CFrame.new(tx - 2.8, FLOOR_Y + 2, tz))
	table.insert(b.seats, CFrame.new(tx + 2.8, FLOOR_Y + 2, tz))

	-- Anchors for the NPC and quest systems.
	anchor(b, foundation, "NPCHome", "NPCHome", Vector3.new(bx + 2.6, FLOOR_Y + 3, bz), spec.lotId)
	anchor(b, foundation, "Entrance", "BuildingEntrance", Vector3.new(doorU, FLOOR_Y + 3, -d / 2 - 3), spec.lotId)
	return foundation
end

-- ─── Lights (a server-wide budget) ──────────────────────────────────────────

local lightsUsed = 0
local lightBudget = 160

-- Sets how many PointLights all generated buildings may create in total (default 160).
function BuildingGenerator.setLightBudget(n: number)
	lightBudget = math.max(0, n)
end

function BuildingGenerator.lightsUsed(): number
	return lightsUsed
end

-- A PointLight on a part, if the budget allows (the part's Neon glow stays either way).
local function light(target: BasePart, color: Color3, range: number, brightness: number)
	if lightsUsed >= lightBudget then
		return
	end
	lightsUsed += 1
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = target
	target.Destroying:Connect(function()
		lightsUsed = math.max(0, lightsUsed - 1)
	end)
end

BuildingGenerator.light = light -- SettlementDecor shares the same budget

-- ─── Shared shell: foundation, floors, walls with openings, stairs, roof ────

type ShellOptions = {
	w: number,
	d: number,
	storyH: number,
	stories: number?, -- 1 (default) or 2
	door: Opening?, -- front opening on the ground floor (default: a door at a seeded offset)
	windows: { front: number, back: number, side: number }?,
	windowTop: number?, -- window top above the story floor (tall windows for halls)
	roof: string?, -- "auto" (culture), "flat", "dome", "none"
	pitchBoost: number?, -- added to the culture's pitch (barns are steeper)
	wallSwatch: Styles.Swatch?,
	lockChance: number?, -- chance the front door starts locked (houses lock up)
	spec: any?, -- the build spec (flagstone path to the street when spec.path)
}

type Shell = {
	w: number,
	d: number,
	storyH: number,
	stories: number,
	top: number, -- wall top (lot-local Y)
	rise: number,
	door: Opening,
	foundation: BasePart,
	wallSwatch: Styles.Swatch,
	wallColor: Color3,
	trimColor: Color3,
	upperY: number?, -- second floor surface
	stairX: number?, -- the stairwell runs along this X (right wall) when two-storey
}

-- `count` windows spread evenly along a wall of `length`, skipping any that hit `avoid`.
local function windowRow(length: number, count: number, bottom: number, top: number, avoid: Opening?): { Opening }
	local out: { Opening } = {}
	if count <= 0 then
		return out
	end
	local usable = length - 2 * T - WINDOW.w
	for i = 1, count do
		local u = if count == 1 then 0 else -usable / 2 + usable * (i - 1) / (count - 1)
		local clash = avoid and math.abs(u - avoid.u) < (avoid.w + WINDOW.w) / 2 + 1
		if not clash then
			table.insert(out, { u = u, w = WINDOW.w, bottom = bottom, top = top })
		end
	end
	return out
end

local function shell(b: Builder, o: ShellOptions): Shell
	local rng, style = b.rng, b.style
	local w, d, storyH = o.w, o.d, o.storyH
	local stories = o.stories or 1
	local wallSwatch = o.wallSwatch or style.walls[rng:NextInteger(1, #style.walls)]
	local wallColor = vary(rng, wallSwatch.color, 0.06)
	local trimColor = vary(rng, style.trim.color, 0.05)
	local windows = o.windows or { front = 2, back = 1, side = 1 }
	local windowTop = o.windowTop or WINDOW.top

	local foundation = plinth(b, w, d)
	floorSlab(b, w, d)
	interior(b, w, d, stories * storyH)

	local door: Opening = o.door or { u = rng:NextNumber(-w / 5, w / 5), w = DOOR.w, bottom = 0, top = DOOR.h, door = true }
	for story = 1, stories do
		local y = FLOOR_Y + (story - 1) * storyH
		local front: { Opening } = if story == 1 then { door } else {}
		for _, win in windowRow(w, windows.front, WINDOW.bottom, windowTop, if story == 1 then door else nil) do
			table.insert(front, win)
		end
		wall(b, "FrontWall" .. story, Vector3.new(0, y, -d / 2 + T / 2), true, w, storyH, front, wallSwatch, wallColor)
		wall(b, "BackWall" .. story, Vector3.new(0, y, d / 2 - T / 2), true, w, storyH, windowRow(w, windows.back, WINDOW.bottom, windowTop, nil), wallSwatch, wallColor)
		wall(b, "LeftWall" .. story, Vector3.new(-w / 2 + T / 2, y, 0), false, d - 2 * T, storyH, windowRow(d, windows.side, WINDOW.bottom, windowTop, nil), wallSwatch, wallColor)
		wall(b, "RightWall" .. story, Vector3.new(w / 2 - T / 2, y, 0), false, d - 2 * T, storyH, windowRow(d, windows.side, WINDOW.bottom, windowTop, nil), wallSwatch, wallColor)
	end

	-- A working door (only for a standard doorway; wide openings like the smithy's stay open).
	if door.w <= DOOR.w + 0.5 then
		frontDoor(b, door, d, trimColor, o.lockChance or 0)
	end
	frontPath(b, o.spec, door.u, doorSteps(b, door.u, door.w + 1, -d / 2 - 0.5, FLOOR_Y + 0.05))

	-- Second floor: a slab with a stairwell along the right wall, and the stairs.
	local upperY, stairX = nil, nil
	if stories >= 2 then
		local y = FLOOR_Y + storyH
		local stairW = 3.5
		local steps = math.ceil(storyH)
		local run = steps * 1.1
		local x0 = w / 2 - T - stairW
		local zEnd = d / 2 - T - 0.5
		local zStart = zEnd - run
		local floorMat, floorColor = style.floor.material, vary(rng, style.floor.color, 0.05)
		part(b, "UpperFloor", Vector3.new(x0 - (-w / 2 + T), 0.6, d - 2 * T), CFrame.new((-w / 2 + T + x0) / 2, y - 0.3, 0), floorMat, floorColor)
		part(b, "UpperFloorFront", Vector3.new(stairW, 0.6, zStart - (-d / 2 + T)), CFrame.new(x0 + stairW / 2, y - 0.3, (-d / 2 + T + zStart) / 2), floorMat, floorColor)
		for i = 1, steps do
			part(b, "Stair", Vector3.new(stairW, storyH / steps, 1.1), CFrame.new(x0 + stairW / 2, FLOOR_Y + (i - 0.5) * storyH / steps, zStart + (i - 0.5) * 1.1), floorMat, vary(rng, floorColor, 0.03), { small = true })
		end
		upperY, stairX = y, x0
	end

	-- Roof.
	local top = FLOOR_Y + stories * storyH
	local roofSwatch = style.roof[rng:NextInteger(1, #style.roof)]
	local roofColor = vary(rng, roofSwatch.color, 0.05)
	local kind = o.roof or "auto"
	if kind == "auto" then
		kind = if style.roofStyle == "flat" then "flat" else "gabled"
	end
	local rise = 0
	if kind == "flat" or kind == "dome" then
		flatRoof(b, CFrame.new(0, top, 0), w, d, roofSwatch, roofColor)
		if kind == "dome" then
			local size = math.min(w, d) * 0.7
			local dome = part(b, "Dome", Vector3.new(size, size, size), CFrame.new(0, top + 0.8, 0), roofSwatch.material, vary(rng, roofColor, 0.04))
			;(dome :: Part).Shape = Enum.PartType.Ball
			rise = size / 2
		end
	elseif kind == "gabled" then
		local alongX = w >= d
		local length, span = if alongX then w else d, if alongX then d else w
		rise = math.clamp((rng:NextNumber(style.pitch[1], style.pitch[2]) + (o.pitchBoost or 0)) * span, 3, 16)
		local frame = CFrame.new(0, top, 0) * (if alongX then CFrame.identity else CFrame.Angles(0, math.pi / 2, 0))
		gabledRoof(b, frame, length, span, rise, roofSwatch, roofColor)
	end

	return {
		w = w, d = d, storyH = storyH, stories = stories, top = top, rise = rise, door = door, foundation = foundation,
		wallSwatch = wallSwatch, wallColor = wallColor, trimColor = trimColor, upperY = upperY, stairX = stairX,
	}
end

-- A chimney through the roof at (x, z), with a hearth facing `inward` (+1 / -1 along X) and embers.
local function chimney(b: Builder, s: Shell, x: number, z: number, inward: number)
	local stone = b.style.foundation
	local stack = s.top - FLOOR_Y + s.rise + 3
	part(b, "Chimney", Vector3.new(2.4, stack, 2.4), CFrame.new(x, FLOOR_Y + stack / 2, z), stone.material, vary(b.rng, stone.color, 0.05))
	part(b, "ChimneyCap", Vector3.new(3, 0.5, 3), CFrame.new(x, FLOOR_Y + stack + 0.25, z), stone.material, vary(b.rng, stone.color, 0.08), { small = true })
	local hearth = part(b, "Hearth", Vector3.new(1.2, 2.6, 2.6), CFrame.new(x + inward * 1.8, FLOOR_Y + 1.3, z), stone.material, vary(b.rng, stone.color, 0.05))
	interact(b, hearth, "hearth")
	fireplaceEmbers(b, CFrame.new(x + inward * 2.5, FLOOR_Y + 0.35, z))
end

-- ─── Furniture and props (lot-local CFrames) ────────────────────────────────

local WOOD = Enum.Material.Wood

local function woodTone(b: Builder): Color3
	return vary(b.rng, Color3.fromRGB(110, 78, 52), 0.08)
end

local function bed(b: Builder, at: CFrame, y: number)
	local wood = woodTone(b)
	part(b, "BedFrame", Vector3.new(3.8, 1.2, 7), at * CFrame.new(0, y + 0.6, 0), WOOD, wood)
	part(b, "Mattress", Vector3.new(3.4, 0.6, 6.2), at * CFrame.new(0, y + 1.5, 0.2), Enum.Material.Fabric, FABRICS[b.rng:NextInteger(1, #FABRICS)], { small = true })
	part(b, "Pillow", Vector3.new(2.4, 0.5, 1.2), at * CFrame.new(0, y + 2, 2.6), Enum.Material.Fabric, Color3.fromRGB(230, 226, 214), { collide = false, small = true })
	bedSeat(b, at * CFrame.new(0, y + 2, 0))
end

-- A table with `chairs` stools around it (0-4).
local function tableSet(b: Builder, at: CFrame, y: number, chairs: number)
	local wood = woodTone(b)
	part(b, "TableTop", Vector3.new(4, 0.4, 3), at * CFrame.new(0, y + 3, 0), WOOD, wood)
	part(b, "TableLeg", Vector3.new(0.8, 2.8, 0.8), at * CFrame.new(0, y + 1.4, 0), WOOD, wood, { small = true })
	local seats = { Vector3.new(-2.8, 0, 0), Vector3.new(2.8, 0, 0), Vector3.new(0, 0, -2.4), Vector3.new(0, 0, 2.4) }
	for i = 1, math.min(chairs, 4) do
		part(b, "Stool", Vector3.new(1.4, 1.8, 1.4), at * CFrame.new(seats[i] + Vector3.new(0, y + 0.9, 0)), WOOD, vary(b.rng, wood, 0.05), { small = true })
		table.insert(b.seats, at * CFrame.new(seats[i] + Vector3.new(0, y + 2, 0)))
	end
end

local function shelf(b: Builder, at: CFrame, y: number, books: number)
	bookshelf(b, part(b, "Shelf", Vector3.new(4, 0.3, 1.2), at * CFrame.new(0, y + 5, 0), WOOD, woodTone(b), { small = true }))
	for i = 1, books do
		part(b, "Book", Vector3.new(0.4, 1.1, 0.9), at * CFrame.new(-1.4 + i * 0.55, y + 5.7, 0), Enum.Material.SmoothPlastic, FABRICS[b.rng:NextInteger(1, #FABRICS)], { collide = false, small = true })
	end
end

-- A standing barrel (a Cylinder turned upright).
-- A standing barrel (a Cylinder turned upright); a small container.
local function barrel(b: Builder, at: CFrame, y: number)
	local p = part(b, "Barrel", Vector3.new(3, 2.4, 2.4), at * CFrame.new(0, y + 1.5, 0) * CFrame.Angles(0, 0, math.pi / 2), WOOD, vary(b.rng, Color3.fromRGB(120, 84, 52), 0.08), { cylinder = true })
	interact(b, p, "barrel")
end

-- A crate; a small container.
local function crate(b: Builder, at: CFrame, y: number, size: number)
	local p = part(b, "Crate", Vector3.new(size, size, size), at * CFrame.new(0, y + size / 2, 0), Enum.Material.WoodPlanks, vary(b.rng, Color3.fromRGB(150, 116, 76), 0.08))
	interact(b, p, "crate")
end

local function counter(b: Builder, at: CFrame, y: number, length: number)
	local wood = woodTone(b)
	part(b, "Counter", Vector3.new(length, 3.2, 1.6), at * CFrame.new(0, y + 1.6, 0), WOOD, wood)
	part(b, "CounterTop", Vector3.new(length + 0.4, 0.3, 2), at * CFrame.new(0, y + 3.35, 0), WOOD, vary(b.rng, wood, 0.06), { small = true })
end

-- A hanging sign with text (SurfaceGui), on a bracket off the front wall.
local SIGN_ADJ = { "Gilded", "Rusty", "Sleeping", "Wandering", "Crooked", "Silver", "Laughing", "Drowned", "Hollow", "Merry" }
local SIGN_NOUN = { "Kettle", "Lantern", "Stag", "Anchor", "Raven", "Tankard", "Wyrm", "Crown", "Hearth", "Oak" }

local function sign(b: Builder, at: CFrame, text: string)
	part(b, "SignBracket", Vector3.new(0.3, 0.3, 3), at * CFrame.new(0, 0, -1.5), WOOD, b.style.trim.color, { small = true })
	local board = part(b, "Sign", Vector3.new(5, 2.2, 0.3), at * CFrame.new(0, -1.4, -2.6) * CFrame.Angles(0, math.pi / 2, 0), Enum.Material.WoodPlanks, Color3.fromRGB(140, 104, 66), { small = true })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.MaxDistance = 120
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.TextScaled = true
		label.Font = Enum.Font.Fondamento
		label.TextColor3 = Color3.fromRGB(250, 236, 200)
		label.Text = text
		label.Parent = gui
		gui.Parent = board
	end
end

-- ─── House (medium): two bedrooms behind a partition, a table for four ──────

local function houseMedium(b: Builder, spec: any): BasePart
	local rng = b.rng
	local w = math.clamp(spec.w - 2 - rng:NextNumber(0, 2), 16, 20)
	local d = math.clamp(spec.d - 2 - rng:NextNumber(0, 2), 13, 16)
	local s = shell(b, { spec = spec, w = w, d = d, storyH = rng:NextNumber(10, 11.5), windows = { front = 2, back = 2, side = 1 }, lockChance = 0.5 })
	-- A partition with a doorway splits off the back third as the bedroom.
	local pz = d / 2 - T - 7.6
	wall(b, "Partition", Vector3.new(0, FLOOR_Y, pz), true, w - 2 * T, s.storyH, { { u = -w / 4, w = 3.5, bottom = 0, top = 7.5, door = true } }, s.wallSwatch, vary(rng, s.wallColor, 0.03))
	bed(b, CFrame.new(-w / 2 + T + 2.2, 0, d / 2 - T - 3.6), FLOOR_Y)
	bed(b, CFrame.new(w / 2 - T - 2.2, 0, d / 2 - T - 3.6), FLOOR_Y)
	chest(b, CFrame.new(0, 0, d / 2 - T - 0.9), FLOOR_Y) -- between the beds, against the back wall
	wardrobe(b, CFrame.new(0.5, 0, pz + T / 2 + 0.75) * CFrame.Angles(0, math.pi, 0), FLOOR_Y) -- bedroom side of the partition
	lamp(b, CFrame.new(0, FLOOR_Y + s.storyH - 1.6, -d / 6))
	lamp(b, CFrame.new(0, FLOOR_Y + s.storyH - 1.6, pz + 3.5))
	tableSet(b, CFrame.new(rng:NextNumber(-w / 8, w / 8), 0, -d / 6), FLOOR_Y, 4)
	shelf(b, CFrame.new(-w / 2 + T + 0.6, 0, -d / 6) * CFrame.Angles(0, math.pi / 2, 0), FLOOR_Y, 3)
	if rng:NextNumber() < b.style.chimney then
		chimney(b, s, w / 2 - 2.2, -d / 8, -1)
	end
	anchor(b, s.foundation, "NPCHome", "NPCHome", Vector3.new(-w / 2 + T + 4.8, FLOOR_Y + 3, d / 2 - T - 3.6), spec.lotId)
	anchor(b, s.foundation, "NPCHome2", "NPCHome", Vector3.new(w / 2 - T - 4.8, FLOOR_Y + 3, d / 2 - T - 3.6), spec.lotId)
	anchor(b, s.foundation, "Entrance", "BuildingEntrance", Vector3.new(s.door.u, FLOOR_Y + 3, -d / 2 - 3), spec.lotId)
	return s.foundation
end

-- ─── House (large): two storeys, bedrooms upstairs ──────────────────────────

local function houseLarge(b: Builder, spec: any): BasePart
	local rng = b.rng
	local w = math.clamp(spec.w - 2 - rng:NextNumber(0, 2), 20, 26)
	local d = math.clamp(spec.d - 2 - rng:NextNumber(0, 2), 16, 20)
	local s = shell(b, { spec = spec, w = w, d = d, storyH = 10, stories = 2, windows = { front = 3, back = 2, side = 2 }, lockChance = 0.6 })
	local up = s.upperY :: number
	tableSet(b, CFrame.new(-w / 6, 0, -d / 8), FLOOR_Y, 4)
	chest(b, CFrame.new(0, 0, d / 2 - T - 0.9), FLOOR_Y) -- back wall, clear of the stairwell
	loom(b, CFrame.new(-w / 2 + T + 1.6, 0, -d / 2 + T + 5) * CFrame.Angles(0, -math.pi / 2, 0), FLOOR_Y)
	wardrobe(b, CFrame.new(0, 0, -d / 2 + T + 0.8) * CFrame.Angles(0, math.pi, 0), up)
	lamp(b, CFrame.new(-w / 6, FLOOR_Y + s.storyH - 1.8, -d / 8))
	lamp(b, CFrame.new(-w / 6, up + s.storyH - 1.8, 0))
	shelf(b, CFrame.new(-w / 2 + T + 0.6, 0, d / 6) * CFrame.Angles(0, math.pi / 2, 0), FLOOR_Y, 3)
	barrel(b, CFrame.new(-w / 2 + T + 1.8, 0, -d / 2 + T + 1.8), FLOOR_Y)
	chimney(b, s, -w / 2 + 2.2, d / 2 - 4, 1)
	-- Upstairs: three beds along the back and left walls.
	bed(b, CFrame.new(-w / 2 + T + 6.6, 0, d / 2 - T - 3.6), up)
	bed(b, CFrame.new(-w / 6 + 3, 0, d / 2 - T - 3.6), up)
	bed(b, CFrame.new(-w / 2 + T + 2.2, 0, -d / 2 + T + 3.8) * CFrame.Angles(0, math.pi, 0), up)
	anchor(b, s.foundation, "NPCHome", "NPCHome", Vector3.new(-w / 2 + T + 9, up + 3, d / 2 - T - 3.6), spec.lotId)
	anchor(b, s.foundation, "NPCHome2", "NPCHome", Vector3.new(-w / 6 + 5.4, up + 3, d / 2 - T - 3.6), spec.lotId)
	anchor(b, s.foundation, "NPCHome3", "NPCHome", Vector3.new(-w / 2 + T + 4.6, up + 3, -d / 2 + T + 3.8), spec.lotId)
	anchor(b, s.foundation, "Entrance", "BuildingEntrance", Vector3.new(s.door.u, FLOOR_Y + 3, -d / 2 - 3), spec.lotId)
	return s.foundation
end

-- ─── Smithy: an open-fronted workshop, forge with glow and chimney, anvil ───

local function smithy(b: Builder, spec: any): BasePart
	local rng = b.rng
	local w = math.clamp(spec.w - 2 - rng:NextNumber(0, 2), 18, 22)
	local d = math.clamp(spec.d - 2 - rng:NextNumber(0, 2), 14, 18)
	local opening: Opening = { u = 0, w = w * 0.55, bottom = 0, top = 8.5, door = true }
	local s = shell(b, { spec = spec, w = w, d = d, storyH = 11, door = opening, windows = { front = 0, back = 1, side = 1 } })
	local stone = b.style.foundation
	-- Forge in the back-left corner: hearth block, glowing coals (with the light), a stack.
	local fx, fz = -w / 2 + T + 2.6, d / 2 - T - 2.6
	local forge = part(b, "Forge", Vector3.new(4.4, 3, 4.4), CFrame.new(fx, FLOOR_Y + 1.5, fz), stone.material, vary(rng, stone.color, 0.05))
	-- Forgehold smithies are master forges (tier 2): their recipes go further.
	interact(b, forge, "forge", { StationTier = if b.style == Styles.cultures.forgehold then 2 else 1 })
	local coals = part(b, "Coals", Vector3.new(3.4, 0.4, 3.4), CFrame.new(fx, FLOOR_Y + 3.2, fz), Enum.Material.Neon, Color3.fromRGB(255, 110, 30), { collide = false, small = true })
	light(coals, Color3.fromRGB(255, 140, 60), 16, 2)
	local stack = s.top - FLOOR_Y + s.rise + 4
	part(b, "ForgeStack", Vector3.new(2.6, stack - 6, 2.6), CFrame.new(fx, FLOOR_Y + 6 + (stack - 6) / 2, fz), stone.material, vary(rng, stone.color, 0.05))
	part(b, "ForgeHood", Vector3.new(4.4, 1.2, 4.4), CFrame.new(fx, FLOOR_Y + 6, fz), stone.material, vary(rng, stone.color, 0.07))
	-- Anvil, quench trough, tool rack, ingots.
	local metal = Color3.fromRGB(60, 62, 68)
	local ax, az = rng:NextNumber(-1, 2), 0
	part(b, "AnvilBase", Vector3.new(1.4, 2.2, 1.4), CFrame.new(ax, FLOOR_Y + 1.1, az), WOOD, woodTone(b))
	part(b, "Anvil", Vector3.new(3.2, 0.9, 1.2), CFrame.new(ax, FLOOR_Y + 2.65, az), Enum.Material.DiamondPlate, metal)
	part(b, "AnvilHorn", Vector3.new(1.2, 0.9, 1.4), CFrame.new(ax + 2.2, FLOOR_Y + 2.65, az) * CFrame.Angles(0, -math.pi / 2, 0), Enum.Material.DiamondPlate, metal, { wedge = true, small = true })
	part(b, "Trough", Vector3.new(4, 1.6, 1.8), CFrame.new(fx + 4.2, FLOOR_Y + 0.8, fz - 1), WOOD, woodTone(b))
	part(b, "TroughWater", Vector3.new(3.6, 0.2, 1.4), CFrame.new(fx + 4.2, FLOOR_Y + 1.5, fz - 1), Enum.Material.Glass, Color3.fromRGB(60, 110, 150), { collide = false, small = true, transparency = 0.3 })
	part(b, "ToolRack", Vector3.new(0.3, 3, 5), CFrame.new(w / 2 - T - 0.2, FLOOR_Y + 5, 0), WOOD, woodTone(b), { small = true })
	for i = 1, 3 do
		part(b, "Tool", Vector3.new(0.3, 2.6, 0.3), CFrame.new(w / 2 - T - 0.5, FLOOR_Y + 4.6, -1.6 + i * 0.9), Enum.Material.Metal, metal, { collide = false, small = true })
	end
	for i = 1, 3 do
		part(b, "Ingot", Vector3.new(1.2, 0.4, 0.5), CFrame.new(w / 2 - T - 2, FLOOR_Y + 0.2 + (i - 1) * 0.4, d / 2 - T - 2), Enum.Material.Metal, Color3.fromRGB(170, 140, 100), { small = true })
	end
	crate(b, CFrame.new(w / 2 - T - 2, 0, -d / 2 + T + 2.5), FLOOR_Y, 2.2)
	anchor(b, s.foundation, "NPCWork", "NPCWork", Vector3.new(ax, FLOOR_Y + 3, az - 2), spec.lotId)
	anchor(b, s.foundation, "Entrance", "BuildingEntrance", Vector3.new(0, FLOOR_Y + 3, -d / 2 - 3), spec.lotId)
	return s.foundation
end

-- ─── Tavern: two storeys, bar, tables, barrels, hearth, rooms, a named sign ─

local function tavern(b: Builder, spec: any): BasePart
	local rng = b.rng
	local w = math.clamp(spec.w - 3 - rng:NextNumber(0, 2), 22, 27)
	local d = math.clamp(spec.d - 3 - rng:NextNumber(0, 2), 17, 21)
	local s = shell(b, { spec = spec, w = w, d = d, storyH = 10, stories = 2, windows = { front = 3, back = 2, side = 2 } })
	local up = s.upperY :: number
	-- Bar along the back, barrels behind it, three tables, the hearth on the left wall.
	local barZ = d / 2 - T - 4.5
	counter(b, CFrame.new(-w / 8, 0, barZ), FLOOR_Y, w * 0.45)
	for i = 1, 3 do
		barrel(b, CFrame.new(-w / 8 - w * 0.18 + (i - 1) * w * 0.18, 0, d / 2 - T - 1.8), FLOOR_Y)
	end
	tableSet(b, CFrame.new(-w / 6, 0, -d / 5), FLOOR_Y, 2)
	tableSet(b, CFrame.new(w / 10, 0, -d / 5), FLOOR_Y, 4)
	tableSet(b, CFrame.new(-w / 10, 0, 0.5), FLOOR_Y, 2)
	chimney(b, s, -w / 2 + 2.2, -d / 6, 1)
	lamp(b, CFrame.new(0, FLOOR_Y + s.storyH - 1.8, 0))
	lamp(b, CFrame.new(-w / 6, up + s.storyH - 1.8, -d / 6))
	-- The notice board: freestanding by the entrance, facing into the room (local quests).
	local nb = CFrame.new(-w / 2 + T + 1.5, 0, -d / 2 + T + 2.5) * CFrame.Angles(0, -math.pi / 2, 0)
	for _, sx in { -1, 1 } do
		part(b, "BoardPost", Vector3.new(0.3, 6, 0.3), nb * CFrame.new(sx * 1.6, FLOOR_Y + 3, 0.1), WOOD, woodTone(b), { small = true })
	end
	local board = part(b, "NoticeBoard", Vector3.new(3.4, 2.6, 0.2), nb * CFrame.new(0, FLOOR_Y + 4.4, 0), Enum.Material.WoodPlanks, Color3.fromRGB(150, 116, 76))
	for i = 1, 3 do
		part(b, "Notice", Vector3.new(0.8, 1, 0.05), nb * CFrame.new(-1.1 + (i - 1) * 1.1, FLOOR_Y + 4.4 + (i % 2) * 0.3, -0.13), Enum.Material.SmoothPlastic, Color3.fromRGB(235, 225, 200), { collide = false, small = true })
	end
	interact(b, board, "notice_board")
	-- Upstairs rooms.
	bed(b, CFrame.new(-w / 2 + T + 2.2, 0, d / 2 - T - 3.6), up)
	bed(b, CFrame.new(-w / 2 + T + 7, 0, d / 2 - T - 3.6), up)
	tableSet(b, CFrame.new(-w / 6, 0, -d / 6), up, 1)
	chest(b, CFrame.new(-w / 2 + T + 11.5, 0, d / 2 - T - 0.9), up)
	-- The sign, with a seeded name.
	local name = string.format("The %s %s", SIGN_ADJ[rng:NextInteger(1, #SIGN_ADJ)], SIGN_NOUN[rng:NextInteger(1, #SIGN_NOUN)])
	sign(b, CFrame.new(s.door.u + DOOR.w / 2 + 2, FLOOR_Y + 9, -d / 2), name)
	b.model:SetAttribute("DisplayName", name)
	anchor(b, s.foundation, "NPCWork", "NPCWork", Vector3.new(-w / 8, FLOOR_Y + 3, barZ + 2), spec.lotId)
	anchor(b, s.foundation, "NPCHome", "NPCHome", Vector3.new(-w / 2 + T + 4.6, up + 3, d / 2 - T - 3.6), spec.lotId)
	anchor(b, s.foundation, "Entrance", "BuildingEntrance", Vector3.new(s.door.u, FLOOR_Y + 3, -d / 2 - 3), spec.lotId)
	return s.foundation
end

-- ─── Market stall: posts, counter, sloped canvas, goods ─────────────────────

local function marketStall(b: Builder, spec: any): BasePart
	local rng = b.rng
	local w = math.clamp(spec.w - 1.5, 7, 9)
	local d = math.clamp(spec.d - 1.5, 5, 7)
	local wood = woodTone(b)
	-- Top at 0.6; sunk below the yard (GROUND_Y) so it never floats.
	local base = part(b, "Base", Vector3.new(w, 1.35, d), CFrame.new(0, (0.6 - 0.75) / 2, 0), b.style.foundation.material, vary(rng, b.style.foundation.color, 0.05))
	local frontH, backH = 7.5, 9
	for _, c in { { -1, -1, frontH }, { 1, -1, frontH }, { -1, 1, backH }, { 1, 1, backH } } do
		part(b, "Post", Vector3.new(0.5, c[3], 0.5), CFrame.new(c[1] * (w / 2 - 0.3), 0.6 + c[3] / 2, c[2] * (d / 2 - 0.3)), WOOD, wood, { small = true })
	end
	-- Canvas: one wedge, high at the back, low over the counter, in a stripe colour.
	local canvasColor = FABRICS[rng:NextInteger(1, #FABRICS)]
	part(b, "Canvas", Vector3.new(w + 1, backH - frontH + 0.4, d + 1), CFrame.new(0, 0.6 + frontH + (backH - frontH + 0.4) / 2, 0), Enum.Material.Fabric, canvasColor, { wedge = true, collide = false })
	part(b, "Valance", Vector3.new(w + 1, 0.8, 0.2), CFrame.new(0, 0.6 + frontH - 0.2, -d / 2 - 0.5), Enum.Material.Fabric, vary(rng, canvasColor, 0.1), { collide = false, small = true })
	counter(b, CFrame.new(0, 0, -d / 2 + 1), 0.6, w - 1)
	-- Goods on the counter: small crates and colourful produce.
	for i = 1, 4 do
		local x = -w / 2 + 1.2 + (i - 1) * (w - 2.4) / 3
		part(b, "Goods", Vector3.new(1.2, 0.6, 1), CFrame.new(x, 0.6 + 3.8, -d / 2 + 1), Enum.Material.SmoothPlastic, FABRICS[rng:NextInteger(1, #FABRICS)], { collide = false, small = true })
	end
	crate(b, CFrame.new(w / 2 - 1.2, 0, d / 2 - 1.2), 0.6, 1.6)
	barrel(b, CFrame.new(-w / 2 + 1.4, 0, d / 2 - 1.4), 0.6)
	anchor(b, base, "NPCWork", "NPCWork", Vector3.new(0, 3, 0.5), spec.lotId)
	return base
end

-- ─── Well: stone ring, water, posts, crossbeam, little roof, bucket ─────────

local function well(b: Builder, spec: any): BasePart
	local rng = b.rng
	local stone = b.style.foundation
	local base = part(b, "Base", Vector3.new(7, 1.35, 7), CFrame.new(0, (0.6 - 0.75) / 2, 0), stone.material, vary(rng, stone.color, 0.05))
	local radius = 2.6
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		part(b, "Ring", Vector3.new(2.3, 2.6, 0.8), CFrame.new(math.cos(a) * radius, 0.6 + 1.3, math.sin(a) * radius) * CFrame.Angles(0, -a + math.pi / 2, 0), stone.material, vary(rng, stone.color, 0.06))
	end
	local water = part(b, "Water", Vector3.new(0.2, 4.4, 4.4), CFrame.new(0, 1.4, 0) * CFrame.Angles(0, 0, math.pi / 2), Enum.Material.Glass, Color3.fromRGB(50, 100, 150), { cylinder = true, collide = false, transparency = 0.25 })
	interact(b, water, "well")
	local wood = woodTone(b)
	for _, sideSign in { -1, 1 } do
		part(b, "Post", Vector3.new(0.6, 6, 0.6), CFrame.new(sideSign * (radius + 0.6), 0.6 + 3, 0), WOOD, wood)
	end
	part(b, "Crossbeam", Vector3.new(radius * 2 + 2, 0.5, 0.5), CFrame.new(0, 5.6, 0) * CFrame.Angles(0, 0, 0), WOOD, wood, { cylinder = true })
	part(b, "Rope", Vector3.new(0.15, 2.6, 0.15), CFrame.new(0, 4.2, 0), Enum.Material.Fabric, Color3.fromRGB(180, 160, 120), { collide = false, small = true })
	part(b, "Bucket", Vector3.new(1, 1.2, 1.2), CFrame.new(0, 2.6, 0) * CFrame.Angles(0, 0, math.pi / 2), WOOD, vary(rng, wood, 0.06), { cylinder = true, small = true })
	local roofSwatch = b.style.roof[rng:NextInteger(1, #b.style.roof)]
	gabledRoof(b, CFrame.new(0, 6.6, 0), radius * 2 + 2.4, 3.6, 1.8, roofSwatch, vary(rng, roofSwatch.color, 0.05))
	anchor(b, base, "Entrance", "BuildingEntrance", Vector3.new(0, 3, -radius - 2.5), spec.lotId) -- where people draw water
	return base
end

-- ─── Watchtower: stone posts and walls, ladder, platform, parapet, brazier ──

local function watchtower(b: Builder, spec: any): BasePart
	local rng = b.rng
	local size = math.clamp(math.min(spec.w, spec.d) - 3, 8, 10)
	local height = rng:NextNumber(24, 30)
	local platformY = FLOOR_Y + height - 6
	local stone = b.style.foundation
	local wallSwatch = b.style.walls[rng:NextInteger(1, #b.style.walls)]
	local wallColor = vary(rng, wallSwatch.color, 0.05)
	local foundation = plinth(b, size, size, stone.material, stone.color)
	local half = size / 2
	for _, c in { Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, 1) } do
		part(b, "Pillar", Vector3.new(1.6, height + 2, 1.6), CFrame.new(c.X * (half - 0.4), FLOOR_Y + (height + 2) / 2, c.Z * (half - 0.4)), stone.material, vary(rng, stone.color, 0.05))
	end
	-- Ground-floor walls (door at the front), open above them.
	local inner = size - 1.6
	wall(b, "FrontWall", Vector3.new(0, FLOOR_Y, -half + T / 2 + 0.3), true, inner, 9, { { u = 0, w = DOOR.w, bottom = 0, top = DOOR.h, door = true } }, wallSwatch, wallColor)
	doorSteps(b, 0, DOOR.w + 1, -half - 0.5, FLOOR_Y)
	wall(b, "BackWall", Vector3.new(0, FLOOR_Y, half - T / 2 - 0.3), true, inner, 9, {}, wallSwatch, wallColor)
	wall(b, "LeftWall", Vector3.new(-half + T / 2 + 0.3, FLOOR_Y, 0), false, inner - 2 * T, 9, {}, wallSwatch, wallColor)
	wall(b, "RightWall", Vector3.new(half - T / 2 - 0.3, FLOOR_Y, 0), false, inner - 2 * T, 9, {}, wallSwatch, wallColor)
	-- A climbable truss up to a hatch in the platform.
	local ladderX, ladderZ = -half + 2.4, 0
	local ladder = Instance.new("TrussPart")
	ladder.Name = "Ladder"
	ladder.Anchored = true
	ladder.CanTouch = false
	ladder.Size = Vector3.new(2, math.floor((platformY - FLOOR_Y) / 2) * 2, 2)
	ladder.CFrame = b.base * CFrame.new(ladderX, FLOOR_Y + ladder.Size.Y / 2, ladderZ)
	ladder.Material = WOOD
	ladder.Color = woodTone(b)
	ladder.Parent = b.model
	b.parts += 1
	-- Platform with a hatch over the ladder: front and back slabs, and a strip beside the hatch.
	local floorColor = vary(rng, b.style.floor.color, 0.05)
	local w2 = size + 2
	local hatchHalf, hatchEdge = 1.3, ladderX + 1.3
	part(b, "PlatformFront", Vector3.new(w2, 0.8, w2 / 2 - hatchHalf), CFrame.new(0, platformY, -(w2 / 2 + hatchHalf) / 2), b.style.floor.material, floorColor)
	part(b, "PlatformBack", Vector3.new(w2, 0.8, w2 / 2 - hatchHalf), CFrame.new(0, platformY, (w2 / 2 + hatchHalf) / 2), b.style.floor.material, floorColor)
	part(b, "PlatformSide", Vector3.new(w2 / 2 - hatchEdge, 0.8, hatchHalf * 2), CFrame.new((w2 / 2 + hatchEdge) / 2, platformY, 0), b.style.floor.material, floorColor)
	-- Parapet with crenels on each side.
	local edge = (size + 2) / 2 - 0.3
	for side = 0, 3 do
		local rot = CFrame.Angles(0, side * math.pi / 2, 0)
		part(b, "Parapet", Vector3.new(size + 2, 1.6, 0.6), rot * CFrame.new(0, platformY + 1.2, -edge), stone.material, wallColor)
		for m = -1, 1 do
			part(b, "Merlon", Vector3.new(1.4, 1.2, 0.6), rot * CFrame.new(m * (size + 2) / 3, platformY + 2.6, -edge), stone.material, wallColor, { small = true })
		end
	end
	-- Little roof on the pillars, and a brazier.
	local roofSwatch = b.style.roof[rng:NextInteger(1, #b.style.roof)]
	gabledRoof(b, CFrame.new(0, FLOOR_Y + height + 2, 0), size + 1, size + 1, 3.5, roofSwatch, vary(rng, roofSwatch.color, 0.05))
	part(b, "Brazier", Vector3.new(1.6, 1.2, 1.6), CFrame.new(half - 1.8, platformY + 1, -half + 1.8), Enum.Material.Metal, Color3.fromRGB(50, 50, 54))
	local fire = part(b, "Fire", Vector3.new(1.2, 0.8, 1.2), CFrame.new(half - 1.8, platformY + 2, -half + 1.8), Enum.Material.Neon, Color3.fromRGB(255, 140, 50), { collide = false, small = true })
	light(fire, Color3.fromRGB(255, 160, 80), 24, 2)
	anchor(b, foundation, "NPCWork", "NPCWork", Vector3.new(0, platformY + 3, 0), spec.lotId)
	anchor(b, foundation, "Entrance", "BuildingEntrance", Vector3.new(0, FLOOR_Y + 3, -half - 3), spec.lotId)
	return foundation
end

-- ─── Barn: wide double doors, steep roof, stalls, hay ───────────────────────

local function barn(b: Builder, spec: any): BasePart
	local rng = b.rng
	local w = math.clamp(spec.w - 2 - rng:NextNumber(0, 2), 20, 24)
	local d = math.clamp(spec.d - 2 - rng:NextNumber(0, 2), 15, 18)
	local wood = b.style.walls[1]
	for _, swatch in b.style.walls do
		if swatch.material == WOOD or swatch.material == Enum.Material.WoodPlanks then
			wood = swatch
		end
	end
	local opening: Opening = { u = 0, w = 8, bottom = 0, top = 10, door = true }
	local s = shell(b, { spec = spec, w = w, d = d, storyH = 12.5, door = opening, windows = { front = 0, back = 0, side = 2 }, pitchBoost = 0.2, wallSwatch = wood })
	-- The two door leaves stand open outward.
	for _, sideSign in { -1, 1 } do
		local hinge = Vector3.new(sideSign * 4, FLOOR_Y, -d / 2)
		part(b, "BarnDoor", Vector3.new(3.9, 9.8, 0.4), CFrame.new(hinge) * CFrame.Angles(0, -sideSign * math.rad(110), 0) * CFrame.new(-sideSign * 1.95, 4.9, 0), Enum.Material.WoodPlanks, s.trimColor, { collide = false })
	end
	-- Stalls along the back: posts and a rail for each divider.
	local stalls = 3
	local span = (w - 2 * T) / stalls
	for i = 1, stalls - 1 do
		local x = -w / 2 + T + i * span
		part(b, "StallPost", Vector3.new(0.6, 5, 0.6), CFrame.new(x, FLOOR_Y + 2.5, d / 2 - T - 5.5), WOOD, s.trimColor, { small = true })
		part(b, "StallRail", Vector3.new(0.4, 0.5, 5.5), CFrame.new(x, FLOOR_Y + 3.6, d / 2 - T - 2.75), WOOD, s.trimColor, { small = true })
	end
	part(b, "Trough", Vector3.new(w - 4, 1.4, 1.4), CFrame.new(0, FLOOR_Y + 0.7, d / 2 - T - 0.9), WOOD, woodTone(b))
	local hay = Color3.fromRGB(214, 186, 96)
	for i = 1, 4 do
		local hx = -w / 2 + T + 2 + (i % 2) * 3.2
		local hy = FLOOR_Y + 1 + (if i > 2 then 2 else 0)
		part(b, "Hay", Vector3.new(3, 2, 2), CFrame.new(hx, hy, -d / 2 + T + 2.5), Enum.Material.Fabric, vary(rng, hay, 0.06))
	end
	crate(b, CFrame.new(w / 2 - T - 2, 0, -d / 2 + T + 2), FLOOR_Y, 2.4)
	-- Both face into the barn: a part's front is its -Z, turned toward the centre.
	workbench(b, CFrame.new(w / 2 - T - 1.2, 0, -1) * CFrame.Angles(0, math.pi / 2, 0), FLOOR_Y)
	loom(b, CFrame.new(-w / 2 + T + 1.4, 0, -1) * CFrame.Angles(0, -math.pi / 2, 0), FLOOR_Y)
	anchor(b, s.foundation, "NPCWork", "NPCWork", Vector3.new(0, FLOOR_Y + 3, 0), spec.lotId)
	anchor(b, s.foundation, "Entrance", "BuildingEntrance", Vector3.new(0, FLOOR_Y + 3, -d / 2 - 4), spec.lotId)
	return s.foundation
end

-- ─── Magic school: tall hall, corner tower, crystal spire, lectern, benches ─

local function magicSchool(b: Builder, spec: any): BasePart
	local rng = b.rng
	local style = b.style
	local w = math.clamp(spec.w - 6, 20, 24)
	local d = math.clamp(spec.d - 8, 18, 22)
	local roofKind = if style.roofStyle == "flat" then "dome" else "auto"
	local s = shell(b, { spec = spec, w = w, d = d, storyH = 15, windows = { front = 2, back = 3, side = 2 }, windowTop = 12, roof = roofKind })
	-- The tower: a stone cylinder at the back-left corner, a stepped cap, a floating crystal.
	local tx, tz = -w / 2 + 1, d / 2 - 1
	local towerH = s.top + s.rise + 8
	local stone = style.foundation
	part(b, "Tower", Vector3.new(towerH, 8, 8), CFrame.new(tx, towerH / 2, tz) * CFrame.Angles(0, 0, math.pi / 2), stone.material, vary(rng, stone.color, 0.04), { cylinder = true })
	local roofColor = vary(rng, style.roof[1].color, 0.05)
	for i, diameter in { 9, 6.5, 4 } do
		part(b, "TowerCap", Vector3.new(2.4, diameter, diameter), CFrame.new(tx, towerH + (i - 0.5) * 2.4, tz) * CFrame.Angles(0, 0, math.pi / 2), style.roof[1].material, vary(rng, roofColor, 0.03), { cylinder = true })
	end
	local crystalColor = if style.glass then style.glass else Color3.fromRGB(180, 160, 255)
	local crystal = part(b, "Crystal", Vector3.new(1.6, 3.2, 1.6), CFrame.new(tx, towerH + 7.2 + 2, tz) * CFrame.Angles(0, math.rad(45), math.rad(45)), Enum.Material.Neon, crystalColor, { collide = false })
	light(crystal, crystalColor, 30, 1.5)
	-- Inside: a lectern at the back, three rows of benches, bookshelves, a glowing orb.
	local wood = woodTone(b)
	part(b, "Lectern", Vector3.new(2, 3.6, 1.4), CFrame.new(0, FLOOR_Y + 1.8, d / 2 - T - 3), WOOD, wood)
	part(b, "LecternTop", Vector3.new(2.4, 0.3, 1.8), CFrame.new(0, FLOOR_Y + 3.7, d / 2 - T - 3) * CFrame.Angles(math.rad(-15), 0, 0), WOOD, vary(rng, wood, 0.05), { small = true })
	-- Two rows of benches; the front of the hall is the workshop (stations along the side walls).
	for row = 1, 2 do
		for _, sideSign in { -1, 1 } do
			local z = d / 2 - T - 6 - row * 2.6
			part(b, "Bench", Vector3.new(w * 0.32, 1.6, 1.4), CFrame.new(sideSign * w * 0.22, FLOOR_Y + 0.8, z), WOOD, wood, { small = true })
			table.insert(b.seats, CFrame.new(sideSign * w * 0.22, FLOOR_Y + 2, z))
		end
	end
	local stationZ = -d / 2 + T + 3.6
	local alchemy = part(b, "AlchemyTable", Vector3.new(1.8, 3, 3.4), CFrame.new(-w / 2 + T + 1.1, FLOOR_Y + 1.5, stationZ), WOOD, vary(rng, wood, 0.05))
	part(b, "Flask", Vector3.new(0.6, 0.9, 0.6), CFrame.new(-w / 2 + T + 1.1, FLOOR_Y + 3.45, stationZ - 0.8), Enum.Material.Glass, Color3.fromRGB(120, 200, 140), { collide = false, small = true, transparency = 0.3 })
	interact(b, alchemy, "alchemy_table")
	local desk = part(b, "EnchantingDesk", Vector3.new(1.8, 3, 3.4), CFrame.new(w / 2 - T - 1.1, FLOOR_Y + 1.5, stationZ), WOOD, vary(rng, wood, 0.05))
	part(b, "Rune", Vector3.new(1.2, 0.05, 1.2), CFrame.new(w / 2 - T - 1.1, FLOOR_Y + 3.03, stationZ), Enum.Material.Neon, crystalColor, { collide = false, small = true })
	interact(b, desk, "enchanting_desk")
	trainingDummy(b, CFrame.new(w / 4 + 1, 0, d / 2 - T - 1.8), FLOOR_Y)
	mat(b, CFrame.new(-3.6, 0, d / 2 - T - 1.8), FLOOR_Y)
	mat(b, CFrame.new(-3.6, 0, d / 2 - T - 4.6), FLOOR_Y)
	for _, sideSign in { -1, 1 } do
		local case = part(b, "Bookcase", Vector3.new(1.2, 8, 6), CFrame.new(sideSign * (w / 2 - T - 0.7), FLOOR_Y + 4, d / 2 - T - 4.5), WOOD, vary(rng, wood, 0.05))
		bookshelf(b, case)
		part(b, "Books", Vector3.new(0.4, 6.4, 5.4), CFrame.new(sideSign * (w / 2 - T - 1.45), FLOOR_Y + 4, d / 2 - T - 4.5), Enum.Material.SmoothPlastic, FABRICS[rng:NextInteger(1, #FABRICS)], { collide = false, small = true })
	end
	-- The focus crystal on its pedestal: studying it once gives an insight in a seeded domain.
	local pedestal = part(b, "Pedestal", Vector3.new(1.4, 3, 1.4), CFrame.new(0, FLOOR_Y + 1.5, -d / 8), stone.material, vary(rng, stone.color, 0.05))
	local domains = { "energy", "earth", "water", "air", "life", "mind", "spirit" }
	interact(b, pedestal, "pedestal", { Domain = domains[rng:NextInteger(1, #domains)] })
	local orb = part(b, "Orb", Vector3.new(1.6, 1.6, 1.6), CFrame.new(0, FLOOR_Y + 3.9, -d / 8), Enum.Material.Neon, crystalColor, { collide = false })
	;(orb :: Part).Shape = Enum.PartType.Ball
	light(orb, crystalColor, 18, 1.2)
	anchor(b, s.foundation, "NPCWork", "NPCWork", Vector3.new(0, FLOOR_Y + 3, d / 2 - T - 5), spec.lotId)
	anchor(b, s.foundation, "Entrance", "BuildingEntrance", Vector3.new(s.door.u, FLOOR_Y + 3, -d / 2 - 3), spec.lotId)
	return s.foundation
end

-- ─── Shrine: stepped platform, pillars, roof or dome, altar and crystal ─────

local function shrine(b: Builder, spec: any): BasePart
	local rng = b.rng
	local style = b.style
	local size = math.clamp(math.min(spec.w, spec.d) - 2, 10, 12)
	local stone = style.foundation
	local stoneColor = vary(rng, stone.color, 0.04)
	local base = part(b, "Platform", Vector3.new(size, 1.4, size), CFrame.new(0, 0.2, 0), stone.material, stoneColor)
	part(b, "PlatformTop", Vector3.new(size - 2, 1, size - 2), CFrame.new(0, 1.4, 0), stone.material, vary(rng, stoneColor, 0.03))
	doorSteps(b, 0, 4, -size / 2, 0.9) -- up to the lower platform; the top tier is a 1-stud step
	local pillarSwatch = style.walls[rng:NextInteger(1, #style.walls)]
	local inner = (size - 2) / 2 - 0.8
	local pillarH = 8
	for _, c in { Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, 1) } do
		part(b, "Pillar", Vector3.new(1.2, pillarH, 1.2), CFrame.new(c.X * inner, 1.9 + pillarH / 2, c.Z * inner), pillarSwatch.material, vary(rng, pillarSwatch.color, 0.04))
	end
	local roofTop = 1.9 + pillarH
	local roofSwatch = style.roof[rng:NextInteger(1, #style.roof)]
	if style.roofStyle == "flat" then
		part(b, "Lintel", Vector3.new(size - 1, 0.8, size - 1), CFrame.new(0, roofTop + 0.4, 0), roofSwatch.material, vary(rng, roofSwatch.color, 0.04))
		local dome = part(b, "Dome", Vector3.new(size - 3, size - 3, size - 3), CFrame.new(0, roofTop + 0.8, 0), roofSwatch.material, vary(rng, roofSwatch.color, 0.04))
		;(dome :: Part).Shape = Enum.PartType.Ball
	else
		part(b, "Lintel", Vector3.new(size - 1, 0.8, size - 1), CFrame.new(0, roofTop + 0.4, 0), pillarSwatch.material, vary(rng, pillarSwatch.color, 0.04))
		gabledRoof(b, CFrame.new(0, roofTop + 0.8, 0), size - 1, size - 1, rng:NextNumber(3, 4.5), roofSwatch, vary(rng, roofSwatch.color, 0.05))
	end
	-- Altar, offering bowl, floating crystal in the culture's glass colour.
	local altar = part(b, "Altar", Vector3.new(2.4, 2.6, 1.8), CFrame.new(0, 1.9 + 1.3, inner * 0.4), stone.material, vary(rng, stoneColor, 0.05))
	interact(b, altar, "ward_stone")
	mat(b, CFrame.new(0, 0, -inner * 0.45), 1.9)
	part(b, "Bowl", Vector3.new(0.6, 1.4, 1.4), CFrame.new(0, 1.9 + 2.9, inner * 0.4) * CFrame.Angles(0, 0, math.pi / 2), Enum.Material.Metal, Color3.fromRGB(180, 150, 90), { cylinder = true, small = true })
	local crystal = part(b, "Crystal", Vector3.new(1, 2.2, 1), CFrame.new(0, 1.9 + 5.4, inner * 0.4) * CFrame.Angles(0, math.rad(45), math.rad(45)), Enum.Material.Neon, style.glass, { collide = false })
	light(crystal, style.glass, 14, 1)
	anchor(b, base, "NPCWork", "NPCWork", Vector3.new(0, 1.9 + 3, inner * 0.4 - 2.4), spec.lotId)
	return base
end

local KINDS: { [string]: { builder: (Builder, any) -> BasePart, tags: { string }, robustness: number } } = {
	house_small = { builder = houseSmall, tags = { "House" }, robustness = 1 },
	house_medium = { builder = houseMedium, tags = { "House" }, robustness = 1.1 },
	house_large = { builder = houseLarge, tags = { "House" }, robustness = 1.2 },
	smithy = { builder = smithy, tags = { "Smithy", "Workplace" }, robustness = 1.4 },
	tavern = { builder = tavern, tags = { "Tavern", "Workplace" }, robustness = 1.2 },
	market_stall = { builder = marketStall, tags = { "MarketStall", "Workplace" }, robustness = 0.5 },
	well = { builder = well, tags = { "Well" }, robustness = 1.5 },
	watchtower = { builder = watchtower, tags = { "Watchtower", "Workplace" }, robustness = 1.6 },
	barn = { builder = barn, tags = { "Barn", "Workplace" }, robustness = 0.9 },
	magic_school = { builder = magicSchool, tags = { "MagicSchool", "Workplace" }, robustness = 1.5 },
	shrine = { builder = shrine, tags = { "Shrine", "Workplace" }, robustness = 1.3 },
}

-- Floor geometry for FoundationBuilder and the specs (lot-local heights above the lot level).
BuildingGenerator.FLOOR_TOP = FLOOR_Y + 0.05
BuildingGenerator.FLOOR_BOTTOM = FLOOR_Y + 0.05 - FLOOR_SLAB
BuildingGenerator.GROUND_Y = GROUND_Y
BuildingGenerator.STEP_RISE = STEP_RISE

function BuildingGenerator.supports(kind: string): boolean
	return KINDS[kind] ~= nil
end

function BuildingGenerator.build(spec: any): (Model?, number, string?)
	local kind = KINDS[spec.kind]
	if not kind then
		return nil, 0, "no generator for " .. tostring(spec.kind) .. " yet"
	end
	local model = Instance.new("Model")
	model.Name = spec.name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local b: Builder = {
		model = model,
		base = spec.cframe,
		rng = Random.new(spec.seed),
		style = Styles.cultures[spec.culture] or Styles.cultures.wayfarer,
		parts = 0,
		lotId = spec.lotId,
		drop = math.max(0, tonumber(spec.drop) or 0),
		counts = {},
		seats = {},
	}
	local primary = kind.builder(b, spec)
	model.PrimaryPart = primary
	for i, seat in b.seats do
		anchor(b, primary, "NPCSeat" .. i, "NPCSeat", seat.Position, spec.lotId)
	end
	model:SetAttribute("LotCFrame", spec.cframe)
	model:SetAttribute("BuildingType", spec.kind)
	model:SetAttribute("Culture", spec.culture)
	model:SetAttribute("SettlementId", spec.settlementId)
	model:SetAttribute("LotId", spec.lotId)
	model:SetAttribute("OwnerNPCId", "")
	model:SetAttribute("Integrity", 100)
	model:SetAttribute("Robustness", kind.robustness)
	-- Access (Server/Interact/Access): homes are private, everything else is open to the public.
	model:SetAttribute("Access", if table.find(kind.tags, "House") then "private" else "public")
	tag(model, { "Building", "Structure" })
	tag(model, kind.tags)
	if spec.parent then
		model.Parent = spec.parent
	end
	return model, b.parts, nil
end

return BuildingGenerator
