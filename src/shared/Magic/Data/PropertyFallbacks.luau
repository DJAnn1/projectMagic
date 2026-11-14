--!strict
--[[
	PropertyFallbacks: what a non-harmful property does with every verb nothing more specific claims
	(docs/SpellOverhaul.md §12–13, stages 1c and 1d). Before this, these fell through to `manifest`
	(no real effect). One `fallback_<property>` route each is generated in Data/EffectLibrary (after
	every specific route, so Time's, Reality's and stage 1b's own effects still win) and its
	Composer words in Data/RouteSummaries.

	Per property, per verb: { status, words, on? }. Who it lands on (Effects/Status `foe`/`friend`):
	a harmful status reaches whoever the form reaches, or everyone around for an area; a helpful one
	lands on whoever you touch or aim at (yourself if nobody), or you and your allies for an area or
	aura. `on = "foe"` sends a status that isn't itself harmful (calm) at the target instead.
	`sense` and `store` have routes of their own and never get here.

	THE RULE (owner, 2026-11-13: "don't make everything harmful, just what seems necessary"):
	generate, amplify, transfer and release mostly help you and your allies (haste, ward, veil,
	luck, featherweight); reduce, bind and sometimes redirect or transmute work against someone,
	where the property plainly means that (time slowed, a shadow pinned, magic drained).
	Tuning status: first pass, 2026-11-13, not yet played. Every status here already exists.
]]

export type Entry = { status: string, words: string, on: string? }

local VERBS = { "generate", "amplify", "reduce", "transfer", "redirect", "transmute", "bind", "release" }

local list: { [string]: { [string]: Entry } } = {
	-- ─── Stage 1c: the six stage 1b didn't touch ────────────────────────────
	sequence = {
		generate = { status = "time_haste", words = "Puts your next moments first: you move quicker" },
		amplify = { status = "time_haste", words = "Hurries what comes next for you: you move quicker" },
		reduce = { status = "time_slow", words = "Pushes their next moment back: they crawl" },
		transfer = { status = "time_haste", words = "Hands the next moment to whoever you touch: they move quicker" },
		redirect = { status = "lucky", words = "Reorders what happens next in your favour: luck leans your way" },
		transmute = { status = "lucky", words = "Rewrites what follows from you: luck leans your way" },
		bind = { status = "stasis", words = "Holds them between one moment and the next" },
		release = { status = "time_haste", words = "Lets your moments run free: you and your allies move quicker" },
	},
	tempo = {
		generate = { status = "time_haste", words = "Quickens time around you" },
		amplify = { status = "time_haste", words = "Quickens time around you" },
		reduce = { status = "time_slow", words = "Slows time around them" },
		transfer = { status = "time_haste", words = "Gives time to whoever you touch: they move quicker" },
		redirect = { status = "time_slow", words = "Bends their time aside: they crawl" },
		transmute = { status = "time_haste", words = "Thins time around you: you move quicker" },
		bind = { status = "stasis", words = "Stops their time for a moment" },
		release = { status = "time_haste", words = "Lets time run free around you and your allies" },
	},
	probability = {
		generate = { status = "lucky", words = "Luck leans your way" },
		amplify = { status = "lucky", words = "Luck leans your way" },
		reduce = { status = "jinxed", words = "Their luck runs thin: crits find them easily" },
		transfer = { status = "lucky", words = "Gives luck to whoever you touch" },
		redirect = { status = "lucky", words = "Turns the odds your way" },
		transmute = { status = "lucky", words = "Rewrites the odds in your favour" },
		bind = { status = "jinxed", words = "Pins bad odds on them: crits find them easily" },
		release = { status = "lucky", words = "Lets luck loose around you and your allies" },
	},
	bond = {
		generate = { status = "ward", words = "Ties you and your allies together: a shared ward soaks up harm" },
		amplify = { status = "haste", words = "Strengthens the ties between you: you and your allies move faster" },
		reduce = { status = "haste", words = "Cuts what holds you back: you move faster" },
		transfer = { status = "ward", words = "Shares your protection: a ward on whoever you touch" },
		redirect = { status = "charm", words = "Turns their loyalty: charmed, they won't fight you for a moment" },
		transmute = { status = "ward", words = "Reforges your ties into a shield: a ward that soaks up harm" },
		bind = { status = "root", words = "Binds them where they stand" },
		release = { status = "haste", words = "Frees you of every tie: you move faster" },
	},
	shadow = {
		generate = { status = "veiled", words = "Shade gathers around you: you're hidden in it" },
		amplify = { status = "veiled", words = "Deepens the shade around you: you're hidden in it" },
		reduce = { status = "jinxed", words = "Strips their shadow away: exposed, crits find them easily" },
		transfer = { status = "veiled", words = "Wraps whoever you touch in shade" },
		redirect = { status = "veiled", words = "Throws your shadow elsewhere: you slip from sight" },
		transmute = { status = "fear", words = "Their own shadow turns on them: they flee" },
		bind = { status = "root", words = "Pins their shadow: they can't move" },
		release = { status = "blind", words = "A burst of darkness: everyone around is blinded" },
	},
	thought = {
		generate = { status = "lucky", words = "Clear thinking: you know what to do, and luck leans your way" },
		amplify = { status = "haste", words = "Quickens your thinking: you move faster" },
		reduce = { status = "silence", words = "Quiets their thoughts: they can't cast for a moment" },
		transfer = { status = "lucky", words = "Shares your insight with whoever you touch" },
		redirect = { status = "charm", words = "Steers their thoughts: charmed, they won't fight you for a moment" },
		transmute = { status = "fear", words = "Twists their thoughts to dread: they flee" },
		bind = { status = "calm", on = "foe", words = "Settles their thoughts: calmed, they won't fight for a moment" },
		release = { status = "lucky", words = "A flash of insight for you and your allies: luck leans your way" },
	},

	-- ─── Stage 1c: the verbs stage 1b left on its properties ────────────────
	-- (generate, amplify and reduce are mostly claimed by stage 1b's own routes; listed for completeness)
	presence = {
		generate = { status = "jinxed", words = "Makes their presence blaze: crits find them easily" },
		amplify = { status = "jinxed", words = "Makes their presence blaze: crits find them easily" },
		reduce = { status = "veiled", words = "Hides your presence" },
		transfer = { status = "veiled", words = "Lends your hiddenness to whoever you touch" },
		redirect = { status = "veiled", words = "Sends watching eyes elsewhere: you're veiled" },
		transmute = { status = "veiled", words = "Hides your presence" },
		bind = { status = "jinxed", words = "Pins a mark on them that can't be hidden: crits find them easily" },
		release = { status = "veiled", words = "Your presence thins to nothing: you and your allies are veiled" },
	},
	humidity = {
		generate = { status = "veiled", words = "A mist rises: you're hidden in it" },
		amplify = { status = "veiled", words = "A mist rises: you're hidden in it" },
		reduce = { status = "slow", words = "Dries them out: they slow" },
		transfer = { status = "veiled", words = "Wraps whoever you touch in mist" },
		redirect = { status = "slow", words = "Drives the damp into them: soaked, they slow" },
		transmute = { status = "chilled", words = "Turns the damp on them to frost: chilled" },
		bind = { status = "slow", words = "Clinging fog holds them: they slow" },
		release = { status = "veiled", words = "A burst of fog hides you and your allies" },
	},
	density = {
		generate = { status = "slow", words = "Makes them heavy: they slow" },
		amplify = { status = "slow", words = "Makes them heavy: they slow" },
		reduce = { status = "gravity_light", words = "Makes you light: Featherweight" },
		transfer = { status = "gravity_light", words = "Takes the weight off whoever you touch: Featherweight" },
		redirect = { status = "slow", words = "Drags their weight down: they slow" },
		transmute = { status = "crumbling", words = "Loosens what they're made of: brittle, every hit hurts more" },
		bind = { status = "root", words = "Makes them too heavy to move" },
		release = { status = "gravity_light", words = "Lets the weight go: you and your allies are Featherweight" },
	},
	perception = {
		generate = { status = "lucky", words = "Sharpens your senses: luck leans your way" },
		amplify = { status = "lucky", words = "Sharpens your senses: luck leans your way" },
		reduce = { status = "blind", words = "Dims their senses: blinded" },
		transfer = { status = "lucky", words = "Lends your sharp senses to whoever you touch" },
		redirect = { status = "veiled", words = "Misdirects every eye: you're veiled" },
		transmute = { status = "dazed", words = "Twists their senses: they reel" },
		bind = { status = "dazed", words = "Locks their senses on nothing: they reel" },
		release = { status = "lucky", words = "Opens every sense for you and your allies: luck leans your way" },
	},
	viscosity = {
		generate = { status = "slow", words = "Thickens everything around them: they slow" },
		amplify = { status = "slow", words = "Thickens everything around them: they slow" },
		reduce = { status = "haste", words = "Makes everything slick: you move faster" },
		transfer = { status = "haste", words = "Makes the way slick for whoever you touch: they move faster" },
		redirect = { status = "slow", words = "Clogs them: they slow" },
		transmute = { status = "haste", words = "Turns the ground slick under you: you move faster" },
		bind = { status = "root", words = "Sets them fast like tar" },
		release = { status = "haste", words = "Everything runs slick for you and your allies: you move faster" },
	},
	contour = {
		generate = { status = "ward", words = "The ground rises around you as cover: a ward that soaks up harm" },
		amplify = { status = "ward", words = "The ground rises around you as cover: a ward that soaks up harm" },
		reduce = { status = "knockdown", words = "The ground drops out from under them" },
		transfer = { status = "haste", words = "Smooths the ground under whoever you touch: they move faster" },
		redirect = { status = "knockdown", words = "Tilts the ground under them: they fall" },
		transmute = { status = "root", words = "The ground closes on their feet" },
		bind = { status = "root", words = "The ground closes on their feet" },
		release = { status = "haste", words = "The ground carries you and your allies: you move faster" },
	},
	buoyancy = {
		generate = { status = "gravity_light", words = "Lifts you: Featherweight" },
		amplify = { status = "gravity_light", words = "Lifts you: Featherweight" },
		reduce = { status = "slow", words = "Takes their lift: they sink and slow" },
		transfer = { status = "gravity_light", words = "Lends lift to whoever you touch: Featherweight" },
		redirect = { status = "gravity_light", words = "Turns your weight upward: Featherweight" },
		transmute = { status = "gravity_light", words = "Turns your drag to lift: Featherweight" },
		bind = { status = "root", words = "Pins them down: they can't move" },
		release = { status = "gravity_light", words = "Lets you and your allies float free: Featherweight" },
	},
	hardness = {
		generate = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		amplify = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		reduce = { status = "crumbling", words = "Softens them: brittle, every hit hurts more" },
		transfer = { status = "ward", words = "Lends your hardness: stone skin on whoever you touch" },
		redirect = { status = "crumbling", words = "Turns their hardness against them: brittle" },
		transmute = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		bind = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		release = { status = "ward", words = "Hardens you and your allies: stone skin" },
	},

	-- ─── Stage 1d: the last twelve (docs/SpellOverhaul.md §13) ──────────────
	-- Routes that already claim some of their verbs (illusion's blind and veil, persistence's
	-- stasis, instinct's soothe, purity's purify and rust, aether's dispel and wellspring, volume's
	-- fold, position's blink, distance's push and pull) still win; these fill every other verb.
	boundary = {
		generate = { status = "ward", words = "Draws a seal around you: a ward that soaks up harm" },
		amplify = { status = "ward", words = "Thickens the seal around you: a ward that soaks up harm" },
		reduce = { status = "crumbling", words = "Wears their edges thin: brittle, every hit hurts more" },
		transfer = { status = "ward", words = "Seals whoever you touch: a ward that soaks up harm" },
		redirect = { status = "slow", words = "Turns them back at every threshold: they slow" },
		transmute = { status = "ward", words = "Redraws your edges: a ward that soaks up harm" },
		bind = { status = "root", words = "Cages them where they stand" },
		release = { status = "haste", words = "No edge holds you: you and your allies move faster" },
	},
	foresight = {
		generate = { status = "lucky", words = "A glimpse of what's coming: luck leans your way" },
		amplify = { status = "lucky", words = "A clearer glimpse of what's coming: luck leans your way" },
		reduce = { status = "dazed", words = "Clouds what they see coming: they reel" },
		transfer = { status = "lucky", words = "Shares a glimpse of what's coming with whoever you touch" },
		redirect = { status = "jinxed", words = "Shows them the wrong future: crits find them easily" },
		transmute = { status = "lucky", words = "Picks the better of what's coming: luck leans your way" },
		bind = { status = "lucky", words = "Holds onto the best outcome: luck leans your way" },
		release = { status = "lucky", words = "Lets every glimpse loose for you and your allies: luck leans your way" },
	},
	illusion = {
		generate = { status = "blind", words = "False light floods their eyes: blinded" },
		amplify = { status = "blind", words = "False light floods their eyes: blinded" },
		reduce = { status = "veiled", words = "Hides you behind a false nothing" },
		transfer = { status = "veiled", words = "Hides whoever you touch behind a false nothing" },
		redirect = { status = "dazed", words = "Shows them false paths: they reel" },
		transmute = { status = "fear", words = "Shows them horrors: they flee" },
		bind = { status = "veiled", words = "Wraps you in a lasting false nothing: veiled" },
		release = { status = "veiled", words = "False nothing spreads over you and your allies: veiled" },
	},
	persistence = {
		generate = { status = "ward", words = "You endure: a ward that soaks up harm" },
		amplify = { status = "ward", words = "You endure: a ward that soaks up harm" },
		reduce = { status = "stasis", words = "Holds them unchanged for a moment" },
		transfer = { status = "ward", words = "Lends your endurance: a ward on whoever you touch" },
		redirect = { status = "slow", words = "Makes them resist their own movement: they slow" },
		transmute = { status = "ward", words = "Makes you unchanging: a ward that soaks up harm" },
		bind = { status = "stasis", words = "Holds them unchanged for a moment" },
		release = { status = "haste", words = "Lets go of what holds you still: you move faster" },
	},
	instinct = {
		generate = { status = "haste", words = "Wakes the beast in you: you move faster" },
		amplify = { status = "haste", words = "Wakes the beast in you: you move faster" },
		reduce = { status = "calm", on = "foe", words = "Quiets their drives: calmed, they won't fight for a moment" },
		transfer = { status = "haste", words = "Lends a beast's speed to whoever you touch" },
		redirect = { status = "charm", words = "Turns their hunt elsewhere: charmed, they won't fight you for a moment" },
		transmute = { status = "fear", words = "Turns their courage to a beast's panic: they flee" },
		bind = { status = "calm", on = "foe", words = "Tames them: calmed, they won't fight for a moment" },
		release = { status = "haste", words = "Lets the pack run: you and your allies move faster" },
	},
	purity = {
		generate = { status = "ward", words = "Refines you: a ward that soaks up harm" },
		amplify = { status = "ward", words = "Refines you: a ward that soaks up harm" },
		reduce = { status = "crumbling", words = "Fouls what they're made of: brittle, every hit hurts more" },
		transfer = { status = "ward", words = "Refines whoever you touch: a ward that soaks up harm" },
		redirect = { status = "crumbling", words = "Drives impurities into them: brittle" },
		transmute = { status = "ward", words = "Refines you: a ward that soaks up harm" },
		bind = { status = "ward", words = "Seals your purity in: a ward that soaks up harm" },
		release = { status = "ward", words = "A wash of clean air: you and your allies are warded" },
	},
	aether = {
		generate = { status = "lucky", words = "Magic gathers around you: luck leans your way" },
		amplify = { status = "lucky", words = "Magic gathers around you: luck leans your way" },
		reduce = { status = "silence", words = "Drains the magic from them: they can't cast for a moment" },
		transfer = { status = "lucky", words = "Lends magic to whoever you touch: luck leans their way" },
		redirect = { status = "silence", words = "Turns their magic aside: they can't cast for a moment" },
		transmute = { status = "silence", words = "Curdles the magic in them: they can't cast for a moment" },
		bind = { status = "silence", words = "Binds their magic: they can't cast for a moment" },
		release = { status = "lucky", words = "Lets magic loose around you: luck leans your way" },
	},
	volume = {
		generate = { status = "haste", words = "Space opens ahead of you: you move faster" },
		amplify = { status = "haste", words = "Space opens ahead of you: you move faster" },
		reduce = { status = "slow", words = "Space presses in on them: they slow" },
		transfer = { status = "haste", words = "Gives your space to whoever you touch: they move faster" },
		redirect = { status = "dazed", words = "Twists the space around them: they reel" },
		transmute = { status = "veiled", words = "Folds you small in the space around you: veiled" },
		bind = { status = "root", words = "Space closes around them: they can't move" },
		release = { status = "haste", words = "Space loosens around you and your allies: you move faster" },
	},
	position = {
		generate = { status = "veiled", words = "You're never quite where they look: veiled" },
		amplify = { status = "veiled", words = "You're never quite where they look: veiled" },
		reduce = { status = "root", words = "Pins them where they are" },
		transfer = { status = "veiled", words = "Moves whoever you touch just out of sight: veiled" },
		redirect = { status = "dazed", words = "Shifts them a step aside: they reel" },
		transmute = { status = "dazed", words = "Muddles where they are: they reel" },
		bind = { status = "root", words = "Pins them where they are" },
		release = { status = "veiled", words = "You and your allies slip out of place: veiled" },
	},
	will = {
		generate = { status = "ward", words = "An iron will: a ward that soaks up harm" },
		amplify = { status = "haste", words = "Sharpens your resolve: you move faster" },
		reduce = { status = "calm", on = "foe", words = "Breaks their will to fight: calmed for a moment" },
		transfer = { status = "ward", words = "Lends your resolve: a ward on whoever you touch" },
		redirect = { status = "charm", words = "Bends their will to yours: charmed, they won't fight you for a moment" },
		transmute = { status = "haste", words = "Remakes your resolve: you move faster" },
		bind = { status = "calm", on = "foe", words = "Holds their will still: calmed, they won't fight for a moment" },
		release = { status = "ward", words = "An unbreakable will for you and your allies: warded" },
	},
	memory = {
		generate = { status = "lucky", words = "Old lessons come back to you: luck leans your way" },
		amplify = { status = "lucky", words = "Sharp recall: you know what to do, and luck leans your way" },
		reduce = { status = "calm", on = "foe", words = "They forget why they were fighting: calmed for a moment" },
		transfer = { status = "lucky", words = "Shares what you remember with whoever you touch" },
		redirect = { status = "charm", words = "A false memory of friendship: charmed for a moment" },
		transmute = { status = "fear", words = "Turns their memories to nightmares: they flee" },
		bind = { status = "silence", words = "They forget the words of their spells: they can't cast for a moment" },
		release = { status = "lucky", words = "Old lessons come back to you and your allies: luck leans your way" },
	},
	distance = {
		generate = { status = "haste", words = "Shrinks the distance ahead of you: you move faster" },
		amplify = { status = "haste", words = "Shrinks the distance ahead of you: you move faster" },
		reduce = { status = "slow", words = "Folds the distance shut on them: they slow" },
		transfer = { status = "haste", words = "Gives your reach to whoever you touch: they move faster" },
		redirect = { status = "dazed", words = "Bends the distance around them: they reel" },
		transmute = { status = "haste", words = "Makes far near for you: you move faster" },
		bind = { status = "root", words = "Fixes the distance around them: they can't move" },
		release = { status = "haste", words = "Lets the distance go slack: you move faster" },
	},
}

return table.freeze({
	list = list,
	verbs = VERBS,
})
