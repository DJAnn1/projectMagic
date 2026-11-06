--!strict
--[[
	Emotes: every gesture in the game, as data (docs/Social.md §5).

		clip      a Roblox default R6 animation, played by the owner's client (it replicates)
		pose      a procedural R6 pose (client/Fx/EmotePoses), drawn by each viewer locally
		flourish  a signature-tinted effect (client/Fx/EmoteFx), drawn by each viewer locally
		seconds   how long it lasts at most; moving, casting or being hit ends it sooner
		cooldown  seconds before this player can start ANOTHER emote (server-enforced)
		command   the chat command, without the slash (Client/Controllers/EmoteController)

	Adding an emote is one entry here. Order is the order on the radial menu.
]]

export type Emote = {
	id: string,
	label: string,
	glyph: string,
	command: string,
	seconds: number,
	cooldown: number,
	clip: string?,
	pose: string?,
	flourish: string?,
	loop: boolean?,
}

local list: { Emote } = {
	{ id = "wave", label = "Wave", glyph = "~", command = "wave", seconds = 2.5, cooldown = 2, clip = "rbxassetid://128777973" },
	{ id = "bow", label = "Bow", glyph = "v", command = "bow", seconds = 2.2, cooldown = 2, pose = "bow" },
	{ id = "cheer", label = "Cheer", glyph = "!", command = "cheer", seconds = 2.5, cooldown = 2, clip = "rbxassetid://129423030" },
	{ id = "laugh", label = "Laugh", glyph = "ha", command = "laugh", seconds = 2.5, cooldown = 2, clip = "rbxassetid://129423131" },
	{ id = "dance", label = "Dance", glyph = "♪", command = "dance", seconds = 30, cooldown = 2, clip = "rbxassetid://182435998", loop = true },
	{ id = "meditate", label = "Meditate", glyph = "o", command = "meditate", seconds = 120, cooldown = 2, pose = "meditate", flourish = "motes", loop = true },
	{ id = "light_show", label = "Light show", glyph = "✦", command = "lightshow", seconds = 3.5, cooldown = 8, flourish = "light_show" },
	{ id = "halo", label = "Halo", glyph = "◯", command = "halo", seconds = 3, cooldown = 8, flourish = "halo" },
}

local byId: { [string]: Emote } = {}
for _, emote in list do
	byId[emote.id] = emote
end

return table.freeze({
	list = list,
	byId = byId,
	range = 150, -- studs: who is told about an emote
	moveLimit = 1.5, -- studs: walking this far ends an emote
})
