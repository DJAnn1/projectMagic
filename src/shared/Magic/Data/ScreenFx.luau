--!strict
--[[
	ScreenFx: what a spell does to your screen and your sky (docs/Smoothness.md, stage 4). Data only;
	Client/Fx/ScreenFx plays it, Fx/SpellFx and Fx/Staging call it. Cosmetic and client-only.

	FLASH    one per release: the view brightens and tints toward the spell's colour, then settles.
	         Your own spells flash by power; someone else's only when strong and near, weaker.
	         Big ones (power >= dipFrom, and every ultimate) leave a short darkening after (the eye
	         adjusting). At most one flash every `minGap` seconds.
	KICK     your own release nudges the camera up and back by power (a recoil).
	SKY      a domain ultimate tints and darkens the world round it while it runs, faded by distance;
	         `void` domains drain the colour almost to black (a pocket of nothing).
	Reduce spell effects / Reduce motion: no full-screen flash (only a faint tint), no kick, a
	weaker sky. Photosensitivity: flashes never exceed `maxBrightness`.
]]

local ScreenFx = {}

ScreenFx.flash = table.freeze({
	ownFrom = 3, -- your own spells flash from this power
	othersFrom = 7, -- someone else's from this power, within `othersRange`
	othersRange = 70,
	othersMult = 0.45,
	brightnessPerPower = 0.035, -- added brightness per power above `ownFrom - 1`
	maxBrightness = 0.35,
	tint = 0.35, -- how far the colour pulls toward the spell's (at full strength)
	rise = 0.05, -- seconds to peak
	fall = 0.35, -- seconds back to normal
	minGap = 0.6,
	reducedMult = 0.25, -- Reduce spell effects / motion: a faint tint only
	dipFrom = 8,
	dip = -0.12, -- brightness of the darkening after a big flash
	dipSeconds = 0.6,
})

ScreenFx.kick = table.freeze({
	-- Off (owner, 2026-11-17: "the camera movement is annoying as I keep having to readjust the
	-- camera"). Roblox's camera reads its own direction back each frame, so turning it after the
	-- camera scripts left the view tilted and every cast added to it. Spells don't move the
	-- camera's direction; if a kick ever comes back it must not turn the camera.
	enabled = false,
	degreesPerPower = 0.35,
	maxDegrees = 3,
	settle = 0.22, -- seconds back
})

export type Sky = { tint: Color3, brightness: number, saturation: number, contrast: number }

ScreenFx.sky = table.freeze({
	range = 260, -- studs from the ultimate: full strength inside `full`, nothing past `range`
	full = 80,
	fadeIn = 0.8,
	fadeOut = 1.2,
	reducedMult = 0.4,
	byDomain = {
		energy = { tint = Color3.fromRGB(255, 150, 120), brightness = -0.05, saturation = 0.15, contrast = 0.1 },
		earth = { tint = Color3.fromRGB(230, 200, 160), brightness = -0.1, saturation = -0.1, contrast = 0.15 },
		water = { tint = Color3.fromRGB(150, 190, 255), brightness = -0.08, saturation = 0, contrast = 0.05 },
		air = { tint = Color3.fromRGB(215, 235, 255), brightness = -0.04, saturation = -0.15, contrast = 0.05 },
		life = { tint = Color3.fromRGB(190, 255, 190), brightness = -0.03, saturation = 0.15, contrast = 0 },
		mind = { tint = Color3.fromRGB(230, 190, 255), brightness = -0.08, saturation = -0.1, contrast = 0.1 },
		spirit = { tint = Color3.fromRGB(200, 230, 255), brightness = -0.12, saturation = -0.25, contrast = 0.1 },
		void = { tint = Color3.fromRGB(150, 130, 190), brightness = -0.3, saturation = -0.85, contrast = 0.25 },
		space = { tint = Color3.fromRGB(150, 160, 255), brightness = -0.28, saturation = -0.6, contrast = 0.2 },
		time = { tint = Color3.fromRGB(255, 235, 180), brightness = -0.06, saturation = -0.5, contrast = 0.1 },
		gravity = { tint = Color3.fromRGB(190, 170, 230), brightness = -0.12, saturation = -0.2, contrast = 0.15 },
		reality = { tint = Color3.fromRGB(255, 170, 230), brightness = -0.25, saturation = -0.7, contrast = 0.25 },
	} :: { [string]: Sky },
})

return ScreenFx
