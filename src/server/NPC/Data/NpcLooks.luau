--!strict
--[[
	NpcLooks data: what NPCs wear on their heads (docs/NPC.md §6c). Every id is a Roblox-made
	catalog accessory (creator "Roblox"), so InsertService:LoadAsset can load it on the server
	whatever its price, and it won't be deleted the way third-party items can be. Picked
	2026-11-05 from the catalog by name; the rules that choose between them live in NPC/NpcLooks.

	hair       by the hair colour NPCFactory already rolls (appearance.hair); "ash", "grey" and
	           "white" have no natural Roblox hair, so those NPCs wear the pale pool more often
	           under a hat or hood
	headwear   pools by kind; `coversHair` drops the hair underneath (helms, hoods)
	byOccupation  chance of headwear and which pools; `culture` overrides per culture
	beards / glasses / eyepatch / scarves  extras driven by the generated feature, age and culture
	scale      body scale per generated build (R6 rigs, Model:ScaleTo)
]]

export type Pool = { ids: { number }, coversHair: boolean }
export type Rule = { chance: number, pools: { string } }

local NpcLooks = {}

NpcLooks.hair = {
	black = {
		1772372988, -- Black Long and Straight Hair
		80922251, -- Black Messy Bun
		7193450455, -- Curly Afro - Black
		7193405096, -- Curly Fade - Black
		9243992729, -- Short and Sleek - Black
		9244111257, -- Wavy Middle Part - Black
		6993754725, -- Straight Bangs - Black
		295456068, -- Dreamy Black Hair
	},
	brown = {
		62234425, -- Brown Hair
		376548738, -- Brown Charmer Hair
		63690008, -- Pal Hair
		17877340, -- Beautiful Brown Hair for Beautiful People
		212961935, -- Big Style Brown Hair
		3814496544, -- Straight Brunette Hair
		7193451306, -- Curly Afro - Cool Brown
		9244010432, -- Curly Fade - Brown
		7193448258, -- Wavy Middle Part - Brown
		343584973, -- Man Bun Hair
		20372960, -- Bed Hair
		26658141, -- Messy Hair
		13477818, -- Normal Boy Hair
		1772336109, -- Down to Earth Hair
	},
	auburn = {
		3814481268, -- Straight Auburn Hair
		81688919, -- Auburn Messy Bun
		25308317, -- Messy Amber Bun
		13745548, -- Cinnamon Hair
	},
	red = {
		2956239660, -- Belle Of Belfast Long Red Hair
		9244131570, -- Curly Afro - Red
		9244014391, -- Curly Fade - Red
		9244114211, -- Wavy Middle Part - Red
		221175027, -- Beautiful Red Hair for Beautiful People
		185893592, -- Red Curly Pigtails
	},
	blond = {
		376526888, -- Straight Blonde Hair
		77800073, -- Blonde Messy Bun
		9244125859, -- Curly Afro - Blonde
		9244008307, -- Curly Fade - Blonde
		7193445686, -- Wavy Middle Part - Blonde
		9243987340, -- Short and Sleek - Blonde
		233615637, -- Beautiful Blonde Hair for Beautiful People
		13476917, -- Golden Hair
	},
}

-- NPCFactory's hair colours -> the pools above (nil = the pale pool: blond, under a hat more often).
NpcLooks.hairColour = {
	black = "black",
	["dark brown"] = "brown",
	brown = "brown",
	auburn = "auburn",
	red = "red",
	blond = "blond",
	ash = "blond",
	grey = "blond",
	white = "blond",
} :: { [string]: string }
NpcLooks.paleColours = { ash = true, grey = true, white = true } :: { [string]: boolean }

NpcLooks.headwear = {
	helm = { coversHair = true, ids = {
		10832171, -- Spartan Helmet
		67239894, -- Silver Plumed Knight
		34898501, -- White Knight
		66333385, -- Grey Knight
		298084053, -- Norse Scout Helmet
		98450250, -- Heavy Iron Helmet
	} },
	northHelm = { coversHair = true, ids = {
		33337024, -- Viking Knight
		298084053, -- Norse Scout Helmet
		62150694, -- Winged Helm of the Northern Brothers
		1323367, -- Helm of the Frozen North
	} },
	wizard = { coversHair = false, ids = {
		13149521, -- Apprentice Wizard Hat
		54957229, -- Old Wizard
		11441821, -- Hedge Wizard's Hat
		57001168, -- Wizard's Apprentice
		13121508, -- Frumpled Wizard Hat of Old Coots
	} },
	waterWizard = { coversHair = false, ids = {
		13149601, -- Blue Hydromage Wizard Hat
		13121435, -- Violet Wizard Hat of Nightshade
	} },
	greenWizard = { coversHair = false, ids = {
		13121696, -- Green Wizard Hat of Vitae
		78033535, -- Deep Forest Wizard
	} },
	fireWizard = { coversHair = false, ids = {
		13121630, -- Red Wizard Hat of Flames
		116770658, -- Fire Wizard
	} },
	straw = { coversHair = false, ids = {
		116778296, -- Wide-brimmed Straw Cap
	} },
	sailor = { coversHair = false, ids = {
		10058505, -- Sailor Cap
		271015438, -- Captain's Tricorn
		5808105, -- Black Tricorne
	} },
	tricorn = { coversHair = false, ids = {
		271015438, -- Captain's Tricorn
		5808105, -- Black Tricorne
	} },
	hood = { coversHair = true, ids = {
		617605556, -- Medieval Hood of Mystery
		102623080, -- Brown Riding Hood
		16954107, -- Viridian Hood
	} },
	furHood = { coversHair = true, ids = {
		18171366, -- Arctic Hood
		335078777, -- Brown Furry Animal Hood and Scarf
	} },
	iron = { coversHair = true, ids = {
		98450250, -- Heavy Iron Helmet
		391491339, -- Metal Pot Helm
	} },
} :: { [string]: Pool }

-- Occupation -> chance of headwear and which pools it draws from.
NpcLooks.byOccupation = {
	guard = { chance = 0.9, pools = { "helm" } },
	scholar = { chance = 0.45, pools = { "wizard" } },
	weathercaller = { chance = 0.6, pools = { "waterWizard", "wizard" } },
	tidepriest = { chance = 0.4, pools = { "waterWizard" } },
	healer = { chance = 0.3, pools = { "greenWizard", "hood" } },
	herbalist = { chance = 0.35, pools = { "greenWizard", "hood" } },
	farmer = { chance = 0.6, pools = { "straw" } },
	fisher = { chance = 0.6, pools = { "sailor" } },
	merchant = { chance = 0.3, pools = { "tricorn", "hood" } },
	hunter = { chance = 0.5, pools = { "hood" } },
	lamplighter = { chance = 0.3, pools = { "hood" } },
	smith = { chance = 0.2, pools = { "iron" } },
	miner = { chance = 0.3, pools = { "iron" } },
	builder = { chance = 0.15, pools = { "iron" } },
	retired = { chance = 0.3, pools = { "wizard", "hood" } },
	innkeeper = { chance = 0, pools = {} },
	child = { chance = 0.05, pools = { "hood" } },
} :: { [string]: Rule }

-- Culture overrides: their guards, and an extra chance of the culture's own headwear.
NpcLooks.culture = {
	frostfolk = { guardPools = { "northHelm" }, extra = { chance = 0.3, pools = { "furHood" } }, scarf = 0.5 },
	skywarden = { guardPools = { "northHelm", "helm" } },
	tidecall = { extra = { chance = 0.15, pools = { "sailor" } } },
	wayfarer = { extra = { chance = 0.3, pools = { "hood" } } },
	emberclan = { extra = { chance = 0.12, pools = { "fireWizard" } } },
	verdant = { extra = { chance = 0.12, pools = { "greenWizard" } } },
	loreseat = { extra = { chance = 0.15, pools = { "wizard" } } },
	forgehold = { extra = { chance = 0.12, pools = { "iron" } } },
} :: { [string]: { guardPools: { string }?, extra: Rule?, scarf: number? } }

NpcLooks.beards = {
	dark = 158066137, -- Andrew's Beard
	red = 461491285, -- Red Braided Beard
	blond = 323418594, -- Daring Blonde Beard
	wizard = 461493477, -- Ancient Wizard Beard (elder scholars, weathercallers, the retired)
}
NpcLooks.glasses = 22070802 -- Secret Kid Wizard Glasses ("spectacles")
NpcLooks.eyepatch = 144506397 -- Leather Eyepatch (a few old guards and hunters)
NpcLooks.scarves = {
	99860652, -- Crimson Winter Scarf
	1149617482, -- Orange Winter Scarf
	323420663, -- Purple Winter Scarf
}

-- Chances for the extras.
NpcLooks.odds = {
	bald = 0.12, -- adults and elders with no hair at all
	beardAdult = 0.18,
	beardElder = 0.4,
	wizardBeard = 0.5, -- of elder scholars / weathercallers / retired who get a beard
	eyepatch = 0.06, -- elder guards and hunters
}

NpcLooks.scale = {
	slight = 0.93, wiry = 0.97, average = 1, sturdy = 1.03, broad = 1.06, heavy = 1.08,
} :: { [string]: number }
NpcLooks.childScale = 0.8

-- ─── Clothing (parts welded to the R6 body) ─────────────────────────────────
--[[
	Roblox makes no medieval classic clothing, so outfits are a few thin parts welded to the body
	over the existing shirt/trouser colours. SmoothPlastic, never Fabric: ThermalSim treats Fabric
	as tinder, and NPCs shouldn't catch fire from a nearby spell by accident.

	garments   shape and place of each piece on its R6 body part (offset from that part's centre)
	outfits    per occupation: pieces always worn, and pieces worn by chance
	palette    the culture's cloth colours (tabards, robes, cloaks, sashes)
	fixed      colours some pieces always have (leather aprons, white aprons)
	wealth     socialClass shifts: "low" mutes and darkens the cloth, "high" deepens it, adds a
	           metal buckle and makes a cloak likelier
]]
NpcLooks.garments = {
	belt = { attach = "Torso", size = Vector3.new(2.06, 0.28, 1.06), offset = CFrame.new(0, -0.82, 0) },
	buckle = { attach = "Torso", size = Vector3.new(0.34, 0.24, 0.06), offset = CFrame.new(0, -0.82, -0.56), metal = true },
	apron = { attach = "Torso", size = Vector3.new(1.5, 2.7, 0.08), offset = CFrame.new(0, -0.75, -0.55) },
	tabardFront = { attach = "Torso", size = Vector3.new(1.35, 3.0, 0.08), offset = CFrame.new(0, -0.6, -0.55) },
	tabardBack = { attach = "Torso", size = Vector3.new(1.35, 3.0, 0.08), offset = CFrame.new(0, -0.6, 0.55) },
	robe = { attach = "Torso", size = Vector3.new(2.2, 1.9, 1.25), offset = CFrame.new(0, -1.95, 0) },
	cloak = { attach = "Torso", size = Vector3.new(2.15, 3.3, 0.1), offset = CFrame.new(0, -0.55, 0.58) },
	sash = { attach = "Torso", size = Vector3.new(0.32, 2.75, 1.08), offset = CFrame.Angles(0, 0, math.rad(38)) },
	wristR = { attach = "Right Arm", size = Vector3.new(1.06, 0.18, 1.06), offset = CFrame.new(0, -0.72, 0) },
	wristL = { attach = "Left Arm", size = Vector3.new(1.06, 0.18, 1.06), offset = CFrame.new(0, -0.72, 0) },
} :: { [string]: { attach: string, size: Vector3, offset: CFrame, metal: boolean? } }

-- Colour sources: "culture" (palette), "leather", "linen" (white aprons), "dark".
NpcLooks.outfits = {
	guard = { always = { tabardFront = "culture", tabardBack = "culture", belt = "leather" }, maybe = { cloak = { 0.35, "culture" } } },
	smith = { always = { apron = "leather", belt = "leather" } },
	miner = { always = { belt = "leather" }, maybe = { apron = { 0.3, "leather" } } },
	builder = { always = { belt = "leather" }, maybe = { apron = { 0.4, "leather" } } },
	farmer = { always = { belt = "leather" }, maybe = { apron = { 0.3, "linen" } } },
	herbalist = { always = { apron = "culture", belt = "leather" } },
	healer = { always = { apron = "linen", belt = "leather" }, maybe = { robe = { 0.3, "culture" } } },
	lamplighter = { always = { belt = "leather" }, maybe = { cloak = { 0.5, "dark" } } },
	tidepriest = { always = { robe = "culture", sash = "culture2" } },
	fisher = { always = { belt = "leather" }, maybe = { apron = { 0.3, "oilskin" } } },
	weathercaller = { always = { robe = "culture" }, maybe = { sash = { 0.6, "culture2" }, cloak = { 0.3, "culture" } } },
	scholar = { always = { robe = "culture" }, maybe = { sash = { 0.5, "culture2" } } },
	merchant = { always = { belt = "leather" }, maybe = { sash = { 0.3, "culture" }, cloak = { 0.25, "culture" } } },
	innkeeper = { always = { apron = "linen", belt = "leather" } },
	hunter = { always = { cloak = "dark", belt = "leather" } },
	child = { maybe = { belt = { 0.5, "leather" } } },
	retired = { always = { belt = "leather" }, maybe = { robe = { 0.3, "culture" }, cloak = { 0.3, "dark" } } },
} :: { [string]: { always: { [string]: string }?, maybe: { [string]: { any } }? } }

NpcLooks.palette = {
	tidecall = { Color3.fromRGB(46, 86, 128), Color3.fromRGB(64, 128, 132), Color3.fromRGB(196, 180, 140), Color3.fromRGB(32, 58, 92) },
	frostfolk = { Color3.fromRGB(118, 124, 134), Color3.fromRGB(214, 216, 220), Color3.fromRGB(128, 36, 40), Color3.fromRGB(70, 74, 84) },
	loreseat = { Color3.fromRGB(78, 52, 112), Color3.fromRGB(36, 46, 96), Color3.fromRGB(146, 120, 70), Color3.fromRGB(58, 40, 72) },
	verdant = { Color3.fromRGB(60, 104, 54), Color3.fromRGB(102, 82, 50), Color3.fromRGB(140, 152, 74), Color3.fromRGB(42, 70, 46) },
	forgehold = { Color3.fromRGB(58, 56, 60), Color3.fromRGB(128, 64, 40), Color3.fromRGB(90, 68, 50), Color3.fromRGB(150, 110, 60) },
	skywarden = { Color3.fromRGB(214, 222, 232), Color3.fromRGB(110, 150, 200), Color3.fromRGB(180, 184, 196), Color3.fromRGB(70, 96, 140) },
	wayfarer = { Color3.fromRGB(150, 116, 70), Color3.fromRGB(106, 84, 58), Color3.fromRGB(172, 140, 90), Color3.fromRGB(84, 92, 70) },
	emberclan = { Color3.fromRGB(142, 40, 30), Color3.fromRGB(196, 96, 36), Color3.fromRGB(40, 34, 34), Color3.fromRGB(120, 70, 40) },
} :: { [string]: { Color3 } }
NpcLooks.defaultPalette = { Color3.fromRGB(110, 96, 80), Color3.fromRGB(90, 100, 110), Color3.fromRGB(130, 110, 80) }

NpcLooks.fixed = {
	leather = Color3.fromRGB(92, 62, 38),
	linen = Color3.fromRGB(226, 220, 204),
	dark = Color3.fromRGB(46, 44, 48),
	oilskin = Color3.fromRGB(196, 160, 60),
	gold = Color3.fromRGB(212, 172, 72),
	iron = Color3.fromRGB(120, 120, 126),
} :: { [string]: Color3 }

NpcLooks.wealth = {
	low = { mute = 0.4, darken = 0.15, buckle = false, cloakBonus = 0 },
	middle = { mute = 0, darken = 0, buckle = false, cloakBonus = 0 },
	high = { mute = 0, darken = 0.12, buckle = true, cloakBonus = 0.4 },
} :: { [string]: { mute: number, darken: number, buckle: boolean, cloakBonus: number } }

-- ─── Signature accents (strong mages show it) ───────────────────────────────
--[[
	By the NPC's best mastery tier index (NPCMagicLife.best): from `trim` on, Neon bands at the wrists
	and a Neon belt or sash in the signature's primary colour; from `motes`, slow signature-coloured
	sparkles at the hands; from `aura`, more of them. No PointLights (the light budget is the town's).
]]
NpcLooks.accent = { trim = 3, motes = 5, aura = 7, motesRate = 3, auraRate = 8 }

return NpcLooks
