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
| **4** | **Beginner situations + a mentor per town** (built 2026-11-05): practice yard, lamps at dusk, show me, lost pet, a lesson from the mentor, sparring; only below Adept, one at a time, never a duel at Sensing. | M–L | EarlyGame #6 | Dead spot 4. |
| **5** | **First creatures** (built 2026-11-05): six critters in seeded dens around every town, every domain strong against at least one. | L | EarlyGame #5 | Replaces dummies as the thing to fight. |
| **6** | **Experimentation pays** (built 2026-11-05): novelty XP, first-reaction toasts, Guided "try something". | M | EarlyGame #7 | Once the basics work. |
| **7** | **First-time flourishes** (built 2026-11-05): first damage, first new verb/form: a stinger and a toast. The rest of EarlyGame #4 (VFX floor) is already met by the VFX and audio work. | S | EarlyGame #4, trimmed | Polish. |
| **8** | **Measure the first hour** (built 2026-11-05): a simulation + live telemetry. | M | EarlyGame #8 | Last: measures the above. |

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

## 6. Item 4, built (2026-11-05, not yet run)

- **Situations:** `beginner` (and `beginner_dusk`, 17:00–22:00 game time) per player and nearest town within 300 studs, only while the best branch is below Adept (`QuestTuning.beginner`). Personal, so twenty newcomers in one town each get their own.
- **Six templates** (`QuestTemplates` B1–B6, docs/Quests.md): Practice Yard (5 harmful hits on the dummies), Lamps at Dusk, Show Me (a seeded property of your domain, cast near a villager), The Lost goat/dog/cat/hen/lamb (sense or ask, then fetch from a seeded dry spot 45–110 studs out), A Lesson (the town mentor: mentor study XP + a hint naming your domain's next technique), Sparring (Novice only; the training master yields at half strength). Every one has a way through for any domain.
- **Gates and pacing:** `requires.maxTier = 2` hides them from Adept and up; at most one beginner quest offered or active at once; low intensity (0.05–0.3), so the calm phase prefers them; Practice Yard and the Lesson weigh most. A Matter of Pride (rival duels) now needs Novice too.
- **The mentor:** QuestFactory picker `mentor`, the town's highest-tier NPC mage, scholars and priests first; deterministic per town.
- **Specs:** Quest.spec: beginner templates are personal, maxTier 2 and ride beginner situations; no duel-type template below Novice; `anyEffect`; the technique hint.
- **Not done (from EarlyGame #6):** Journal "Path" hints (3 soft goals from your profile).
- **Next:** item 5, the first creatures.

## 7. Item 5, built (2026-11-05, not yet run)

| Creature | Behaviour | Weak to (at or below -0.3) | Resists |
|---|---|---|---|
| Ember Sprite | swarm, floats | water | energy |
| Mud Crawler | defends its den | energy, time | earth, water |
| Gust Moth | flees, floats, can't attack | earth, gravity | air |
| Gloom Rat | swarm | spirit, mind, life | void |
| Glass Beetle | defends its den | air, space | earth |
| Mana Wisp | ignores you until hit, floats | void, reality | none at 0.3+ |

- **Data:** `Server/Creatures/Data/Creatures` holds everything per creature, plus tuning. A new creature is one entry there.
- **Dens:** `CreatureRules.planDens`, seeded from `(worldSeed, "settlement:<id>", "creatures")`. Up to 4 per town, a different type each, weighted by the town's biome, 45–150 studs beyond its edge, on dry gentle ground, outside every town and 45+ studs apart. Seeded per settlement rather than per chunk (the prompt's wording), because dens belong to towns. Roads aren't considered.
- **Population:** dens are data until a player comes within 220 studs and the chunk is built; they sleep at 300. `creatures_max_alive` (70) caps the total, nearest dens first, at most 6 rigs built per second. A dead member respawns in 80–200 s, but not while someone stands within 35 studs of the den.
- **Body:** `CreatureRig` builds a real Humanoid + HumanoidRootPart, so targeting, projectiles, statuses, knockdowns and lock-on need no creature code. Server network owner, atomic streaming, no animation yet. The Humanoid's own overhead shows the name and health.
- **Movement:** straight-line `MoveTo` at 4 Hz, no pathfinding. The leash (32–44 studs from the den) keeps them out of town. Past it they go home, and on arrival they heal and forget the fight.
- **Law:** hitting a creature is never a crime (`Damage` marks it `practice`, as with dummies).
- **Weakness feedback:** "Weak!" or "Resists" floats over the target, using the status-word cue.
- **Rewards:** everyone who dealt 20% of its health gets XP (`challenge` channel, to the branch that last hit it; `DamageModel` and `MeleeService` now pass `branch`) and their own seeded loot roll. Weapon-only kills give loot but no magic XP. Both scale by `1 / (1 + killsThisHour / 8)` per type, saved in `PlayerData.creatureHunt` so server-hopping doesn't reset it. The practice anti-grind also applies (AFK, repeats, relevance to your power ceiling).
- **Items:** five new materials (`crawler_chitin`, `moth_dust`, `gloom_fur`, `beetle_glass`, `wisp_mote`); sprites drop the existing `ember_essence`. Loot goes straight to the inventory (world drops are Items stage 3). No recipes use them yet, apart from `gloom_fur` carrying the `hide` tag.
- **Admin:** `creature spawn <type> [count]`, `creature clear`, `creatures`, `creaturedens`. Flag `creatures_enabled`.
- **Spec:** `Tests/Creatures.spec` (10 tests).
- **Not done (from EarlyGame #5):** guards killing pests and farmers paying for them (dens stay outside towns, so they never meet), creature sounds, animation, and a quest or Journal entry pointing at dens.
- **Next:** item 6, experimentation pays.
- **Verified in play (2026-11-05):** dens (56 in 14 towns), `creature spawn`, kills, XP to the branch used and the falling reward factor.

## 8. Item 6, built (2026-11-05, not yet run)

- **Novelty XP:** the first *effective* cast of a new verb + property + form pays `max(3, 30 x 0.95^found)` base XP through the `experimentation` channel (daily cap 2500), with a "Something new: ..." toast. It works at power 1, which recipe discoveries ignore (`minPowerForCredit = 2`). Power and branch don't make a new combination. It doesn't count toward breakthroughs. Saved in `discoveries.novelty`, capped at 400 entries.
- **First reactions:** the first time you trigger each `InteractionMatrix` reaction: "You discovered: <its description>", the discovery sound and 60 base XP. Only the caster who set it off is credited (`EffectRunner` publishes `MagicReaction`). Saved in `discoveries.reactions`.
- **Try something:** Guided has a button at the top. The server (`SuggestSpell`, rate limited) picks a seeded spell from your unlocked branches that you haven't tried, one power under your ceiling, checked with the real validator, skipping forbidden branches. The client shows it as an ordinary card with the preview, Save and Customize. No world seed or hidden profile data reaches the client.
- **Spec:** `Tests/Experiment.spec` (7 tests). Pure rules: `Progression/Experiment`.
- **Not done (from EarlyGame #7):** the Grimoire page of rumoured techniques (not in this plan item), and toasts for environmental reactions such as dry grass catching or ice being slick: those don't run through the matrix.
- **Next:** item 7, first-time flourishes.

## 9. Item 7, built (2026-11-05, not yet run)

- **What fires:** the first blow you ever land (spell, weapon or damage over time, on anything but yourself, dummies and creatures included), and the first effective cast of each verb and form. Each fires once per save: "First time: a blow that lands · Generate · Touch", with the new `sting.first` stinger.
- **One moment, one flourish:** a spell's first hit and first cast arrive moments apart, so `DiscoveryLog` holds a first for 0.25 s and merges what arrives. A cast that opens a verb or form skips its novelty or discovery toast; the XP still pays.
- **Saved:** `discoveries.firsts`, created on first use and filled from the save's recipes and novelty set, so existing players aren't told they've just found Generate. First damage can't be inferred from a save, so an existing player sees it once.
- **Stinger:** "Small Discoveries (sting b)", 9040172806, previously the alternate for `sting.discovery`. Not auditioned.
- **Spec:** `Tests/Experiment.spec` (3 more tests).
- **Not done (from EarlyGame #4):** sputter and fizzle visuals near the power ceiling.
- **Next:** item 8, measure the first hour.

## 10. Item 8, built (2026-11-05, not yet run)

**Targets** (`Progression/FirstHour`, used by both tools): first damage < 2 min, first ranged < 10 min, Novice < 30 min, something new < 20 min, no domain over 25% slower than Energy.

- **Simulation (`Tests/FirstHourSim`, admin `firsthoursim [minutes]`, prints to the Output):** every domain at Modest, Gifted and Prodigy (Faint is excluded: `playerMinGiftTier` is Modest), through the real Cantrips, stats, Reservoir, Progression, Experiment and Creatures. It's a separate module rather than an extension of JourneySim, whose hour-long steps can't resolve a two-minute target. The player is a model (`BEHAVIOUR`, at the top of the file): it never gets lost and always hits. So it finds rule problems, not confusion.
- **"Discovery" in the target means novelty.** A recipe discovery needs power 2, so it can't happen before Novice. Both are reported.
- **Novice is reported with and without the mentor lesson,** which pays `650 x tier gap` XP against about 835 to reach Novice from practice. The comparison with Energy uses the no-lesson number, since the lesson is the same for everyone.
- **Live (`Services/FirstHourService`, admin `firsthour [player]`):** new players only, in seconds of play, saved in `PlayerData.firstHour`. Logged as `first_hour` with no user id. The server report is medians only; the per-player report is admin only. Idle is a ceiling (gaps over 60 s between casts include walking and reading).
- **Spec:** `Tests/FirstHour.spec` (4 tests): a 12-minute simulation per domain at Modest must meet the first-damage and first-ranged targets. Slower targets are only reported, never failed: they're for a person to judge.
- **Not modelled:** reactions, weapons, other quests, travel beyond `walkToNext`, overdrawing the reservoir.
- **Next:** the plan's eight items are built. Read the numbers, then decide what to tune.

