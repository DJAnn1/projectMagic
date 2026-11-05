--!strict
--[[
	Audio: the client's sound layer (docs/Audio.md). Every sound the game makes goes through here
	or through Fx/FxLayers.sound, which uses these groups too.

	GROUPS   SoundGroups under SoundService: Master, with Music, Spells, Combat, UI and Ambience
	         inside it (a child group's volume multiplies its parent's). Controllers/AudioController
	         sets their volumes from Settings.
	ROLES    Shared/Audio/AudioLibrary maps a role ("energy.impact", "ui.click") to a licensed
	         Creator Store asset. groupFor(role) puts it in the right group by its prefix.
	FALLBACK Everything in the library is preloaded once (preload); an asset that fails to load
	         (taken down, not allowed in this experience) is remembered, and resolve() hands back
	         the built-in fallback instead, so a broken pick goes quiet or plain, never errors.
	BUDGET   live one-shots per group are capped (CAPS); past a cap a sound is skipped, not queued.
]]

local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AudioLibrary = require(Shared.Audio.AudioLibrary)

export type PlayOptions = {
	position: Vector3?, -- 3D at this point; omit for a flat (UI-style) sound
	volume: number?, -- multiplies the library volume
	pitch: number?, -- PlaybackSpeed (before the ±4% variation)
	group: string?, -- overrides groupFor(role)
	fallback: string?, -- content id when the role is missing or failed to load
	vary: boolean?, -- ±4% pitch variation (default true for 3D sounds)
}

local CAPS: { [string]: number } = { Music = 4, Spells = 14, Combat = 10, UI = 6, Ambience = 4 }
local GROUP_NAMES = { "Music", "Spells", "Combat", "UI", "Ambience" }

local Audio = {}

local master: SoundGroup? = nil
local groups: { [string]: SoundGroup } = {}
local live: { [string]: number } = {}
local failed: { [string]: boolean } = {}
local rng = Random.new()

-- The SoundGroup for a name ("Music", "Spells", ...), created on first use.
function Audio.group(name: string): SoundGroup
	local existing = groups[name]
	if existing and existing.Parent then
		return existing
	end
	if not master or not master.Parent then
		local m = Instance.new("SoundGroup")
		m.Name = "Master"
		m.Parent = SoundService
		master = m
	end
	local g = Instance.new("SoundGroup")
	g.Name = name
	g.Parent = master
	groups[name] = g
	return g
end

function Audio.master(): SoundGroup
	Audio.group("UI") -- makes sure Master exists
	return master :: SoundGroup
end

-- Which group a role belongs to, from its prefix.
function Audio.groupFor(role: string): string
	local prefix = string.match(role, "^([%a]+)%.") or ""
	if prefix == "music" then
		return "Music"
	elseif prefix == "amb" then
		return "Ambience"
	elseif prefix == "ui" or prefix == "sting" then
		return "UI"
	elseif prefix == "combat" or prefix == "weapon" then
		return "Combat"
	end
	return "Spells"
end

-- A content id, or `fallback` if it's empty or known to have failed to load.
function Audio.resolve(id: string?, fallback: string?): string?
	if id and id ~= "" and not failed[id] then
		return id
	end
	return if fallback and fallback ~= "" then fallback else nil
end

-- The content id for a role (nil if the role has none, or it failed and there's no fallback).
function Audio.content(role: string, fallback: string?): string?
	return Audio.resolve(AudioLibrary.idOf(role), fallback)
end

function Audio.failed(id: string): boolean
	return failed[id] == true
end

-- Preloads every library asset once; failures are remembered (and reported once, together).
function Audio.preload()
	local ids: { string } = {}
	for role in AudioLibrary.entries do
		local id = AudioLibrary.idOf(role)
		if id then
			table.insert(ids, id)
		end
	end
	local bad: { string } = {}
	pcall(function()
		ContentProvider:PreloadAsync(ids, function(contentId: string, status: Enum.AssetFetchStatus)
			if status ~= Enum.AssetFetchStatus.Success then
				failed[contentId] = true
				table.insert(bad, contentId)
			end
		end)
	end)
	if #bad > 0 then
		warn(string.format("[Audio] %d of %d sounds failed to load and use fallbacks: %s", #bad, #ids, table.concat(bad, ", ")))
	end
	return #ids - #bad, #bad
end

-- Plays a content id once in a group. Returns the Sound (already playing) or nil.
function Audio.playId(id: string, groupName: string, volume: number, opts: PlayOptions?): Sound?
	local o: PlayOptions = opts or {}
	if (live[groupName] or 0) >= (CAPS[groupName] or 8) then
		return nil
	end
	live[groupName] = (live[groupName] or 0) + 1
	local holder: Instance
	if o.position then
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = o.position
		attachment.Parent = workspace.Terrain
		holder = attachment
	else
		holder = SoundService
	end
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	local vary = if o.vary == nil then o.position ~= nil else o.vary
	sound.PlaybackSpeed = (o.pitch or 1) * (if vary then 0.96 + rng:NextNumber() * 0.08 else 1)
	sound.SoundGroup = Audio.group(groupName)
	if o.position then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = 10
		sound.RollOffMaxDistance = 240
	end
	sound.Parent = holder
	sound:Play()
	local done = false
	local function cleanup()
		if done then
			return
		end
		done = true
		live[groupName] = math.max(0, (live[groupName] or 1) - 1)
		if holder ~= SoundService then
			holder:Destroy()
		else
			sound:Destroy()
		end
	end
	sound.Ended:Once(cleanup)
	task.delay(12, cleanup) -- one that never loads or never ends still frees its slot
	return sound
end

-- Plays a library role once. Returns the Sound or nil (no such role, failed, or over the cap).
function Audio.play(role: string, opts: PlayOptions?): Sound?
	local o: PlayOptions = opts or {}
	local entry = AudioLibrary.get(role)
	local id = Audio.content(role, o.fallback)
	if not id then
		return nil
	end
	local base = if entry and id == AudioLibrary.idOf(role) then entry.volume else 0.5
	return Audio.playId(id, o.group or Audio.groupFor(role), base * (o.volume or 1), o)
end

-- Makes every group (for AudioController's volumes before anything plays).
function Audio.ensureGroups()
	for _, name in GROUP_NAMES do
		Audio.group(name)
	end
end

Audio.GROUP_NAMES = GROUP_NAMES

return Audio
