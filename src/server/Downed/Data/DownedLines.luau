--!strict
--[[
	DownedLines: what people say, and what your Journal says, after you lose (docs/LivingHistory.md §7).
	`lines` has the same shape and conditions as NPC/Data/Barks (AmbientLifeService:lineFor picks and
	fills them); `journal` is first person, one list per moment, picked by seed.

	CATEGORIES
		healer_wake     the healer, as you come round in their care: {carrier}
		carrier_greet   whoever carried you, the next time you pass
		carrier_thanks  whoever carried you, when you talk to them (that's your thanks)
		purse_found     a passer-by picks up a purse in the street (said to nobody)
		purse_return    the finder gives you back your purse
		purse_kept      someone else in town, asked for news: {finder} kept your purse

	VARS: {carrier} {finder} {healer} {town} {where}, plus Barks' own. Our own data, never player text.
	Rules: short (a chat bubble), no digits, nobody owns anybody: a captor holds, never keeps.
]]

local Barks = require(script.Parent.Parent.Parent.NPC.Data.Barks)

local Lines: { Barks.Line } = {
	{ cat = "healer_wake", text = "Easy. Don't sit up yet. {carrier} carried you in." },
	{ cat = "healer_wake", text = "There you are. {carrier} brought you in over their shoulder." },
	{ cat = "healer_wake", text = "You'll mend. Thank {carrier}, not me. They found you." },
	{ cat = "healer_wake", text = "Lie still a moment. {carrier} wouldn't leave until I'd looked at you.", high = { agreeableness = 0.5 } },
	{ cat = "healer_wake", text = "Back with us. You're lucky {carrier} was passing." },

	{ cat = "carrier_greet", text = "Back on your feet, then?" },
	{ cat = "carrier_greet", text = "You look better than the last time I saw you." },
	{ cat = "carrier_greet", text = "Steadier today? Good." },
	{ cat = "carrier_greet", text = "You gave me a fright, you know.", high = { neuroticism = 0.5 } },

	{ cat = "carrier_thanks", text = "Glad you're on your feet. You were heavier than you look." },
	{ cat = "carrier_thanks", text = "Anyone would have done it. Well. Not anyone." },
	{ cat = "carrier_thanks", text = "Just watch yourself out there." },
	{ cat = "carrier_thanks", text = "You'd have done the same. I'll hold you to that.", high = { conscientiousness = 0.5 } },

	{ cat = "purse_found", text = "Someone's dropped a purse." },
	{ cat = "purse_found", text = "Well, look at this." },
	{ cat = "purse_found", text = "Whose is this, then?" },

	{ cat = "purse_return", text = "You dropped this when you went down. It's all there." },
	{ cat = "purse_return", text = "Here. Your purse. I kept it safe for you." },
	{ cat = "purse_return", text = "This is yours, I think. Found it where you fell." },

	{ cat = "purse_kept", text = "{finder}'s been spending like they found money in the road. Was it yours?" },
	{ cat = "purse_kept", text = "I saw {finder} pick up a purse where you fell. Didn't see them give it back." },
	{ cat = "purse_kept", text = "Ask {finder} about a purse. Or don't. They'll only lie." },
}

local Journal: { [string]: { string } } = {
	carry = {
		"I went down {where}. I woke at {healer}'s with no memory of the road. {carrier} carried me in.",
		"Everything went dark {where}. {carrier} found me and brought me to {healer}. I owe them.",
	},
	carry_nohealer = {
		"I went down {where} and woke in {town}. {carrier} had carried me there.",
	},
	wake = {
		"I went down {where}. When I came round, whatever did it had gone.",
		"I lay {where} a long while. Nothing finished me. I don't know why.",
	},
	capture = {
		"Something dragged me off. I woke among standing stones, and it was watching me.",
		"I came round somewhere I didn't know, with a Wildborn standing over me. It hadn't finished me. It was keeping me.",
	},
	escaped_fought = { "I fought my way out of the Wildborn's ring." },
	escaped_walked = { "I slipped away from the Wildborn while it wasn't looking." },
	escaped_waited = { "In the end it lost interest in me and wandered off. I walked away." },
	purse_lost = { "My purse went when I fell. I'm lighter by some coin." },
	purse_own = { "I found my purse where I'd fallen." },
	purse_returned = { "{finder} brought back the purse I'd lost. All of it there." },
	purse_kept = { "Someone in {town} told me {finder} kept my purse." },
	thanked = { "I thanked {carrier} for carrying me in." },
}

return { lines = Lines, journal = Journal }
