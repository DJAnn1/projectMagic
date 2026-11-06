--!strict
--[[
	BorrowedPowers: what a relic lets you do (docs/Moments.md). Using one gives anyone a short taste of a
	mythic domain, with real spells at a real tier. It's meant to be rare and remembered, not farmed.

		seconds     how long it lasts
		tier        the mastery tier the spells count as (7 = Grandmaster: Timestop's full moment, Meteor)
		abilities   up to three, on the keys in Shared/UI/Controls (borrowed_1..3)

	The recipes are ordinary grammar, so Tests/Moments.spec checks each is valid and routes where it says.
	Tuning status: first guesses, not yet played.
]]

export type Ability = { name: string, glyph: string, text: string, route: string, recipe: { [string]: any } }
export type Relic = { id: string, item: string, name: string, line: string, domain: string, seconds: number, tier: number, abilities: { Ability } }

local relics: { [string]: Relic } = {
	time = {
		id = "time",
		item = "time_relic",
		name = "Borrowed Time",
		line = "A stopped clock starts ticking in your hand. For a minute, time answers to you.",
		domain = "time",
		seconds = 60,
		tier = 7,
		abilities = {
			{
				name = "Stop Time", glyph = "◷", text = "Everything nearby stops but you.", route = "timestop",
				recipe = { branch = "stasis", property = "tempo", verb = "reduce", form = "zone", power = 7 },
			},
			{
				name = "Mark Yourself", glyph = "⟲", text = "Then press N to come back to this moment, with everything you had. It even saves you from dying.", route = "self_timeline",
				recipe = { branch = "rewind", property = "sequence", verb = "store", form = "aura", power = 5 },
			},
			{
				name = "Hang Your Spells", glyph = "◌", text = "Your projectiles wait in the air. Press L to send them.", route = "stored_moment",
				recipe = { branch = "rewind", property = "sequence", verb = "bind", form = "aura", power = 5 },
			},
		},
	},
	gravity = {
		id = "gravity",
		item = "gravity_relic",
		name = "Borrowed Gravity",
		line = "The stone in your hand weighs nothing, then everything. For a minute, down is your choice.",
		domain = "gravity",
		seconds = 60,
		tier = 7,
		abilities = {
			{
				name = "Take Flight", glyph = "▲", text = "Fly. Space climbs, Shift sinks, Y lands, and U dives like a meteor.", route = "flight",
				recipe = { branch = "levitation", property = "buoyancy", verb = "amplify", form = "aura", power = 5 },
			},
			{
				name = "Crush", glyph = "◉", text = "Pin whoever you're aiming at, and tighten until they break.", route = "crushing_grip",
				recipe = { branch = "crushing", property = "weight", verb = "amplify", form = "beam", power = 7 },
			},
			{
				name = "Gravity Well", glyph = "◎", text = "Everything in reach is dragged to where you aim.", route = "gravity_well",
				recipe = { branch = "attraction", property = "weight", verb = "amplify", form = "zone", power = 5 },
			},
		},
	},
}

return table.freeze({
	relics = relics,
	ids = { "time", "gravity" },
})
