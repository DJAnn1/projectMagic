--!strict
--[[
	DomainFx: what each domain's magic is MADE of on screen. Pure data, read by Fx/SpellFx and
	Fx/FxLayers. Colours are the domain palette tinted by the caster's Signature (SpellFx);
	this decides the material: fire is additive sparks and scorch, earth is lit debris and cracks,
	water is droplets and puddles, void eats light.

	Every texture falls back to a built-in rbxasset (verified in the Studio content folder), so
	everything renders before custom art exists. Uploaded textures go in UPLOADED below; sounds
	are still built-in. docs/Combat.md §8 lists what to commission.

	Fields
		body      the main particle mass (bolt body, impact cloud): texture, size, lifetime, speed,
		          additive (bright LightEmission, no lighting) or lit (dust, mist)
		sparks    fast secondary bits: texture, size, speed, gravity (studs/s² down; negative rises)
		smoke     optional lingering after-cloud on impacts (lit, grey-tinted)
		core      the bolt / flash core: Neon by default; `dark` cores are near-black (void, gravity)
		light     PointLight per effect: brightness, range multiplier, flicker 0..1 (fire flickers)
		mark      the ground mark an impact leaves (FxLayers.groundMark kinds) or nil
		shake     camera shake multiplier for impacts (earth and gravity hit hardest)
		sounds    cast (charge-up), launch, impact: { id, pitch, volume }; pitch is varied ±6%
]]

local KenneyTextures = require(script.Parent.KenneyTextures)

--[[
	Uploaded textures, one per role. Each value is either
	  - a Kenney Particle Pack file name ("flame_04"), looked up in Fx/KenneyTextures;
	  - a bare asset id ("1234567890") or "rbxassetid://1234567890" for any other upload;
	  - "" to keep the built-in fallback.
	To try another texture for a role, change the name (see the contact sheet of the pack).
	Uploads must be Image ids from Asset Manager, owned by the place's creator.
]]
local UPLOADED: { [string]: string } = {
	sparkles = "star_04", -- small 4-point star (motes, water, life, mind sparks)
	fire = "flame_04", -- fire body
	fireSparks = "flare_01", -- embers and hot sparks
	smoke = "smoke_04", -- soft smoke, air body
	core = "star_09", -- bright impact core
	shock = "circle_02", -- thin ring (shockwave, cast counter-ring)
	implode = "twirl_02", -- void / gravity body
	burstSmoke = "smoke_08", -- chunky explosion smoke, earth body
	glow = "circle_05", -- soft glow (mind, spirit, puddles)
	vortex = "twirl_01", -- space / time body
	square = "window_04", -- glitch diamonds (reality, void sparks)
	rune = "magic_02", -- rune circle (cast circle, rune ground marks)
	scorch = "scorch_01", -- scorch ground mark
	crack = "spark_03", -- crack ground mark (tinted dark)
	debris = "dirt_02", -- earth / gravity debris chunks
	-- Lightning (beam textures run along the beam, so these are the horizontal versions).
	lightning = "spark_07", -- horizontal crackle
	lightningAlt = "spark_06_rotated", -- tall bolt, turned sideways
	lightningAlt2 = "spark_05_rotated", -- thin bolt, turned sideways
	-- Melee crescents (SlashFx): one per swing in a combo.
	slash1 = "slash_01",
	slash2 = "slash_02",
	slash3 = "slash_03",
	slash4 = "slash_04",
	streak = "trace_01_rotated", -- projectile trail texture (runs along the trail)
	muzzle = "muzzle_02", -- launch flash, standing along the shot
}

local P = "rbxasset://textures/particles/"

-- The uploaded texture for a role, or the built-in one when none is set (or the name is unknown).
local function pick(role: string, builtin: string): string
	local value = UPLOADED[role]
	if value == nil or value == "" then
		return builtin
	end
	local kenney = KenneyTextures[value]
	if kenney then
		return kenney
	elseif string.match(value, "^%d+$") then
		return "rbxassetid://" .. value
	elseif string.match(value, "^rbxassetid://%d+$") then
		return value
	end
	return builtin
end

local TEX = {
	sparkles = pick("sparkles", P .. "sparkles_main.dds"),
	fire = pick("fire", P .. "fire_main.dds"),
	fireSparks = pick("fireSparks", P .. "fire_sparks_main.dds"),
	smoke = pick("smoke", P .. "smoke_main.dds"),
	core = pick("core", P .. "explosion01_core_main.dds"),
	shock = pick("shock", P .. "explosion01_shockwave_main.dds"),
	implode = pick("implode", P .. "explosion01_implosion_main.dds"),
	burstSmoke = pick("burstSmoke", P .. "explosion01_smoke_main.dds"),
	glow = pick("glow", P .. "forcefield_glow_main.dds"),
	vortex = pick("vortex", P .. "forcefield_vortex_main.dds"),
	square = pick("square", P .. "SquareParticle.png"),
	-- Roles that used to share a texture above; each falls back to what it used before.
	rune = pick("rune", P .. "forcefield_vortex_main.dds"),
	scorch = pick("scorch", P .. "smoke_main.dds"),
	crack = pick("crack", P .. "explosion01_shockwave_main.dds"),
	debris = pick("debris", P .. "SquareParticle.png"),
	lightning = pick("lightning", P .. "sparkles_main.dds"),
	lightningAlt = pick("lightningAlt", P .. "sparkles_main.dds"),
	lightningAlt2 = pick("lightningAlt2", P .. "sparkles_main.dds"),
	slash1 = pick("slash1", P .. "explosion01_shockwave_main.dds"),
	slash2 = pick("slash2", P .. "explosion01_shockwave_main.dds"),
	slash3 = pick("slash3", P .. "explosion01_shockwave_main.dds"),
	slash4 = pick("slash4", P .. "explosion01_shockwave_main.dds"),
	streak = pick("streak", ""),
	muzzle = pick("muzzle", P .. "fire_main.dds"),
}

local S = "rbxasset://sounds/"
local SND = {
	boom = S .. "impact_explosion_03.mp3",
	splash = S .. "impact_water.mp3",
	whoosh = S .. "action_swim.mp3",
	thud = S .. "action_jump_land.mp3",
	wind = S .. "action_falling.ogg",
	rise = S .. "action_jump.mp3",
	tick = S .. "volume_slider.ogg",
}

export type Sound = { id: string, pitch: number, volume: number }
export type Look = {
	body: { texture: string, size: number, lifetime: number, speed: number, additive: boolean },
	sparks: { texture: string, size: number, speed: number, gravity: number, lifetime: number },
	smoke: { texture: string, tint: Color3, size: number, lifetime: number }?,
	core: { dark: boolean },
	light: { brightness: number, range: number, flicker: number },
	mark: string?,
	shake: number,
	sounds: { cast: Sound, launch: Sound, impact: Sound },
}

local GREY = Color3.fromRGB(70, 66, 62)

local function snd(id: string, pitch: number, volume: number): Sound
	return { id = id, pitch = pitch, volume = volume }
end

local looks: { [string]: Look } = {
	energy = {
		body = { texture = TEX.fire, size = 1.4, lifetime = 0.45, speed = 6, additive = true },
		sparks = { texture = TEX.fireSparks, size = 0.35, speed = 38, gravity = 35, lifetime = 0.6 },
		smoke = { texture = TEX.burstSmoke, tint = GREY, size = 3, lifetime = 1.6 },
		core = { dark = false },
		light = { brightness = 6, range = 1.6, flicker = 0.35 },
		mark = "scorch",
		shake = 1,
		sounds = { cast = snd(SND.rise, 0.7, 0.35), launch = snd(SND.whoosh, 1.5, 0.45), impact = snd(SND.boom, 1.15, 0.6) },
	},
	earth = {
		body = { texture = TEX.burstSmoke, size = 2.2, lifetime = 0.9, speed = 9, additive = false },
		sparks = { texture = TEX.debris, size = 0.45, speed = 30, gravity = 90, lifetime = 1.1 },
		smoke = { texture = TEX.smoke, tint = Color3.fromRGB(120, 100, 80), size = 4, lifetime = 2 },
		core = { dark = false },
		light = { brightness = 1.5, range = 1, flicker = 0 },
		mark = "crack",
		shake = 1.6,
		sounds = { cast = snd(SND.thud, 0.55, 0.5), launch = snd(SND.whoosh, 0.7, 0.5), impact = snd(SND.boom, 0.65, 0.75) },
	},
	water = {
		body = { texture = TEX.sparkles, size = 1.1, lifetime = 0.6, speed = 14, additive = false },
		sparks = { texture = TEX.sparkles, size = 0.4, speed = 26, gravity = 70, lifetime = 0.8 },
		smoke = { texture = TEX.smoke, tint = Color3.fromRGB(215, 235, 250), size = 3.5, lifetime = 1.4 },
		core = { dark = false },
		light = { brightness = 2, range = 1.2, flicker = 0 },
		mark = "puddle",
		shake = 0.8,
		sounds = { cast = snd(SND.splash, 1.4, 0.3), launch = snd(SND.whoosh, 1.1, 0.45), impact = snd(SND.splash, 0.9, 0.7) },
	},
	air = {
		body = { texture = TEX.smoke, size = 2, lifetime = 0.5, speed = 22, additive = false },
		sparks = { texture = TEX.sparkles, size = 0.3, speed = 45, gravity = -4, lifetime = 0.5 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 1, range = 1, flicker = 0 },
		mark = nil,
		shake = 0.7,
		sounds = { cast = snd(SND.wind, 1.3, 0.3), launch = snd(SND.wind, 1.8, 0.45), impact = snd(SND.whoosh, 0.8, 0.6) },
	},
	life = {
		body = { texture = TEX.sparkles, size = 1, lifetime = 0.9, speed = 5, additive = true },
		sparks = { texture = TEX.sparkles, size = 0.45, speed = 10, gravity = -6, lifetime = 1.4 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 2.5, range = 1.3, flicker = 0 },
		mark = "bloom",
		shake = 0.4,
		sounds = { cast = snd(SND.rise, 1.1, 0.3), launch = snd(SND.whoosh, 1.3, 0.35), impact = snd(SND.splash, 1.6, 0.4) },
	},
	mind = {
		body = { texture = TEX.glow, size = 1.6, lifetime = 0.7, speed = 4, additive = true },
		sparks = { texture = TEX.sparkles, size = 0.3, speed = 12, gravity = -2, lifetime = 0.9 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 2.5, range = 1.2, flicker = 0.15 },
		mark = "rune",
		shake = 0.5,
		sounds = { cast = snd(SND.tick, 0.5, 0.4), launch = snd(SND.whoosh, 1.7, 0.35), impact = snd(SND.tick, 0.35, 0.6) },
	},
	spirit = {
		body = { texture = TEX.glow, size = 1.8, lifetime = 0.8, speed = 5, additive = true },
		sparks = { texture = TEX.sparkles, size = 0.4, speed = 9, gravity = -10, lifetime = 1.2 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 3, range = 1.4, flicker = 0.1 },
		mark = "rune",
		shake = 0.6,
		sounds = { cast = snd(SND.wind, 0.6, 0.3), launch = snd(SND.whoosh, 1.2, 0.4), impact = snd(SND.boom, 1.6, 0.4) },
	},
	void = {
		body = { texture = TEX.implode, size = 2, lifetime = 0.6, speed = 3, additive = false },
		sparks = { texture = TEX.square, size = 0.3, speed = 16, gravity = 0, lifetime = 0.6 },
		smoke = { texture = TEX.smoke, tint = Color3.fromRGB(25, 18, 35), size = 3, lifetime = 1.2 },
		core = { dark = true },
		light = { brightness = 0.6, range = 0.8, flicker = 0.2 },
		mark = "void",
		shake = 0.9,
		sounds = { cast = snd(SND.wind, 0.45, 0.35), launch = snd(SND.whoosh, 0.55, 0.45), impact = snd(SND.boom, 0.45, 0.55) },
	},
	space = {
		body = { texture = TEX.vortex, size = 2, lifetime = 0.6, speed = 2, additive = true },
		sparks = { texture = TEX.sparkles, size = 0.35, speed = 20, gravity = 0, lifetime = 0.5 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 2.5, range = 1.2, flicker = 0.25 },
		mark = "rune",
		shake = 0.8,
		sounds = { cast = snd(SND.tick, 0.7, 0.4), launch = snd(SND.whoosh, 2, 0.4), impact = snd(SND.boom, 1.9, 0.4) },
	},
	time = {
		body = { texture = TEX.vortex, size = 2.2, lifetime = 1, speed = 1.5, additive = true },
		sparks = { texture = TEX.sparkles, size = 0.4, speed = 6, gravity = -3, lifetime = 1.6 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 3, range = 1.4, flicker = 0 },
		mark = "rune",
		shake = 0.7,
		sounds = { cast = snd(SND.tick, 0.9, 0.45), launch = snd(SND.wind, 0.8, 0.35), impact = snd(SND.tick, 0.6, 0.7) },
	},
	gravity = {
		body = { texture = TEX.implode, size = 2.6, lifetime = 0.7, speed = 2, additive = false },
		sparks = { texture = TEX.debris, size = 0.4, speed = 22, gravity = 140, lifetime = 0.7 },
		smoke = { texture = TEX.burstSmoke, tint = Color3.fromRGB(45, 35, 60), size = 3.5, lifetime = 1.4 },
		core = { dark = true },
		light = { brightness = 1.2, range = 1, flicker = 0 },
		mark = "crack",
		shake = 1.8,
		sounds = { cast = snd(SND.thud, 0.4, 0.5), launch = snd(SND.wind, 0.5, 0.45), impact = snd(SND.boom, 0.4, 0.8) },
	},
	reality = {
		body = { texture = TEX.square, size = 0.9, lifetime = 0.5, speed = 12, additive = true },
		sparks = { texture = TEX.sparkles, size = 0.35, speed = 30, gravity = 0, lifetime = 0.4 },
		smoke = nil,
		core = { dark = false },
		light = { brightness = 3, range = 1.3, flicker = 0.6 },
		mark = "rune",
		shake = 1,
		sounds = { cast = snd(SND.tick, 1.4, 0.45), launch = snd(SND.tick, 1.8, 0.4), impact = snd(SND.boom, 2.2, 0.45) },
	},
}

local DomainFx = {
	textures = TEX,
	sounds = SND,
	looks = looks,
}

-- The look for a domain id (falls back to energy, so a new domain still renders).
function DomainFx.look(domain: string?): Look
	return looks[domain or ""] or looks.energy
end

return DomainFx
