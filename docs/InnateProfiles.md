# Innate Magical Profiles: Spec (v1)

Every person, player or NPC, is born with a unique magical profile, generated from:

```
profile = ProfileGenerator.generate(worldSeed, entityId, context)
```

The source of truth for the numbers is `src/server/Magic/Data/ProfileTuning.luau`. This doc explains them.

---

## 1. The profile

| Field | Meaning | Visible to the person? |
|---|---|---|
| `giftTier`, `potential` | How gifted the person is overall: Faint, Modest, Gifted, Prodigy or Paragon. `potential` is a number from 0 to 1 | Never directly. It shows up through everything else |
| `capacity` | Multiplier on reservoir size. Roughly 0.6–1.6, before temperaments | As a band at knowledge level 2; exact at level 3 |
| `regen` | Multiplier on regeneration, 0.85–1.15, before temperaments | Exact at level 3 |
| `domains` | Affinity for all 12 Domains, 0–1 each | Grows with knowledge level (see §5) |
| `leanings` | A multiplier for each tier-1 branch. Branch affinity = `clamp(domain × leaning)` | Level 2 and up |
| `manifest` | The Domains awake from birth, strongest first | Always |
| `temperaments` | 0–3 traits that change how the person's magic flows | Level 1 and up |
| `growth` | Growth curve: early, steady, late or breakthrough | Level 2 and up |
| `learning` | Mastery gain multiplier for each learning style | The favourite style at level 2; all of them at level 3 |
| `latents` | Hidden potential, unlocked by Awakening Events | **Never** before it's revealed. Level 3 gives vague hints; mythic latents are never hinted at |
| `signature` | The person's personal colours, particle style, motion, timbre and pitch | Always. Everyone can see it |
| `awakenings`, `history` | Which awakenings have happened, how often, and when | The person themselves |

How the profile feeds the magic system: `InnateProfile.toCasterProfile(profile, progression)` builds the `CasterProfile` that MagicCore and Reservoir already use:
- Domain affinities become `affinities`.
- Manifest Domains become `awakened`.
- Branch leanings pull the effective affinity 30% of the way toward the branch's value (`Tuning.affinity.branchBlend`).
- Temperaments and the innate capacity/regen become `traits`, which multiply power, cost, instability, cast time, reservoir size, regen and overdraw risk.

---

## 2. Generation math

Each part of the profile draws from **its own seeded random stream**: `Seed.random(worldSeed, entityId, "profile.<aspect>")`. This matters for tuning: retuning temperaments, for example, never changes anyone's Domains. There is no pity system and no shared state, so every person is an independent draw.

### 2.1 Gift tier

| Tier | Probability | `potential` | How many primary Domains (1 / 2 / 3 / 4) | Mythic multiplier |
|---|---|---|---|---|
| Faint | **30%** | U(0.05, 0.20) | 70 / 25 / 5 / 0 | ×0 |
| Modest | **45%** | U(0.20, 0.45) | 45 / 40 / 13 / 2 | ×0.25 |
| Gifted | **18%** | U(0.45, 0.65) | 30 / 45 / 20 / 5 | ×1 |
| Prodigy | **6%** | U(0.65, 0.85) | 20 / 45 / 28 / 7 | ×4 |
| Paragon | **1%** | U(0.85, 1.00) | 10 / 35 / 40 / 15 | ×20 |

**Players have a floor of Modest** (`playerMinGiftTier`). A player who rolls Faint is moved up to Modest. Their position within the band uses the same random number, so the floor doesn't reshuffle anything else.

**Number of primary Domains overall** (the tiers mixed together):

| Primary Domains | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| Share of people | 47.95% | 36.65% | 13.03% | 2.37% |

So 97.6% of people have 1–3 primary Domains. The average is 1.70.

### 2.2 Which Domains

Primary Domains are picked one at a time, without repeats, using these weights:

| Domain rarity | Domains | Weight each | Chance of being the first pick (each) |
|---|---|---|---|
| Common | Energy, Earth, Water, Air | 1.00 | 17.7% |
| Uncommon | Life, Mind, Spirit | 0.45 | 7.96% |
| Rare | Void, Space | 0.15 | 2.65% |
| Mythic | Time, Gravity, Reality | 0 | never picked here (see §3) |

**Chance a given Domain is manifest from birth**, estimated analytically across all primaries:
- Each Common Domain: **≈ 29%**
- Each Uncommon Domain: **≈ 14%**
- Each Rare Domain: **≈ 4.9%**

Hidden Domain latents add to this later. Their picks use an extra rarity boost (Uncommon ×1.5, Rare ×2.5), because hidden gifts skew rarer.

`context.domainBias[domain]` multiplies these weights. Use it for lineage (a mage's children lean toward the parent's Domains) or birthplace (a volcano town leans toward Energy). The context must be deterministic: either store it with the NPC or derive it from the NPC's spawn data.

### 2.3 Affinity values

- **The k-th primary Domain** gets `max(0.25, potential × rankFactor[k] × U(0.85, 1.15))`, clamped to at most 1. The rank factors are 1.0, 0.8, 0.65 and 0.55.
- **Every other non-mythic Domain** gets a small background value: `0.18 × u³`. That averages 0.045, and only 20.6% of these exceed 0.1. The cube is what makes the distribution heavily skewed toward low values.
- **Thresholds:** an affinity of 0.25 or more is *meaningful* (manifest), and 0.8 or more is *exceptional*.

**Chance of having at least one exceptional Domain:**
- Gifted: impossible, because the maximum is 0.65 × 1.15 = 0.75.
- Prodigy: **28.6%**
- Paragon: **91.6%**
- Overall: **≈ 2.6%** of people.

### 2.4 Everything else

| Aspect | Distribution |
|---|---|
| Branch leaning | U(0.7, 1.3) for each tier-1 branch. One favoured branch per Domain gets ×1.35 on top |
| Capacity | `(0.7 + 0.8·potential) · (1 ± 0.1)`, so Faint ≈ 0.75 and Paragon ≈ 1.45 |
| Regen | U(0.85, 1.15) |
| Number of temperaments (0 / 1 / 2 / 3) | 15% / 50% / 28% / 7%. Picks are weighted (below) and never conflict with each other |
| Growth curve | Early 25%, Steady 45%, Late 20%, Breakthrough 10% |
| Learning styles | One favourite style at ×1.4–1.7, one weak style at ×0.6–0.8, the rest at ×0.9–1.1 |
| Number of non-mythic latents (0 / 1 / 2 / 3) | 35% / 40% / 18% / 7% |
| Latent kind | Domain 40, Amplify 25, Capacity 15, Temperament 20. Each latent gets 2 random trigger categories |
| Latent strength | Domain: raised to U(0.25, 0.6). Amplify: +U(0.08, 0.25). Capacity: +U(0.10, 0.35) |
| Signature | Top Domain's palette with a hue shift of ±0.05 and some saturation/brightness jitter. Secondary colour from the second Domain. Accent is a random hue. Pitch is a triangular distribution over ±7 semitones |

**Temperament weights:** volatile 10, precise 10, swift 9, patient 9, steadfast 8, subtle 7, radiant 7, resonant 6, hollow 6, deepwell 6, conduit 6, brittle 5, bloodbound 3.

| Temperament | Effect |
|---|---|
| Volatile | power ×1.15, instability ×1.35 |
| Precise | power ×0.95, cost ×0.88, instability ×0.75, cast ×1.08 |
| Resonant | allies nearby +8% power; own power ×0.97 |
| Hollow | capacity ×0.6, regen ×1.8 |
| Deepwell | capacity ×1.4, regen ×0.7 |
| Swift | cast ×0.85, instability ×1.08 |
| Patient | cast ×1.15, power ×1.08 |
| Steadfast | overdraw consequences ×0.7, instability ×0.92 |
| Brittle | overdraw consequences ×1.5, capacity ×1.1 |
| Conduit | +15% of cost drawn from the surroundings when using Ambient casting; capacity ×0.9 |
| Bloodbound | Vital casting costs ×0.7 health; regen ×0.9 |
| Subtle | detectability ×0.6, power ×0.97 |
| Radiant | detectability ×1.6, power ×1.05 |

**Growth curves** set the mastery gain multiplier at each mastery level:

| Curve | Mastery 0 | 40 | 50 | 70 | 100 |
|---|---|---|---|---|---|
| Early Bloomer | 1.6 | 1.0 | — | 0.65 | 0.5 |
| Steady | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 |
| Late Bloomer | 0.6 | 0.9 | — | 1.4 | 1.5 |
| Breakthrough (before) | 1.1 | 1.0 | 0.25 | 0.25 | 0.25 |
| Breakthrough (after) | 1.1 | 1.0 | 1.7 | ~1.43 | 1.1 |

A Breakthrough person flips to the "after" curve on any awakening that reveals a latent, or on any Danger, Emotion or Mentor awakening.

---

## 3. Rarity

### 3.1 Mythic potential

```
P(mythic latent | tier) = (1 / 30,000) × tier.mythicMult
P(mythic)               = (1/30,000) × (0.45·0.25 + 0.18·1 + 0.06·4 + 0.01·20)
                        = (1/30,000) × 0.7325
                        ≈ 1 in 40,956 people
```

| | Odds | Notes |
|---|---|---|
| Any mythic | **1 in 40,956** | Players (with the Modest floor): 1 in 37,152 |
| Time (45%) | 1 in 91,013 | |
| Gravity (45%) | 1 in 91,013 | |
| Reality (10%) | **1 in 409,556** | |
| Mythic, by gift tier | Paragon 1 in 1,500 · Prodigy 1 in 7,500 · Gifted 1 in 30,000 · Modest 1 in 120,000 · Faint never | |
| Which tier a mythic person comes from | Modest 15% · Gifted 25% · Prodigy 33% · Paragon 27% | |

A mythic potential is **always a hidden latent**. It is never manifest at birth, and it's revealed only by a matching Mythic awakening event (§4).

**What this means for a world:** a world with about 2,000 persistent NPCs has a 5% chance of containing even one naturally mythic NPC. Mythic NPCs in the story should therefore be *authored*, using `context.forceMythic`. Natural mythic players will appear about once per 37,000 players.

### 3.2 Person rarity tier

`getRarityTier(profile, includeHidden)` checks these rules top to bottom and returns the first match. `includeHidden = true` counts unrevealed latents as if they were already revealed (what the person *could* become). `false` uses only what can be perceived.

| Tier | Rule |
|---|---|
| Mythic | Has any mythic Domain (or, with `includeHidden`, a mythic latent) |
| Legendary | Paragon gift (hidden only), or 2+ exceptional Domains |
| Epic | Prodigy gift (hidden only), or 1 exceptional Domain, or a Rare Domain at 0.6+ |
| Rare | Gifted gift with a top affinity of 0.55+ (hidden only), or a Rare Domain at 0.35+, or 4+ manifest Domains |
| Uncommon | An Uncommon or Rare Domain at 0.35+, or 3+ manifest Domains |
| Common | everything else |

The target true-tier shares are roughly 45 / 30 / 17 / 6 / 1.5 (Common to Legendary). These rules depend on several interacting draws, so the debug script measures the distribution instead of the spec predicting it. The thresholds are in `ProfileTuning.rarity`.

Measured with 1,000 people at seed 1337, before the 0.55 / 0.35 thresholds were added: 30.6 / 35.7 / 26.0 / 6.6 / 1.1. The thresholds exist to pull Rare and Uncommon down toward the targets.

---

## 4. Awakening Events

`InnateProfile.applyAwakening(profile, eventId, { now = os.time(), domain? })` applies an awakening.

**What it does:**
1. It finds every unrevealed latent that meets all of these:
   - its kind is in the event's `reveals` list;
   - one of its trigger categories is the event's category;
   - if it's a Domain or Amplify latent, its Domain is in the event's Domain list (or the event allows any Domain).
2. It reveals the strongest of those, up to `maxReveals`.
3. If nothing was revealed, it gives a small affinity boost (`minorGain`) to a related awakened Domain instead. The boost halves each time the same event repeats.
4. It rolls the event's risk.
5. It records the event, which enforces `once` and the cooldown.

**Randomness and timing:**
- The random numbers come from `Seed(worldSeed, entityId, "awakening:<id>", occurrence)`, so the same history always produces the same outcome.
- `now` must be **Unix time** (`os.time()`), so that cooldowns survive server restarts.

**Who decides an event happened:** the caller detects the trigger on the server. An event can also list `requires`: numeric facts the caller must measure and pass in `context.facts`, each with a min and/or max. `applyAwakening` returns `TRIGGER_NOT_MET` if any fact is missing or out of range. This keeps the conditions in data rather than scattered through combat code. Brush with Death uses it so that ordinary near-misses don't drain everyone's latents.

| # | Event | Category | Trigger | Domains | Can reveal | Risk (chance → result) |
|---|---|---|---|---|---|---|
| 1 | Brush with Death | Danger | HP ≤ 5% from a hostile at least 1.5× stronger; survives 10 s with no healing from others (enforced via `requires`) | any | Domain, Amplify, Temperament | 10% → Brittle |
| 2 | Struck by Lightning | Danger | natural lightning during a storm event | Energy, Air | Domain, Amplify | 25% → Volatile |
| 3 | Pulled from the Deep | Danger | breath runs out underwater for 5 s+, survives | Water, Life | Domain, Amplify | 10% → Hollow |
| 4 | Buried Alive | Danger | trapped under debris for 20 s+ | Earth | Domain, Amplify | — |
| 5 | The Long Fever | Danger | sick for a full in-game day, recovers | Life, Mind | Domain, Temperament | — |
| 6 | Wild Surge Survivor | Danger | survives own backfire at instability > 0.5 | any | Capacity, Temperament | 20% → Brittle |
| 7 | Night at the Nexus | Location | rests a full night at density ≥ 2.5 | any | Capacity, Amplify | — |
| 8 | The Singing Caverns | Location | 5 min in a resonant-crystal cave (once) | Earth, Mind | Domain, Amplify | — |
| 9 | Eye of the Storm | Location | stands in the eye of a tempest event | Air, Energy | Domain, Amplify | — |
| 10 | The Hollow Grove | Location | meditates 3 min in a dead grove (once) | Life, Spirit, Void | Domain, Temperament | 15% → Subtle |
| 11 | The Sunken Shrine | Location | reaches the lake-bottom altar (once) | Water, Spirit | Domain, Amplify | — |
| 12 | The Quiet Place | Location | 10 min at density 0 | Void, Space | Domain | 15% → Hollow |
| 13 | A Mentor's Lesson | Mentor | 3 sessions with a mentor at 60+ mastery | the mentor's Domain | Domain, Amplify | — |
| 14 | Humbled by a Master | Mentor | loses a duel to someone with +30 attunement | any | Temperament, Amplify | — |
| 15 | Teaching Another | Mentor | an apprentice reaches 25 mastery | any | Amplify, Temperament | — |
| 16 | Rite of Attunement | Ritual | paid temple rite (once) | any | Domain | — |
| 17 | Blood Oath | Ritual | swears a Pactcraft pact | Spirit, Life | Temperament, Domain | 35% → Bloodbound |
| 18 | The Seven-Day Vigil | Ritual | 7 in-game days of meditation | Mind, Spirit | Capacity, Amplify (up to 2 at once) | — |
| 19 | Grief | Emotion | someone with a max-tier bond dies | any | Domain, Amplify, Temperament | 15% → Brittle |
| 20 | Righteous Fury | Emotion | saves an ally below 10% HP by defeating the attacker | any | Amplify, Temperament | 20% → Volatile |
| 21 | Bond Forged | Emotion | a relationship reaches its top tier | Life, Mind, Spirit | Temperament, Amplify | — |
| 22 | Sudden Epiphany | Experiment | casts a recipe nobody in the world has cast before | any | Domain, Amplify | — |
| 23 | Alchemical Accident | Experiment | a failed brew explodes within 5 studs | any | Domain, Temperament | 30% → Volatile |
| 24 | Touching a Relic | Experiment | holds an ancient relic for its attunement time | any | Amplify, Capacity | — |
| 25 | The Stopped Clock | **Mythic** | stands in the frozen ruin during an eclipse (once) | **Time** | Mythic | — |
| 26 | Meeting Yourself | **Mythic** | within 20 studs of someone else's Unmooring backlash | **Time** | Mythic | — |
| 27 | Starfall | **Mythic** | within 50 studs of a starfall impact | **Gravity** | Mythic | — |
| 28 | The Long Fall | **Mythic** | falls 1,500+ studs in one drop and survives | **Gravity** | Mythic | — |
| 29 | The Seam | **Mythic** | touches a Seam (a crack in reality) | **Reality** | Mythic | — |
| 30 | Witness to Paradox | **Mythic** | within 30 studs of a Paradox backlash | **Reality** | Mythic | — |

**Risk and reward in practice:**
- **Danger and Emotion** events are the most common route to Domain latents and can change a person's temperament.
- **Location** events have a strong theme (specific Domains) and are mostly one-time.
- **Mentors** are safe and repeatable, but slow.
- **Rituals** are reliable and paid for in money or time.
- **Experiments** are random and risky.
- **Mythic events** reveal nothing for anyone without a matching latent. For them, the event is an eerie moment with no effect, and it still goes on cooldown.
- **A risk can override a temperament.** If a risk adds a temperament that conflicts with one the person has, the old one is replaced; the person is changed by the experience.

---

## 5. What people know (`getVisibleProfile`)

| Level | Name | Sees |
|---|---|---|
| 0 | Untrained | Their manifest Domains (names only) and their signature |
| 1 | Aware | Strength bands (Faint / Moderate / Strong / Formidable / Exceptional) and temperaments |
| 2 | Studied | Affinities to the nearest 0.05, faint stirrings in unawakened Domains (≥ 0.1), branch leanings, growth curve, favourite learning style, reservoir band, and a *visible* rarity tier |
| 3 | Introspective | Exact values (0.01) for all non-mythic Domains, exact capacity and regen, the full learning table, and one vague hint per hidden non-mythic latent (its trigger category, e.g. "Danger") |

**Mythic Domains are never shown until they're revealed**, not even as a hint. A mythic-latent person's visible rarity tier never says Mythic.

The same function handles observers. An NPC scholar who examines someone uses a knowledge level based on the scholar's own skill. **The client never chooses its knowledge level.** The server decides it and sends only the result.

---

## 6. Mythic magic

All three mythic Domains share these rules:
- They never appear in the normal tree UI unless the Domain is awakened.
- Their spells already pay rarity costs of ×1.6–1.8 and carry volatility of 1.4–1.7, with brutal overdraw risks: Unmooring, Crush and Unraveling (mutation ×2–3).
- Their runtime effects must go through **server-owned systems with hard budgets**, described below. These are design commitments for the effect resolver, which comes next.

### 6.1 Time

The runtime is built: see `docs/Time.md`. On the owner's decision (2026-11-06, "don't hold back"), it goes past some limits below: Self Timeline restores everything for up to 45 s, not 3 s, and restores health and reservoir, and it can save you from death at Grandmaster.

| Mastery | Effects (branch) |
|---|---|
| Early | Slow one target to 0.8× speed for 3 s; sense where an object was 5 s ago (chronokinesis, causality) |
| Mid | Haste of up to 1.35× on yourself or 1.5× on others; 3 s of stasis on an object (hastening, stasis) |
| High | Rewind a small object up to 5 s; precognition shows enemy telegraphs 0.5 s early (rewind, precognition) |
| Pinnacle | **Unhappening** (a ritual): undo one *physical* event from the last 30 s, i.e. a destroyed structure or an NPC's death. Once per in-game day per server |

**Guardrails:**
- **The server tick never changes.** "Slow" means scaling each affected entity: WalkSpeed, animation speed, projectile speed and cooldown rate. The scale never goes below 0.25×.
- **The rewind buffer is lazy and bounded.** Snapshots (position, velocity, HP) are recorded only while a Time caster is within 100 studs: 5 s at 5 Hz, for at most 30 entities per caster.
- **Rewinds are physical only.** They never touch inventory, currency, quest flags, kill credit or anything that reaches a DataStore. A rewound player's damage dealt is *not* undone; this asymmetry stops duplication exploits.
- **Self-rewind** covers at most 3 s, with a cooldown of at least 120 s.
- **Stasis** on players lasts at most 3 s, with diminishing returns: each repeat within 15 s halves the duration. A target in stasis is invulnerable *and* inert.
- **Haste** doesn't stack. The highest active haste applies.

**Discovery:**
- The Stopped Clock, a ruin seen only during eclipse world events.
- Meeting Yourself, which needs another Time mage's backlash nearby, so Time spreads socially.

### 6.2 Gravity

The runtime is built: see `docs/Gravity.md`. On the owner's decision (2026-11-06, "don't hold back"), it goes past some limits below: a grip can kill and players can be anchored by the server.

| Mastery | Effects |
|---|---|
| Early | Make an object up to 30% heavier or lighter; brief feather-fall on yourself |
| Mid | Levitation; pinning a target with weight ×2; a crushing field that deals capped damage over time |
| High | Up to 6 orbiting objects; inverting gravity locally (dropping enemies "up" for 2 s) |
| Pinnacle | **Vectoring an area**: change which way is "down" within 60 studs for 30 s, as a ritual |

**Guardrails:**
- **Never touch `Workspace.Gravity`**, because it's global. Local gravity is a VectorForce on each assembly inside a zone.
- **Assembly budget:** at most 40 unanchored assemblies per gravity zone and 120 per server. Anchored parts are never moved; Collapse rituals use only pre-fractured debris parts.
- **Character "down" changes** use a client-side character controller that the server validates (plausible position and velocity). Velocities are capped at 150 studs/s.
- **Orbitals** must be network-owned by the server.
- **Damage limits:** crushing damage per second is capped, so it can't one-shot anyone. Fall damage caused by gravity magic counts as the caster's damage, under PvP rules.

**Discovery:**
- Starfall, a rare world event that happens a few times per server-week.
- The Long Fall, surviving a 1,500-stud drop. This can be found by accident or deliberately sought.

### 6.3 Reality (the rarest)

Reality magic uses its own resource, **Convergence**:
- **Pool size:** `10 + 30 × reality affinity`, so 10–40.
- **Regeneration:** 1 point per 20 real minutes, or ×2 while standing at a Seam. It is **never** refilled by potions, ambient density or the reservoir.
- **Cost per cast:** `ceil(P^1.5 / 2)`, so P1 costs 1, P5 costs 6 and P10 costs 16. This is paid in addition to the normal reservoir cost.

| Mastery | Effects |
|---|---|
| Early | Small *rule edits* on one object for a few seconds: a rock briefly soft, a door briefly not there, a coin landing heads |
| Mid | Conjuring simple matter for 30 s; temporary polymorph of objects; fatebending (forcing one roll) |
| High | Edicts: a local rule in a 20-stud area for 20 s ("fire does not burn here", "nothing falls") |
| Pinnacle | **Worldlaw** (a ritual): a regional law, lasting at most an in-game week, that can only be kept in place (anchored) at extreme cost |

**Paradox** builds up with every edit:

`paradox += magnitude × duration_s × (1 + 0.25 × observers) / 100`

It decays by 1 per minute. Being watched increases Paradox, which discourages griefing in crowds.

| Paradox | What the world does |
|---|---|
| ≥ 25 | A **Seam** opens nearby: a visible crack in reality, and an awakening site for others |
| ≥ 50 | **Unraveling backlash**: a random rule edit hits the caster (temperament swap, displacement, or a mutation roll ×3) |
| ≥ 100 | **Correction**: every one of the caster's active edits reverts at once, and Reality magic is locked for one real hour |

**Pushback:**
- Every edit lasts for its spell duration and then reverts.
- **Anchoring** an edit (keeping it past its duration) costs 10× the Convergence and needs a Ritual at maximum power.
- Anchored edits decay after one in-game week.
- A server can hold at most 3 anchored edits at once.

**Guardrails: the Edit Ledger.** Every edit goes through one server-side ledger that records the instance, the property, the old value and the expiry time.
- **Allowed properties:** only Transparency, CanCollide, Material, Color, Size (within ±50%), Anchored and CustomPhysicalProperties. Never Destroy or Parent changes.
- **Protected things are immune:** anything tagged `Protected` through CollectionService (spawns, quest objects, other players' builds), players' character root parts, and anything tied to the economy or inventory.
- **Limits:** 1–5 active edits per caster depending on power, 40 per server, and a rate limit.
- **Guaranteed revert:** everything reverts on expiry, when the caster leaves, and in `BindToClose`, so no edit outlives the server unless it's an anchored edit stored in world state.

**Discovery:**
- The Seam, which is mostly created by Paradox elsewhere, so Reality spreads from Reality.
- Witness to Paradox, at 1 in ~410,000 with a latent. Most worlds will never see a natural Reality mage.

### 6.4 How the world reacts

Each mythic caster has a **Notoriety** score for each mythic Domain:
- It goes up when the caster casts mythic magic where others can see it: `+ power × detectability × witnesses`. Subtle (×0.6) and Radiant (×1.6) temperaments matter here.
- It decays slowly.
- NPCs react according to their faction and personality.

| Notoriety | Reaction |
|---|---|
| 0–20 | Rumours in NPC dialogue |
| 20–50 | Scholars seek the caster out; superstitious NPCs avoid them; prices change |
| 50–80 | **Faction contact**: offers of recruitment or threats |
| 80+ | Pilgrims and worshippers, *or* hunters and bounties, depending on region and faction |

| Domain | Seekers / worshippers | Hunters | Common folk |
|---|---|---|---|
| Time | *The Horologe*, a secret order that recruits chronomancers or quietly "corrects" them | *Clockbreakers* | Ill omen; fear |
| Gravity | *Cult of the Fallen Star*, who worship the caster | Nobles' retainers, who fear for their castles | Awe; miners' guilds want to hire them |
| Reality | *The Unwritten*, who trade forbidden knowledge | *The Continuity*, who kill on sight above 80 Notoriety | Split between dread and worship by personality |

---

## 7. Saving

The profile **is** the save shape: plain, JSON-safe data. Colours are stored as hex strings because a Color3 can't be written to a DataStore.

```lua
{
  v = 1, gen = 1,                       -- save schema version; generator version that produced it
  worldSeed = 1337, entityId = "player:12345", kind = "Player",
  giftTier = "Gifted", potential = 0.52, capacity = 1.13, regen = 0.97,
  domains = { energy = 0.48, earth = 0.031, ... },   -- all 12 Domains
  leanings = { thermal = 1.21, luminous = 0.83, ... },
  manifest = { "energy", "water" },
  temperaments = { "swift" },
  growth = "late", breakthrough = false,
  learning = { study = 1.02, combat = 1.55, teaching = 0.71, meditation = 0.94, experimentation = 1.08 },
  latents = { { id = "L1", kind = "Domain", target = "spirit", strength = 0.41, triggers = { "Emotion", "Ritual" }, revealed = false } },
  signature = { primary = "ff8a2b", secondary = "2f7fe0", accent = "c95cff", particle = "embers", motion = "darting", timbre = "warm", pitch = -2 },
  awakenings = { nearDeath = { count = 1, lastAt = 1793600000 } },
  history = { { e = "nearDeath", t = 1793600000 } },   -- capped at 50 entries
}
```

A full profile is about 2–3 KB.

**Storage strategy:**
- **Players:** store the full profile as one field of their session-locked player document. A snapshot is immune to future generator changes.
- **Named NPCs:** snapshot the profile in world state the first time it matters (a relationship, an awakening, a quest).
- **Generic NPCs:** never save them. Regenerate from `(worldSeed, npcId, context)` with the current generator. Nobody has met them yet, so a generator change can't break continuity.

**Versioning and migration:**
- `deserialize` runs the save migrations (`MIGRATIONS[n]`) and resolves renamed ids through Aliases.
- Domains added after a save was written get an affinity of 0.
- Corrupt data returns `nil, reason`. The caller may regenerate from the seed, but that loses the person's earned awakenings, so it must be logged.
- `gen` records which generator version produced the profile. Bump `GENERATOR_VERSION` whenever a change to tuning or code would alter the output for an existing seed.

Computed values are never saved. Traits, CasterProfile and visible views are always rebuilt from the profile plus progression.
