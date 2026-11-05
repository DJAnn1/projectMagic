--!strict
--[[
	AudioLibrary: every sound the game uses, by role (docs/Audio.md). Pure data, shared.

	Sources (both licensed for every Roblox experience, so they keep working):
		ProSoundEffects  sound effects        APMOfficial  music and stingers
	Picked 2026-11-05 by name and length from the Creator Store; NOT yet auditioned. docs/Audio.md
	links each one to its store page. To swap one, change its id (alternates are listed).

	role = { id, name, alt = { { id, name } }?, loop, volume }
	Missing roles (no good licensed match yet): amb.wind, amb.snow.
]]

export type Entry = { id: number, name: string, alt: { { id: number, name: string } }?, loop: boolean, volume: number }

local entries: { [string]: Entry } = {
	["energy.cast"] = { id = 9114446852, name = "Fire Whoosh 15", loop = false, volume = 0.5 },
	["energy.launch"] = { id = 9114428740, name = "Fireball Pass By 1", loop = false, volume = 0.55 },
	["energy.impact"] = { id = 9114554567, name = "Gas Fire Explosion 3", alt = { { id = 9114554766, name = "Gas Fire Explosion 4" } }, loop = false, volume = 0.65 },
	["lightning.zap"] = { id = 9114277757, name = "Electric Zaps 12", alt = { { id = 9114277402, name = "Electric Zaps 6" } }, loop = false, volume = 0.5 },
	["lightning.strike"] = { id = 9126082854, name = "Synth Thunder Cracks Individual Explosion", alt = { { id = 9119841134, name = "Synth Thunder Tubular Cracks Rolls 2" } }, loop = false, volume = 0.7 },
	["earth.cast"] = { id = 9125881620, name = "Rock Scrape Deep Tumbling Clunks", alt = { { id = 9113222322, name = "Avalanche Rumble 8" } }, loop = false, volume = 0.55 },
	["earth.launch"] = { id = 9114658416, name = "Gravel Slide 1", loop = false, volume = 0.5 },
	["earth.impact"] = { id = 9125869504, name = "Rock Cracks Rock Hitting Rock Impact Debris", alt = { { id = 9118612665, name = "Rock Impact 7" } }, loop = false, volume = 0.7 },
	["water.cast"] = { id = 9116317694, name = "Liquid Shake 2", loop = false, volume = 0.5 },
	["water.launch"] = { id = 9118859146, name = "Seahorse Splash Fast 402", alt = { { id = 9117822127, name = "Pool Jumps Splashes Water Impact" } }, loop = false, volume = 0.5 },
	["water.impact"] = { id = 9120585252, name = "Water Splash Big Dive In 1", alt = { { id = 9120585530, name = "Water Splash Big Dive In 3" } }, loop = false, volume = 0.65 },
	["air.cast"] = { id = 9113324270, name = "Basement Wind Tubular Airy Swirling 13", loop = false, volume = 0.5 },
	["air.launch"] = { id = 9126283592, name = "Swish Whoosh Fast Movement In Air", loop = false, volume = 0.5 },
	["air.impact"] = { id = 9120749463, name = "Wind Burst Alien Vortex Blasts 11", alt = { { id = 9120749311, name = "Wind Burst Alien Vortex Blasts 8" } }, loop = false, volume = 0.6 },
	["life.cast"] = { id = 9114369623, name = "Fairy Dust 1", alt = { { id = 9125635650, name = "Magical Exit Sparkling Pass Bys" } }, loop = false, volume = 0.5 },
	["life.launch"] = { id = 9116411685, name = "Magic Swoosh Fast Zooming Pass Bys 18", alt = { { id = 9125647212, name = "Magic Whooshes Metallic Shimmering" } }, loop = false, volume = 0.5 },
	["life.impact"] = { id = 9116395089, name = "Magic Glows Soft Chiming Hits 4", alt = { { id = 9114519078, name = "Foliage Rustle 1" } }, loop = false, volume = 0.55 },
	["mind.cast"] = { id = 9126213995, name = "Whisper Bursts Unintelligible Eerie", loop = false, volume = 0.45 },
	["mind.launch"] = { id = 9114340693, name = "Energy Pass By Sci Fi Tonal Whooshes", loop = false, volume = 0.5 },
	["mind.impact"] = { id = 9125740659, name = "Pipe Ring Offs Soft Ringing Impacts", loop = false, volume = 0.55 },
	["spirit.cast"] = { id = 9043336050, name = "SWELL 22 (APM)", alt = { { id = 9043347151, name = "DISTURBED WHISPERS 06 (APM)" } }, loop = false, volume = 0.5 },
	["spirit.launch"] = { id = 9113080102, name = "Airy Pass By Fast Breathing Rush Of Air 2", loop = false, volume = 0.5 },
	["spirit.impact"] = { id = 9113804401, name = "Church Bell Soft Clanking Hits 2", loop = false, volume = 0.55 },
	["void.cast"] = { id = 9114344093, name = "Energy Presence 8", loop = false, volume = 0.55 },
	["void.launch"] = { id = 9125404594, name = "Boom Pass By Subtle Low End", loop = false, volume = 0.55 },
	["void.impact"] = { id = 9125404320, name = "Boom Impact Deep Distant Thumping", loop = false, volume = 0.7 },
	["space.cast"] = { id = 9126102694, name = "Time Warp Searing Build Up Large Suck", loop = false, volume = 0.55 },
	["space.launch"] = { id = 9118158795, name = "Reverse Suck 1", loop = false, volume = 0.5 },
	["space.impact"] = { id = 9114315023, name = "Energy Burst Growl 1", alt = { { id = 9120057087, name = "Time Warp Build Up Boomy Explosion 5" } }, loop = false, volume = 0.65 },
	["time.cast"] = { id = 9114064432, name = "Dial Switch Twisting Sharp Ticking 3", loop = false, volume = 0.5 },
	["time.launch"] = { id = 9120984892, name = "Zap High Pitch Glassy Reversed Whoosh 9", alt = { { id = 9118158113, name = "Reversed Whoosh Backwards Hissing Burst 2" } }, loop = false, volume = 0.5 },
	["time.impact"] = { id = 9119447936, name = "Sparkle Bell Tree Wind Chimes 1", loop = false, volume = 0.6 },
	["gravity.cast"] = { id = 9126009589, name = "Subwoofer Impact Deep Rumbling Pops", loop = false, volume = 0.6 },
	["gravity.launch"] = { id = 9120728815, name = "Whoosh Heavy Punches 1", loop = false, volume = 0.55 },
	["gravity.impact"] = { id = 9118617342, name = "Rock Impact Large Hit Scrape 1", alt = { { id = 9113470178, name = "Body Fall Heavy 3" } }, loop = false, volume = 0.75 },
	["reality.cast"] = { id = 9126160991, name = "Video Static Distortion Burst", loop = false, volume = 0.45 },
	["reality.launch"] = { id = 9114240232, name = "Airy Whirring Whine Pass By 16", loop = false, volume = 0.5 },
	["reality.impact"] = { id = 9114592245, name = "Glass Breaks 3", alt = { { id = 9114855870, name = "Ice Block Drop To Concrete Shatter 1" } }, loop = false, volume = 0.6 },
	["spell.charge"] = { id = 9125973984, name = "Energy Charge Up (high pitch)", alt = { { id = 9125974435, name = "Energy Charge Up 2" } }, loop = false, volume = 0.45 },
	["spell.beam"] = { id = 9125550012, name = "Energy Slow Synth Pulsing Buzz Hum", loop = true, volume = 0.4 },
	["spell.zone"] = { id = 9125674129, name = "Metallic Glow Constant Deep Ticking Bassy Hum", loop = true, volume = 0.35 },
	["spell.backfire"] = { id = 9119236749, name = "Small Explosion 1", loop = false, volume = 0.65 },
	["combat.hit"] = { id = 9113502506, name = "Body Hits 8", alt = { { id = 9113534108, name = "Body Pats Cloth Hits 24" } }, loop = false, volume = 0.55 },
	["combat.crit"] = { id = 9113566123, name = "Boxing Hits 19", alt = { { id = 9120728815, name = "Whoosh Heavy Punches 1" } }, loop = false, volume = 0.65 },
	["combat.kill"] = { id = 9113480915, name = "Body Fall Thud 2", loop = false, volume = 0.6 },
	["combat.knockdown"] = { id = 9113475819, name = "Body Fall Master 28", loop = false, volume = 0.6 },
	["combat.block"] = { id = 9119072660, name = "Shield Clang As Hit Metal Sword 1", alt = { { id = 9119072674, name = "Shield Clang 2" } }, loop = false, volume = 0.6 },
	["combat.parry"] = { id = 9116709512, name = "Metal Impacts And Scrapes 8", loop = false, volume = 0.65 },
	["combat.slash"] = { id = 9120972321, name = "Whoosh Slicing Air Quick Swings 4", alt = { { id = 9126229280, name = "Whoosh By Fast Airy Swooshing" } }, loop = false, volume = 0.5 },
	["combat.dash"] = { id = 9120704978, name = "Whooshes Fast Wipes Quick Airy Slices 3", loop = false, volume = 0.5 },
	["weapon.bowRelease"] = { id = 9125407239, name = "Bow Stretches Wood Creaking (check: may be the draw, not the release)", loop = false, volume = 0.5 },
	["weapon.arrowHit"] = { id = 9113161857, name = "Arrow In And Hit 19", loop = false, volume = 0.55 },
	["ui.click"] = { id = 9119717523, name = "Switch Click Toggle Button 2", alt = { { id = 9119717529, name = "Switch Click Toggle Button 1" } }, loop = false, volume = 0.35 },
	["ui.open"] = { id = 9118835414, name = "Scrapbook Open And Turn Pages 2", loop = false, volume = 0.4 },
	["ui.close"] = { id = 9113819036, name = "Cloth Flap 16", loop = false, volume = 0.35 },
	["ui.confirm"] = { id = 9116394545, name = "Magic Glows Soft Chiming Hits 1", loop = false, volume = 0.4 },
	["ui.notify"] = { id = 9126073001, name = "Synth Sparkle Bell Tone Ding", loop = false, volume = 0.35 },
	["ui.error"] = { id = 9113085764, name = "Alarm Buzzer 5 (play quiet)", alt = { { id = 9116271264, name = "Light Bulb Buzz 15" } }, loop = false, volume = 0.25 },
	["sting.awakening"] = { id = 9039420865, name = "Something Magical (sting)", alt = { { id = 9048764475, name = "Magical Meetup - Hit2" } }, loop = false, volume = 0.6 },
	["sting.breakthrough"] = { id = 1845287239, name = "Triumphant Fanfare", alt = { { id = 1837953552, name = "Triumphant Escape Sting" } }, loop = false, volume = 0.6 },
	["sting.tierUp"] = { id = 1848016523, name = "Global Success StingA", alt = { { id = 9041815872, name = "The Heroes Return" } }, loop = false, volume = 0.55 },
	["sting.discovery"] = { id = 1837765739, name = "New Discovery (sting)", alt = { { id = 9040172806, name = "Small Discoveries (sting b)" } }, loop = false, volume = 0.55 },
	["sting.questDone"] = { id = 1838597103, name = "Four Short Fanfare Bridges 4", loop = false, volume = 0.55 },
	["amb.forest"] = { id = 9112835056, name = "Neighborhood Birds 1", alt = { { id = 9112807051, name = "Jungle Dawn 3" } }, loop = true, volume = 0.3 },
	["amb.grassland"] = { id = 9116969466, name = "Morning Birds 2", loop = true, volume = 0.3 },
	["amb.swamp"] = { id = 9112807844, name = "Jungle Frogs 1", loop = true, volume = 0.3 },
	["amb.ocean"] = { id = 9126201834, name = "Waves Long Rolling In Constantly Heavy Surf", alt = { { id = 9120572331, name = "Water Lap Small Waves 1" } }, loop = true, volume = 0.35 },
	["amb.night"] = { id = 9112764573, name = "Crickets Night 3", loop = true, volume = 0.3 },
	["amb.town"] = { id = 9112767169, name = "Crowd Walla 1", loop = true, volume = 0.2 },
	["amb.cave"] = { id = 9120590261, name = "Water Splatter Drip 2", loop = true, volume = 0.3 },
	["amb.volcano"] = { id = 9118030782, name = "Rain Of Fire 3", loop = true, volume = 0.3 },
	["amb.rain"] = { id = 9112853422, name = "Rain Heavy Rainfall Grass Wooden Roof 1", loop = true, volume = 0.35 },
	["music.explore"] = { id = 1841593944, name = "Enchanted Kingdom a", alt = { { id = 1837211641, name = "The Enchanted Forest" }, { id = 1844859347, name = "Holy Mission" } }, loop = true, volume = 0.3 },
	["music.town"] = { id = 1847223666, name = "Medieval Market D", alt = { { id = 1839906422, name = "Medieval Castle" } }, loop = true, volume = 0.3 },
	["music.night"] = { id = 9045934037, name = "The Night Sky - Underscore", alt = { { id = 138749442993417, name = "Night Reflections (Ambience Version)" } }, loop = true, volume = 0.25 },
	["music.combat"] = { id = 1836963388, name = "Into Battle", alt = { { id = 1836104000, name = "Determined Epic Theme (Alt 1)" } }, loop = true, volume = 0.35 },
	["music.event"] = { id = 9044407196, name = "Back to the Shadows 60A", loop = true, volume = 0.3 },
	["music.mystic"] = { id = 1839883317, name = "Mystical Nature", alt = { { id = 1842471518, name = "Mystical Journey (A)" } }, loop = true, volume = 0.3 },
	["music.snow"] = { id = 1844634116, name = "Frozen Planet", loop = true, volume = 0.3 },
	["music.desert"] = { id = 1839873157, name = "Desert Journey (b)", loop = true, volume = 0.3 },
}

local AudioLibrary = {}
AudioLibrary.entries = entries

-- The entry for a role, or nil.
function AudioLibrary.get(role: string): Entry?
	return entries[role]
end

-- The "rbxassetid://" content id for a role, or nil.
function AudioLibrary.idOf(role: string): string?
	local entry = entries[role]
	return if entry then "rbxassetid://" .. tostring(entry.id) else nil
end

return AudioLibrary
