# Progression: Learning and Mastering Magic (v1)

There are no classes and no character level. You get better at a **branch** by *doing* and *studying* within it. Each branch has its own mastery, and that mastery visibly changes what your magic can do and how it looks.

Code lives in three places:
- **Server rules:** `src/server/Progression/` (Progression, SubBranchRules, Breakthroughs, ProgressionTuning).
- **Server services:** ProgressionService, SpecializationService, DiscoveryLog.
- **Shared data:** `src/shared/Magic/Data/` (MasteryTiers, Specializations, Techniques, EnvironmentRules).

---

## 1. Mastery tiers

Two numbers describe your progress in a branch:
- **XP** is what's saved. It's the source of truth.
- **Mastery** (0–100) is derived from XP, and it's what the spell system reads.

The formulas:

```
xpForMastery(m) = 2.3 · m^2.56          masteryForXp(xp) = (xp / 2.3)^(1/2.56)
```

| # | Tier | Mastery | Power ceiling | Newly usable verbs | Newly usable forms | Breakthrough? | How it looks |
|---|---|---|---|---|---|---|---|
| 0 | Untouched | 0 | — | — | — | | — |
| 1 | **Sensing** | 1 | 1 | Sense, Generate | Touch, Aura | | a faint flicker |
| 2 | **Novice** | 10 | 3 | Amplify, Reduce | Projectile, Burst | | a steady glow; slightly unstable particles |
| 3 | **Adept** | 25 | 5 | Transfer, Redirect, Store, Release | Beam, Wall, Pillar, Chain | | clean shapes; your signature colours become recognisable |
| 4 | **Skilled** | 40 | 6 | Transmute, Bind | Zone | | your signature particle style and sound appear. *Specialization oaths open* |
| 5 | **Expert** | 55 | 7 | | Summon | **yes** | residual sparks; your aura is visible to sensitives |
| 6 | **Master** | 70 | 8 | | Ritual | **yes** | the environment answers: dust lifts, water ripples. *You can mentor unlocks* |
| 7 | **Grandmaster** | 85 | 10 | | | **yes** | your palette saturates the area; an ambient effect follows you |
| 8 | **Transcendent** | 100 | 10 | | | **yes (rare)** | magic bends toward you; **no overreach instability** |

**What limits a spell's power** is the lowest of three values: the branch's own maximum, the tier ceiling above, and the comfort curve plus 2. Below that limit, mastery also keeps lowering cost (down to −45%), cast time (−35%) and instability (−50%). Each tier's `vfxScale` (0.2 → 1.35) tells the effects system how strongly your magic shows.

**Any branch you've unlocked counts as at least Sensing.** Every domain you were born with is unlocked from your first day.

### XP curve

The hours column assumes about 2,500 XP per hour of focused play. That's an estimate; the journey sim (§8) measures it properly.

| Mastery | Total XP | ≈ Focused hours |
|---|---|---|
| 1 (Sensing) | 2 | — |
| 5 | 142 | 0.1 |
| 10 (Novice) | 835 | 0.3 |
| 15 | 2,360 | 1 |
| 20 | 4,930 | 2 |
| 25 (Adept) | 8,720 | 3.5 |
| 30 | 13,900 | 5.5 |
| 40 (Skilled) | 29,000 | 12 |
| 50 | 51,400 | 21 |
| 55 (Expert) | 65,600 | 26 |
| 60 | 82,000 | 33 |
| 70 (Master) | 121,600 | 49 |
| 80 | 171,400 | 69 |
| 85 (Grandmaster) | 200,000 | 80 |
| 90 | 231,600 | 93 |
| 100 (Transcendent) | 303,200 | 121 |

**Parent branches grow alongside.** Every gain trickles upward: 40% of it to the parent, 16% to the grandparent, and so on. A hybrid branch's root passes 30% to each of its two prerequisite branches. So the deeper you focus, the faster your foundations grow too.

### Breakthroughs: you can't just grind

Entering **Expert, Master, Grandmaster and Transcendent** requires *doing* specific things on top of earning the XP. Until you've done them:
- Your mastery holds just below the tier (e.g. at 54.99).
- XP keeps banking, up to the next tier's threshold.
- Completing the breakthrough releases all the banked XP at once, so you jump forward.

| Into | Default requirements | Domain-specific examples |
|---|---|---|
| Expert | Invent 2 recipes in the branch; cast a power-5 spell in it | — |
| Master | Study 1 insight site; bring a student to Novice; cast power 6 *under real danger* | **Earth:** study a real fault zone, teach a student, **survive a collapse you caused**. **Water:** study the ocean trench, teach, survive your own undertow. **Energy:** study a volcanic vent, teach, survive your own fire |
| Grandmaster | 2 insight sites; 5 inventions; 3 students; power 8 under real danger | — |
| Transcendent | Declare a signature spell; power 10 under danger; 5 students; studied under a Grandmaster | — |

Requirements are data: `Breakthroughs.luau` holds the defaults, and a domain entry replaces them for that domain. They check facts recorded by the server, such as insights, survivals, students taught, feats, inventions and mentors.

---

## 2. Experience channels

**Every channel is triggered by something the server observed.** No remote carries XP.

| Channel | Base amount | Learning style | Limits |
|---|---|---|---|
| **Practice** | `1.2 × reservoirCost^0.6` per cast (effort-weighted: bigger spells teach more, but regeneration limits how often you can cast them) | — | repetition decay, relevance, effect, AFK, macro check, hourly soft cap (§6) |
| **Challenge** | practice × **1.75** when casting under real danger (a stronger enemy, a hazard, or while overdrawn) | combat | same as practice |
| **Study** | scroll 120 · book 300 · lecture 450 · mentor 650 × (mentor tier − your tier) | study | each book/scroll once per branch; lectures and mentors every 20 h; a mentor must be ahead of you |
| **Experimentation** | your first cast of a recipe: 40 + 25×power; world-first: **1,500** | experimentation | power ≥ 2 and a real effect; 2,500 per day |
| **Observation** | watching a better caster nearby: 4 × tier gap × their power; studying an insight site: 600 (once) | meditation | 60 s per caster; 1,500 per day; nothing while AFK |
| **Teaching** | 30% of what your student learns from you | teaching | you must be Adept and ≥ 2 tiers ahead; 2,500 per day. Bringing a student to Novice counts toward breakthroughs |

**Final XP** = base × channel weight × learning style (0.6–1.7, innate) × growth curve (innate; varies by mastery) × focus × breadth × specialization × anti-grind factors, capped by the daily limit.

### Focus vs breadth

- **Focus bonus:** `× (1 + 0.5 × share²)`.
  - `share` is this domain's share of your *recent* XP. "Recent" uses a 48-hour half-life, so old play gradually stops counting.
  - Fully focused players get ×1.5. A player split across four domains gets ×1.03.
  - Because the share is squared, the bonus rewards *real* focus, not a token majority.
- **Breadth penalty:** `× max(0.5, 1 − 0.10 × (activeLines − 3))`.
  - A *line* is a top-level branch (Thermal, Geomancy, Tidal Arts are each in a different line), counted once you're Adept somewhere in it.
  - Three lines are free; each extra line costs 10% on *all* XP, down to a floor of ×0.5.
- **Generalists still get something.** Your reservoir size comes from the *sum* of all your mastery, so wide players get bigger reservoirs: more sustained casting and more utility, but less depth.

---

## 3. Unlocking branches

Every non-root branch needs a mix of conditions. All of them are data (`SubBranchRules.luau`):

| Depth | Parent tier | Affinity (innate) | Knowledge item | Catalyst |
|---|---|---|---|---|
| 1 (e.g. Geomancy) | Novice | ≥ 0.10 | — | — |
| 2 (e.g. Metallurgy) | Adept | ≥ 0.20 | `primer:<branch>` | per branch |
| 3 (e.g. Cataclysm) | Skilled | ≥ 0.30 | `treatise:<branch>` | per branch |
| Hybrid root | both prerequisites | ≥ 0.20 (geometric mean) | `codex:<hybrid>` | per hybrid |
| Mythic sub-branches | as above | as above | `fragment:<branch>` (rare) | — |

### Worked example: Earth → Geomancy → **Metallurgy**

1. **Parent:** reach **Adept in Geomancy** (mastery 25).
2. **Affinity:** Earth affinity × your innate leaning toward Geomancy must be **≥ 0.25**. Someone with almost no Earth talent can't become a smith.
3. **Knowledge**, from any one of:
   - `primer:metallurgy`: an apprentice smith NPC's primer;
   - `tome:iron_and_flame`: a book in the dwarven library;
   - `mentor:metallurgy`: a lesson from a Master metallurgist.
4. **Catalysts:** *both* `exposure:ore` (handle raw ore) **and** `exposure:heat` (stand near a forge or lava). You need to have physically worked metal.

When every condition is met, `UnlockBranch` opens Metallurgy at Sensing. Until then, the client sees each condition as a ✓/✗ hint, and the specific missing knowledge item or catalyst is named. It's only revealed as a hint once its branch appears as a candidate.

Other catalyst examples:
- Crystallurgy: a geode, or the Singing Caverns.
- Cataclysm: a real fault zone.
- Tsunamancy: the ocean trench.
- Conflagration: a wildfire or a volcanic vent.
- Necromancy: a grave.
- **Stormcalling**: survive *Struck by Lightning* or stand in the *Eye of the Storm*.

### Hybrid branches

A hybrid needs both prerequisite branches (from the branch data; e.g. Stormcalling needs **Electromancy 40 and Aeromancy 40**), plus combined affinity, a codex, and usually a catalyst. Practising the hybrid feeds 30% back into each parent branch, so hybrid specialists don't fall behind in their roots.

---

## 4. Specialization commitments

These are optional oaths. Each boosts one branch and everything beneath it, and weakens the opposing branches:

| Boosted (with descendants) | Weakened (with descendants) |
|---|---|
| power ×1.2 · cost ×0.85 · XP ×1.25 | power ×0.8 · cost ×1.2 · XP ×0.6 |

There are 14 oaths in `Specializations.luau`. For example:
- **Forgeheart** (Metallurgy) weakens Sandshaping (erosion).
- **Oath of the Pyre** ↔ **Vow of Stillfrost**.
- **Warden** ↔ **Hexbound**.
- **Nullbound** weakens *all* Spirit magic.

**Rules:**
- You need 40 mastery in the oath's branch.
- How many oaths you can hold depends on your best tier anywhere: 1 at Skilled, 2 at Master, 3 at Grandmaster.
- Two oaths that oppose each other can't both be held.

**Undoing an oath** requires the *Rite of Unbinding*, a rare knowledge item that is consumed. It costs **35% of the XP** in the oath's whole branch, and you can't take a new oath for **30 days**.

The effects run through `CasterProfile.branchMods`: MagicCore applies the power and cost changes, and Progression applies the XP changes.

---

## 5. Discovery and paradigm shifts

- **Personal discovery:** the first time *you* successfully cast a recipe at power ≥ 2. This grants Experimentation XP and counts toward the "inventions" breakthrough requirements.
- **World-first:** the first time *anyone in the world* casts it.
  - The claim is made atomically in the `Discoveries` DataStore, keyed by a 64-bit hash of the recipe, so two servers can never both win.
  - It grants 1,500 XP, a chronicle entry, and a chance of an *Epiphany* awakening.
- **Paradigm shift (signature spell):** a world-first recipe of yours that you have **named**, **cast 50+ times**, and reached **Expert** in can be declared your **signature**. You can have at most 3.
  - When you cast it, it's ×1.1 power and ×0.9 cost.
  - Its filtered name is announced to the world.
  - It's required for Transcendence.

---

## 6. Anti-exploit

| Threat | Defence |
|---|---|
| **Spoofed XP from the client** | No remote carries XP, mastery, feats or "I did X" claims. Every award comes from a server-observed event: cast resolution, a study interaction, proximity to an insight site, server-side combat state. The save schema rejects writes with out-of-range XP or mastery |
| **AFK grinding** | Practice and observation pay **0** if you haven't moved 4+ studs or turned your aim 10°+ in 120 s (sampled by the server every 5 s, plus the aim updates). Casts that hit nothing and change nothing pay ×0.25. Study needs new sources and mentors have cooldowns |
| **Spell-spam grinding** | Repetition decay: `exp(−repeats/12)` per recipe, with repeats halving every 10 min (floor ×0.05). Relevance: casting far below your comfort power pays as little as ×0.2. A per-branch soft cap of 2,500 practice XP per hour, ×0.25 beyond it. And practice XP is cost-weighted, so your reservoir's regeneration caps the sustainable rate |
| **Macros and auto-clickers** | Over the last 20 casts, a timing variation below 3% (machine-regular) halves XP and logs a throttled warning for moderators |
| **Discovery farming** | Discoveries need power ≥ 2 and a real effect; 2,500 per day; each recipe counts once per player; world-firsts are atomic and global |
| **Teaching/observation collusion** (alt accounts) | Teachers must be ≥ 2 tiers ahead and earn only 30% of what the student gains *from them*; a daily cap. Observation is capped per caster and per day, and pays nothing while AFK |
| **Breakthrough skipping** | Requirements check server-recorded facts; they can never be set from the client |

---

## 7. Skill ladders (data: `Techniques.luau`)

Every rung is an ordinary recipe, and a unit spec checks each one is castable at its tier. **Environment** names what the server must measure near the cast (`CastContext.environment`). Big workings get weaker below what they need (power × √ratio), and below a hard floor they're blocked outright.

| Energy | Tier | Recipe |
|---|---|---|
| Glow Mote: spark a tiny glow | Sensing | Raw Energy · luminosity · Generate · Touch · P1 |
| Lantern: a light source | Novice | Raw Energy · luminosity · Generate · Aura · P2 |
| Searing Beam: a focused beam | Adept | Luminous · luminosity · Generate · Beam · P3 |
| Warmth Draw: heat transfer | Adept | Thermal · temperature · Transfer · Touch · P3 |
| Hearthflame: controlled flame | Skilled | Pyromancy · combustion · Generate · Pillar · P5 +channeled |
| Sustained Inferno | Master | Conflagration · combustion · Generate · Zone · P8 +channeled +lingering · *fuel* |
| Firestorm | Grandmaster | Conflagration · Ritual · P10 · *fuel* |

| Earth | Tier | Recipe |
|---|---|---|
| Pebble Nudge | Sensing | Raw Earth · contour · Generate · Touch · P1 |
| Shape Stone | Novice | Geomancy · contour · Generate · Touch · P2 |
| Ore Sense: metal sensing | Adept | Metallurgy · purity · Sense · Aura · P3 |
| Forge Hand: forging | Skilled | Alloycraft · purity · Transmute · Touch · P4 |
| Magnetic Grip: magnetic control | Expert | Ferromancy · magnetism · Redirect · Projectile · P5 |
| Tremor | Skilled | Seismic · seismicity · Generate · Burst · P4 |
| Localized Quake | Master | Faultwork · seismicity · Generate · Zone · P7 · *groundMass, seismicStress* |
| **Cataclysm: region-scale** | Grandmaster | Cataclysm · Ritual · P10 · *groundMass ≥ ~0.51 (0.3 × 1.08⁷), seismicStress ≥ ~0.37 (0.12 × 1.25⁵)*. Ritual cooldown ~4.7 min, reservoir + ambient cost ~2,400 |

| Water | Tier | Recipe |
|---|---|---|
| Dew Sense: moisture sensing | Sensing | Raw Water · humidity · Sense · Aura · P1 |
| Pour: pouring and guiding | Novice | Raw Water · flow · Generate · Touch · P2 |
| Ice Wall: ice shaping | Adept | Glaciation · temperature · Reduce · Wall · P3 |
| Currents | Skilled | Hydromancy · flow · Redirect · Beam · P4 · *waterVolume* |
| Swell | Expert | Tidal · flow · Redirect · Wall · P6 · *waterVolume* |
| **Tsunami** | Grandmaster | Tsunamancy · Redirect · Ritual · P10 · *waterVolume ≥ ~112,000 studs³* (4,000 × 2.3⁴; blocked below 30% of that, ~34,000). An ocean, not a pond |

**Seismic stress** builds up over time on the world's fault map and is spent by quakes, so one region can't be shaken twice in a row. Recording and applying that is part of WorldGen, which comes next.

---

## 8. Player journeys (30 hours)

The narratives below are the **design intent**. `Tests/JourneySim` runs the same three player types through the real code and prints measured snapshots at hours 1, 3, 5, 10, 15, 20, 25 and 30. Tune until they match.

**Fire-focused** (Gifted, Energy 0.7, one domain, all-in):
- **Hours 0–1:** Sensing → Novice in Raw Energy (Glow Mote, Lantern); Thermal unlocks.
- **Hours 1–5:** works Thermal to Adept (*Warmth Draw*). Its trickle lifts Energy too. A primer opens Pyromancy.
- **Hours 5–15:**
  - Pyromancy Novice → Adept → Skilled; *Hearthflame* at Skilled.
  - Takes the **Oath of the Pyre**: ×1.25 XP and ×1.2 power, at the cost of frost magic.
  - Focus bonus is a steady ×1.5, with no breadth penalty.
- **Hours 15–30:**
  - Pyromancy hits the Expert wall at 54.99. XP banks while they invent two fire recipes and land a power-5 cast, then the breakthrough releases it.
  - A wildfire catalyst plus a treatise unlock Conflagration.
  - **At 30 h:** Pyromancy Expert (power ceiling 7). Thermal is Skilled and Energy Adept, both pushed by trickle. Narrow but deep: the strongest single-element caster of the three.

**Generalist** (Gifted, Energy, Earth, Water and Air at 0.45 each):
- **Hours 0–5:** Novice in four roots almost immediately, and a pile of Sensing/Novice utility spells (light, pebbles, dew, breezes).
- **Hours 5–15:**
  - Adept in 5–6 lines.
  - Breadth penalty ×0.8 → ×0.7, and the focus bonus is almost nothing (~×1.03).
  - Their reservoir grows fastest (high total mastery), so they can cast for longer.
- **Hours 15–30:**
  - Progress slows to a crawl.
  - **At 30 h:** around Adept in many lines, Skilled in perhaps one, nothing past the Expert wall.
  - Hybrids (Stormcalling needs 40 in both parents) are just coming into reach. That's the generalist's long-term payoff: hybrid magic the specialists can't touch.

**Mythic gravity** (Earth 0.4, a hidden Gravity latent at 0.6):
- **Hours 0–6:** a modest Earth mage, Novice → Adept in Geomancy.
- **Hour 6:** *Starfall* reveals Gravity, the start of a 1-in-91,000 life. Gravity's root is at Sensing.
- **Hours 6–20:**
  - Gravity spells are ×1.6 cost, but practice XP is cost-weighted. They cast less often and learn about as fast per hour.
  - Sub-branches need rare `fragment:` knowledge, which is the true gate.
  - *Weightcraft* (feather-falling, heavier blows) by about hour 12; *Attraction* later.
- **Hours 20–30:**
  - Around Adept in Gravity's lines, so a power ceiling of 5, but every effect is something no one else can do.
  - Notoriety rises with each visible cast: scholars seek them out, and the Cult of the Fallen Star takes notice.
  - **Weaker raw output than the fire specialist, with far stranger tools and far more attention.**

---

## 9. Tunable config

| Knob | Where | Default | Effect |
|---|---|---|---|
| `xpScale`, `xpExponent` | MasteryTiers | 2.3, 2.56 | overall length; the exponent sets how much steeper the late game is |
| tier `minMastery`, `powerCeiling` | MasteryTiers | §1 table | where gates sit |
| `practice.base`, `costExponent` | ProgressionTuning | 1.2, 0.6 | XP per cast |
| `practice.repeatScale`, `repeatHalfLife` | ProgressionTuning | 12, 600 s | how quickly spam stops paying |
| `practice.hourlySoftCap`, `hourlyOverflow` | ProgressionTuning | 2,500, ×0.25 | grind ceiling per branch per hour |
| `practice.idleSeconds` | ProgressionTuning | 120 | AFK threshold |
| `channels.*.weight`, `dailyCap` | ProgressionTuning | §2 | balance between channels |
| `study.*.xp`, `cooldownHours` | ProgressionTuning | §2 | how valuable books and mentors are |
| `experimentation.worldFirst` | ProgressionTuning | 1,500 | reward for invention |
| `focus.maxBonus`, `halfLifeSeconds` | ProgressionTuning | 0.5, 48 h | reward for focus, and how fast it forgets |
| `breadth.freeLines`, `penaltyPerLine`, `floor` | ProgressionTuning | 3, 0.10, 0.5 | cost of spreading thin |
| `lineage.trickle`, `hybridTrickle` | ProgressionTuning | 0.4, 0.3 | how much depth feeds the foundations |
| `specialization.*` | ProgressionTuning + Specializations | ×1.2/×0.8 etc. | oath strength, renounce cost, cooldown |
| `signature.*` | ProgressionTuning, Tuning | 50 casts, Expert, max 3; ×1.1/×0.9 | paradigm shifts |
| Breakthrough requirements | Breakthroughs | §1 | what "craft" means per domain |
| Unlock conditions | SubBranchRules | §3 | how branches open |
| Environment `base`, `growth`, `hardFraction` | EnvironmentRules | §7 | how much world big magic needs |

**Saves survive retuning.** Saves store XP, so changing the curve or a tier threshold never corrupts data: mastery is recomputed on every join. Breakthroughs that were already earned are kept.
