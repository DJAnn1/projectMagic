--!strict
--[[
	ShapeFx: draws spell shapes (docs/SpellOverhaul.md §2B, stage 3), from WorldEffect cues of kind
	"shape" sent by Server/Magic/Cast/Shapes. Everything wears the spell's own look: its domain
	palette, the caster's signature and the property's layer (Data/PropertyLooks via DomainFx and
	PropertyFx), so a hail of frost and a rain of fire read differently.

		stage "warn"     a ground warning on each spot: a rim and a fill that grows until it lands
		stage "hit"      an extra impact (echo, nova ring, lob splash, eruption, aura pulse)
		stage "split"    shards flying from the impact to others nearby
		stage "drain"    life drawn back to the caster
		stage "drop"     one drop of a rain falling onto its marked spot
		stage "zone"     a lingering area or barrier, kept until "zoneEnd" (or its time runs out)
		stage "rise"     an elemental standing up out of the ground (Server/Magic/Cast/Elementals)
		stage "fade"     an elemental coming apart
		(an elemental's blows reuse "hit" and "split")

	Warnings are always drawn, even at far LOD and with Reduce effects on: they're how people
	read what is about to land.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local SpellFx = require(script.Parent.SpellFx)
local Staging = require(script.Parent.Staging)
local FeatureFlags = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Core.FeatureFlags)
local PropertyFx = require(script.Parent.PropertyFx)
local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local FxPool = require(script.Parent.FxPool)
local Recipes = require(script.Parent.FxRecipes)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

local ShapeFx = {}

local WARNING_RIM = Color3.fromRGB(255, 70, 50)
local folder: Folder? = nil
local zones: { [string]: { Instance } } = {}

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "ShapeFx"
	made.Parent = workspace.CurrentCamera or workspace
	folder = made
	return made
end

-- A flat disc on the ground (a Cylinder turned on its side).
local function disc(at: Vector3, radius: number, color: Color3, transparency: number, thickness: number, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material or Enum.Material.Neon
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(thickness, radius * 2, radius * 2)
	p.CFrame = CFrame.new(at + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
	p.Color = color
	p.Transparency = transparency
	p.Parent = folderOf()
	return p
end

local function v3(value: any): Vector3?
	return if typeof(value) == "Vector3" then value else nil
end

local function spotsOf(cue: { [string]: any }): { Vector3 }
	local out: { Vector3 } = {}
	for _, at in (if typeof(cue.spots) == "table" then cue.spots else {}) :: { any } do
		local spot = v3(at)
		if spot then
			-- Snap to the ground the client sees (the server's spot may be a little off the surface).
			local ground = FxLayers.ground(spot + Vector3.new(0, 4, 0), 14)
			table.insert(out, ground or spot)
		end
	end
	return out
end

type Kit = { style: any, look: DomainFx.Look, tier: any, tierIndex: number, power: number, lod: number }

local function kitFor(cue: { [string]: any }): Kit
	local property = if typeof(cue.property) == "string" then cue.property else nil
	local style = PropertyFx.tint(SpellFx.styleFor(cue.caster, cue.domain or "energy", cue.signature), property)
	local index = math.clamp(tonumber(cue.masteryTier) or 2, 0, 8)
	return {
		style = style,
		look = DomainFx.look(cue.domain, property),
		tier = Recipes.tiers[index],
		tierIndex = index,
		power = math.clamp(tonumber(cue.power) or 3, 1, 10),
		lod = tonumber(cue.lod) or 2,
	}
end

local function impactAt(kit: Kit, at: Vector3, radius: number, origin: Vector3?)
	SpellFx.impact({ position = at, radius = radius, power = kit.power, style = kit.style, look = kit.look, tier = kit.tier, tierIndex = kit.tierIndex, lod = kit.lod, harmful = true })
	PropertyFx.flourish(kit.look, { position = at, origin = origin, radius = radius, power = kit.power, style = kit.style, lod = kit.lod, lightning = SpellFx.lightning, tier = kit.tier })
end

local handlers: { [string]: (cue: { [string]: any }, kit: Kit) -> () } = {}

handlers.warn = function(cue, kit)
	local radius = math.clamp(tonumber(cue.radius) or 4, 1, 60)
	local delay = math.clamp(tonumber(cue.delay) or 0.6, 0.1, 3)
	local rim = kit.style.primary:Lerp(WARNING_RIM, 0.55)
	for _, spot in spotsOf(cue) do
		local outer = disc(spot, radius, rim, 0.55, 0.12)
		local fill = disc(spot, 0.3, FxLayers.whiten(kit.style.primary, 0.3), 0.35, 0.16)
		TweenService:Create(fill, TweenInfo.new(delay, Enum.EasingStyle.Linear), { Size = Vector3.new(0.16, radius * 2, radius * 2) }):Play()
		Debris:AddItem(outer, delay + 0.05)
		Debris:AddItem(fill, delay + 0.05)
	end
end

handlers.hit = function(cue, kit)
	local radius = math.clamp(tonumber(cue.radius) or 3, 1, 60)
	for _, spot in spotsOf(cue) do
		if cue.shape == "nova" or cue.shape == "pulse" then
			-- A ring rolling out along the ground, then a lighter impact at its middle.
			FxLayers.shockwave(spot, Vector3.yAxis, radius, kit.style.accent, 0.45)
			FxLayers.shockwave(spot, Vector3.yAxis, radius * 0.75, kit.style.primary, 0.4)
			impactAt(kit, spot + Vector3.new(0, 1, 0), math.min(radius * 0.35, 4))
		elseif cue.shape == "erupt" then
			-- It bursts up out of the marked ground.
			impactAt(kit, spot, math.min(radius, 10))
			SpellFx.burstAt(spot + Vector3.new(0, radius * 0.4, 0), radius * 0.5, kit.style, kit.tier, math.floor(20 + kit.power * 3), { lifetime = 0.8, speedMult = 2.5 })
		else
			impactAt(kit, spot, radius)
		end
	end
end

handlers.split = function(cue, kit)
	local from = v3(cue.from)
	if not from then
		return
	end
	for _, spot in spotsOf(cue) do
		local to = spot + Vector3.new(0, 2.5, 0)
		SpellFx.beam(from, to, kit.style, kit.tier, 0.18, 0.18, kit.look)
		task.delay(0.15, function()
			impactAt(kit, to, 1.2)
		end)
	end
end

handlers.drain = function(cue, kit)
	local from = v3(cue.from)
	local to = spotsOf(cue)[1]
	if not from or not to then
		return
	end
	local draw = PropertyFx.kinds.drain
	draw({ position = from, origin = to, radius = 2, power = kit.power, style = kit.style, lod = kit.lod, tier = kit.tier }, Theme.settings.reducedEffects == true)
end

handlers.drop = function(cue, kit)
	local radius = math.clamp(tonumber(cue.radius) or 4, 1, 20)
	for _, spot in spotsOf(cue) do
		local top = spot + Vector3.new(math.random(-6, 6), 60, math.random(-6, 6))
		local anchor = FxPool.anchor(CFrame.new(top), Vector3.one * (0.8 + kit.power * 0.12))
		if not anchor then
			impactAt(kit, spot, radius)
			continue
		end
		anchor.Shape = Enum.PartType.Ball
		anchor.Material = if kit.look.core.dark then Enum.Material.SmoothPlastic else Enum.Material.Neon
		anchor.Color = if kit.look.core.dark then Color3.fromRGB(14, 10, 20) else FxLayers.whiten(kit.style.primary, 0.4)
		anchor.Transparency = 0
		local tail = FxLayers.emitter(anchor, {
			texture = kit.look.body.texture,
			color = FxLayers.ramp(kit.style, kit.look.core.dark),
			size = FxLayers.seq(0, 1.2 + kit.power * 0.1, 1, 0),
			transparency = FxLayers.seq(0, 0.1, 1, 1),
			lifetime = NumberRange.new(0.25, 0.4),
			emission = if kit.look.body.additive then 1 else 0.2,
			influence = if kit.look.body.additive then 0 else 0.7,
			rate = 70,
		})
		if tail then
			tail.Enabled = true
		end
		local fall = 0.28
		FxLayers.animate(fall, function(t)
			anchor.CFrame = CFrame.new(top:Lerp(spot, t * t))
		end, function()
			anchor.Transparency = 1
			if tail then
				tail.Enabled = false
			end
			FxPool.releaseAfter(anchor, 0.5)
			impactAt(kit, spot, radius)
		end)
	end
end

handlers.zone = function(cue, kit)
	local spot = spotsOf(cue)[1]
	if not spot then
		return
	end
	local radius = math.clamp(tonumber(cue.radius) or 6, 1, 40)
	local seconds = math.clamp(tonumber(cue.seconds) or 4, 0.5, 15)
	local made: { Instance } = {}
	local barrier = cue.shape == "barrier"
	local field = disc(spot, radius, kit.style.primary, if barrier then 0.65 else 0.75, if barrier then 6 else 0.2, Enum.Material.ForceField)
	if barrier then
		-- A standing shimmer, not a floor.
		field.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
		field.Shape = Enum.PartType.Ball
		field.CFrame = CFrame.new(spot)
		field.Transparency = 0.82
	end
	table.insert(made, field)
	local rim = disc(spot, radius, kit.style.accent, 0.5, 0.1)
	table.insert(made, rim)
	if kit.lod >= 1 then
		local e = Instance.new("ParticleEmitter")
		e.Texture = kit.look.body.texture
		e.Color = FxLayers.ramp(kit.style, kit.look.core.dark)
		e.Size = FxLayers.seq(0, 0.6 + kit.power * 0.05, 0.5, 1.4, 1, 0.2)
		e.Transparency = FxLayers.seq(0, 0.4, 1, 1)
		e.Lifetime = NumberRange.new(0.8, 1.4)
		e.Speed = NumberRange.new(0.5, 2)
		e.Acceleration = Vector3.new(0, if kit.look.sparks.gravity < 0 then 3 else 0.5, 0)
		e.LightEmission = if kit.look.body.additive then 1 else 0
		e.LightInfluence = if kit.look.body.additive then 0 else 0.8
		e.Rate = math.clamp(radius * 2.5, 6, 50) * (if Theme.settings.reducedEffects then 0.35 else 1)
		e.Shape = Enum.ParticleEmitterShape.Cylinder
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		e.Parent = field
	end
	local key = tostring(cue.caster) .. ":" .. tostring(cue.id)
	zones[key] = made
	task.delay(seconds + 0.5, function()
		if zones[key] == made then
			zones[key] = nil
		end
		for _, instance in made do
			instance:Destroy()
		end
	end)
end

handlers.zoneEnd = function(cue, _kit)
	local key = tostring(cue.caster) .. ":" .. tostring(cue.id)
	local made = zones[key]
	zones[key] = nil
	for _, instance in (made or {}) :: { Instance } do
		if instance:IsA("BasePart") then
			TweenService:Create(instance, TweenInfo.new(0.4), { Transparency = 1 }):Play()
			Debris:AddItem(instance, 0.45)
		end
	end
end

handlers.rise = function(cue, kit)
	local radius = math.clamp(tonumber(cue.radius) or 3, 1, 12)
	for _, spot in spotsOf(cue) do
		local ground = spot - Vector3.new(0, 3, 0)
		FxLayers.shockwave(ground, Vector3.yAxis, radius * 2.2, kit.style.accent, 0.5)
		SpellFx.burstAt(spot, radius, kit.style, kit.tier, math.floor(24 + kit.power * 3), { lifetime = 0.9, speedMult = 1.6 })
		impactAt(kit, ground, radius)
	end
end

handlers.fade = function(cue, kit)
	local radius = math.clamp(tonumber(cue.radius) or 3, 1, 12)
	for _, spot in spotsOf(cue) do
		SpellFx.burstAt(spot, radius, kit.style, kit.tier, math.floor(16 + kit.power * 2), { lifetime = 0.8, speedMult = 0.8 })
	end
end

-- A domain ultimate's whole run (docs/Smoothness.md stage 3): its sigil spreads and light rises,
-- stillness before the first hit, then the flash, the field-sized dome and a ring stream.
handlers.ultimate = function(cue, kit)
	local spot = spotsOf(cue)[1] or v3(cue.position)
	if not spot then
		return
	end
	local _, up = FxLayers.ground(spot + Vector3.new(0, 2, 0), 8)
	local domain = if typeof(cue.domain) == "string" then cue.domain else "energy"
	local property = if typeof(cue.property) == "string" then cue.property else nil
	local verb = if typeof(cue.verb) == "string" then cue.verb else nil
	local sigil = if FeatureFlags.get("sigils_enabled") ~= false then SpellFx.sigilSpec(cue.caster, domain, property, verb, kit.tierIndex, kit.style) else nil
	Staging.ultimate(spot, up or Vector3.yAxis, tonumber(cue.radius) or 20, kit.style, tonumber(cue.reveal) or 1, tonumber(cue.length) or 4, sigil)
end

function ShapeFx.handle(cue: { [string]: any })
	local fn = handlers[tostring(cue.stage)]
	if not fn then
		return
	end
	if cue.stage == "ultimate" and FeatureFlags.get("staging_enabled") == false then
		return
	end
	-- Warnings, zone ends and ultimates always draw; everything else is skipped far away.
	if (tonumber(cue.lod) or 2) <= 0 and cue.stage ~= "warn" and cue.stage ~= "zoneEnd" and cue.stage ~= "zone" and cue.stage ~= "ultimate" then
		return
	end
	fn(cue, kitFor(cue))
end

return ShapeFx
