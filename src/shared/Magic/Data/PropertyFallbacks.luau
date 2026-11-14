--!strict
--[[
	PropertyFallbacks: what a non-harmful property does with every verb nothing more specific claims
	(docs/SpellOverhaul.md §12, stage 1c; owner, 2026-11-13: "do stage 1c"). Before this, these
	fell through to `manifest` (no real effect). One `fallback_<property>` route each is generated
	in Data/EffectLibrary (after every specific route, so Time's, Reality's and stage 1b's own
	effects still win) and its Composer words in Data/RouteSummaries.

	Per property, per verb: { status, words }. The status decides who it lands on (Effects/Status
	`foe`/`friend`): a harmful one reaches whoever the form reaches, or everyone around for an area;
	a helpful one lands on whoever you touch or aim at (yourself if nobody), or you and your allies
	for an area or aura. `sense` and `store` have routes of their own and never get here.
	Tuning status: first pass, 2026-11-13, not yet played. Every status here already exists.
]]

export type Entry = { status: string, words: string }

local VERBS = { "generate", "amplify", "reduce", "transfer", "redirect", "transmute", "bind", "release" }

local list: { [string]: { [string]: Entry } } = {
	-- ─── The six stage 1b didn't touch ──────────────────────────────────────
	sequence = {
		generate = { status = "time_haste", words = "Puts your next moments first: you move quicker" },
		amplify = { status = "time_haste", words = "Hurries what comes next for you: you move quicker" },
		reduce = { status = "time_slow", words = "Pushes their next moment back: they crawl" },
		transfer = { status = "time_haste", words = "Hands the next moment to you: you move quicker" },
		redirect = { status = "dazed", words = "Shuffles their causes and effects: they reel" },
		transmute = { status = "jinxed", words = "Rewrites what follows from them: luck turns on them" },
		bind = { status = "stasis", words = "Holds them between one moment and the next" },
		release = { status = "dazed", words = "Lets their moments fall out of order: they reel" },
	},
	tempo = {
		generate = { status = "time_haste", words = "Quickens time around you" },
		amplify = { status = "time_haste", words = "Quickens time around you" },
		reduce = { status = "time_slow", words = "Slows time around them" },
		transfer = { status = "time_haste", words = "Takes time for yourself: you move quicker" },
		redirect = { status = "time_slow", words = "Bends their time aside: they crawl" },
		transmute = { status = "time_slow", words = "Thickens their time: they crawl" },
		bind = { status = "stasis", words = "Stops their time for a moment" },
		release = { status = "time_haste", words = "Lets time run free around you" },
	},
	probability = {
		generate = { status = "lucky", words = "Luck leans your way" },
		amplify = { status = "lucky", words = "Luck leans your way" },
		reduce = { status = "jinxed", words = "Their luck runs thin: crits find them easily" },
		transfer = { status = "lucky", words = "Gives luck where you aim it (you, or whoever you touch)" },
		redirect = { status = "jinxed", words = "Turns their luck aside: crits find them easily" },
		transmute = { status = "jinxed", words = "Sours their luck: crits find them easily" },
		bind = { status = "jinxed", words = "Pins bad odds on them: crits find them easily" },
		release = { status = "lucky", words = "Lets luck loose around you" },
	},
	bond = {
		generate = { status = "ward", words = "Ties you and your allies together: a shared ward soaks up harm" },
		amplify = { status = "haste", words = "Strengthens the ties between you: you and your allies move faster" },
		reduce = { status = "dazed", words = "Cuts what anchors them: they reel" },
		transfer = { status = "ward", words = "Shares your protection: a ward on whoever you touch or aim at" },
		redirect = { status = "charm", words = "Turns their loyalty: charmed, they won't fight you for a moment" },
		transmute = { status = "charm", words = "Rewrites who they're bound to: charmed for a moment" },
		bind = { status = "root", words = "Binds them where they stand" },
		release = { status = "haste", words = "Frees you of every tie: you move faster" },
	},
	shadow = {
		generate = { status = "blind", words = "Darkness falls over them: blinded" },
		amplify = { status = "veiled", words = "Deepens the shade around you: you're hidden in it" },
		reduce = { status = "jinxed", words = "Strips their shadow away: exposed, crits find them easily" },
		transfer = { status = "veiled", words = "Wraps whoever you touch in shade" },
		redirect = { status = "veiled", words = "Throws your shadow elsewhere: you slip from sight" },
		transmute = { status = "fear", words = "Their own shadow turns on them: they flee" },
		bind = { status = "root", words = "Pins their shadow: they can't move" },
		release = { status = "blind", words = "A burst of darkness: everyone around is blinded" },
	},
	thought = {
		generate = { status = "dazed", words = "Floods their mind with noise: they reel" },
		amplify = { status = "haste", words = "Quickens your thinking: you move faster" },
		reduce = { status = "silence", words = "Quiets their thoughts: they can't cast for a moment" },
		transfer = { status = "dazed", words = "Pushes your thoughts into theirs: they reel" },
		redirect = { status = "charm", words = "Steers their thoughts: charmed, they won't fight you for a moment" },
		transmute = { status = "fear", words = "Twists their thoughts to dread: they flee" },
		bind = { status = "calm", words = "Settles their thoughts: calmed, they won't fight for a moment" },
		release = { status = "dazed", words = "Scatters their thoughts: everyone around reels" },
	},

	-- ─── Stage 1b's properties: the verbs it left alone ─────────────────────
	presence = {
		generate = { status = "jinxed", words = "Makes their presence blaze: crits find them easily" },
		amplify = { status = "jinxed", words = "Makes their presence blaze: crits find them easily" },
		reduce = { status = "veiled", words = "Hides your presence" },
		transfer = { status = "veiled", words = "Lends your hiddenness to whoever you touch" },
		redirect = { status = "veiled", words = "Sends watching eyes elsewhere: you're veiled" },
		transmute = { status = "veiled", words = "Hides your presence" },
		bind = { status = "jinxed", words = "Pins a mark on them that can't be hidden: crits find them easily" },
		release = { status = "jinxed", words = "A flare of presence: everyone around stands out, and crits find them" },
	},
	humidity = {
		generate = { status = "veiled", words = "A mist rises: you're hidden in it" },
		amplify = { status = "veiled", words = "A mist rises: you're hidden in it" },
		reduce = { status = "slow", words = "Dries them out: they slow" },
		transfer = { status = "slow", words = "Soaks them through: they slow" },
		redirect = { status = "slow", words = "Drives the damp into them: they slow" },
		transmute = { status = "chilled", words = "Turns the damp on them to frost: chilled" },
		bind = { status = "slow", words = "Clinging fog: they slow" },
		release = { status = "slow", words = "A burst of drenching fog: everyone around slows" },
	},
	density = {
		generate = { status = "slow", words = "Makes them heavy: they slow" },
		amplify = { status = "slow", words = "Makes them heavy: they slow" },
		reduce = { status = "gravity_light", words = "Makes you light: Featherweight" },
		transfer = { status = "slow", words = "Pushes weight onto them: they slow" },
		redirect = { status = "slow", words = "Drags their weight down: they slow" },
		transmute = { status = "crumbling", words = "Loosens what they're made of: brittle, every hit hurts more" },
		bind = { status = "root", words = "Makes them too heavy to move" },
		release = { status = "gravity_light", words = "Lets the weight go: Featherweight" },
	},
	perception = {
		generate = { status = "dazed", words = "Floods their senses: they reel" },
		amplify = { status = "dazed", words = "Floods their senses: they reel" },
		reduce = { status = "blind", words = "Dims their senses: blinded" },
		transfer = { status = "veiled", words = "Turns eyes away from whoever you touch" },
		redirect = { status = "veiled", words = "Misdirects every eye: you're veiled" },
		transmute = { status = "dazed", words = "Twists their senses: they reel" },
		bind = { status = "dazed", words = "Locks their senses on nothing: they reel" },
		release = { status = "dazed", words = "Overloads every sense around: everyone reels" },
	},
	viscosity = {
		generate = { status = "slow", words = "Thickens everything around them: they slow" },
		amplify = { status = "slow", words = "Thickens everything around them: they slow" },
		reduce = { status = "haste", words = "Makes everything slick: you move faster" },
		transfer = { status = "slow", words = "Clogs them: they slow" },
		redirect = { status = "slow", words = "Clogs them: they slow" },
		transmute = { status = "haste", words = "Turns the ground slick under you: you move faster" },
		bind = { status = "root", words = "Sets them fast like tar" },
		release = { status = "slow", words = "A burst of sludge: everyone around slows" },
	},
	contour = {
		generate = { status = "root", words = "The ground closes on their feet" },
		amplify = { status = "root", words = "The ground closes on their feet" },
		reduce = { status = "knockdown", words = "The ground drops out from under them" },
		transfer = { status = "slow", words = "The ground shifts under them: they slow" },
		redirect = { status = "knockdown", words = "Tilts the ground under them: they fall" },
		transmute = { status = "root", words = "The ground closes on their feet" },
		bind = { status = "root", words = "The ground closes on their feet" },
		release = { status = "knockdown", words = "The ground heaves: everyone around falls" },
	},
	buoyancy = {
		generate = { status = "gravity_light", words = "Lifts you: Featherweight" },
		amplify = { status = "gravity_light", words = "Lifts you: Featherweight" },
		reduce = { status = "slow", words = "Takes their lift: they sink and slow" },
		transfer = { status = "gravity_light", words = "Lends lift to whoever you touch: Featherweight" },
		redirect = { status = "gravity_light", words = "Turns your weight upward: Featherweight" },
		transmute = { status = "slow", words = "Turns their lift to drag: they slow" },
		bind = { status = "root", words = "Pins them down: they can't move" },
		release = { status = "gravity_light", words = "Lets you float free: Featherweight" },
	},
	hardness = {
		generate = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		amplify = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		reduce = { status = "crumbling", words = "Softens them: brittle, every hit hurts more" },
		transfer = { status = "ward", words = "Lends your hardness: stone skin on whoever you touch" },
		redirect = { status = "crumbling", words = "Turns their hardness against them: brittle" },
		transmute = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		bind = { status = "ward", words = "Stone skin: a ward that soaks up harm" },
		release = { status = "crumbling", words = "Shatters what holds them hard: everyone around turns brittle" },
	},
}

return table.freeze({
	list = list,
	verbs = VERBS,
})
