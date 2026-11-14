# People noticed that (#38)

Built 2026-11-14 (group 3 of the build queue, "NPCs noticing"). Your magic has an audience: people who see it say something, and big spells are talked about in towns that only heard them.

No interface. Everything is said aloud in a chat bubble by someone who was there.

## Seen

When a player's cast resolves (`Topics.MagicWitnessed`, now with what the spell did: `recipe`, `key`, `form`, `effective`, `backfire`, `practice`, `hurt`, `killed`, `changedLand`), the townspeople within **36 studs** of the caster or the landing spot are witnesses. Only drawn (T0), awake, free people can speak: not in a fight, a conversation, a scene/quest leash, asleep or sheltering.

The likeliest to speak up (extraversion, children, closeness, a seeded roll) may say **one** thing, 0.5–1.1 s later, stopping to face you for 2.5 s. They speak only if their own chance comes up: ordinary magic gets 30–95% by temperament, and anything alarming or big gets 100%.

What they say, most specific first (`NPC/Noticing.categories`; a category with no line that fits this person falls through):

| Category | When |
|---|---|
| backfire | it went wrong on you |
| killed / hurt | it killed or hurt someone (practice dummies don't count) |
| scared | harmful and landed within 12 studs of them |
| mythic | Time, Gravity or Reality |
| land | the ground changed |
| dud | nothing real happened (the Composer's "no real effect") |
| big | power 6+ |
| weak | they're a mage of tier 4+ and it was power 2 or less |
| dummy | practice on a dummy ("Do that again!") |
| heal / protect / boost / control / move / sense / utility | the spell's kind (`SpellOutcome`) |
| `<domain>` | its first domain |
| any | always has a line |

Lines are picked by the person's job, mood, traits, whether they're a child or a mage, and now **their fears** (BarkEngine's new `fear` condition: someone afraid of fire reacts to fire).

**Limits:** one speaker per cast; one comment per player per 20 s (6 s if big); the same person to the same player once per 4 min; the same spell again within 10 min isn't news unless big.

## Heard

A big spell (power 6+, the land changed, someone killed, a mythic domain) is heard in every town whose centre is within **420 studs**. For 20 real minutes, when you walk up to someone there who **didn't** see it, they may (60%) ask about it instead of greeting you, with the direction it came from: "Was that you, out north? The whole house shook." At most 3 people per spell per town; each person decides once.

They ask the caster, guessing. They don't ask other players (see open questions).

## Code

- `NPC/Noticing`: pure rules and tuning (`Noticing.Tuning`).
- `NPC/Data/NoticedLines`: the lines (Barks shape).
- `Services/NoticeService`: the witnesses, the delay, the heard lists, admin.
- `AmbientLifeService`: `lineFor`, `face`, `markGreeted`, `setGreetHook` (the "heard" question comes before mark remarks).
- `BarkEngine`: `fear` condition, `ctx.fears`.
- `CastService`: the richer `MagicWitnessed` payload.
- Flag `noticing_enabled` (also needs `ambient_life_enabled`).
- Admin: `noticing` (counts and what each town heard; `noticing clear` resets every cooldown), `noticetest <what> [domain]` (categories and the nearest person's line, said aloud).
- Log: `npc_noticed` (throttled), `npc_asked_about_magic`.
- Spec: `Tests/Noticing.spec` (5).

## What still feels like a game

- Witnesses see through walls (distance only, no line of sight). Cheap, but someone indoors can comment on a spell outside.
- The "heard" question always guesses right: they only ask the actual caster.

## Open questions

1. Should "heard" questions go to any mage in town (sometimes the wrong one) instead of always the caster?
2. Line of sight for witnesses (one raycast per candidate)?
3. Should being noticed feed reputation (a big heal in the plaza raising standing a little)?
