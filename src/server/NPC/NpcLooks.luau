--!strict
--[[
	NpcLooks: hair, headwear, beards, glasses, scarves and body scale for NPC rigs (docs/NPC.md §6c).
	Data: NPC/Data/NpcLooks (Roblox-made catalog accessories only).

	CLOTHES  part-built outfits (Roblox makes no medieval classic clothing): belts, aprons, tabards,
	         robes, cloaks, sashes by occupation, coloured from the culture's palette and shifted by
	         wealth (socialClass); welded to the body, SmoothPlastic (never Fabric: fire), no collision.
	ACCENTS  strong mages show it in their signature colour: Neon wrist bands and a Neon belt or
	         sash from Skilled (tier 3), slow sparkles at the hands from Master (5), more from 7.
	CHOOSE   choose(npc) is deterministic: a Random seeded from the NPC's own seed (itself from
	         Seed.derive(worldSeed, id, "npc")), so the same person always looks the same, on every
	         server. Inputs it reads: appearance.hair (colour) / build / feature, ageBand,
	         occupation, culture. A helm or hood replaces the hair under it; wizard hats, straw
	         caps and tricorns sit on top of it.
	LOAD     preload() loads every id once with InsertService:LoadAsset (Roblox-made assets load
	         whatever their price) into a cache under ServerStorage; failures are logged and that
	         piece is simply skipped. It yields, so it runs in the background; anything dressed
	         before it finishes is re-dressed through the onReady callback.
	APPLY    apply(model, humanoid, look): removes the previous wearer's pieces, resets the scale,
	         adds clones (Handle: massless, no collision, no queries, no touch), then scales the
	         body by build (Model:ScaleTo). Cheap: at most 4 cloned accessories per rig, and rigs
	         exist only for nearby (T0) NPCs.
]]

local InsertService = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")

local Data = require(script.Parent.Data.NpcLooks)
local NPCMagicLife = require(script.Parent.NPCMagicLife)
local InnateProfile = require(script.Parent.Parent.Magic.InnateProfile)

export type Garment = { kind: string, color: Color3, neon: boolean }
export type Accent = { tier: number, primary: Color3, secondary: Color3 }
export type Look = { ids: { number }, scale: number, garments: { Garment }, accent: Accent? }

local NpcLooks = {}

local TAG = "NpcLook" -- attribute on every accessory we add, so we only ever remove ours
local cache: { [number]: Accessory } = {}
local failed: { [number]: boolean } = {}
local ready = false
local cacheFolder: Folder? = nil

-- ─── Choosing ───────────────────────────────────────────────────────────────

local function pick<T>(rng: Random, list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

-- A pool name from a list of pool names, then an id from it.
local function fromPools(rng: Random, pools: { string }): (number?, boolean)
	local name = pick(rng, pools)
	local pool = name and Data.headwear[name]
	if not pool then
		return nil, false
	end
	return pick(rng, pool.ids), pool.coversHair
end

function NpcLooks.choose(npc: any): Look
	local seed = if typeof(npc.seed) == "number" then npc.seed else hash(tostring(npc.id))
	local rng = Random.new((seed + hash("looks")) % 2147483647)
	local a = npc.appearance or {}
	local ids: { number } = {}
	local child = npc.ageBand == "child"
	local elder = npc.ageBand == "elder"
	local culture = Data.culture[npc.culture or ""]

	-- Headwear: the occupation's chance first, then the culture's own extra.
	local rule = Data.byOccupation[npc.occupation or ""]
	local hat: number?, covers = nil, false
	if rule and rng:NextNumber() < rule.chance then
		local pools = rule.pools
		if npc.occupation == "guard" and culture and culture.guardPools then
			pools = culture.guardPools
		end
		hat, covers = fromPools(rng, pools)
	end
	if not hat and culture and culture.extra and rng:NextNumber() < culture.extra.chance then
		hat, covers = fromPools(rng, culture.extra.pools)
	end
	-- Pale hair has no natural Roblox match: those NPCs reach for a hood more often.
	local colour = tostring(a.hair or "brown")
	if not hat and Data.paleColours[colour] and not child and rng:NextNumber() < 0.4 then
		hat, covers = fromPools(rng, { "hood" })
	end

	-- Hair (unless the hat covers it, or they're bald).
	local bald = not child and rng:NextNumber() < Data.odds.bald
	if not covers and not bald then
		local pool = Data.hair[Data.hairColour[colour] or "brown"]
		local hair = pool and pick(rng, pool)
		if hair then
			table.insert(ids, hair)
		end
	end
	if hat then
		table.insert(ids, hat)
	end

	-- Face: a beard (the "braided beard" feature always; otherwise by age), glasses, an eyepatch.
	if not child then
		local feature = tostring(a.feature or "")
		local wantsBeard = feature == "a braided beard"
			or rng:NextNumber() < (if elder then Data.odds.beardElder else Data.odds.beardAdult)
		if feature == "spectacles" then
			table.insert(ids, Data.glasses)
		elseif wantsBeard then
			local wise = elder and (npc.occupation == "scholar" or npc.occupation == "weathercaller" or npc.occupation == "retired")
			if wise and rng:NextNumber() < Data.odds.wizardBeard then
				table.insert(ids, Data.beards.wizard)
			elseif colour == "red" or colour == "auburn" or feature == "a braided beard" then
				table.insert(ids, Data.beards.red)
			elseif colour == "blond" then
				table.insert(ids, Data.beards.blond)
			else
				table.insert(ids, Data.beards.dark)
			end
		elseif elder and (npc.occupation == "guard" or npc.occupation == "hunter") and rng:NextNumber() < Data.odds.eyepatch then
			table.insert(ids, Data.eyepatch)
		end
	end

	-- A scarf in the cold.
	if culture and culture.scarf and rng:NextNumber() < culture.scarf then
		local scarf = pick(rng, Data.scarves)
		if scarf then
			table.insert(ids, scarf)
		end
	end

	local scale = if child then Data.childScale else (Data.scale[tostring(a.build or "average")] or 1)
	local garments = NpcLooks.chooseClothes(npc, seed)
	local accent = NpcLooks.chooseAccent(npc)
	if accent then
		-- The signature shows in Neon: wrist bands, and the belt (or a sash) takes the colour.
		local lit = false
		for _, g in garments do
			if (g.kind == "belt" or g.kind == "sash") and not lit then
				g.color, g.neon, lit = accent.primary, true, true
			end
		end
		if not lit then
			table.insert(garments, { kind = "sash", color = accent.primary, neon = true })
		end
		table.insert(garments, { kind = "wristR", color = accent.primary, neon = true })
		table.insert(garments, { kind = "wristL", color = accent.secondary, neon = true })
	end
	return { ids = ids, scale = scale, garments = garments, accent = accent }
end

local GREYISH = Color3.fromRGB(120, 112, 100)
local BLACK = Color3.new(0, 0, 0)

local function sortedKeys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- The outfit: pieces from the occupation, colours from the culture's palette, shifted by wealth.
function NpcLooks.chooseClothes(npc: any, seed: number): { Garment }
	local rng = Random.new((seed + hash("clothes")) % 2147483647)
	local palette = Data.palette[npc.culture or ""] or Data.defaultPalette
	local wealth = Data.wealth[npc.socialClass or "middle"] or Data.wealth.middle
	local first = palette[rng:NextInteger(1, #palette)]
	local second = palette[rng:NextInteger(1, #palette)]
	local function colourOf(source: string): Color3
		local c = if source == "culture" then first elseif source == "culture2" then second else (Data.fixed[source] or first)
		if source ~= "linen" then
			c = c:Lerp(GREYISH, wealth.mute):Lerp(BLACK, wealth.darken)
		end
		return c
	end
	local out: { Garment } = {}
	local outfit = Data.outfits[npc.occupation or ""]
	if outfit then
		for _, kind in sortedKeys(outfit.always or {}) do
			table.insert(out, { kind = kind, color = colourOf((outfit.always :: any)[kind]), neon = false })
		end
		for _, kind in sortedKeys(outfit.maybe or {}) do
			local entry = (outfit.maybe :: any)[kind]
			local chance = entry[1] + (if kind == "cloak" then wealth.cloakBonus else 0)
			if rng:NextNumber() < chance then
				table.insert(out, { kind = kind, color = colourOf(entry[2]), neon = false })
			end
		end
	end
	-- The well-off wear a metal buckle on their belt.
	if wealth.buckle then
		for _, g in out do
			if g.kind == "belt" then
				table.insert(out, { kind = "buckle", color = Data.fixed.gold, neon = false })
				break
			end
		end
	end
	return out
end

-- The signature accent for a strong mage (nil below Skilled, or without a profile).
function NpcLooks.chooseAccent(npc: any): Accent?
	local ok, _, _, tier = pcall(NPCMagicLife.best, npc)
	if not ok or typeof(tier) ~= "number" or tier < Data.accent.trim then
		return nil
	end
	local okColours, colours = pcall(InnateProfile.signatureColors, npc.profile)
	if not okColours or typeof(colours) ~= "table" then
		return nil
	end
	return { tier = tier, primary = colours.primary, secondary = colours.secondary }
end

-- Every id the data can produce (preload).
function NpcLooks.allIds(): { number }
	local set: { [number]: boolean } = {}
	for _, list in Data.hair do
		for _, id in list do
			set[id] = true
		end
	end
	for _, pool in Data.headwear do
		for _, id in pool.ids do
			set[id] = true
		end
	end
	for _, id in Data.beards do
		set[id] = true
	end
	for _, id in Data.scarves do
		set[id] = true
	end
	set[Data.glasses] = true
	set[Data.eyepatch] = true
	local out: { number } = {}
	for id in set do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

-- ─── Loading ────────────────────────────────────────────────────────────────

local function folder(): Folder
	if cacheFolder and cacheFolder.Parent then
		return cacheFolder
	end
	local f = Instance.new("Folder")
	f.Name = "NpcLookCache"
	f.Parent = ServerStorage
	cacheFolder = f
	return f
end

local function loadOne(id: number): Accessory?
	local ok, result = pcall(function()
		return InsertService:LoadAsset(id)
	end)
	if not ok or not result then
		return nil
	end
	local accessory = result:FindFirstChildWhichIsA("Accessory", true)
	if accessory then
		accessory.Parent = folder()
	end
	result:Destroy()
	return accessory
end

--[[
	Loads every accessory once (yields; run it in a task). Returns loaded, failed counts and the
	failed ids. `onReady` runs when it's done (NPCLOD re-dresses its live rigs).
]]
function NpcLooks.preload(onReady: (() -> ())?): (number, number, { number })
	local loaded, bad = 0, {}
	for _, id in NpcLooks.allIds() do
		if not cache[id] and not failed[id] then
			local accessory = loadOne(id)
			if accessory then
				cache[id] = accessory
				loaded += 1
			else
				failed[id] = true
				table.insert(bad, id)
			end
			task.wait() -- spread the loads over frames
		end
	end
	ready = true
	if onReady then
		onReady()
	end
	return loaded, #bad, bad
end

function NpcLooks.isReady(): boolean
	return ready
end

-- ─── Applying ───────────────────────────────────────────────────────────────

local GARMENT_TAG = "NpcGarment"
local MOTES = "rbxasset://textures/particles/sparkles_main.dds"

local function strip(model: Model)
	for _, child in model:GetChildren() do
		if child:IsA("Accessory") and child:GetAttribute(TAG) then
			child:Destroy()
		end
	end
	for _, item in model:GetDescendants() do
		if item:GetAttribute(GARMENT_TAG) then
			item:Destroy()
		end
	end
end

-- One clothing piece welded to its body part.
local function addGarment(model: Model, garment: Garment)
	local def = Data.garments[garment.kind]
	local host = def and model:FindFirstChild(def.attach)
	if not def or not host or not host:IsA("BasePart") then
		return
	end
	local part = Instance.new("Part")
	part.Name = "Garment_" .. garment.kind
	part.Size = def.size
	part.Material = if garment.neon then Enum.Material.Neon elseif def.metal then Enum.Material.Metal else Enum.Material.SmoothPlastic
	part.Color = garment.color
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.CFrame = host.CFrame * def.offset
	part:SetAttribute(GARMENT_TAG, true)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = host
	weld.Part1 = part
	weld.Parent = part
	part.Parent = model
end

-- Slow signature-coloured sparkles at a hand (Master and above).
local function addMotes(model: Model, armName: string, accent: Accent, rate: number)
	local arm = model:FindFirstChild(armName)
	if not arm or not arm:IsA("BasePart") then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "SignatureMotes"
	attachment.Position = Vector3.new(0, -arm.Size.Y / 2, 0)
	attachment:SetAttribute(GARMENT_TAG, true)
	attachment.Parent = arm
	local e = Instance.new("ParticleEmitter")
	e.Texture = MOTES
	e.Color = ColorSequence.new(accent.primary, accent.secondary)
	e.LightEmission = 1
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(0.8, 1.4)
	e.Speed = NumberRange.new(0.3, 0.8)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, 1.5, 0)
	e.Rate = rate
	e.Parent = attachment
end

function NpcLooks.apply(model: Model, humanoid: Humanoid, look: Look)
	strip(model)
	pcall(function()
		model:ScaleTo(1)
	end)
	for _, id in look.ids do
		local template = cache[id]
		if template then
			local accessory = template:Clone()
			accessory:SetAttribute(TAG, id)
			for _, part in accessory:GetDescendants() do
				if part:IsA("BasePart") then
					part.Massless = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
				end
			end
			pcall(function()
				humanoid:AddAccessory(accessory)
			end)
		end
	end
	for _, garment in look.garments or {} do
		addGarment(model, garment)
	end
	local accent = look.accent
	if accent and accent.tier >= Data.accent.motes then
		local rate = if accent.tier >= Data.accent.aura then Data.accent.auraRate else Data.accent.motesRate
		addMotes(model, "Right Arm", accent, rate)
		if accent.tier >= Data.accent.aura then
			addMotes(model, "Left Arm", accent, rate)
		end
	end
	if math.abs(look.scale - 1) > 0.005 then
		pcall(function()
			model:ScaleTo(look.scale)
		end)
	end
end

-- The names of a look's pieces (from the loaded accessories; ids before they load), for admins.
function NpcLooks.describe(look: Look): string
	local names: { string } = {}
	for _, id in look.ids do
		local template = cache[id]
		table.insert(names, if template then template.Name else (if failed[id] then tostring(id) .. " (failed)" else tostring(id) .. " (loading)"))
	end
	local clothes: { string } = {}
	for _, g in look.garments or {} do
		table.insert(clothes, g.kind .. (if g.neon then " (signature)" else ""))
	end
	local accent = look.accent
	return string.format("%s · wears %s · scale %.2f%s",
		if #names > 0 then table.concat(names, ", ") else "nothing on the head",
		if #clothes > 0 then table.concat(clothes, ", ") else "plain clothes",
		look.scale,
		if accent then string.format(" · signature accent (tier %d)", accent.tier) else "")
end

return NpcLooks
