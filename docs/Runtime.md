# Magic Runtime

What happens after a spell is cast: effects, simulations, world changes, budgets, backlash, interactions and visuals.
This builds on [Casting.md](Casting.md) (the validation pipeline) and [UI.md](UI.md) (the HUD and composer).

Status (2026-11-02): code complete, it passes `rojo build` and luau-lsp, and `Tests/Cast.spec` covers the data invariants. **Not yet verified in play.**

---

## 1. Module map

| Deliverable | Where | Role |
|---|---|---|
| **CastService** | `Services/CastService` | Server pipeline: validate → measure → stats → pay → resolve → aftermath |
| **CastClient** | client `Controllers/CastClient` | Input, aim, client-side pre-checks, predicted casting VFX and cast bar, reconciliation |
| **EffectRunner** | `Services/EffectRunner` | Ticks everything that outlives a cast: fields (10 Hz), statuses (4 Hz), heat and fire (2 Hz), presences (1 Hz). LOD cue fan-out, dispel |
| **EffectLibrary** | `Magic/Data/EffectLibrary` | Data: ordered routes from recipe to effect + params. `Shared/Magic/Data/SpellExamples` holds 50+ examples |
| **Effect resolvers** | `Magic/Cast/Effects/*` | Impact, Restore, Force, Light, Construct, Sense, Store, Manifest, Status, Field, Terrain, Thermal, Wave, Blink, Dispel, Siphon, Metal, Earthquake, Tsunami |
| **InteractionMatrix** | `Magic/Cast/InteractionMatrix` | Elemental tags per spell, reaction table, reaction handlers |
| **BacklashService** | `Services/BacklashService` | Overdraw consequences and loss of control, with domain-flavoured risk effects |
| **EffectBudget** | `Magic/Cast/EffectBudget` | Per-server slots, token buckets (parts, terrain ops), LOD tiers, metrics |
| **TerrainDeform** | `World/TerrainDeform` | Temporary (revertible) and persistent (saved) terrain changes |
| **WaveSimulator** | `World/WaveSimulator` | Column height-field wave front (tsunamis, spell waves) |
| **FieldEffects** | `Magic/Cast/FieldEffects` | Time, gravity, current and reality zones |
| Supporting | `Magic/Cast/StatusEffects`, `Damage`, `ThermalSim`, `FireSim`, `Targeting`, `Constructs` | Conditions, the single damage path, heat model, fire spread, form targeting, construct caps |
| VFX | client `Fx/SpellFx`, `Fx/FxRecipes`, `Fx/FxPool`, `Controllers/WorldEffectController` | Signature × tier × form rendering, pooling, LOD |

How the pieces connect:

```
Client  CastClient ──CastIntent(recipe, aim, target)──►  Server  CastService
          ▲  predicted glow + cast bar                       │ validate (MagicCore, real caster) · range · LoS · plausibility
          │                                                  │ EffectLibrary.routeFor → resolver (+ precheck: budgets)
          │◄── CastResult refused | accepted | resolved ─────│ castContext (WorldState) → computeStats → pay (Reservoir, seeded)
          │                                                  │ BacklashService.overdraw
          │◄── WorldEffect cues (LOD near/mid/far) ──────────│ EffectRunner.cue("spell", begin)
WorldEffectController → SpellFx (pooled, signature-tinted)  │ … castTime … resolver.resolve(ctx, params)
                                                             │   ├─ Damage / StatusEffects / ThermalSim / FireSim
                                                             │   ├─ FieldEffects (EffectRunner owns them)
                                                             │   └─ TerrainDeform / WaveSimulator / World effects
                                                             │ EffectRunner.addPresence → InteractionMatrix reactions
                                                             └ XP, discoveries, MagicWitnessed (NPCs), noteMagic, judgeCast
```

## 2. Effect systems by domain

| Domain | Systems (examples in SpellExamples) |
|---|---|
| **Energy** | Light sources (`Light`, capped at `budget.maxLights`). Heat model (`ThermalSim`: conduction, cooling, ignition on tagged parts). Heat transfer (`Thermal` transfer). Spreading fire (`FireSim`: part fires + ground cells, downwind spread, vegetation burn, scorch marks). Lasers (beam form `Impact`: raycast hits + heats the struck part) |
| **Earth** | Stone shaping (`Terrain` stone: Granite walls, pillars, spike rings that sink back). Metal (`Metal`: fling or pull metal parts, extract ore chunks). Tremors (`Terrain` tremor: shake, light structure damage). Earthquakes (`World/Effects/Earthquake` via `TerrainDeform.faultRupture`, stress release, aftershocks). Landslides (`Terrain` landslide: carve upslope, deposit downslope, persistent) |
| **Water** | Pour (temporary water ball, never where water already is). Ice (`freeze`: water surface → Ice, reverts; melt reaction). Currents (`Field` current: a force on swimmers and floating parts). Waves (`Wave` → `WaveSimulator`, no terrain writes). Tsunami (`WaveSimulator` with terrain, erosion, debris, flooding, salted farmland) |
| **Air** | Gust (force), Thunderclap / Breathless / Static Bolt (harm), Wind Sense. Wind feeds fire (firestorm reaction) |
| **Life** | Mending Touch (restore), Blighted Bolt (poison), Entangle (root), Purge (cleanse), Calm the Wild (calm) |
| **Mind** | Dread (fear), Charm (charm), Mirage (blind), Veil (veiled), Read Intent (sense) |
| **Spirit** | Spirit Ward (absorb shield), Hex (damage taken ×1.25 + DoT), Soul Chain (root), Lay to Rest (harm vs unlife), Spirit Sight |
| **Void** | Unravel (dispel), Hush (silence: can't cast), Eclipse (blind + lights out), Stillness (slow + loose parts stop), Siphon (drain HP and reservoir) |
| **Space** | Blink (teleport to aim, onto a surface with clearance), Displace (pull a target), Seal (root in zone), Fold (everything pulled to a point), Spatial Sense |
| **Time** *(mythic)* | Slow Field (time ×0.35 zone), Haste, Stasis (frozen; NPCs anchored), Wither Years |
| **Gravity** *(mythic)* | Heavy Ground (×2.2), Featherfall (×0.25, follows you), Inversion (−0.8 g with a hover ceiling), Crush |
| **Reality** *(mythic)* | Slick Edict (friction 0), Unweave (a loose object goes intangible), Transmute (material swap), Fortune (backfire ×0.5) |

**Mythic constraints.**
- Time, gravity and reality zones take a `mythicFields` slot: at most 2 per server, and at most 4 fields of any kind.
- Each field lasts at most 30 s, has a radius of at most 60 studs, and touches at most 40 assemblies per tick, charged to the parts bucket.
- Reality edits touch at most 40 parts. Every original value is kept in a ledger and restored on expiry, dispel, the owner leaving, or server shutdown.
- Reality never touches characters, Terrain, `NoMagicEdit` parts, or anything inside a `Structure` model. Intangible applies to unanchored props only and anchors them, so nothing falls through the world and floors never vanish.

**Time, server-safe.**
- Humanoids get a refreshed `time_slow` / `time_haste` status: WalkSpeed changes, NPC `AnimationTrack:AdjustSpeed`, and a client tint for the player.
- Unanchored server-owned parts and projectiles have their velocity scaled on entry (×factor) and restored on exit (÷factor).
- Gravity inside is scaled by factor² with a VectorForce, so a crate falls in consistent slow motion.
- Spell projectiles are instant raycasts, so they aren't slowed. Only physical projectile parts are.

**Gravity.**
- Implemented as a VectorForce on each assembly root, with `Force = (0, m·g·(1 − mult), 0)`, `RelativeTo = World`, `ApplyAtCenterOfMass`.
- Player characters get it too: constraints parented into a character replicate, and the owning client simulates them.
- Above 80% of the field's height an inverted pull becomes `mult = 0` (hover), and server-owned assemblies have their vertical velocity halved each tick.

## 3. Scaling and safety

| Limit | Value (`CastTuning.budget`) | When hit |
|---|---|---|
| Heavy effects (quake, tsunami, P8+ harm/ignite/waves/fields) | 2 at once | `WORLD_STRAINED` refusal **before payment** |
| Durational effects | 60 per server, 4 per player | Field refused before payment (`precheck`) |
| Fields / mythic fields | 4 / 2 | Same |
| Parts touched | 600/s (burst 900), token bucket | Effects touch fewer parts this tick (graceful) |
| Terrain writes | 80/s (burst 160) | Deformations get smaller (fewer ops) |
| Dynamic lights | 40 | Light refused before payment |
| Burning parts / ground fire cells | 60 / 120 | Fire stops spreading |
| Constructs per player | 3 | Oldest removed |
| Cue LOD | near ≤150 full · mid ≤400 at 45% · far ≤1200 heavy only at 15% | Clients draw less, then nothing |

**Magnitude.** Effects scale from `stats.power` (≈1 at P1, ≈250–500 at P10) through sub-linear exponents, and every formula has a hard cap:

| Effect | Formula | Example values | Cap |
|---|---|---|---|
| Damage | 4·power^0.7 | 4 at P1 · 23 at P5 · ≈200 at P10 | — |
| Heal | 5·power^0.7 | — | — |
| Push | 30·power^0.45 | — | 220 studs/s |
| Wave crest | 6 + 34·√(power/520) | — | 44 studs |
| Quake magnitude | log10(power+1)·2·(0.5+stress) | — | 150 ops, then the terrain bucket |

**Backlash** (`BacklashService`):
- **Overdraw:** the consequences come from `Reservoir.trySpend`, proportional to how deep below zero the cast went and multiplied by `riskMult` (temperament: Steadfast < 1 < Brittle). Backlash HP is internal damage, so wards don't absorb it. Reaching burnout or lockout also fires the domain's risk effect.
- **Loss of control:** a backfire at power ≥ 6. Severity = (1 + overreach) × riskMult × (1 + 0.25·(power − 6)). The caster takes `4·power^0.7 × 0.25 × severity` damage (this part alone can't kill) plus the risk effect scaled by severity.

| Risk | Domain | Effect | Risk | Domain | Effect |
|---|---|---|---|---|---|
| burnout | Energy | Burning | haunting | Spirit | Fear |
| ossification | Earth | Slow | hollowing | Void | −20% reservoir |
| saturation | Water | Slow | dislocation | Space | Thrown 14 studs |
| breathlessness | Air | Silence | unmooring | Time | Slowed time |
| withering | Life | Rot | crush | Gravity | Root |
| fracture | Mind | Blind | unraveling | Reality | A random status |

## 4. Interaction matrix

Every cast leaves a **presence** where it lands: tags, radius and power, lasting 4 s, or as long as its field. When a new presence overlaps an existing one from any caster, matching pairs react:
- each pair at most once per 2 s per 16-stud cell;
- at most 3 reactions per presence.

| A | B | Result |
|---|---|---|
| null (Void aether) | anything | **dispel**: the other effect ends, and magic in the area is unmade |
| water | fire | **extinguish** (+ steam cue) |
| water | heat | **steam**: brief burn and blind in the area; fires out |
| water | cold | **freeze**: the surface ices; swimmers rooted |
| water / metal | lightning | **conduction**: everyone swimming, or within 4 studs of metal, takes 0.8× lightning damage |
| ice | heat / fire | **melt**: magic ice reverts to water early |
| stone | gravity | **crush**: damage, root and structure damage |
| wind | fire | **firestorm**: fire spreads ×3 for 15 s in 3× the radius |
| life | fire | **wildfire**: a ring of ground fires |
| rot | fire | **toxic smoke**: poison in 1.5× the radius |
| cold | wind | **blizzard**: slow + chill |
| light / life | dark / rot | **cancel**: both effects end |
| time | gravity | **shear**: damage in the overlap |

Tags come from the property:
- temperature → heat (reduce → cold); combustion → fire+heat;
- flow and pressure → water in water magic, wind in air magic;
- charge → lightning; magnetism → metal; weight → gravity; aether → null;
- (full table in `InteractionMatrix.PROPERTY_TAGS`).

`Cast.spec` checks every reaction has a handler and only uses tags something can produce.

## 5. Visual and audio identity

Every visual is **Signature × Tier × Form**:
- The caster's Signature (`Player` attribute `MagicSignature`, published when their data loads) sets the colours: primary → secondary → accent across each particle's life.
- Their particle style picks the texture and size; their motion picks speed, spread, spin and lift.
- Mastery tier sets refinement.
- So two Novice fire mages look different from each other, and both look different from a Grandmaster.

### 5.1 Tier refinement (`FxRecipes.tiers`)

| | Novice (tier 2) | Adept (3) | Master (6) | Grandmaster (7) |
|---|---|---|---|---|
| SpreadAngle × | 1.6 | 1.3 | 0.75 | 0.6 |
| Transparency flicker | 0.45 (jagged keypoints) | 0.3 | 0.06 | 0.02 (smooth fade) |
| Size jitter (envelope) | 0.5 | 0.35 | 0.1 | 0.05 |
| Lifetime spread | ±60% | ±45% | ±18% | ±12% |
| LightEmission | 0.25 | 0.35 | 0.65 | 0.75 |
| Drag (control) | 1 | 2 | 5 | 6 |
| Beam CurveSize (wobble) | ±2.5 | ±1.5 | ±0.15 | 0 (straight) |
| Trail Lifetime | 0.16 s | 0.2 s | 0.32 s | 0.36 s |
| Emission × | 0.75 | 0.9 | 1.2 | 1.3 |

### 5.2 Concrete recipes

**Novice embers vs Grandmaster embers** (signature particle `embers`, motion `flickering`, form `burst`, P5):

| ParticleEmitter property | Novice | Grandmaster |
|---|---|---|
| `Texture` | `rbxasset://textures/particles/fire_main.dds` | same |
| `Color` | primary → secondary → accent | same |
| `Size` | 0.6→mid(±37%)→0, envelope 0.15 | 0.6→0.6→0, no envelope |
| `Transparency` | 0.1, then 6 jittered points (±0.36), then 1 | 0.1 → 0.3 → 1 |
| `Lifetime` | 0.8 × [0.52, 1.6] | 0.8 × [0.9, 1.1] |
| `Speed` | 1.2–2.8 | same |
| `SpreadAngle` | 56° | 21° |
| `Drag` | 1 | 6 |
| `LightEmission` / `LightInfluence` | 0.25 / 0 | 0.75 / 0 |
| `RotSpeed` | ±90 | ±90 |
| `Acceleration` | (0, 1, 0) | (0, 1, 0) |
| Count | `Emit(60 × 0.75 × quality × lod)` | `Emit(60 × 1.3 × quality × lod)` |

**Beam (laser, beam form):**
- `Attachment0/1` on two pooled anchors; `FaceCamera = true`; `Segments = 12`.
- `Width0 = 0.6 × clamp(P/5, 0.4, 2.5)`, `Width1 = 0.6 × Width0`.
- `Texture = sparkles_main`, `TextureMode = Wrap`, `TextureLength = 4`, `TextureSpeed = 2 + Drag × 0.3`.
- `CurveSize0/1 = ±tier.beamCurve` (random per cast).
- `Transparency` animates t² + flicker noise over 0.4 s.

**Trail (projectile):**
- Two attachments 0.5 studs apart on a Neon ball (size 0.7, signature primary).
- `Lifetime = tier.trailLife`; `Color` primary → accent; `Transparency` 0.2 → 1; `WidthScale` 1 → 0; `FaceCamera = true`; `LightEmission = tier.emission`.
- The ball weaves `sin(20t) × beamCurve × 0.4`, so a Novice's bolt wobbles.

### 5.3 Pooling and cleanup (`FxPool`)

**Pooled objects.** Anchors (invisible anchored parts with attachment `A`), ParticleEmitters, Beams and Trails, all from free lists.
- `release(anchor)` returns the anchor and every pooled thing under it.
- `releaseAfter(anchor, t)` schedules that return.

**Caps.** 90 anchors, 140 emitters, 30 beams and 30 trails, scaled by device quality. When a cap is full, effects are skipped, never queued.

**Lifetime rule.** Everything is either pooled with a scheduled release, or (fields and waves) owned by one Heartbeat connection that destroys it. Nothing survives its cue.

**Local only.** Everything sits in `workspace.MagicFx`, created by the client, so none of it replicates.

### 5.4 Audio

Each domain cue (`Theme.sounds.domain_<id>`) is pitched by the Signature's `pitch` (semitones) and coloured by `timbre`. The asset list is in UI.md §6. Mapping timbre to `EqualizerSoundEffect` presets is still to build: the cue data is ready, the sounds aren't delivered.

## 6. Walkthroughs

### (a) A Novice lights a candle: *Candle*, `energy · temperature · generate · touch · P1`

1. **Client.**
   - CastClient: the slot key is pressed; the cooldown and silence checks pass.
   - `MagicState:preview` estimates range ≈4 studs and castTime ≈0.5 s.
   - The aim ray hits the candle's wick, 3 studs away, which is in range.
   - The casting glow appears at once: tier 2, the caster's embers, flickering. The cast bar starts. `CastIntent` is sent.
2. **CastService.**
   - `validateRecipe` with the real caster: `energy` is unlocked, `generate`/`touch` open at Sensing, P1 ≤ cap.
   - Aim checks: plausible, in range, line of sight clear.
   - `routeFor`: no earlier route matches (light needs luminosity; heat_transfer needs transfer; freeze needs a water branch), so it lands on **thermal** (`Thermal`, mode byVerb → heat).
3. **Stats.**
   - `castContext` at the wick, then `computeStats`: power ≈1.
   - `Reservoir.trySpend` pays ≈4 mana, rolled with `Seed.random(worldSeed, "player:<id>", "cast", 37)`.
   - CastResult `accepted` corrects the cast bar; the `spell begin` cue is skipped for us because CastClient is predicting.
4. **Resolve** after ≈0.5 s: the backfire roll is ≈0% (instability² at P1). `Thermal.heat`:
   - `ThermalSim.partsNear(wick, 3)` returns the candle first.
   - `addHeat(candle, 40 × 1)`; capacity = max(0.5, volume × 0.9) = 0.5, so +80 °C → 100 °C.
   - The designer set `IgnitionPoint = 60` and `Flammability = 1`, so `FireSim.ignitePart` adds a `Fire`. It burns its `Fuel` attribute (designer: 600 s) and warms neighbours.
   - No characters are hit, but a part changed, so the cast is **effective**.
5. **Aftermath.**
   - A presence (`heat`, 4 s) is added; no reaction.
   - Practice XP is awarded (full, not the 25% ineffective rate); the discovery log records the first cast.
   - The `spell resolve` cue draws a small tier-2 burst at the wick; the client's FxPool returns it after 1.5 s.

### (b) An Adept transfers heat: *Warmth Draw*, `calefaction · temperature · transfer · touch · P3`

1. Route **heat_transfer** (`Thermal`, transfer). Power ≈3.5, so E = 40 × 3.5 = 140.
2. **Source:** the nearest part at the aim, a cooling ingot at 600 °C with capacity ≈2.5 (1 stud³ of metal). `addHeat(ingot, −140)` → −56 °C, leaving ≈544 °C.
3. **Destinations:** up to 4 heat-capable parts within the spell's area of the ingot, here a kettle and a stool. Each gets `140 × 0.6 / 2 = 42`:
   - kettle (capacity ≈4): +10.5 °C;
   - stool (wood, capacity ≈1.8): +23 °C.
4. **The simulation carries on** (2 Hz, at most 150 active parts):
   - the ingot keeps conducting 8%/s of the difference to anything touching it and cooling 2%/s toward 20 °C;
   - if the stool ever reaches its 260 °C ignition point, it catches.
5. **Variants.**
   - Targeting a **character** chills them (Slow 3 s) and deals 0.3 × damage, PvP rules apply.
   - With no destination, the note reads "You draw the warmth into your hands."
   - A backfire chills the caster.

### (c) A Master's earthquake: *Fault Rupture*, `faultwork · seismicity · generate · zone · P7`

1. **Route:** **earthquake**, since the seismic branch at P ≥ 5. `Earthquake.measure` asks for a radius of max(area, 150).
2. **Environment rules.**
   - `fault_stress` needs 0.12 × 1.25² = 0.19 stress; below 35% of that (0.066) the cast is blocked and refused **before payment**.
   - `ground_mass` needs 0.41.
   - Shortfalls scale power by √ratio; surplus adds up to +15%.
3. **Pay and commit.** A long zone cast time. P7 is below the heavy threshold (8), so no heavy slot; a P8+ Cataclysm takes one of the 2.
4. **Resolve** (`World/Effects/Earthquake`, seeded with the cast's RNG):
   - Magnitude = log10(power + 1) × 2 × (0.5 + stress). At power ≈50 and stress 0.4 that is ≈3.1.
   - `releaseStress` drains part of the region's stress and pushes 15% into its neighbours.
   - `TerrainDeform.faultRupture` builds the fissure, uplift, subsidence and cracks along the local fault direction: ≤150 ops, also capped by the terrain bucket. `world:edit` makes them persistent and replayed by every server.
   - Clients get a `quake` cue: camera shake ∝ magnitude × distance falloff, plus dust.
   - `damageStructures(25 × M)` and `damageCharacters(6 × M)`; the caster is always included.
   - If the caster survives 5 s inside the shaken area, they record `survived earth:self_collapse`.
5. **Aftershocks.** Any of the 8 neighbouring points (1.5 regions out) holding ≥0.45 stress, raised by the 15% push, ruptures 4–10 s later at half magnitude and half radius. At most 2, with no cascade.
6. **Aftermath.** Presence `stone` (a gravity mage overlapping it gets **crush**). The world chronicle records it if P ≥ 8. EventDirector notes the magic pressure.

### (d) A Grandmaster's tsunami: *Tsunami*, `tsunamancy · flow · redirect · ritual · P10 · efficient · ambient`

1. **Aim and measure.**
   - The caster aims at the coast they want hit.
   - `Tsunami.measure` finds the nearest open-sea cell (16 bearings, 64-stud steps) and backs off 200 studs. No sea in reach → `ENVIRONMENT_BLOCKED` before payment.
   - `castContext(origin, 400)`: `great_wave` needs 4000 × 2.3⁴ ≈ 112k studs³ of water.
2. **Budget and pay.** It takes a heavy slot (P10), refused if both are busy. The ambient cost profile draws up to 60% from density.
3. **Coastline.** `checkCoastline` marches the coarse grid: the path must stay on connected open sea to an **open** coast within 1800 studs.
4. **The wave** (`WaveSimulator.run`).
   - Size: crest = 6 + 34·√(power/520) ≈ 40 studs; width = clamp(area × 1.2, 60, 480), i.e. up to 30 columns of 16 studs; reach inland up to 420 studs.
   - At sea, each column shoals by Green's law: H ∝ depth^−¼, capped at 2.2×.
   - On land, each column loses 0.035·√crest per stud travelled and 0.9 per stud of elevation, and dies at ≤1 stud, so headlands split the front and valleys funnel it.
   - Diffusion smooths 25% across live neighbours each step.
   - Terrain: live columns merge into runs, one water `FillBlock` per run per step. The previous step's runs are cleared **above sea level + 1 only**, so the ocean is never touched.
   - On land, per run: structure damage, character damage through `Damage` (NPCs included), pushes (players via a client knockback cue, the rest directly), and wooden debris (≤16, 30 s, from the parts budget).
5. **Aftermath.**
   - A shallow flood that drains after 25 s.
   - **Persistent** erosion (grass → sand) on the first 10 flooded points.
   - Salted farmland (vegetation 0.3, regrows over days).
   - A chronicle entry and magic pressure.
   - Clients see the server's water plus a spray emitter riding the front, with a rumble within 200 studs.

### (e) A mythic gravity inversion: *Inversion*, `inversion · orientation · transmute · zone · P6`

1. **Route:** **gravity_field** (the gravity branch, an area form). Heavy only at P8+.
2. **Precheck before payment.** `Field.precheck` needs a free `active` slot (server and per player), a `fields` slot and a `mythicFields` slot (2 per server). Otherwise `WORLD_STRAINED` and nothing is paid.
3. **Start.** `Field.resolve` → `modeFor` → **invert**. `EffectRunner:startField("gravity", "invert", point, area, max(duration, 5) ≤ 30 s)`.
   - It takes 3 budget slots and sends a `field` cue: clients draw a ForceField cylinder of the radius and 1.5× height.
4. **Every 0.1 s** (`FieldEffects.step`):
   - `GetPartBoundsInRadius`, grouped into assembly roots (characters by HumanoidRootPart), cylinder test, at most 40, then `EffectBudget.takeParts(n)`. Anything over budget this tick is released.
   - Each root gets an `Attachment` + `VectorForce`, `Force = (0, m·g·(1 − (−0.8)), 0) = 1.8·m·g`. The net pull is 0.8 g **upward**, deliberately weaker than normal gravity.
   - Roots above 80% of the field height get `mult = 0` (weightless hover), and server-owned ones have their vertical velocity halved, so nothing is launched into the sky.
   - Roots that leave have their force and attachment destroyed.
5. **End.** On expiry, dispel (Void, or a `null` presence reaction), the owner leaving, or server shutdown, `FieldEffects.stop` removes every force. The field's presence (`gravity`) lasts as long as the field: stone magic inside it reacts with **crush**, time magic with **shear**.
6. **Backfire:** the field centres on the caster.

## 7. Exploit and lag stress-test checklist

### Exploits
Each is a case to try; the defence that should stop it follows the dash.

| Attempt | Expected defence |
|---|---|
| Fire `CastIntent` 50×/s | Net rate limit (8 burst, 4/s) → `net_violation`; plus BUSY / global cooldown. `net_kick_on_abuse` kicks |
| Recipe with a locked branch, an over-cap power, or junk ids | `validateRecipe` with the real caster → refusal codes. Schema rejects shapes |
| Aim 900 studs away / underground / behind a wall | `OUT_OF_RANGE` / `BAD_AIM` (deeper than 40 studs below the surface) / `NO_LINE_OF_SIGHT` |
| Target hint = a far-away player | Ignored unless within area + 12 studs of the aim |
| Cast while silenced, dead, or mid-cast | `SILENCED` / `DEAD` / `BUSY` |
| Spam fields, lights or quakes to lag the server | Field, light and heavy budgets refuse **before payment**; the parts and terrain buckets degrade the rest |
| Grief with Reality intangible floors | Unanchored props only; never `Structure` models or characters; everything restored |
| Blink into a wall | Surface ray + clearance box; "No room there" |
| Ignore a knockback (modified client) | Only spares themselves; damage is server-side |
| Forge a `MagicSignature` attribute | Server-set and replicated; clients can't change other players' attributes |

### Lag

| Scenario | Watch |
|---|---|
| 30 players all casting P5 bursts | Server heartbeat ≥ 55 FPS (`perf`), the parts bucket not pinned at 0 (`budget`) |
| 4 fields + 60 burning parts + 120 ground fires | `effects`: fire tick time, `ThermalSim.activeCount` ≤ 150 |
| A Grandmaster tsunami beside a town | Scheduler budget ms, terrain bucket denials, client FPS near the front |
| 2 quakes + aftershocks | Terrain ops/s, `chunk` rebuild times |
| Mobile client in a 20-caster fight | FPS ≥ 30, FxPool `stats()` at caps, no memory growth over 10 minutes |

### What to log and measure

| Name | Kind | Purpose |
|---|---|---|
| `cast_accepted` / `cast_refused{reason}` | counter per reason, per minute | Tuning and exploit detection: a spike in `BAD_AIM` / `NO_LINE_OF_SIGHT` is a cheater |
| `cast_resolve_failed` | error with traceback | Resolver bugs |
| `control_lost{severity, risk}` / `mutation_rolled` | info | Backlash tuning |
| `reaction{result}` | debug + counter | Emergent-play health |
| `EffectBudget.metrics` (parts and terrain granted/denied, refusals per slot) | `budget` command, logged each minute | Are budgets too tight or too loose? |
| Field steps / assemblies touched, fire counts, active statuses | `effects` command | Runtime load |
| `terrain_edit{cause, ops}` | info (existing) | Saved-delta growth |
| Client: FxPool live counts, SpellFx quality | `cperf` (extend) | Device load |

## 8. Mobile and low-end devices

**Quality scaling.** `SpellFx.quality()` = graphics level / 10 (0.25–1), ×0.7 on touch-only devices, ×0.35 with *Reduce spell effects*.
- It scales every particle count, and FxPool caps scale with it (minimum 4 live of each kind).
- Far cues (lod 0) draw only zone and ritual shapes; mid cues draw at 45%.

**Settings.**
- *Reduce spell effects* also turns off camera shake and status blur; field rings become near-invisible.
- *Reduce motion* turns off shake.

**Rendering cost.**
- Dynamic lights are server-capped (40) because they cost clients the most; `PointLight.Shadows` is on only at P4+.
- No per-frame `Instance.new` anywhere: pooled emitters, at most one Heartbeat/RenderStepped connection per live visual, all disconnected when done.

**Network.** Cues go only to players within 400 studs (1200 for heavy effects). Status cues go only to the affected player. Knockback goes only to the pushed player.

**Touch casting.** The screen-centre crosshair is the aim. CastClient pre-checks range locally, so a misaimed tap gives instant feedback instead of a round trip.

## 9. Known gaps
- **Mutation:** logged only.
- **Channeling:** fixed-length (no hold or cancel input).
- **Audio:** sounds aren't delivered yet (UI.md §6).
- **Wave visuals:** the client draws a simple glass wall; a proper height-field mesh is future work.
- **NPC casting:** NPCs can't cast through CastService yet (it assumes a Player).
- **Fortune:** reduces only *your* backfire chance; no "jinx" counterpart.
- **Temporary terrain:** Granite stone, poured water and ice are per server. A chunk rebuilt by streaming loses them early, which is harmless.
