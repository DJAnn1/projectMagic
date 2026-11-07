# Magic Marks ("Magic Changes You")

Built 2026-11-07 on the owner's "Begin with magic changes you". Stage 1, not yet run.

The magic you use most slowly and visibly changes your body. A fire mage's hands blacken with soot, then their arms. A water mage drips and leaves damp footprints. NPC mages carry the same marks from their own careers, so the old smith with soot-black arms is just part of the world.

Following the design rule (2026-11-07): there's no meter, card or popup. You learn about a mark by looking at your hands, from a first-person Journal line, and from what people say when they see you.

## How it works

| Part | What happens | Where |
|---|---|---|
| Counting | Every spell that works (SpellResolved: effective, not borrowed, not backfired) adds 1 point to its domain. A hybrid splits the point. At most one counted cast per 2 s per player, and 600 points per domain per real day. | `Services/MarkService`, `Magic/MarkRules.addCast` |
| Fading | Every real day takes 2% of every domain's points, applied on load and at midnight on a running server. The owner's decision (2026-11-07): marks fade over time and are never permanent. With no use, a top stage 3 mark drops to stage 2 in about 9 days, to stage 1 in about 68, and is gone in about 146; a fresh stage 1 is gone in about 9. | `MarkRules.decay` |
| Stages | 250 / 1,200 / 4,000 points. A shown stage only drops below threshold × 0.85, so a mark doesn't flicker on a boundary. | `MarkRules.stageFor` |
| Share | A domain must be at least 35% of all your points to mark you, and keeps the mark down to 25%. Two marks at most: the strongest win. A little of everything marks nobody. | `MarkRules.evaluate` |
| On the body | The character gets the attribute `MagicMarks` (`"energy:2,water:1"`) and the tag `MagicMarked`. NPC rigs get the same through `NPCLOD.setMarksProvider`. | `MarkService`, `NPC/NPCLOD` |
| Drawing | The strongest mark covers both arms from the hand up: 30%, 60% and all of an R6 arm (R15: hands, lower arms, upper arms). Every mark sends a few particles off the hands, and at stage 3 some add a haze at the head. From stage 2, Energy, Earth, Water, Life, Void and Gravity leave footprints. Only drawn within 120 studs; prints only within 70. | `Client/Fx/MarkFx`, `Controllers/MarkController` |
| Perk | Each stage gives 4% resistance to your own domain (12% at stage 3). It's a new `marks` source in `Cast/Resistances`, so NPC mages get it too. | `MarkRules.resist` |
| Quirk | Void, Reality, Time, Spirit (and a little Space, Gravity, Mind) unsettle nervous people: `GreetingRules` takes nervousness × unsettle × 0.35 off the greeting score. The footprints and particles are the visible quirk. | `MarkRules.unsettle`, `NPC/GreetingRules` |
| Journal | A first-person line when a mark appears, grows or fades (kind `mark`). | `Data/Marks` `journal` |
| NPCs notice | The first time an NPC sees a mark on you, or a mark that's grown, they remark on it instead of their usual greeting. NPCs further off sometimes (35%) whisper about it. Someone who carries the same mark talks to you as kin. Once per NPC per mark and stage. | `AmbientLifeService.markLine`, `NPC/Data/MarkLines` |
| NPC marks | An NPC's best branch: Skilled → stage 1, Master → 2, Grandmaster+ → 3. | `MarkRules.npcStage` |

How long it takes, at the daily cap: stage 1 is less than a day of focused casting (about 250 spells that work, realistically 1 to 2 hours of play), stage 2 at least 2 days, stage 3 at least 7 days. Without the cap it depends on how often you cast, so these are the floor.

## Files

- `ReplicatedStorage/Shared/Magic/Data/Marks.luau`: tuning, and per domain the look, phrases, unsettle and Journal lines.
- `ReplicatedStorage/Shared/Magic/MarkRules.luau`: pure rules (count, fade, stages, share, wire format, perk, quirk, NPC stage).
- `ServerScriptService/Server/Services/MarkService.luau`: counting, saving, applying, NPC provider, admin.
- `ServerScriptService/Server/NPC/Data/MarkLines.luau`: NPC remarks, kin lines, whispers.
- `StarterPlayerScripts/Client/Fx/MarkFx.luau` and `Client/Controllers/MarkController.luau`: drawing and footprints.
- Changed: `Cast/Resistances` (`marks` source), `NPC/GreetingRules` (optional `unsettle`), `NPC/BarkEngine.pick` (optional line list), `NPC/NPCLOD` (marks provider, cleared on release), `Services/AmbientLifeService` (remarks, whispers, `greetstate` shows unsettle, `dailylife` counts remarks), `Persistence/Schemas` (`marks`), `Config/Flags` (`magic_marks_enabled`).
- Spec: `Tests/Marks.spec` (27).

## Saving and safety

- Saved in `PlayerData.marks` (reconcile fills old saves, no schema bump). It's in the player save, so it's under `progressKey`, and progress resets and erasure already cover it.
- No remotes. The client only reads an attribute the server writes.
- The wire format is clamped on decode: unknown domains, stage 0, more than 2 marks and stages past 3 are dropped or clamped. A client can't set another character's attribute anyway.
- Nothing secret is sent: the data module is shared on purpose.

## Admin

- `marks [player]`: points per domain, share, today's points against the cap, the stage shown.
- `markset <domain> <stage> [player]`: enough points for that stage, and enough share to show it. Journal lines fire as in play.
- `markclear [player]`: erases the record and takes the marks off.
- `npcmarks`: how many NPCs carry marks, by stage and domain, and re-marks every NPC body.
- `greetstate` now shows the `marks unsettle` value; `dailylife` counts mark remarks.
- Kill switch: `flag magic_marks_enabled false` takes every mark off players and NPCs and stops counting. Saves keep their points.

## What still feels like a game (for the owner to judge)

- The resistance perk is a number. It's small and invisible, but it's a stat bonus.
- Marks come from a points count, not from what you did with the magic. The Journal and NPCs never mention numbers, but the thresholds are sharp edges.

## Not in stage 1

- A real per-domain perk with its own feel (Water: swim faster; Air: fall more slowly; Earth: harder to knock down; Life: slow healing out of combat; Energy: warm in cold biomes).
- Hiding a mark (gloves, sleeves, a cloak, or a hood for the head haze).
- Signature tint: the mark coloured by your own signature, as spells are.
- Backfilling marks from mastery you earned before this existed.
- Faces and eyes (glowing eyes, hair turning white for Time, and so on).
- Creatures and familiars reacting to marks.
