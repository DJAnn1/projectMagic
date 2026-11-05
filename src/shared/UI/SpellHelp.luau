--!strict
--[[
	SpellHelp: every explanation the Spell Composer shows, as data (docs/UI.md §4 Composer).

	The grammar's own one-line descriptions (Data/Verbs, Forms, Modifiers, Properties) say what a
	part IS; this says what it DOES for the player and gives an example, so nobody has to guess.
	Shared so a spec can check it covers every verb, form and modifier id (Tests/SpellHelp.spec).
	Nothing here is secret: it describes the public grammar, never tuning odds or hidden latents.

	steps      the question and a longer explanation for each Composer step
	verbs      does = what it does to the property ("{p}" = the property's name, lower case),
	           example = a concrete use
	forms      shape = how the spell reaches the world (finishes the describe() sentence),
	           example = a concrete use
	modifiers  plain = the effect in a few words (for describe()), when = when to pick it
	tour       the Composer's first-time walkthrough (pages)
	glossary   words the Composer uses, explained
	describe(recipe, harmful) -> one plain sentence for a whole spell
]]

export type Page = { title: string, body: string }
export type Term = { term: string, text: string }

local SpellHelp = {}

SpellHelp.steps = {
	branch = {
		question = "Which part of your magic?",
		explain = "A branch is one school inside a domain, like Pyromancy inside Energy. You can only build spells in branches you've opened, and the deeper you've trained one, the more it lets you do.",
	},
	property = {
		question = "What will the spell affect?",
		explain = "The property is the thing your magic works on: heat, light, stone, flow, minds. Each branch reaches a few properties. Faded ones have nothing you can do with them yet.",
	},
	verb = {
		question = "What will you do to it?",
		explain = "The verb is the action: make some of the property, strengthen or weaken what's there, move it, change it, feel it, or store it for later. Some verbs open up as your mastery grows.",
	},
	form = {
		question = "What shape does it take?",
		explain = "The form is how the spell reaches the world: by touch, as a thrown bolt, a beam, a burst around you, a wall, a lasting zone and more. The form decides range, area and who gets hit.",
	},
	modifiers = {
		question = "Any refinements?",
		explain = "Modifiers are optional tweaks: homing, piercing, delayed, cheaper, stronger. You can hold only a few at once, and some fight each other.",
	},
	power = {
		question = "How hard, and paid from where?",
		explain = "Power is how much force you put in. More power hits harder and costs more. Past your comfortable power the spell gets unstable and can backfire. Most spells are paid from your reservoir; some ways of paying draw on the magic around you instead.",
	},
}

SpellHelp.verbs = {
	generate = { does = "Makes {p} out of raw power", example = "Generate + Temperature: warm your hands, light a candle, or burn an enemy." },
	amplify = { does = "Strengthens the {p} something already has", example = "Amplify + Hardness: turn your skin to iron for a while." },
	diminish = { does = "Weakens or smothers the {p} something has", example = "Diminish + Temperature: put out a fire, or chill a foe." },
	transfer = { does = "Moves {p} from one thing to another", example = "Transfer + Temperature: pull the heat out of a fire into your hands. Cheap, but needs a source." },
	redirect = { does = "Steers {p} that's already moving", example = "Redirect + Flow: turn a river aside, or push a wave at someone." },
	transmute = { does = "Turns {p} into a different state or kind", example = "Transmute + Phase: freeze water into ice to walk on." },
	bind = { does = "Fixes {p} in place, or ties it to something", example = "Bind + Position: pin someone where they stand." },
	sense = { does = "Lets you feel {p} at a distance", example = "Sense + Vitality: find the wounded nearby. Never harms." },
	store = { does = "Captures {p} to release later", example = "Store + Charge: soak up a lightning bolt now, throw it back later." },
	release = { does = "Unleashes {p} you stored earlier, all at once", example = "Release + Charge: let out what you stored in one blast. Needs a stored charge." },
}

SpellHelp.forms = {
	touch = { shape = "on whoever you touch, or on yourself", example = "Close and cheap: a healing hand, a burning palm." },
	projectile = { shape = "thrown as a bolt that flies where you aim", example = "The classic attack: aim, release, and it travels to the target." },
	beam = { shape = "as a line straight from your hand to the target", example = "Hits instantly along a line. Harder to dodge, shorter reach." },
	burst = { shape = "as a sphere bursting out around you", example = "Hits everything close around you at once." },
	aura = { shape = "as a field that moves with you", example = "A lasting glow around you: warmth, a ward, a slowing chill." },
	wall = { shape = "as a barrier raised where you aim", example = "Raise stone or water between you and danger." },
	zone = { shape = "as an area that lasts where you place it", example = "Leave a patch of fire, frost or calm behind." },
	pillar = { shape = "as a column bursting up from the ground (or down from the sky)", example = "Strikes one spot hard from below or above." },
	chain = { shape = "leaping from target to target", example = "Jumps between nearby enemies, weaker each hop." },
	summon = { shape = "given a body that acts on its own", example = "An elemental, a construct, a familiar that fights or works for you." },
	ritual = { shape = "as a long, channelled working over a huge area", example = "The only way to change the land itself: quakes, tsunamis. Takes time to cast." },
}

SpellHelp.modifiers = {
	delayed = { plain = "goes off a few seconds later, stronger for the wait", when = "Traps, or hitting where someone will be." },
	homing = { plain = "seeks its target", when = "Fast or dodging targets. Costs a little power." },
	piercing = { plain = "passes through targets and light cover", when = "Enemies in a line, or behind a thin wall." },
	lingering = { plain = "lasts much longer, but gentler", when = "Healing over time, zones you want to hold." },
	linked = { plain = "ties two targets so what happens to one echoes in the other", when = "Sharing a heal, or making one foe feel another's hurt." },
	silent = { plain = "makes almost no sound or light", when = "Casting where you shouldn't be seen. Harder to trace." },
	efficient = { plain = "costs less and is steadier, but weaker and slower", when = "Long fights, low reservoir, learning safely." },
	reckless = { plain = "hits harder and faster, but far less stable", when = "When you need it now and can afford a backfire." },
	channeled = { plain = "is held while you keep casting, paying as you go", when = "Beams and fields you want to keep up." },
	echoing = { plain = "repeats after it lands, weaker each time", when = "More hits from one cast." },
}

SpellHelp.tour = {
	{ title = "Spells are built, not picked", body = "Every spell is a short sentence: a VERB done to a PROPERTY, in a FORM. \"Generate Temperature as a Projectile\" is a fire bolt. Change one word and you have a new spell." },
	{ title = "Guided: start here", body = "Guided shows spells you can cast right now. Pick a power and press Save: it goes straight onto your hotbar. Then press its number (1 to 8) to ready it, and click to cast." },
	{ title = "Full: build your own", body = "Full walks you through six steps: Branch, Property, Verb, Form, Modifiers, Power. Hover any choice (or select it on a gamepad) to read what it does. Faded choices say why they're locked." },
	{ title = "Read the preview", body = "The right side says what your spell will do, what it costs, and how likely it is to backfire. The ≈ means it's an estimate: casting it shows the truth." },
	{ title = "Name it, use it, grow", body = "Name your spell if you like (others see a filtered version). Every cast trains its branch; mastery opens new verbs, forms and more power." },
}

SpellHelp.glossary = {
	{ term = "Reservoir", text = "Your store of magic (the blue bar). Spells are paid from it, and it refills over time, faster when you rest." },
	{ term = "Overdraw", text = "Casting with more cost than your reservoir holds. It works, but your body pays: backlash, burnout, even harm." },
	{ term = "Power", text = "How much force you put in (1 to 10). Higher hits harder, costs more, and is harder to control." },
	{ term = "Comfortable power", text = "The power you can hold steadily in this branch now. Above it you're overreaching: less stable." },
	{ term = "Backfire", text = "The chance a spell gets away from you and hurts you instead. Rises with instability." },
	{ term = "Instability", text = "How wild the spell is. Overreaching, reckless casting and some properties raise it." },
	{ term = "Mastery", text = "How well you know a branch: Novice, Adept and up. It grows each time you cast there and unlocks verbs, forms and power." },
	{ term = "Ambient magic", text = "Magic in the world around you, strongest near ley lines. Some ways of paying draw on it instead of your reservoir." },
	{ term = "Cast time", text = "How long you're casting before it goes off. Getting hit or dodging can interrupt it." },
	{ term = "Cooldown", text = "How long before you can cast that same spell again." },
	{ term = "Modifier slots", text = "How many modifiers one spell can hold together. More open up as the branch deepens." },
	{ term = "Strike", text = "Your domain's first attack form. It adds a little extra on hit, like a daze or a jinx." },
}

local function lower(s: string): string
	return string.lower(s)
end

--[[
	One plain sentence for a whole spell, e.g. "Makes temperature out of raw power, thrown as a
	bolt that flies where you aim. Seeks its target. It can hurt what it hits."
	Takes the verb, form and modifier ids, the property's display name, and whether the spell can
	harm (SpellStats.harmful). Unknown ids fall back to plain wording.
]]
function SpellHelp.describe(verbId: string, propertyName: string, formId: string, modifierIds: { string }, harmful: boolean): string
	local verb = SpellHelp.verbs[verbId]
	local form = SpellHelp.forms[formId]
	-- Parenthesised: gsub also returns a count, which must not leak into the expression.
	local action = if verb then (string.gsub(verb.does, "{p}", lower(propertyName))) else ("Works on " .. lower(propertyName))
	local text = action .. ", " .. (if form then form.shape else "in its own shape") .. "."
	for _, id in modifierIds do
		local mod = SpellHelp.modifiers[id]
		if mod then
			local plain = mod.plain
			text ..= " " .. string.upper(string.sub(plain, 1, 1)) .. string.sub(plain, 2) .. "."
		end
	end
	if harmful then
		text ..= " It can hurt what it hits."
	elseif verbId == "sense" then
		text ..= " It never harms anyone."
	end
	return text
end

return SpellHelp
