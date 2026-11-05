# Prompt pack: the early game and an attack for every domain

Paste these one at a time, in order. Each one builds on the one before it. They assume the project bible rules, the current code (MagicCore, Registry, EffectLibrary, CastService, DamageModel, ProgressionService, QuestDirector, NPCService, JourneySim) and docs/MagicSystem.md, Progression.md, Combat.md and Roadmap.md.

**Why this pack exists (audit, 2026-11-03):**
- **Sensing** (the starting tier) allows only `sense`/`generate`, the `touch`/`aura` forms and power 1. **Novice** (mastery 10, about 835 XP) adds `amplify`/`reduce` and `projectile`/`burst`.
- **6 of 12 domains have no `harmful` property in their root branch.** Earth (hardness, density, contour), Mind (perception, emotion), Void (aether, presence), Space (distance, presence), Time (tempo) and Reality (probability) can't make a damaging spell with their starting branch at any tier. The only `harm` route needs `harmful = true`.
- **Life** can only harm from Novice on (`reduce vitality`), because `generate vitality` routes to `restore`.
- **Earth is in the vertical slice** (Energy + Earth, Roadmap.md), so this blocks the slice and doesn't only affect rare domains.
- At Sensing, `vfxScale` is 0.2 ("barely visible"), so a new player's first spells look like almost nothing.

**Decisions this pack must respect:** `xpScale = 2.3` stays. No paid features. Everything is server-authoritative, data-driven and seeded.

---

## 1. An attack for every domain (the guarantee)

```
Guarantee that every domain can build at least one damaging spell from its ROOT
branch at Sensing, and a ranged one at Novice. Today Earth, Mind, Void, Space, Time
and Reality can't damage anything from their root (no harmful property), and Life
can't until Novice. Earth is in the vertical slice, so this is a blocker.

Design: a per-domain "strike" in data, not special cases in CastService.
- Domains[d].strike = { property, verbs, damageKind, rider, flavour }, where
  property is a ROOT-branch property. Proposed:
    energy  temperature  "Scorch"        burn chance at P2+
    earth   hardness     "Stone Shot"    small stagger; touch = "Stonefist"
    water   flow         "Lash"          small push
    air     pressure     "Gust Blade"    small knockback
    life    vitality     "Wither Touch"  reduce/drain at Sensing (generate stays a heal)
    mind    perception   "Psychic Spike" brief aim jitter/disorient; mental damage
    spirit  essence      "Soul Prick"    small reservoir drain
    void    aether       "Unmake"        strips one buff; null damage
    space   distance     "Shear"         a tiny displacement
    time    tempo        "Hasten Decay"  short DoT (age)
    gravity weight       "Press"         slows briefly
    reality probability  "Misfortune"    the next hit on the target is more likely to crit
- A new EffectLibrary route `strike`, placed before `harm` and after the specific
  routes. It matches when the recipe's property is its domain's strike property and the
  verb is in strike.verbs. It goes through Impact + DamageModel with the domain's
  damageKind, so resistances (Resist_<domain>), wards, guards and crits all apply.
  Specific routes still win (generate luminosity stays Light; generate vitality stays
  Restore). Explain how strike verbs avoid stealing utility casts: e.g. strike only
  on `reduce` for Life, and on `generate` with a hostile target or a point form for
  the others.
- Riders are small, data-driven status hooks (StatusEffects), budgeted, with
  diminishing returns on repeat.
- Damage parity: at equal power every strike lands within ±15% of the energy
  baseline (9·power^0.6). Exotic domains trade raw damage for their rider; they are
  never strictly better. Show the table.
- MagicCore.describe and the Composer show a "Strike" tag and an ≈ damage preview.
- New spec invariant (Tests/EarlyGame.spec): for every domain, for every tier from
  Sensing up, at least one valid recipe using only that domain's root branch routes
  to a damaging effect, and at Novice at least one is ranged. This must fail loudly
  if someone adds a domain or edits a branch and breaks it.
- Bump RECIPE_VERSION if existing saved recipes change route. List which SpellExamples
  change route and update them.
Cover: hybrid branches, the Granite-is-unused invariant, NPC casts (cosmetic today),
PvP caps, and strike damage against structures (none, or only for Earth?).
```

## 2. A ranged first spell (Sensing reach)

```
At Sensing a player has only touch and aura forms, so their first damaging spell is
melee-range at power 1. Fix the first 10 minutes without changing xpScale.

Proposal, choose and implement one (or tell me why another is better):
A) A "flick" form at Sensing: a short, weak projectile (range ~25 studs, power capped
   at 1, slower, no pierce/bounce/homing, no splash). Data in Forms + MasteryTiers.
B) Let `projectile` open at Sensing for strike routes only, capped at power 1.
C) Novice comes earlier through a one-time "First Steps" milestone (a breakthrough-
   like requirement set: cast 20 times, hit 5 targets, sense 3 things) that grants a
   flat block of XP into the branch. The curve itself is untouched.
Whatever you pick:
- Delivery, Aim and ReticleController all support it (Aim stays the single source of
  range/flight maths).
- Touch gets real feel: a short lunge, a hit-stop and a bigger impact than an aura.
- JourneySim reports "minutes to first ranged damaging spell" per domain and per gift
  tier (Modest to Prodigy). Target: under 10 minutes for every domain.
Cover exploits (flick spam, out-damaging Novice projectiles), cooldowns and budgets.
```

## 3. The awakening gives you a spell (innate cantrip)

```
Right now an awakened player has to open the Composer before they can do anything.
Make the awakening moment hand them a working, named, signature-tinted first spell.

- On awakening (and for every existing save without one, by reconcile), generate a
  seeded "innate cantrip" from Seed.random(worldSeed, entityId, "cantrip"): their top
  domain's strike (prompt 1) in the best form their tier allows, plus one utility
  cantrip (light, nudge, warmth, sense...) from their temperament. Put both in the
  spellbook and on hotbar slots 1 and 2.
- The cantrip gets a generated default name (grammar from the profile and signature,
  e.g. "Ember Flick"). It's still renameable through SpellbookService, with the same
  filtering rules.
- The awakening UI ends with "Press 1 to attune, click to cast" (and the gamepad and
  touch equivalents), driven by the castMode setting.
- When a new branch unlocks, offer (don't force) one seeded starter recipe for it.
Cover: players who already composed spells, rerolls (none are paid), NPCs (do they get
cantrips too, for NPCMagicLife?), and the spellbook cap.
```

## 4. Low-tier spells that look and feel good

```
At Sensing, vfxScale is 0.2 ("barely visible"). That fits the fiction but is a bad
first impression. Keep the progression of spectacle, but put a floor under combat
readability.

- A separate floor for combat feedback: hit markers, damage numbers, hurt flash, impact
  sound and a small impact burst are always readable, whatever the tier. Only the
  ambience (lingering particles, ground marks, environment response) scales with
  vfxScale.
- Each domain's strike (prompt 1) gets a distinct low-tier look and sound in DomainFx,
  so a stone shot never reads like an ember. Colour is never the only cue (shape +
  sound + word).
- A "first time" flourish: the first time a player ever damages something, and the
  first cast of each new verb or form, gets a one-off toast and stinger.
- Low-tier instability as flavour, not punishment: occasional sputter or fizzle
  visuals when casting near the power ceiling, tied to the existing overreach maths.
Cover the FxPool and light budgets when 30 new players spam cantrips in the spawn town.
```

## 5. Things worth hitting near spawn (the first creatures)

```
New players need low-risk targets that aren't villagers. This is the seed of the
later "creatures" world stage, so build it as that system's first slice, not a
throwaway.

- Data/Creatures: 4-6 low-tier magical critters for the starting biomes (e.g. ember
  sprites, mud-crawlers, gust-moths, gloom-rats, glass beetles). Each has domain
  resistances and weaknesses, a seeded den location, a simple behaviour (wander, flee,
  swarm, defend den), and loot-table hooks for the Items system.
- They spawn deterministically from (worldSeed, chunk, "creatures") around settlements
  and roads, with respawn timers, a per-server population budget, and NPCLOD-style
  sleeping when no player is near.
- Weakness design so EVERY domain's strike is good against something (Mind against
  the cunning ones, Void against magical ones, Earth against fliers knocked down...).
- Killing one gives combat-channel XP to the branch used, with the anti-grind rules
  (diminishing returns per creature type per hour).
- Admin: `creature spawn <type>`, `creatures`, `creaturedens`.
Cover pathing cost, StreamingEnabled (creatures outside streamed areas), farming
exploits and NPC reactions (guards kill pests; farmers pay for it).
```

## 6. Early goals without a story (first-hour situations)

```
The sandbox needs small, readable goals in the first hour. Use the existing
QuestDirector/SituationDetector, not a scripted tutorial.

- 6-8 low-stakes templates that only spawn near the player's settlement and only
  for players below Adept, e.g.: light the plaza lamps at dusk; clear gloom-rats
  from a cellar; spar with the town's training master; find a lost pet (sense);
  help a farmer (water / earth / growth); deliver a sealed letter (tests a door/lock);
  "show me your magic" (an NPC asks for a specific verb or property).
- Each one accepts creative solutions through interaction tags (any domain should be
  able to clear the rats, thanks to prompt 1).
- An NPC mentor in every settlement, chosen from existing NPCs by profession and
  magic tier, who offers one "lesson": a seeded technique hint for the player's top
  domain, and a mentor-channel XP award (ProgressionService:awardStudy "mentor").
- Journal "Path" hints: 3 soft goals generated from the player's profile (e.g. "Your
  affinity for Air is strong. Try redirecting a gust.") that never spoil hidden
  latents.
Cover: shared-quest collisions when 20 new players are in one town, reward caps,
the Narrative Director's pacing (don't flood beginners), and what veterans see.
```

## 7. Experimentation pays (discovery for beginners)

```
The spell grammar is the game's best feature, but beginners don't know it's there.
Reward experimenting in the first hours.

- A "novelty" XP bonus for the first cast of each new (verb, property, form) combination,
  decaying fast so it can't be farmed. It goes through the existing XP channels and
  anti-grind rules; xpScale is untouched.
- Early environmental reactions made obvious: dry grass catches, water conducts charge,
  ice makes slopes slick, wind spreads fire. When a player triggers an InteractionMatrix
  reaction for the first time, it gets logged to DiscoveryLog with a short "You
  discovered: ..." toast.
- Composer Guided mode: a "try something" button that suggests one seeded,
  valid, unexplored recipe at the player's current tier, with its ≈ preview.
- A Grimoire page of "rumoured" techniques (seeded, partial, unlocked by NPC gossip
  and bookshelves).
Cover: discovery spam in logs, saved-data growth (cap and compress the novelty set),
and keeping mythic fragments secret.
```

## 8. Measure the first hour

```
Extend JourneySim and add live telemetry so we can tell whether the early game works.

- JourneySim: simulate a new player per domain × gift tier for the first 60 minutes
  using the cantrip, the strike route, creatures and starter situations. Report:
  minutes to first damage, to first ranged damage, to Novice, to first discovery,
  to first quest completed; casts per minute; and time spent with nothing to do.
- Live: server-side counters (no PII) for the same milestones, written to the Logger
  and an admin `firsthour` report (per server, and per player for admins).
- Targets to check against: first damage < 2 min, first ranged < 10 min, Novice < 30 min,
  a discovery in the first 20 min, and no domain more than 25% slower than Energy.
- A spec that runs a shortened JourneySim and fails if any domain misses the first-
  damage target.
```

---

**Suggested order:** 1 → 2 → 3 come first because they unblock the vertical slice: Earth needs an attack. Then 4, then 5 and 6 together (situations use creatures), then 7 and 8. Prompt 8's JourneySim part can run right after prompt 2 to measure the baseline.
