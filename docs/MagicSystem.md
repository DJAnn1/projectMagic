# Magic System: Core Grammar Spec (v1)

Every spell is a **recipe** assembled from reusable parts. Nothing is hand-authored as "Fireball".

```
Recipe = { Branch, Property, Verb, Form, Modifiers[], PowerLevel, CostProfile }

Fireball = Thermal/Pyromancy · Combustion · Generate · Projectile · [] · P4 · Reservoir
```

The source of truth is the data under `src/shared/Magic/Data/`. If this doc and the data disagree, the data is right.

---

## 1. Layer 1: Domains

The game has twelve Domains, and each has a root branch with the same id. Rarity sets two things: how often a person is born with an affinity for the Domain (the odds are server-side in `ProfileTuning`; see [InnateProfiles.md](InnateProfiles.md)), and a cost tax on its spells (`costMult`).

| Domain | Rarity | Core concept | Properties | Synergy | Opposition | Volatility | Overdraw risk |
|---|---|---|---|---|---|---|---|
| **Energy** | Common | Force in motion | temperature, luminosity, momentum, charge, radiation, combustion, shadow | Air, Earth | Water, Void | 1.20 | **Scorched Channels**: long burnout |
| **Earth** | Common | The solid world | hardness, density, cohesion, contour, magnetism, resonance, seismicity, purity | Life, Water, Gravity | Air, Space | 0.85 | **Ossification**: slowed, long lockout |
| **Water** | Common | Flow and freeze | humidity, viscosity, pressure, temperature, flow, phase, buoyancy, purity | Life, Air, Mind | Energy | 1.00 | **Saturation**: heavy backlash |
| **Air** | Common | Sky, sound, weather | pressure, flow, sound, humidity, charge, breath, temperature, buoyancy | Energy, Water | Earth, Gravity | 1.05 | **Breathlessness**: stamina collapse |
| **Life** | Uncommon | Living and dying | vitality, growth, decay, toxin, instinct, metabolism | Earth, Water, Spirit | Void, Time | 0.95 | **Withering**: max-HP loss |
| **Mind** | Uncommon | Inner world | perception, emotion, memory, illusion, thought, will | Space, Spirit, Water | Void | 1.10 | **Fracture**: hallucinations |
| **Spirit** | Uncommon | Souls and bonds | soul, warding, malediction, bond, essence, unlife, will | Mind, Life, Earth | Void | 1.10 | **Haunting**: attracts hostiles |
| **Void** | Rare | Negation | aether, sound, luminosity, momentum, essence, presence, charge, temperature | Space, Gravity | Energy, Spirit, Life, Mind, Reality | 1.15 | **Hollowing**: capacity shrinks |
| **Space** | Rare | Where things are | distance, position, volume, boundary, orientation, presence | Mind, Void, Gravity | Earth | 1.25 | **Dislocation**: random teleport |
| **Time** | Mythic | Tempo and causality | tempo, age, persistence, sequence, foresight, decay | Space, Reality | Life, Void | 1.50 | **Unmooring**: aging, desync |
| **Gravity** | Mythic | Weight and down | weight, orientation, density, momentum, buoyancy, cohesion | Earth, Space, Void | Air | 1.40 | **Crush**: heavy backlash |
| **Reality** | Mythic | Existence and law | probability, substance, persistence, sequence, law, identity | Time, Mind | Void | 1.70 | **Unraveling**: mutation ×3 |

**How each Domain looks and sounds.** Full palettes live in the data.

| Domain | Palette | Sound | Particles |
|---|---|---|---|
| Energy | orange / gold / electric blue | crackle, hum, snaps | fast additive sparks, embers, shimmer |
| Earth | umber / slate / jade | grinding, thuds, chimes | chunky lit debris, dust, heavy motion |
| Water | deep blue / ice / foam | rushing, groans, cracking ice | fluid trails, mist, refraction |
| Air | pale sky / white | whistle, whoosh, muffled vacuum | translucent streaks, swirling debris |
| Life | leaf / pollen / rot-brown | breath, heartbeat, rustle | petals, motes, sickly spores |
| Mind | violet / pink / indigo | whispers, reversed tones | client-side screen ripples, afterimages |
| Spirit | spectral cyan / ivory / ghost-green | choir, bells | wisps, sigils, slow fades |
| Void | near-black / bruise purple | sound drops out, sub-bass | inward particles, desaturation |
| Space | indigo / starlight | phase shifts, doppler | star-speckled tears, warped geometry |
| Time | brass / sepia / teal | ticking, reversed audio | clockwork glyphs, frozen particles |
| Gravity | dark violet / black | low hum, creaks | orbiting debris, lensing |
| Reality | white / magenta / cyan | glitch stutter | chromatic aberration, fragments |

**Opposition (future use).** Opposition doesn't change cost today. It's reserved for the spell-interaction resolver: water douses fire, and void dispels spirit.

---

## 2. Layer 2: Branch tree

- **Tier** is the node's depth in the tree. Every root is tier 0. Hybrid roots start at tier 2.
- **Unlocking a node** takes three things: its parent is unlocked, the parent's mastery has reached `unlockMastery[tier]` (15 / 30 / 50 / 70), and any explicit prerequisites are met.
- **Default power ceiling by tier** (`tierMaxPower`) is 3 / 5 / 7 / 9 / 10. Nodes tagged ★ are world-altering and raise their ceiling to 10.
- **Properties are inherited.** A node grants the properties listed in braces plus everything its ancestors grant.

```
ENERGY {temperature, luminosity, momentum}
├ thermal {combustion}
│ ├ pyromancy ─ conflagration ★
│ ├ cryothermy ─ stillfrost
│ └ calefaction
├ luminous {shadow}
│ ├ photomancy ─ irradiance {radiation}
│ └ umbramancy
├ kinetic
│ ├ impetus
│ └ deflection ─ inertia
└ electric {charge}
  ├ galvanism
  └ arcweaving

EARTH {hardness, density, contour}
├ geomancy {cohesion}
│ ├ lithomancy ─ architectonics ★
│ ├ metallurgy {magnetism, purity} ─ ferromancy, alloycraft
│ └ crystallurgy {resonance, purity} ─ focuscraft
├ seismic {seismicity}
│ ├ faultwork ─ cataclysm ★ (earthquakes)
│ └ tremorsense
└ sandshaping {cohesion} ─ dunecalling

WATER {humidity, flow, temperature}
├ hydromancy {pressure, viscosity}
│ ├ tidal {buoyancy} ─ tsunamancy ★
│ ├ glaciation {phase} ─ permafrost
│ ├ vapor {phase} ─ fogweaving
│ └ hydrostatics
└ purification {purity} ─ wellspring

AIR {flow, pressure, sound}
├ aeromancy {buoyancy}
│ ├ windshaping ─ tempest ★
│ └ vacuity {breath}
├ sonics ─ echolocation, thunderclap
└ weathercraft {humidity, temperature, charge} ─ rainmaking, stormbrewing

LIFE {vitality, growth}
├ restoration {metabolism}
│ ├ mending ─ resurgence
│ └ purgation {toxin}
├ flora ─ arborism, mycology {decay}
├ fauna {instinct} ─ beastspeech, wildshape {metabolism} (max 8)
└ blight {decay, toxin}
  ├ pestilence ─ greatplague ★ ⚠
  └ withering

MIND {perception, emotion}
├ perceptics ─ farsight, insight {thought}
├ empathy ─ charm, dread
├ illusion {illusion}
│ ├ phantasm ─ grandillusion ★
│ └ veiling
├ mnemonics {memory} ─ oblivion ⚠
└ telepathy {thought} ─ dominion {will} ⚠

SPIRIT {essence, warding}
├ warding
│ ├ sanctum ─ hallowing ★
│ └ counterwarding
├ hexcraft {malediction} ─ greatercurses ⚠
├ binding {bond} ─ pactcraft {will}, soulbinding {soul}
└ necrourgy {unlife, soul} ─ deathspeech, revenancy

VOID {aether, presence}
├ negation ─ dispelling ─ antimagic ★
├ dampening {momentum, sound, luminosity, temperature, charge} ─ silence, eclipse, stillness
├ absorption {essence} ─ siphoning
└ obscurance ─ nullsign

SPACE {distance, presence}
├ translocation {position}
│ ├ blinking
│ └ gatecraft {boundary} ─ worldgates ★
├ folding {volume} ─ pocketcraft
├ containment {boundary, volume} ─ sealing
└ spatialsense {orientation} ─ clairsentience

TIME {tempo}                                  (mythic)
├ chronokinesis ─ hastening, stasis {persistence}
├ aeonics {age, decay} ─ rejuvenation
└ causality {sequence, foresight}
  ├ precognition
  └ rewind ─ unhappening ★ ⚠

GRAVITY {weight}                              (mythic)
├ weightcraft {buoyancy, density} ─ levitation, crushing
├ vectoring {orientation, momentum} ─ inversion
└ attraction {cohesion} ─ orbitcraft ─ collapse ★

REALITY {probability}                         (mythic)
├ fortune ─ fatebending
├ substantiation {substance, persistence} ─ conjuration, unmaking ⚠
└ lawcraft {law, identity, sequence}
  ├ polymorphy
  └ edict ─ worldlaw ★ ⚠
```
★ = world-altering (ceiling 10). ⚠ = tagged `forbidden`, a hook for NPC factions and law.

### Hybrid branches (tier 2)

| Hybrid | Domains | Prerequisites | Grants | Child |
|---|---|---|---|---|
| Clayshaping (`mudshaping`) | Earth + Water | geomancy 40, hydromancy 40 | viscosity, cohesion, contour | none |
| Stormcalling | Energy + Air | electric 40, aeromancy 40 | charge, pressure | skyfire ★ |
| Verdancy | Life + Earth | flora 40, geomancy 30 | growth, contour | wildwood ★ |
| Mindlink | Space + Mind | telepathy 40, translocation 40 | thought, distance | none |
| Magmacraft | Energy + Earth | thermal 40, geomancy 40 | temperature, contour, density | volcanism ★ |
| Mistweaving | Water + Mind | vapor 35, illusion 35 | humidity, illusion | none |
| Necromancy ⚠ | Life + Spirit | blight 45, necrourgy 45 | unlife, decay, soul | lichcraft ⚠ |
| Runesmithing | Spirit + Earth | warding 40, metallurgy 40 | warding, purity, bond | none |
| Nullwarding | Void + Spirit | negation 40, warding 40 | aether, warding | none |
| Singularity | Gravity + Void | attraction 50, absorption 50 | weight, aether, density | none |

For a hybrid, **affinity is the geometric mean** of the caster's affinities in its Domains, so one weak Domain drags the whole hybrid down. **Cost and volatility** are the average of its Domains' values. **Overdraw risk** takes the worst multiplier of each kind across its Domains.

---

## 3. Layer 3: The grammar

### Properties (58), grouped by category

`costWeight` multiplies cost. `volatility` adds flat instability.

| Category | Properties (costWeight) |
|---|---|
| Thermal | temperature 1.0, combustion 1.1 |
| Energetic | luminosity 0.8, shadow 0.9, radiation 1.5, charge 1.2 |
| Kinetic | momentum 1.0, seismicity 1.3, sound 0.8, resonance 1.1, weight 1.4 |
| Material | hardness 1.0, density 1.1, cohesion 1.1, contour 1.0, magnetism 1.2, purity 1.0 |
| Fluid | humidity 0.8, viscosity 1.0, pressure 1.1, flow 1.0, phase 1.2, buoyancy 1.1, breath 1.3 |
| Vital | vitality 1.2, growth 1.0, decay 1.2, toxin 1.2, instinct 1.2, metabolism 1.3 |
| Mental | perception 1.0, emotion 1.2, memory 1.6, illusion 1.1, thought 1.4, will 1.6 |
| Spiritual | soul 1.8, warding 1.0, malediction 1.3, bond 1.3, essence 1.4, unlife 1.6 |
| Arcane | aether 1.3, presence 1.1 |
| Spatial | distance 1.5, position 1.6, volume 1.5, boundary 1.3, orientation 1.5 |
| Temporal | tempo 2.0, age 1.9, persistence 1.8, sequence 2.4, foresight 1.8 |
| Metaphysical | probability 2.2, substance 2.5, law 3.0, identity 2.6 |

### Verbs

| Verb | Min tier | Needs from world | Cost× | Power× | Instab | Duration× |
|---|---|---|---|---|---|---|
| Generate | 0 | nothing | 1.0 | 1.0 | .05 | 1.0 |
| Amplify | 0 | target | 0.8 | 1.0 | .04 | 1.2 |
| Reduce | 0 | target | 0.8 | 1.0 | .03 | 1.2 |
| Sense | 0 | nothing | 0.4 | 0.6 | .01 | 1.5 |
| Transfer | 1 | source | 0.7 | 0.9 | .05 | 1.0 |
| Redirect | 1 | source | 0.6 | 1.1 | .07 | 1.0 |
| Store | 1 | source | 0.9 | 0.8 | .06 | 3.0 |
| Release | 1 | stored charge | 0.5 | 1.25 | .10 | 0.5 |
| Transmute | 2 | source | 1.4 | 1.0 | .12 | 1.5 |
| Bind | 2 | target | 1.2 | 0.9 | .08 | 2.0 |

Redirect and Transfer are cheap because they reuse energy that already exists in the world. The cast pipeline must check that the source really exists. MagicCore only reports the requirement.

### Forms

| Form | Min tier | Range | Area r | Dur | Cast | CD | Cost× | Power× | Instab | Targets |
|---|---|---|---|---|---|---|---|---|---|---|
| Touch | 0 | 6 | 0 | 5 | .4 | .5 | 0.7 | 1.2 | .02 | 1 |
| Projectile | 0 | 60 | 2 | 1 | .5 | 1 | 1.0 | 1.0 | .05 | 1 |
| Burst | 0 | 0 | 10 | 1 | .8 | 3 | 1.4 | 0.8 | .10 | area |
| Aura | 0 | 0 | 6 | 10 | 1 | 5 | 1.5 | 0.5 | .04 | area |
| Beam | 1 | 40 | .5 | 2 | .7 | 2 | 1.3 | 1.1 | .08 | 1 |
| Wall | 1 | 25 | 8 | 12 | 1 | 4 | 1.3 | 0.9 | .06 | area |
| Zone | 1 | 30 | 12 | 8 | 1.2 | 6 | 1.6 | 0.6 | .08 | area |
| Pillar | 1 | 30 | 3 | 6 | .9 | 3 | 1.2 | 1.1 | .07 | area |
| Chain | 2 | 30 | 0 | 1 | .6 | 3 | 1.4 | 0.75 | .10 | 3 (+1 per 3 power levels) |
| Summon | 2 | 15 | 0 | 30 | 2 | 15 | 2.0 | 1.0 | .12 | 1 |
| Ritual | 2, mastery 60 | 10 | 40 | 20 | 10 | 120 | 3.0 | 1.6 | .15 | area, +1 modifier slot |

An "area" form hits every target inside its area, up to `Tuning.maxAreaTargets` (24).

### Modifiers

| Modifier | Min tier | Forms | Cost× | Power× | Other | Instab | Excludes |
|---|---|---|---|---|---|---|---|
| Delayed | 1 | any | .95 | 1.1 | +2 s delay | +.03 | Channeled |
| Homing | 1 | projectile, chain | 1.3 | .9 | | +.05 | |
| Piercing | 1 | projectile, beam, chain | 1.25 | .95 | range ×1.1 | +.04 | |
| Lingering | 0 | touch, projectile, burst, aura, wall, zone, pillar | 1.35 | .85 | duration ×3 | +.03 | |
| Linked | 2 | any | 1.2 | 1 | duration ×1.2 | +.06 | |
| Silent | 1 | any | 1.15 | 1 | cast ×1.2, no VFX/SFX | 0 | Echoing, Reckless |
| Efficient | 0 | any | .75 | .85 | cast ×1.3 | −.04 | Reckless |
| Reckless | 0 | any | 1.1 | 1.35 | area ×1.1, cast ×.8, CD ×.8 | +.18 | Efficient, Silent |
| Channeled | 0 | touch, beam, aura, wall, zone, pillar | 40% upfront + 25%/s | 1.2 | up to 6 s | −.05 | Delayed |
| Echoing | 2 | all except aura, wall, summon, ritual | 1.4 | 1 | 2 echoes at 50%, CD ×1.3 | +.08 | Silent |

**Modifier slots** = `min(3, 1 + floor(mastery / 30))`, plus the form's bonus (Ritual +1). The absolute cap is 4.

### Compatibility matrices

0 means **invalid**. Any other value is an efficiency `e`: power ×`e`, cost ×`e^-0.5`.

**Verb × Property category**

| | Therm | Enrg | Kine | Matr | Flui | Vital | Ment | Spir | Arca | Spat | Temp | Meta |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| generate | 1.15 | 1.15 | 1 | .8 | .9 | .6 | .8 | .6 | .5 | **0** | **0** | .4 |
| amplify | 1 | 1 | 1 | 1 | 1 | 1.1 | 1 | 1 | .9 | .9 | .9 | .8 |
| reduce | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1.1 | 1 | .9 | .8 |
| transfer | 1.15 | 1 | 1.1 | .8 | 1 | 1 | .9 | .9 | 1 | 1 | .7 | .6 |
| redirect | .9 | 1.1 | 1.15 | .6 | 1.1 | .6 | .8 | .7 | .9 | 1 | .7 | .6 |
| transmute | .8 | .8 | .6 | 1.15 | 1 | .9 | .7 | .8 | .8 | .6 | .5 | 1 |
| bind | .6 | .7 | .9 | .9 | .8 | .9 | 1 | 1.15 | 1 | 1.1 | 1 | .9 |
| sense | 1 | 1 | 1 | 1 | 1 | 1 | 1.1 | 1 | 1.15 | 1.1 | 1 | .8 |
| store | 1 | 1.1 | 1 | **0** | .7 | .8 | .9 | 1 | 1.15 | .7 | .8 | **0** |
| release | 1 | 1.1 | 1.1 | **0** | .8 | .8 | .8 | 1 | 1.1 | .7 | .8 | **0** |

Space and Time can't *generate*. You fold distance by **reducing** it, and you teleport by **transferring** position.

**Form × Verb**

| | gen | amp | red | xfer | redir | xmut | bind | sense | store | rel |
|---|---|---|---|---|---|---|---|---|---|---|
| touch | 1 | 1 | 1 | 1.1 | .9 | 1.1 | 1 | 1 | 1 | 1 |
| projectile | 1 | .9 | .9 | **0** | 1 | .8 | .8 | **0** | **0** | 1.1 |
| beam | 1 | 1 | 1 | 1 | 1 | .9 | .8 | 1.1 | **0** | 1 |
| burst | 1 | 1 | 1 | **0** | 1 | .8 | .7 | 1 | **0** | 1.1 |
| aura | .9 | 1.1 | 1.1 | 1 | 1 | .8 | .9 | 1 | 1.1 | .9 |
| wall | 1 | .9 | .9 | **0** | 1.1 | .9 | 1 | .8 | 1 | **0** |
| zone | .9 | 1 | 1 | .9 | 1 | .8 | 1 | 1 | .9 | .9 |
| pillar | 1.1 | 1 | .9 | **0** | 1 | .9 | .9 | **0** | **0** | 1 |
| chain | 1 | .9 | .9 | 1 | 1 | **0** | 1 | **0** | **0** | 1 |
| summon | 1 | **0** | **0** | **0** | **0** | 1 | 1 | **0** | **0** | **0** |
| ritual | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |

**Form × Category blocks.** Summon can't carry Spatial, Temporal or Arcane. Pillar can't carry Mental. Chain can't carry Spatial or Temporal.

**Tier gates** apply to verbs, forms and modifiers alike, and use the tier of the branch being cast from.

---

## 4. Recipe schema

```lua
{
  v = 1,                       -- schema version
  branch = "metallurgy",       -- domain(s) are derived from the branch
  property = "hardness",
  verb = "amplify",
  form = "touch",
  modifiers = { "lingering" }, -- sorted and unique after normalization
  power = 4,                   -- integer 1..10
  costProfile = "reservoir",   -- reservoir | ambient | vital
}
```

The canonical key is `v|branch|property|verb|form|power|costProfile|mods`. Use it for spellbook dedupe, cooldown tracking and caches.

---

## 5. The math

Symbols used below:
- `P` is the power level (1–10).
- `m` is mastery of the cast branch divided by 100.
- `a` is affinity (0–1). For hybrids it's the geometric mean.
- `eV` is the Verb × Category efficiency, and `eF` is the Form × Verb efficiency.
- `Πmod` is the product of the modifier multipliers, and `Σmod` is the sum of their additive terms.

| Quantity | Formula |
|---|---|
| Magnitude | `M = 1.85^(P−1)`, so P1 = 1, P5 ≈ 11.7, P10 ≈ 254 |
| Power | `M · verb.power · form.power · Πmod.power · eV · eF · (0.75+0.5a) · (1+0.3m) · profile.power` |
| Cost | `4 · 1.95^(P−1) · verb.cost · form.cost · Πmod.cost · prop.costWeight · (eV·eF)^-0.5 · (1.3−0.5a) · (1−0.45·m^0.8) · domain.costMult · scarcity` |
| Scarcity | `1 + 0.6 · max(0, 1 − density)`, so a dead zone costs ×1.6 |
| Range | `form.range · (1+0.12(P−1)) · (1+0.4m) · Πmod.range` |
| Area radius | `form.area · M^0.4 · Πmod.area`, so P10 is ≈ ×9.2 |
| Duration | `form.dur · (1+0.08(P−1)) · verb.dur · Πmod.dur` |
| Cast time | `form.cast · verb.cast · (1+0.06(P−1)) · (1−0.35m) · Πmod.cast · profile.cast` |
| Cooldown | `max(0.25, form.cd · (1+0.15(P−1)) · Πmod.cd)` |
| Comfort power | `1 + 9 · m^0.75` |
| Power cap | `min(branch.maxPower, floor(comfort) + 2)` |
| Instability | `(verb.i + form.i + Σmod.i + prop.vol) · (0.5+0.1P) · (1−0.5m) · domain.volatility · profile.instab + 0.12·max(0, P−comfort)`, clamped to 0–1 |
| Backfire chance | `instability²` |

Why the curves look like this:
- **Cost grows faster than power** (1.95 vs 1.85 per level). A P10 spell does ~254× the effect of a P1 spell for ~400× the cost, so spamming big spells is self-limiting.
- **Area grows sublinearly** (M^0.4). Bigger spells cover more ground, but not quadratically more, which keeps area effects within the server's performance budget.
- **Overreach is allowed but punished.** A caster can attempt up to two levels above their comfort power, and each level over adds 12 percentage points of instability.

---

## 6. Layer 4: Resources

| Concept | Rule |
|---|---|
| Attunement | `100 · (1 − e^(−Σmastery / 600))`. Overall magical development, or set explicitly |
| Max reservoir | `100 + 900 · (attunement/100)^1.25`, ranging 100–1000 |
| Regen / s | `max · 0.012 · √density · activity · (1 − 0.5·strain/100)`. Activity is Normal 1, Resting 2.5 or Combat 0.4. Burnout stops regen entirely |
| Ambient density | 0 is a dead zone (no regen, cost ×1.6), 1 is normal, 3 is a ley nexus. A per-domain bias applies (a volcano boosts Energy) |
| Cost profiles | **Reservoir** pays 100% from the reservoir. **Ambient** pays `min(60%, 20%·density)` from the area, with cast time ×1.5 and instability ×1.15, and doesn't work below density 0.25. **Vital** pays 30% as HP (0.5 HP per mana), with power ×1.15 and instability ×1.25 |
| Mastery discount | Up to −45% cost, −35% cast time and −50% instability at mastery 100 |

**Overdraw.** A caster may spend down to −50% of their max reservoir. *Depth* is how far below zero the caster ends up, as a fraction of max. The cost of the cast is split as follows:

| Depth | Consequence (× the Domain's risk multiplier) |
|---|---|
| any | **Backlash**: 0.5 HP per mana overdrawn |
| > 15% | **Burnout**: no regen and no further overdraw for `10 + 60·depth` s |
| > 30% | **Domain lockout**: can't cast that Domain for `30 + 120·depth` s |
| > 25% | **Mutation roll**: chance `min(35%, (depth−0.25)·0.4·mutationMult)`, rolled from `Seed.random(worldSeed, casterId, "overdraw", castCounter)` |
| — | **Strain** += `depth·100`. It decays 2/s and reduces regen while it lasts |

Each consequence carries the Domain's `risk.id` (withering, fracture, dislocation and so on). Status-effect systems use it to choose the flavour.

---

## 7. Extending without breaking saves

1. **Ids are forever.** Saves store string ids, never array indices. Never rename or reuse an id. To change one, add an entry to `Data/Aliases.luau` (`old = "new"`); normalization follows the alias on every load.
2. **Don't delete; deprecate.** Give a retired node a `deprecated` tag (a future field) so the UI hides it, but keep the definition so old recipes still resolve. If you truly must remove one, alias it to the closest replacement.
3. **Additive changes are free.** A new property, verb, form, modifier, branch, hybrid or Domain needs its data entry, a matrix row or column, and nothing else. The Registry fails loudly at boot if anything is incomplete.
4. **Moving a branch** in the tree changes its tier but not its id, so saved mastery stays valid. Do re-check that player unlocks still make sense afterwards.
5. **Recipe schema changes:** bump `Tuning.RECIPE_VERSION` and append `MIGRATIONS[n]` in MagicCore. Never edit a migration that has already shipped.
6. **Balance changes** (anything in Tuning, multipliers or matrices) never invalidate saves, because stats are always recomputed, never stored. A recipe that becomes invalid, such as one whose power is now above a lowered cap, should be **clamped on load** (lower power, drop the failing modifier) rather than deleted. The spellbook loader should do this.
7. **Never persist computed stats.** Persist only recipes, mastery, affinities and the reservoir's current value.
