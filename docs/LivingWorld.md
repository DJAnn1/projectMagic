# The living world

Making the world feel like it exists whether or not the player is looking, and like the player's actions matter. Built in stages; each waits for the owner to confirm the last.

| Stage | What | State |
|---|---|---|
| **1** | Audit, daily life in one settlement, 100+ barks, reputation greetings, 10 scenes | built 2026-11-05, not yet run |
| 2 | Settlement growth, rumours that distort | not started |
| 3 | Vignettes, world history | not started |
| 4 | Wonder events, landmarks | not started |

---

## 1. Audit: what the world did before this work (2026-11-05, read from the code)

### When the player isn't interacting

| System | What actually happens | The gap |
|---|---|---|
| **NPC schedules** | Real: 9 schedule templates, utility brains, needs. T2 NPCs (data only) keep deciding once per game hour, so a town's day runs with nobody there. | The result is mostly invisible. |
| **Where NPCs go** | Homes and workplaces are real building anchors (NPC.md §6b). **Leisure isn't:** `tavern`, `market`, `temple`, `school`, `forge` and others are abstract points around the town centre (`ScheduleService.LAYOUT`), so "going to the tavern" doesn't mean the tavern. | Fixed here for the spawn town. |
| **What NPCs do on arrival** | Stand in the idle pose. Every occupation looks the same; only a small cast gesture differs. | Fixed here. |
| **Guards** | All on one 07:00–15:00 shift: **no guard works at night.** | Fixed here: three watches. |
| **Market stalls** | Goods always out. | Fixed here for the spawn town. |
| **Lamps** | Building lamps do follow dusk (`Interact/Lamps`). **Street lamps are always on,** and lamplighters only stand about. | Fixed here for the spawn town. |
| **Festivals** | None. | A rest-day procession scene here; real festivals later. |
| **Magic in daily life** | Work casts: a cosmetic spell every 12–25 s from the NPC's real profession and mastery (T0 only). | Works. Troughs, wall mending and magic shops aren't built. |
| **Barks** | The grammar in `Data/DialogueGrammar` every 45–90 s. No memory of what was said, and nothing about local events beyond a hook. | Replaced here. |
| **Creatures** | Real, in 56 dens. Exist only near players. | Fine. |
| **World events** | `EventDirector` runs 10 types per server, with effects on NPCs. No sky visuals. | Visuals are a later stage. |
| **Social life** | Hourly pairing, gossip between NPCs, careers in 7-day chapters. Real, but nothing surfaces it. | Barks can now mention it. |
| **Stories with no player** | None. | Scenes, here. |

### What persists from a player's actions

| Change | Persists? | Where |
|---|---|---|
| Terrain edits: quakes, ruptures, landslides | **Yes, across servers** | Terrain deltas per chunk, `WorldDeltas` messages |
| Coast and vegetation changes from disasters | **Yes** | Region state |
| Reputation, faction standing, infamy, bounties, notoriety | **Yes, per player** | Player save |
| What an NPC thinks of a player (top 80 NPCs) | **Yes** | Player save |
| NPC memories of players (top 8 per NPC), mythic awakenings | **Yes, per town** | `NpcTowns` store |
| World firsts and big events | **Yes, shared** | Discovery store, chronicle (a capped list nobody can read in game) |
| Houses and furniture | **Yes** | Player save, `Housing` store |
| Settlement state | **Numbers only** | Settlement deltas exist, but nothing in the world changes from them |
| Killed creatures, cleared dens | **No** | They respawn |
| Scene outcomes (new) | **No** | In memory on one server, except what a player's reputation and bonds save |

**In short:** the simulation underneath was already good, and much of it just couldn't be seen. Persistence is strong for terrain and for what NPCs think of you, and weak for anything that visibly changes a town, which is what stage 2 is for.

---

## 2. Daily life

**How it works:** the schedule still decides everything. `NPCBrain` picks the action, `NPCService` routes the NPC, and then `NPC/DailyLife` plays the activity from `Data/Activities`. It runs **only on T0 rigs**, so distant NPCs stay data only.

| Who | What you'll see |
|---|---|
| Smith, builder, miner, farmer | Hammering or digging with a tool. Builders and farmers move around. |
| Guards | A spear and a patrol: their post, then the plaza. Three watches, so shifts really change at 07:00, 15:00 and 23:00. |
| Lamplighter | Walks the street lamps at dusk with a lantern. Each one lights as they arrive. All are lit by 21:00 regardless, or at dusk if the town has no lamplighter. |
| Merchant | At their stall, pointing at passers-by. Goods appear at 08:00 and go at 18:00. |
| Innkeeper, evening crowd | Mugs in hand. Anyone socialising now goes to the real tavern's seats, so it fills in the evening. |
| Children | Run around the plaza, jump and cheer, with tiny sparks from their own magic. Sit in lessons. |
| Everyone else | Sit to eat, read, pray, point while teaching. |

**Animations:** each is one slot in `Activities.Clips`; to replace one, change its id there. `hammer`, `dig`, `hold`, `point` and `sit` are the owner's own clips (2026-11-05). `wave`, `cheer`, `laugh` and `dance` are still Roblox's defaults. A clip that can't load gives one `[DailyLife] clip ... didn't load` warning.

**One settlement for now:** the town the world spawn sits in. `flag ambient_all_towns true` turns it on everywhere. Barks, greetings and scenes already run everywhere.

**Crowd density:** comes from the schedules and town size, within `NPCLOD`'s caps (40 T0, 100 T1). Nothing new. A larger town has more people, and the plaza empties at night because people have gone home.

**Not built yet:** water mages at troughs, earth mages mending walls, magic shops, real fields (farmers work at the barn), holiday festivals.

## 3. Barks and greetings

**Barks** (`Data/Barks`, `NPC/BarkEngine`): over 100 ambient lines, by time of day, land, work, personality and quirks, mood, nearby events, magic, children, leisure, news, and what this NPC remembers about the player beside them.

- A line with more conditions is more likely when they all hold, so a specific line beats a general one.
- News and memories get a further boost.
- **Cooldowns:** an NPC won't repeat its last 8 lines, a line won't recur in a town for 3 minutes, and only one person in a town speaks every 6 seconds.
- **Weather is really land:** there's no weather system yet, so lines come from the biome and active world events.

**Greetings** (`NPC/GreetingRules`):

`score = town reputation/50 + faction standing/600 × 0.5 + the NPC's opinion − infamy/25 + (agreeableness − neuroticism) × 0.4`

| Score | Reaction | What they do |
|---|---|---|
| ≥ 1 | **Fawn** | Stop, face you, cheer. |
| ≥ 0.3 | **Warm** | Stop, face you, wave. |
| middle | **Neutral** | A word, sometimes curt. Stares (**awe**) if you've got a spell readied. |
| ≤ −0.3 | **Wary** | A warning. |
| ≤ −0.9 | **Avoid** | Backs away for a few seconds. |

- A bounty here caps it at wary, and so does high mythic notoriety.
- From 14–26 studs, people **whisper** about you, if you're well or badly known.
- Limits: once per NPC per player per 5 minutes, and one greeting per player per 5 seconds.
- They're cosmetic. Reactions never change your standing.

## 4. Budgets

| Thing | Limit |
|---|---|
| Activity checks | Once a second per T0 NPC (40 at most) |
| Props | 1–2 welded parts per T0 NPC, destroyed when the rig goes back to the pool |
| Clips | Loaded lazily, one at a time per rig. One-shots share `NPCLOD`'s 30 clip starts per second |
| Roaming | Goes through the existing path queue (4 paths a second, shared and cached) |
| Barks | One per 6 s per town |
| Stalls and lamps | A tag scan every 5 s, only in enabled towns |
| Scenes | 2 staged at once, 1 per town. Unwatched scenes create no Instances |

**Known risks:** roaming indoors could hit walls and trigger `NPCLOD`'s 6-second stuck snap. Tuned for one town; turn on `ambient_all_towns` and watch `npclod` before relying on it.

## 5. Scenes

`Services/SceneDirector` + `Scenes/Data/SceneTemplates` + `Scenes/SceneRules`.

**Same on every server:** each game hour every town rolls from `(worldSeed, town, "scene", hour)`. Below 6% a scene happens whether or not anyone's there. Below 16% it happens only if a player is within 200 studs, so there's something to stumble on.

**Nobody there:** no Instances. An ending is rolled, NPC memories are written (normal gossip carries them), and the story reaches the town's barks: *"Did you hear? Hedda beat Corvel in a duel in Ashford."*

**Someone there:** real rigs act it out, and the player can step in.

| Template | Where | Step in by | Changes |
|---|---|---|---|
| `caravan_ambush` | edge | killing the rats | saved, +4 reputation |
| `apprentice_duel` | plaza | talking to either; a harmless spell | calmed, or upstaged |
| `farmer_hermit` | edge | talking to either | settled |
| `moth_passage` | edge | killing the moths | −1: it's bad luck |
| `wounded_stranger` | edge | Life magic; talking | healed +5, aided +3 |
| `rival_test` | edge, night | talking | stopped |
| `festival_procession` | plaza, Sundays | a harmless spell | dazzled |
| `lost_child` | plaza | talking to the child or the parent | found +3, asked +1 |
| `market_quarrel` | plaza | talking to either | smoothed |
| `pickpocket` | plaza | hitting or talking to the thief | caught, shamed |

**Limits to know about:**
- Creatures only attack players, so in `caravan_ambush` the rats threaten the scene rather than truly fight the NPCs.
- There are no wolves yet, so it uses gloom rats.
- Stories last on this server only. The Chronicle comes later.
- A hit on a resident actor is still an ordinary assault, with the usual crime and reputation results. `pickpocket`'s thief is a stranger, so hitting them is treated the same way by the law today.

## 6. Tools

| Command | What |
|---|---|
| `timescale 20` (exists) | Fast-forward to watch schedules |
| `dailylife` | Which town, how many NPCs are doing what near you, counts |
| `bark [npc]` | Bark now, ignoring cooldowns |
| `greetstate [npc]` | Every input, the score and the reaction. Resets that NPC's cooldown |
| `scene <template>` | Start one in front of you |
| `scenes` | Running and recent |

**Flags:** `ambient_life_enabled`, `ambient_all_towns`, `scenes_enabled`.

**Spec:** `Tests/LivingWorld.spec`: data consistency, 100+ lines, conditions, no repeats, greeting bands, scene endings.

**Not yet (later stages):** spreading a rumour, settlement growth state, world history, nearest vignette, the 30-day simulation.
