# The first 30 minutes (play-design, 2026-11-05)

Ideas prompt 9, step 1: the first half hour as it runs **today**, read from the code, with every
dead spot, confusing moment and missing reward; then the remaining early-game prompts
(docs/Prompts-EarlyGame.md 2–8) re-ordered into a plan. Step 2 builds the plan's first item.

## 1. Minute by minute, today

| When | What happens | What's wrong |
|---|---|---|
| 0:00 | Spawn on the spawn town's plaza (WorldStateService moves the spawn there). Town music and crowd ambience start; the HUD shows the region chip, the menu and empty `+` hotbar slots. The innate profile was generated on join; the root branch of each awakened domain is unlocked at **Sensing** (power 1, verbs sense/generate, forms touch/aura). | Nothing tells you what you are. You don't know your domain until you open something. |
| 0:05 | The "Something stirs in you" card: **Reach inward [C]**. ~6 s later a toast: "Press H to see every control". | Fine. |
| 0:10 | The Composer opens in Guided mode **and the 5-page "How spells work" walkthrough opens on top of it**. | A wall of text before the first spell, the opposite of UI.md §5's "discovery, not text walls". |
| 0:40 | Guided shows a card per awakened domain. Only Energy, Earth and Water have a named Sensing technique (Glow Mote, Pebble Nudge, Dew Sense: utility). Every other domain gets "First spark", the **first template in alphabetical order** (typically *Generate X as Aura*). | Your first spell is usually **harmless and barely visible**. The domain's attack (the Strike from EarlyGame #1, e.g. Scorch) exists but Guided never offers it. |
| 1:00 | Save to hotbar → slot 1. Press 1 to ready it (equip mode), click to cast. Power 1, touch or aura. | You have one spell. To get an attack you must already know the grammar (Full mode). |
| 1–5 | Cast at… what? Villagers (now a crime only if you actually hurt one), the air, a training dummy **only inside the magic school**, if the spawn town has one. | **Nothing to hit.** No creatures exist. |
| 1–2 | Quests arrive: in the logs, a *duel challenge* and an *escort journey* were offered within ~60 s of joining. | Generic, and a duel is no fit for a power-1 touch caster. No beginner-sized goals. |
| 5–30 | Practice XP trickles in (~900 XP/h focused, JourneySim). Novice (mastery 10, ~835 XP) arrives around **55 minutes**. | **No ranged attack for the first hour.** Every fight is at arm's length at power 1. |
| any | VFX and sound are now good at every tier (Kenney textures, licensed audio), so casting itself feels better than it did. | — |

**Biggest dead spots, in order:** (1) the first spell is harmless and has to be built; (2) nothing to fight; (3) melee-only for an hour; (4) no small goals; (5) a text wall at 0:10.

## 2. The plan (EarlyGame prompts 2–8, re-ordered)

| # | Item | Size | Source | Why here |
|---|---|---|---|---|
| **1** | **Innate spells on the hotbar** (built 2026-11-05): on your first awakening you get your domain's **Strike** (e.g. Scorch, touch, power 1) and a **utility** (a Sensing technique, or *Sense <property>*), named, in slots 1–2; Guided's "First spark" becomes the Strike; the walkthrough waits until you've cast once. | S–M | EarlyGame #3 + this audit | Fixes dead spots 1 and 5 in the first minute. |
| 2 | **Practice targets in every town**: a training yard by the plaza (2–3 PracticeTarget dummies, no crime), before creatures exist. | S | EarlyGame #5, split | Fixes dead spot 2 now, cheaply. |
| **3** | **First ranged spell** (built 2026-11-05): no milestone, no gate. Projectile opens at **Sensing**, and the awakening also gives your Strike thrown (Ember Dart...) in slot 3. The owner chose against the "First Steps" checklist: "I don't want to restrict anything for the player". | S | EarlyGame #2 | Dead spot 3. |
| 4 | **Beginner situations + a mentor per town** (light the lamps, spar the training master, find a lost pet, "show me your magic"), only below Adept, never a duel at Sensing. | M–L | EarlyGame #6 | Dead spot 4. |
| 5 | **First creatures** (4–6 critters near settlements, every domain strong against one). | L | EarlyGame #5 | Replaces dummies as the thing to fight. |
| 6 | **Experimentation pays** (novelty XP, first-reaction toasts, Guided "try something"). | M | EarlyGame #7 | Once the basics work. |
| 7 | **First-time flourishes** (first damage, first new verb/form: a stinger and a toast). The rest of EarlyGame #4 (VFX floor) is already met by the VFX and audio work. | S | EarlyGame #4, trimmed | Polish. |
| 8 | **Measure the first hour** (JourneySim + telemetry). | M | EarlyGame #8 | Last: measures the above. |

Rules kept: non-linear (suggestions and situations, never a mandatory chain), no paid features, `xpScale = 2.3`, server-authoritative, seeded.

## 3. Item 1, built (2026-11-05, not yet run)

- **`Shared/Magic/Cantrips`:** per domain, the **Strike** (Data/Strikes: generate <property> as touch, power 1; named, e.g. Scorch) and a **utility** (the domain's Sensing technique, else *Sense <property>* on a seeded root property, aura or touch). Seeded: `Seed.random(worldSeed, "player:<id>", "cantrip:<domain>")`.
- **`Services/CantripService`:** grants them once per awakened, unlocked domain (`PlayerData.cantrips`, filled into old saves by reconcile): on data load (existing players get theirs too) and when an awakening opens a domain (`ProgressionService:setAwakenHook`). `SpellbookService:grant` validates against the real caster, saves the named entry and puts it on the first empty hotbar slots (the first domain's on 1 and 2); `SpellbookChanged` makes the client refetch.
- **HUD first steps:** "Something stirs in you" (Reach inward) only with an empty spellbook; otherwise **"Your magic answers."** with exactly how to use slot 1 on your input and cast mode ("Press 1 to ready Scorch, then click to cast."), until the first cast goes through.
- **Composer:** Guided's "First spark" is the domain's Strike; the "How spells work" walkthrough opens by itself only after your first cast.
- **Spec:** `Tests/Cantrips.spec` (every domain: a valid, damaging Strike and a utility at Sensing; seeded utility).
- **Next:** item 2, practice targets in every town.

## 4. Item 2, built (2026-11-05, not yet run)

- **A practice yard in every town** (`SettlementDecor` kind `practiceYard`, tag `PracticeYard`): planned on the first clear spot on rings 9–27 studs out from the plaza edge, facing it. A dirt pad, three straw training dummies in a row, posts and a sign ("Practice yard / Strike freely").
- **Each dummy** is its own Model with a Humanoid (normal targeting and damage), `PracticeTarget` (never a crime) and an Interactable "dummy" root (InteractionService: damage readout, Reset prompt, heals itself at 20%).
- **Fireproof:** every piece has `Flammability = 0` (ThermalSim), the magic school's dummy too: practising Scorch can't set the town alight. The yard dummies are Sand, not Fabric.
- **HUD:** the "Your magic answers" card points at the yard.
- **Spec:** Settlement.spec checks at least 80% of settlements get a yard within reach of the plaza.
- **Next:** item 3, the first ranged spell.

## 5. Item 3, built (2026-11-05, not yet run)

- **The owner's call:** nothing is restricted for the player. Instead of the "First Steps" milestone (cast 20, hit 5, sense 3 → an XP block) or a separate weak "flick" form, the real **Projectile form opens at Sensing** (`Data/MasteryTiers`; Novice now opens only amplify, reduce and Burst). The Sensing power ceiling (1) is what keeps a first bolt weak (~9 damage before resistances).
- **A third innate spell:** your Strike thrown, power 1, named by `Data/Strikes` `rangedName`: Ember Dart (Energy), Boiling Drop (Water), Crack Shot (Air), Heavy Mote (Gravity), Soul Dart (Spirit), Pebble Sling (Earth), Thorn Dart (Life), Mind Dart (Mind), Hollow Mote (Void), Rift Dart (Space), Withering Mote (Time), Ill Omen (Reality). `Cantrips.bolt`; granted after the strike and utility, so a new player's first domain fills slots 1–3.
- **Old saves:** `PlayerData.cantrips` now records `"<domain>:<kind>"`. A bare `"<domain>"` key (saved before today) counts as strike + utility given, so those players get only the bolt, on their next load, on their first empty slot.
- **HUD:** "Your magic answers" also names the thrown spell and its slot ("Ember Dart in slot 3 throws your magic from afar.").
- **Specs:** EarlyGame.spec checks every domain's projectile strike at **Sensing** (was Novice); Cantrips.spec checks every domain gets a damaging bolt, third.
- **Next:** item 4, beginner situations and a mentor per town.

