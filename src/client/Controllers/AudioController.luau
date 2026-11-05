--!strict
--[[
	AudioController: volumes, music and ambience (docs/Audio.md). One-shot sounds (spells, combat,
	UI) are played where they happen, through Client/Audio/Audio; this owns the long sounds.

	VOLUMES  Settings › Volume: everything / music / spells / combat / menus and fanfares /
	         ambience set the SoundGroups' volumes (Master and the five inside it).
	MUSIC    every MUSIC_TICK seconds the director picks what should be playing:
	           combat    you were hurt, or your spell or weapon hit someone, in the last
	                     COMBAT_HOLD seconds (music.combat; starts at once, fades fast)
	           event     a world event covers where you stand (RegionInfo.event)
	           town      inside a settlement (night: music.night)
	           biome     snow / desert / mystic biomes have their own music
	           night     ClockTime 19:00–06:00
	           explore   everything else
	         A change waits until the new pick has held for SETTLE seconds and the current track
	         has played at least DWELL seconds (combat skips both), then crossfades over FADE.
	         Each start picks the role's main track or one of its alternates.
	AMBIENCE the biome's loop (birds, waves, frogs...), a town's crowd inside a settlement, and
	         crickets at night outside towns, crossfaded the same way. Roles with no pick yet
	         (wind, blizzard) are silence.
	PRELOAD  every library sound once at start (Audio.preload); failures fall back to built-ins.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AudioLibrary = require(Shared.Audio.AudioLibrary)
local Audio = require(script.Parent.Parent:WaitForChild("Audio").Audio)

local MUSIC_TICK = 1
local COMBAT_HOLD = 12
local SETTLE = 6
local DWELL = 25
local FADE = 3
local COMBAT_FADE = 1.2

local MUSIC_BIOME: { [string]: string } = {
	tundra = "music.snow", frostpeaks = "music.snow", frozen_coast = "music.snow",
	desert_dunes = "music.desert", badlands = "music.desert",
	ruinlands = "music.mystic", skyreach = "music.mystic", volcanic_highlands = "music.mystic",
}
local AMBIENCE_BIOME: { [string]: string } = {
	ocean = "amb.ocean", tidal_flats = "amb.ocean", frozen_coast = "amb.ocean",
	grasslands = "amb.grassland", deep_forest = "amb.forest", swamp = "amb.swamp",
	volcanic_highlands = "amb.volcano", ruinlands = "amb.cave",
	tundra = "amb.snow", frostpeaks = "amb.snow",
	desert_dunes = "amb.wind", badlands = "amb.wind", mountains = "amb.wind", skyreach = "amb.wind",
}
local NIGHT_AMBIENCE: { [string]: boolean } = { grasslands = true, deep_forest = true, swamp = true }

local VOLUME_SETTINGS: { [string]: string } = {
	Music = "volumeMusic", Spells = "volumeSpells", Combat = "volumeCombat", UI = "volumeUI", Ambience = "volumeAmbience",
}

local AudioController = {
	name = "AudioController",
	dependencies = { "MagicStateController" },
}

type Layer = {
	group: string,
	role: string?, -- what's playing (nil = silence)
	sound: Sound?,
	baseVolume: number,
	since: number, -- when the current role started
	pending: string?, -- what the director wants next
	pendingSince: number,
}

local magic: any = nil
local combatUntil = 0
local music: Layer = { group = "Music", role = nil, sound = nil, baseVolume = 0, since = -math.huge, pending = nil, pendingSince = 0 }
local ambience: Layer = { group = "Ambience", role = nil, sound = nil, baseVolume = 0, since = -math.huge, pending = nil, pendingSince = 0 }
local rng = Random.new()

-- ─── Volumes ────────────────────────────────────────────────────────────────

local function applyVolumes(settings: { [string]: any })
	local function value(key: string, default: number): number
		local v = settings[key]
		return if typeof(v) == "number" then math.clamp(v, 0, 1) else default
	end
	Audio.master().Volume = value("volumeMaster", 1)
	for group, key in VOLUME_SETTINGS do
		Audio.group(group).Volume = value(key, if group == "Music" then 0.5 else 1)
	end
end

-- ─── Long sounds (music, ambience) ──────────────────────────────────────────

-- A role's main track or one of its alternates, at random. Returns (content id, volume) or nil.
local function pickTrack(role: string): (string?, number)
	local entry = AudioLibrary.get(role)
	if not entry then
		return nil, 0
	end
	local choices = { entry.id }
	for _, alt in (entry.alt or {}) :: { { id: number, name: string } } do
		table.insert(choices, alt.id)
	end
	-- Prefer tracks that loaded; if none did, there's nothing to play.
	for _ = 1, #choices do
		local id = "rbxassetid://" .. tostring(choices[rng:NextInteger(1, #choices)])
		if not Audio.failed(id) then
			return id, entry.volume
		end
	end
	return nil, 0
end

local function fadeOut(sound: Sound, seconds: number)
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Volume = 0 })
	tween.Completed:Once(function()
		sound:Destroy()
	end)
	tween:Play()
end

-- Crossfades a layer to `role` (nil = fade to silence).
local function switch(layer: Layer, role: string?, seconds: number)
	local old = layer.sound
	layer.role, layer.sound, layer.since = role, nil, os.clock()
	if old then
		fadeOut(old, seconds)
	end
	if not role then
		return
	end
	local id, volume = pickTrack(role)
	if not id then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = role
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.SoundGroup = Audio.group(layer.group)
	sound.Parent = Audio.group(layer.group)
	sound:Play()
	TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Volume = volume }):Play()
	layer.sound, layer.baseVolume = sound, volume
end

-- Moves a layer toward `want`, respecting SETTLE and DWELL unless `urgent`.
local function steer(layer: Layer, want: string?, urgent: boolean, fade: number)
	local t = os.clock()
	if want == layer.role then
		layer.pending = nil
		return
	end
	if urgent or (layer.role == nil and layer.sound == nil) then
		-- Combat, or nothing playing yet (the first track after joining starts at once).
		switch(layer, want, fade)
		layer.pending = nil
		return
	end
	if layer.pending ~= want then
		layer.pending, layer.pendingSince = want, t
		return
	end
	if t - layer.pendingSince >= SETTLE and t - layer.since >= DWELL then
		switch(layer, want, fade)
		layer.pending = nil
	end
end

-- ─── The director ───────────────────────────────────────────────────────────

local function isNight(): boolean
	local hour = Lighting.ClockTime
	return hour >= 19 or hour < 6
end

local function wantedMusic(region: any): (string, boolean)
	if os.clock() < combatUntil then
		return "music.combat", true
	end
	if region and typeof(region.event) == "string" then
		return "music.event", false
	end
	local night = isNight()
	if region and region.settlement then
		return if night then "music.night" else "music.town", false
	end
	local biome = region and MUSIC_BIOME[region.biome]
	if biome then
		return biome, false
	end
	return if night then "music.night" else "music.explore", false
end

local function wantedAmbience(region: any): string?
	if not region then
		return nil
	end
	if region.settlement then
		return "amb.town"
	end
	if isNight() and NIGHT_AMBIENCE[region.biome] then
		return "amb.night"
	end
	local role = AMBIENCE_BIOME[region.biome]
	return if role and AudioLibrary.get(role) then role else nil
end

local function tick()
	local region = magic.region:get()
	local want, urgent = wantedMusic(region)
	-- Leaving combat isn't urgent: the battle music finishes its fade naturally.
	steer(music, want, urgent and music.role ~= "music.combat", if urgent then COMBAT_FADE else FADE)
	steer(ambience, wantedAmbience(region), false, FADE)
end

-- Combat: you were hurt, or your attack hit someone.
local function noteCombat()
	combatUntil = os.clock() + COMBAT_HOLD
end

local function watchHealth(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	local last = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		if health < last - 0.5 then
			noteCombat()
		end
		last = health
	end)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function AudioController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
	Audio.ensureGroups()
end

function AudioController.start(_self: any, _ctx: any)
	applyVolumes(magic.settings:get())
	magic.settings:observe(applyVolumes)

	task.spawn(Audio.preload)

	magic.events:Connect(function(event: any)
		if typeof(event) ~= "table" then
			return
		end
		local result = event.result
		local landed = (event.kind == "cast" and typeof(result) == "table" and typeof(result.damage) == "number" and result.damage > 0)
			or (event.kind == "melee" and typeof(result) == "table" and result.hit == true)
		if landed then
			noteCombat()
		end
	end)
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(watchHealth)
	if player.Character then
		task.spawn(watchHealth, player.Character)
	end

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < MUSIC_TICK then
			return
		end
		acc = 0
		local ok, err = pcall(tick)
		if not ok then
			warn("[AudioController] " .. tostring(err))
		end
	end)
end

return AudioController
