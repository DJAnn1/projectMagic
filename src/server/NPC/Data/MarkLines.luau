--!strict
--[[
	MarkLines: what NPCs say about the Magic Marks on someone they meet (docs/MagicMarks.md).
	Same shape and conditions as Data/Barks (NPC/BarkEngine picks from it). Services/MarkService
	chooses the category; AmbientLifeService speaks it in place of an ordinary greeting, once per
	NPC per mark and stage.

	CATEGORIES
		mark_<domain>  close up, about that domain's mark
		mark_kin       close up, from someone who carries the same mark
		mark_any       close up, any mark (fallback when no domain line fits)
		mark_whisper   further off, to whoever's beside them

	VARS: {player} {name} {town}, and {mark}: what they see, by stage (Data/Marks `seen`).
]]

local Barks = require(script.Parent.Barks)

local Lines: { Barks.Line } = {
	-- ─── Energy ─────────────────────────────────────────────────────────────
	{ cat = "mark_energy", text = "Fire's got into your hands, hasn't it?" },
	{ cat = "mark_energy", text = "You've been playing with fire. It shows.", low = { agreeableness = 0.45 } },
	{ cat = "mark_energy", text = "Stand there a moment. You're warmer than my hearth.", mood = { "content", "cheerful", "tired" } },
	{ cat = "mark_energy", text = "Your hands are black! Does it hurt?", child = true },
	{ cat = "mark_energy", text = "Mind where you put those hands near my thatch.", occ = { "farmer", "builder" } },

	-- ─── Earth ──────────────────────────────────────────────────────────────
	{ cat = "mark_earth", text = "Hands like a quarryman's. You've been working stone." },
	{ cat = "mark_earth", text = "There's more rock in you than skin these days." },
	{ cat = "mark_earth", text = "Can I knock on your arm? Does it go clunk?", child = true },
	{ cat = "mark_earth", text = "You'd make a good wall. Sorry. Just saying.", high = { extraversion = 0.6 } },

	-- ─── Water ──────────────────────────────────────────────────────────────
	{ cat = "mark_water", text = "You're dripping on my step." },
	{ cat = "mark_water", text = "Been in the river, or is that the magic?" },
	{ cat = "mark_water", text = "Your hands are see-through! Like ice!", child = true },
	{ cat = "mark_water", text = "Handy in a drought, someone like you.", occ = { "farmer" } },

	-- ─── Air ────────────────────────────────────────────────────────────────
	{ cat = "mark_air", text = "Where's that draught coming from? Oh. You." },
	{ cat = "mark_air", text = "Pale as a cloud, you are. Eat something.", high = { agreeableness = 0.55 } },
	{ cat = "mark_air", text = "My hair's blowing and there's no wind!", child = true },
	{ cat = "mark_air", text = "You blew half my stall over walking past.", occ = { "merchant" } },

	-- ─── Life ───────────────────────────────────────────────────────────────
	{ cat = "mark_life", text = "Is that green in your veins? Bless." },
	{ cat = "mark_life", text = "You smell like a spring meadow. It's not unpleasant." },
	{ cat = "mark_life", text = "There's a flower where you were standing!", child = true },
	{ cat = "mark_life", text = "Walk through my field a few times, would you?", occ = { "farmer" } },

	-- ─── Mind ───────────────────────────────────────────────────────────────
	{ cat = "mark_mind", text = "Don't look at me like that. I can feel you doing it." },
	{ cat = "mark_mind", text = "Those violet hands. You're one of the thinkers.", high = { openness = 0.55 } },
	{ cat = "mark_mind", text = "I wasn't going to say anything rude. Honestly.", high = { neuroticism = 0.55 } },
	{ cat = "mark_mind", text = "Are you reading my head right now?", child = true },

	-- ─── Spirit ─────────────────────────────────────────────────────────────
	{ cat = "mark_spirit", text = "You've been talking with the dead. I can see it on you." },
	{ cat = "mark_spirit", text = "Keep your distance, please. No offence.", high = { neuroticism = 0.55 } },
	{ cat = "mark_spirit", text = "Are you a ghost?", child = true },
	{ cat = "mark_spirit", text = "Your hands. Like a candle flame. My grandmother had those.", high = { openness = 0.55 } },

	-- ─── Void ───────────────────────────────────────────────────────────────
	{ cat = "mark_void", text = "I can't look at your hands. My eyes won't stay on them." },
	{ cat = "mark_void", text = "Whatever you've been doing, I don't want to know.", high = { neuroticism = 0.5 } },
	{ cat = "mark_void", text = "Your hands are like holes!", child = true },
	{ cat = "mark_void", text = "Dark work leaves dark hands. Be careful.", high = { agreeableness = 0.55 } },

	-- ─── Space ──────────────────────────────────────────────────────────────
	{ cat = "mark_space", text = "Your hand moved before you did. I saw it." },
	{ cat = "mark_space", text = "Stop that shimmering, it makes me dizzy." },
	{ cat = "mark_space", text = "Do it again! The blurry thing!", child = true },

	-- ─── Time ───────────────────────────────────────────────────────────────
	{ cat = "mark_time", text = "You've an old woman's hands and a young face. That's not natural." },
	{ cat = "mark_time", text = "My clock's been wrong since you walked in." },
	{ cat = "mark_time", text = "Why are your hands so old?", child = true },
	{ cat = "mark_time", text = "Time's taking its fee from you, I see.", high = { openness = 0.55 } },

	-- ─── Gravity ────────────────────────────────────────────────────────────
	{ cat = "mark_gravity", text = "There's dust going round your arms. Did you know?" },
	{ cat = "mark_gravity", text = "Heavy hands, you've got. Heavy magic." },
	{ cat = "mark_gravity", text = "The pebbles are following you!", child = true },

	-- ─── Reality ────────────────────────────────────────────────────────────
	{ cat = "mark_reality", text = "Your hands keep... no. Never mind. I must be tired." },
	{ cat = "mark_reality", text = "Something's wrong with you and I can't say what.", high = { neuroticism = 0.5 } },
	{ cat = "mark_reality", text = "Your fingers flickered! Like a bad candle!", child = true },

	-- ─── Any mark ───────────────────────────────────────────────────────────
	{ cat = "mark_any", text = "That's {mark}. Magic does that, if you let it." },
	{ cat = "mark_any", text = "You've got {mark}. Been at it a while, I'd guess." },
	{ cat = "mark_any", text = "{mark}, eh? Mind it doesn't take the rest of you.", high = { agreeableness = 0.5 } },
	{ cat = "mark_any", text = "Hm. {mark}.", low = { extraversion = 0.35 } },
	{ cat = "mark_any", text = "I remember when you didn't have {mark}.", rel = { "friend", "close", "acquaintance" } },
	{ cat = "mark_any", text = "Ooh, {mark}!", child = true },

	-- ─── Kin: the same mark on them ─────────────────────────────────────────
	{ cat = "mark_kin", text = "{mark}. Same as mine. It doesn't stop, you know." },
	{ cat = "mark_kin", text = "Look at us. Matching hands." },
	{ cat = "mark_kin", text = "Give it a few years. You'll look like me." },
	{ cat = "mark_kin", text = "Someone else who can't leave it alone. Good.", high = { extraversion = 0.5 } },

	-- ─── Whispers ───────────────────────────────────────────────────────────
	{ cat = "mark_whisper", text = "Did you see? {mark}." },
	{ cat = "mark_whisper", text = "Don't stare. They've got {mark}." },
	{ cat = "mark_whisper", text = "That one's got {mark}. Some sort of mage." },
	{ cat = "mark_whisper", text = "Look at that one! {mark}!", child = true },
	{ cat = "mark_whisper", text = "{mark}. Wonder what they've been doing.", high = { openness = 0.5 } },
}

return Lines
