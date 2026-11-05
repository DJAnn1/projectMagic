# Combat and VFX rebuild

Status (2026-11-02): Step 1 (audit) is done. Step 2 (the damage pipeline core) and Step 3 (the layered VFX) are written. They pass `rojo build` but are **not yet run in Studio**. The Step 3 brief was cut off at "shockwave ring (expanding"; everything after that point uses the defaults in §8.

## 1. Audit: why spells cast but didn't land

Ranked by impact:

1. **Damage numbers were far too low.**
   - The formula was `4 × power^0.7`. A typical new caster at P3 has `stats.power ≈ 3.4`, which gives **9 damage**.
   - Fire (`ignite`) took 50% of that, so it dealt **~5 damage against 100 HP**. P1 dealt 2–4.
   - Hits did connect; they just read as "nothing happened".
2. **Hits were decided instantly, against a stale aim point.**
   - The aim point was captured at intent time. After the cast time (0.4–2 s), one ray went to that old point.
   - Anyone who moved during the cast was missed, and the projectile VFX then flew *after* the damage had already been settled.
3. **Chains never jumped.** The chain form has `baseArea = 0`, so the hop radius `stats.area` was 0.
4. **Thin rays.** Beams and projectiles were 0-width raycasts, so a grazing shot missed.
5. **Touch** was a 4-stud sphere around the aim point, not a reach in front of the caster.
6. **There was no hit feedback at all.**
   - No damage numbers, hit markers, kill confirmation, hurt flash or hit-stop.
   - `CastResult` only carried a hit count.
7. **The visuals were weak by construction.**
   - Particles were 0.3–0.9 studs.
   - LightEmission was 0.1–0.35 at tiers 0–2, so most players' magic looked dull.
   - Projectile and touch bursts had 10–18 particles.
   - Only 3 textures were used, with no lights, sounds, impact flashes, shockwaves or ground marks.
   - Far LOD drew nothing for most forms.
8. **Every route looked identical.**
   - The client drew a generic burst at the aim point no matter what the resolver did.
   - It drew it before the resolver had even run.

These were **not** problems:
- Routing: every harmful property with an offensive verb reaches a damaging resolver (Impact, Thermal, Force, Status impact, Siphon, Terrain).
- NPCs and players are both Humanoid targets, and `Cast/Damage` already fed NPC memory.
- T2 NPCs (no rig) can't be hit. That's by design.

## 2. Pipeline

```
CastIntent → CastService (validate, pay) → wait castTime
  → currentPoint: re-aim at the validated target where it is NOW (aura: where the caster is now)
  → strike():  projectile? → Delivery.plan + "launch" cue → Delivery.fly (yields) → impact point + hits
               "resolve" cue → resolver (Targeting.select by form) → DamageModel.hit → Damage.apply
               chain? → "chain" cue with the hop points
  → echoes / channel pulses repeat strike() (a channelled beam re-aims every tick)
  → aftermath: per-cast log, Topics.SpellHit, CastResult { damage = total }
```

| Form | Hit detection (`Cast/Targeting`, `Cast/Delivery`) |
|---|---|
| projectile | Server-stepped flight: one Spherecast per Heartbeat. Speed `95 + 9·(P−1)`, capped at 220. Gravity by domain (earth lobs, water arcs), with a launch lift so the arc still lands on the aim. Homing with the modifier. Piercing passes `pierceCount` characters. Optional bounces. Fizzles past `range × 1.25` or 4 s. Ground splash 2.5 studs. Over 160 live flights, it falls back to an instant sweep. |
| beam | A thick Spherecast sweep (radius `0.9 + 0.08·P`) from the chest to the point; walls stop it. |
| touch | The explicit target within `range + 2`, else the nearest in a 55° cone in front. |
| chain | The beam's first hit, then hops within `10 + 1.2·(P−1)` studs. Each hop needs line of sight. Damage falls off 0.8× per hop. |
| burst / zone / pillar / ritual / wall / summon | Overlap at the point, minus targets behind walls (an occlusion ray per target). |
| aura | Overlap around the caster. |

## 3. Damage formula (`Cast/DamageModel`, numbers in `Data/CombatTuning.damage`)

```
amount = base(power) × share × falloff × (1 − resistance) × variance × (crit ? 1.6 : 1)
base(power) = 9 × power^0.6        P1 ≈ 9 · P3 ≈ 19 · P5 ≈ 39 · P8 ≈ 105 · P10 ≈ 250
```

- `power` is `stats.power`, which already includes affinity, mastery, temperament, resonance, environment, specialization and signature, so none of those are applied twice.
- **share** is set per route: Impact 1, heat 0.8, fire 0.6 + a burn, cold 0.6, siphon 0.6, landslide 0.5, Force 0.3, afflictions by `params.impact`.
- **falloff:**
  - area forms: 100% at the centre, down to 45% at the rim (curve 1.5);
  - chains: 0.8 per hop.
- **resistance:** `Cast/Resistances`: NPC innate (affinities + traits), wards, gear and manual `Resist_<key>` attributes; domain keys are averaged over a hybrid's domains; clamped to −0.5 … +0.8 (§9).
- **variance:** ±8%, plus 6% per point of overreach.
- **crit:** chance is `4% + 1.5% × masteryTier` (+8% Reckless), capped at 25%.
- **limits:**
  - minimum 1;
  - at most 400 per hit;
  - one hit takes at most 60% of a player's MaxHealth (PvP anti-one-shot).
- Every roll uses the cast's seeded `ctx.rng`, so damage is reproducible from the cast counter.
- Heals mirror the curve: `8 × power^0.6`.

## 4. Shared health interface

`Cast/Damage.apply(humanoid, amount, source, kind, info?)` remains the single entry point (wards, hexes, ForceFields). It now:
- detects kills;
- carries `{ domain, crit, killed }`;
- records hits per thread (`Damage.record`) for the cast log.

`Damage.heal` has an `onHeal` hook.

## 5. Status effects

These already existed in `Cast/StatusEffects`: stacking by refresh, durations, ticks, cleanup, dispel classes and client overlays. New:
- `StatusEffects.onApplied`, which publishes `StatusApplied`;
- a floating status word over the target.

Since then: a `knockdown` status, statuses that grant resistances (wards), and a HUD status bar (§9).

## 6. Events and logging

Topics:
- `SpellCast` fires on accept.
- `SpellHit` gives the per-cast targets and totals.
- `TargetDamaged` and `TargetKilled` fire per hit.
- `StatusApplied` fires when a new status lands.
- `MagicDamage` is unchanged (it feeds NPC memory).

**Per-cast log:** `cast_hits` records the recipe power, stats.power, base damage, and each target's damage with CRIT/KILL and the damage kind. It logs at Debug normally, and at Info with the `combat_debug_log` flag.

## 7. Client feedback (`Fx/CombatFeedback`)

- **Damage numbers:**
  - in the domain colour; crits are bigger and end in `!`, kills end in `✕`;
  - damage over time is summed server-side every 0.75 s and shown smaller, in the status colour;
  - heals show as green `+N`;
  - other people's numbers are smaller and fainter.
- **Hit marker** at your aim, with a tick sound:
  - crits: gold and wider;
  - kills: a red X with a lower tick.
- **Hit-stop on your heavy, crit or kill hits:** a 0.14 s FOV punch plus a small shake. "Heavy" means ≥ 25% of the target's MaxHealth.
- **When you're hit:** a red edge flash scaled by the share of your health lost, plus a shake.
- **Settings:** the new *Damage numbers* toggle, plus Reduce motion and High contrast are respected.

## 8. VFX (`Fx/SpellFx` + `Fx/FxLayers` + `Fx/DomainFx`)

Each effect is a recipe of layers. Colours start from the domain's palette and are tinted by the caster's Signature (`SIGNATURE_TINT` in SpellFx: primary 25%, secondary 40%, accent 100%), so a domain stays readable while every caster still looks like themselves. The material comes from the domain, and polish from the mastery tier. Textures can be swapped for uploads in `DomainFx.UPLOADED` (Kenney Particle Pack sources in `assets/vfx/kenney/`):

| Layer | Implementation |
|---|---|
| core | Neon sphere, white-hot primary (dark Void/Gravity cores are near-black) |
| body | domain particles, hot→cool ramp (white → primary → secondary → dim accent), size and transparency over life |
| trails / beams | trail across the bolt; beams are a white-hot core inside a wide, textured signature beam (low tiers wobble) |
| lights | pooled PointLights (global cap of 14), scaled by power, with fire flicker |
| sparks / debris | domain sparks with gravity (fire sparks, earth chunks, water droplets) |
| smoke | lit after-cloud for fire, earth, water, void and gravity |
| ground marks | flat particles (no decals needed): scorch + embers, crack, puddle, frost, bloom, rune, void; fade over 4–12 s |
| cast | rotating runic circle and counter-ring at the feet, an inward pull at the chest, a swelling light, the domain's cast sound |
| impact | flash sphere, core burst, body cloud, sparks, smoke, an expanding shockwave ring (+ an inner ring at Expert+), a light pulse, a ground mark (+ runes at Master+), camera shake, sound |
| areas | aura: rings at the caster · zone: rune circle + rising motes · pillar/ritual/summon: column of light · chain: arcs between hop points |
| lightning | `charge` spells' beams and chains, and conduction arcs (`SpellFx.lightning`): a jagged white-hot core (≤ 5 segment beams between jittered joints, re-struck every 45–75 ms) inside a wide crackling beam whose bolt texture (`lightning*` roles) swaps on each strike; dark blinks; a flickering light |
| muzzle | `SpellFx.muzzle` on every projectile launch: a flame-shaped flash standing along the shot (VelocityParallel) + a quick glow |
| streaks | projectile trails carry the `streak` texture (stretched along the trail) |
| slashes | `Fx/SlashFx` via `Controllers/SlashFxController`: when a character's action state becomes `slashing`, a crescent (`slash1..4`) lies in the swing plane in front of them at ~30% of the swing (Slash1 tilted down from the right, Slash2 from the left), sweeps, grows and fades. Drawn with SurfaceGuis (a particle's in-plane rotation can't be pinned). Spellblades use the caster's style and glow; plain weapons are steel. Your own arc follows the server state, so it lands one round-trip after the predicted animation. `CANVAS_TURN` (180) flips the crescent if it ever curves toward the swinger. |

Preview any domain with the admin command `fxpreview <domain> [power] [property] [tier]` (only the caller sees the spells).

Notes:
- **Projectiles** simulate the exact server flight from the `launch` cue (velocity, gravity, homing) and burst where the server's impact cue says.
- **Budgets and LOD:**
  - FxPool caps: 160 anchors, 280 emitters, 40 beams, 40 trails, 14 lights; 12 sounds. Over the cap, an effect is skipped, never queued.
  - Mid LOD drops lights, marks and smoke; far LOD keeps only area forms.
- **Assets:** all textures and sounds are built-in `rbxasset://` content, verified in the installed Studio. Each is one line in `DomainFx`. To commission:
  - per-domain impact and cast sounds;
  - flipbook fire and lightning textures;
  - a proper rune-circle texture;
  - crack and scorch decals.

## 9. Reactions, NPC aggro, conduction, explosions, resistances (written 2026-11-02, not yet run)

### Hit reactions (`Cast/HitReactions`, called by EffectRunner for every hit; `CombatTuning.reactions`)
- **Knockdown** happens on a hit worth **30%** of MaxHealth, or on kinetic magic (momentum, seismicity, weight, pressure, crush, landslide, wave) at **P4+** dealing **12%**.
  - It applies the `knockdown` status for 1.6 s: walk 0, jump 0.
  - The target is pushed away from the attacker.
  - NPCs use PlatformStand and get up when the status ends. Players fall on their own client (status cue) and take the push (knockback cue).
  - **4 s of immunity** follow, so nobody can be stun-locked.
- **Flinch** applies to NPC rigs only. A hit worth ≥ 4% of MaxHealth tilts the torso back (Waist C0, up to 18°) for 0.3 s, and the NPC pauses.
- Damage over time never triggers either.

### NPC aggro (`NPC/NPCCombat`, driven by NPCService's damage handler; `CombatTuning.aggro`)
- **Threat** goes up 1 per point of damage taken. Guards and hunters within 40 studs add 8 when someone near them is attacked (they come to help). Threat decays 2 per second.
- **Stance** is chosen when the fight starts and re-checked below ⅓ health.
  - courage = Σ (trait − 0.5) × 2 × weight (neuroticism −0.9, pride +0.5, loyalty +0.3, ambition +0.2, agreeableness −0.2), + 0.08 per mastery tier, + (health − 0.5) × 0.5, + 0.6 for guards and hunters.
  - The NPC **fights** if courage ≥ 0.15 and it has an attack spell; otherwise it **flees**. Children and the retired always flee.
- **Fighting:** the NPC jogs to 18 studs, faces the target and casts a **real bolt** every ~2.2 s (±20%, deterministic per NPC) when it has line of sight within 45 studs.
  - The bolt is its own best branch's domain → the first valid property in `attackProperties`, validated by MagicCore against its caster profile, at power ≤ min(its cap, 5).
  - It flies through `Cast/Delivery`, is dealt by `DamageModel` (the 60% PvP cap applies), and is drawn in the NPC's Signature.
  - NPCs don't pay a reservoir; the cast interval is their limit.
- **Fleeing:** the NPC jogs 45 studs away from the attacker.
- **The fight ends** after 45 s without a hit, when threat decays, when the target leaves or dies, on a knockout, or when the NPC drops out of T0. Then the brain re-decides; safety is low, so the NPC usually shelters.

### Conduction (`Cast/Conduction`, from Impact for `charge`; `CombatTuning.conduction`)
- **Metal:** a flood fill across metal parts (Metal, DiamondPlate, CorrodedMetal, Foil) within 1.5 studs of each other, starting within 3.5 studs of the strike. It stops at 40 parts, each charged to the part budget.
  - Anyone within 3.5 studs of a charged part takes 60% × 0.85^hops.
  - Clients see an arc from the strike, through the metal, to each victim.
- **Water:** if there's water at the strike (or under anyone it hit), everyone *in* water within 10 + 2.5·(P−1) studs takes 60%, falling to 40% at the edge.
  - **That includes the caster** (half damage, counted as self-harm).
- Damage goes through DamageModel, so insulated gloves and chain mail matter.

### Explosions (`Cast/Explosion`, from Impact and Thermal heat/ignite; `CombatTuning.explosion`)
- **When:** harmful Thermal/Kinetic/Energetic spells of the burst, zone, pillar, ritual or projectile form at **P3+**.
- **Loose parts:** unanchored, server-owned parts ≤ 12 studs within the blast get an outward velocity (70 × falloff, ≤ 160).
- **Breakables:** at **P5+**, anchored parts of models tagged `Decor`, `Breakable` or `Rubble` lose their welds, fly, and are cleaned up after 20 s (tag `BlastDebris`).
- **Never touched:** structures (`Structure` tag) still go through `damageStructures`. Characters aren't moved here; HitReactions handles them.
- At most 60 parts per blast, charged to `EffectBudget.takeParts`.

### Resistances (`Cast/Resistances`; DamageModel uses it for every hit)

| Source | From |
|---|---|
| innate | NPCs only: each domain with affinity > 0.35 resists itself, at `(a − 0.35) × 0.45`, ≤ 30%. Traits shift keys: neuroticism makes mind easier to hurt; patience resists mind and time; conscientiousness resists curses; pride resists emotion; compassion makes essence easier. Cached per NPC per magical chapter. |
| ward | statuses with a `resist` table: every **Ward** resists **all** magic by `0.06 + 0.025 × P` (≤ 35%), on top of its absorb |
| gear | `Data/Gear` items (apron, chain mail, oilskin, insulated gloves, helm, charms…) through `Gear_<slot>` attributes. NPCs wear their occupation's set; players get gear with the `gear` admin command until an inventory exists. |
| manual | `Resist_<key>` attributes (admin `resist`) |

Keys can be a domain, a property or `all`. The applied value is the domain average + the property + all, summed over sources and clamped to −50% … +80%.

### HUD status bar (`HudController.buildStatuses`)
- Chips sit above the reservoir. Each shows **▼** (harmful, orange) or **▲** (helpful, blue), the status name from `Shared/Magic/Data/StatusInfo`, the seconds left (hidden in Compact) and a draining bar.
- Data comes from the replicated `Status_<id>` Humanoid attributes via `MagicStateController.statuses`.

### Crushing gravity fields (`Effects/Field`, `FieldEffects`; `CombatTuning.crush`)

- **When:** a heavy gravity field (weight or density, in a gravity branch, as an area form) cast with a harmful verb (generate, amplify). Before this change those fields only changed gravity and did no damage.
- **Damage:** everyone inside except the caster takes 15% of a full hit once a second, through DamageModel, so resistances, crits and the PvP cap apply. It falls off to the rim like other area spells.
- **Knockdown:** weight is a knockdown kind, so strong fields knock people flat.
- **The caster:** heavy and light fields no longer weigh down their caster. Inverted fields and backfires still do.

## 10. Not yet built

- Ice making surfaces slippery.
- Beam reflection.
- Status stack counts and per-status immunity (only knockdown has immunity).
- Hit-reaction VFX on the target's body.
- NPCs casting their full spell repertoire (only the attack bolt, with no reservoir).
- NPC-vs-NPC fights (NPC bolts have no source, so they don't build aggro).
- A visible gear and resistance panel.

## 11. Animations and action states (written 2026-11-03, not yet run)

**The rule:** the server decides what a body is doing, and animations only follow it.

- **Data:** `Shared/Magic/Data/CombatAnimations`.
  - Clips: BlockStart, Block, BlockHit, Equip, Hold, Slash1, Slash2, Run, Dash, CastSpell. Each has an id, priority, looping, fades, speed, `approxLength` and the markers it is expected to have.
  - States: idle, equipping, holding, charging, casting, slashing, blocking, dashing, staggered. Each lists its clips, a duration, `next`, `allows` and `interruptedBy`.
  - Per-domain speed and weight.
  - `duplicates`: any two clips sharing an id are reported at boot and by `animstate`. (Run and Slash1 used to; Run is now 136370984503271.)
  - `locomotion`: Animate set → clip. The client points the default Animate script's `walk`/`run` Animations at Run on spawn.
- **Rules:** `Shared/Magic/ActionRules` is read-only.
  - Attributes on the character model: `ActionState`, `ActionStateUntil`, `ActionStateDuration`, `ActionStateDomain`, `ActionStateVariant`, `ActionStateSeq`, `ActionReact`, `ActionReactSeq`.
  - Functions: `effective` (an expired state counts as its `next`), `allows`, `canEnter`, `clipsFor`, `playbackSpeed`.
  - `playbackSpeed` scales the clip so CastSpell's `Release` marker lands at the cast time, clamped to 0.35–2.5×.
- **Server:** `Cast/ActionState` provides `set`/`clear`/`get`/`can`/`react` and a `changed` signal.
  - Expiry runs on one 10 Hz Heartbeat loop, and only while some timed state exists.
  - Forced sets (knockdowns) ignore `interruptedBy`.
- **Players:** client `Controllers/AnimationController`.
  - Loads every clip on each spawn and preloads them through ContentProvider. A clip that fails to load is logged once and skipped; its state still works.
  - Follows `ActionStateSeq`. Other clients see the clips through normal Animator replication.
  - `predict`/`cancelPrediction` let CastClient start CastSpell when the key is pressed.
  - `marker(clip, name)` fires on the real keyframe marker, or else at the data's fraction of the clip.
- **NPCs:** NPCLOD loads the combat clips into every pooled rig and follows `ActionState.changed`.
  - Only T0 (unanchored) rigs play clips, at most 30 clip starts per second server-wide.
  - Without a CastSpell clip, casting falls back to the old ambient cast gesture.
- **Wired into existing code:**
  - CastService refuses casting while the body's state doesn't allow it (`STAGGERED`, `ACTION_LOCKED`) and sets `casting` for `castTime + delay`, at least `CastTuning.minCastAnimation`.
  - HitReactions forces `staggered` for the length of a knockdown.
  - NPCCombat sets `casting` before each bolt.
- **Admin:**
  - `anim <clip> [player]` plays a clip once through the player's own AnimationController, and the client logs `animation_played` or `animation_not_played`. `npcanim <clip> [npc]` plays one on an NPC rig.
  - `animcheck [player]` fetches every clip (KeyframeSequenceProvider) and reports its rig (R6/R15) against the avatar's, its real length and its keyframe markers.
  - `actionstate <state> [player] [seconds] [domain]` and `npcstate` force a state.
  - `animstate [radius]` lists states.
  - The flag `combat_anim_debug` shows a label over each head. It replicates to every client, so it's for Studio.
- **Spec:** `Tests/Animation.spec`.
- **Ownership:** the clips must belong to the place's owner (user or group), or they play in Studio but not in live servers.
- **Rig: R6** (`CombatAnimations.rigType`).
  - The clips are R6, so players (via Game Settings › Avatar), NPC rigs (NPCLOD, with Roblox's default R6 idle/walk/wave as ambient clips) and test dummies are R6.
  - The client logs `rig_mismatch` once when the avatar's rig differs.
  - The flinch tilts R6's RootJoint (R15: the Waist).
  - Gear attachments have the same names on both rigs.
  - `Block` (old id 128098131606169) failed to load: an ownership problem, separate from the rig. It was re-uploaded by the place owner as 111952812431898 (2026-11-03).

## 12. Guards: blocking, wards and parries (written 2026-11-03, not yet run)

**Rules and numbers:** `Shared/Magic/GuardRules`. **Server:** `Cast/Guard` (state, the meter, mitigation, projectile parries) and `Services/GuardService` (player input, reservoir drain, the meter tick).

**Controls:** equip mode with a spell attuned. Hold right mouse (gamepad L1, or the touch **Block** button) to raise a ward; release to lower it.
- Raising drops a charge. You can't cast while guarding.
- Stowing the spell lowers the ward.
- The ward is in front of the body: a slate plate for Earth, a glass film for Water, a pale shimmer for Air, and a hex force field in your Signature colours for everything else. Every client draws it from the `Guarding` attribute (`Controllers/GuardFxController`).
- Clips: BlockStart, then the Block loop. Block is now 111952812431898 (re-uploaded). If a loop clip ever fails to load, the last BlockStart pose is held instead, on players and NPCs.

**Block:** a hit from the front (within 70° of facing) loses 70% of its damage.
- That share is taken from the guard meter (capacity 0.6 × MaxHealth) and, for players, from the reservoir (0.5 per point).
- An empty meter or reservoir **breaks** the guard: a 1.5 s stagger, and no guard for 2.5 s.
- The meter refills at 25%/s once you haven't been hit for 1 s. The HUD shows a thin ⛨ meter, and "Broken" when it shattered.
- Walk speed is ×0.5 while guarding. Each block plays BlockHit and flashes the ward.

**Parry:** within 0.18 s of raising (server time, plus up to 0.12 s of the player's ping), the hit is turned away completely.
- **Projectiles** turn back at their caster (`Cast/Delivery`): they home in, get a fresh range and a new projectile id, the old bolt bursts on the ward, and a new one is cued. If it reaches the caster, the spell lands on them as a backfire does.
- NPC bolts can come back at the NPC.
- **Touch spells** stagger the attacker for 1.2 s.
- Each parry flashes the ward and shows "⛨ Parry!".
- One parry per raise. Re-raising within 0.6 s of lowering gives a block but no parry window, so spamming guard gains nothing.

**Through guards:**
- Mental and Temporal magic is **unblockable**.
- **Piercing** halves what a guard turns away.
- Damage over time and environment damage (no `from`) are never blocked.
- The reticle label says "⊘ Unblockable" or "↣ Pierces guards", and the Composer shows a "Guards" line.

**Order in Damage.apply:** quest ward → guard → hexes/wards (StatusEffects) → health. A guard never heals (it doesn't touch `Damage.heal`), so Brush with Death's "no healing" clock keeps running.

**NPCs (NPCCombat):** when its target begins a cast, a fighting NPC may raise its guard after a reaction delay and hold it for 0.9 s.
- Chance: 15% + 7% per magic tier + conscientiousness, capped at 80%.
- Delay: 0.35 s − 0.04 s per tier, at least 0.06 s. Masters therefore land parries sometimes.
- The roll is seeded.

**Admin:** `npcguard [npc] [seconds]` makes an NPC hold its guard so you can practise; `guard [player]` shows the meter and broken state.

**Spec:** `Tests/Guard.spec`.

**Limits:**
- A hit the server already applied just before your raise arrived isn't rewound. The latency allowance only extends the window after the raise.
- There's no melee yet, so "parried melee" means touch spells until prompt 6.

## 13. Spellblade melee (written 2026-11-03, not yet run)

**Data and rules:** `Shared/Magic/Data/MeleeTuning` and `Shared/Magic/Melee`. **Server:** `Services/MeleeService`.

**Controls:** equip mode with a spell attuned. **F**, gamepad **B**, or the touch **Slash** button swings the edge of the attuned spell. Left click stays cast/charge, and doesn't double as melee.
- Slash1 → Slash2 → Slash1…: a press inside the combo window (from `comboFrom` to the end of the swing + 0.3 s) continues; after that the combo restarts.
- A press too early is buffered by the client until the window opens. The server refuses early presses (`TOO_EARLY`).

**The server owns the hit:** `MeleeIntent` has no arguments, so the client never says what it hit.
- The server starts the swing's clock when the intent arrives and sweeps 3 boxes in front of the chest, turning with the body, between `hitFrom` and `hitTo`.
- Each character is hit at most once per swing, never through walls, and other players only with `pvp_enabled`.
- A swing cancelled by a block, a dash, a cast or a stagger (its action-state seq changed) lands nothing more.

**Damage:**
- `DamageModel.compute` at the swing's share (Slash1 0.45, Slash2 0.6) of the attuned spell's power, plus the weapon's flat damage, through `Damage.apply` as a **touch** from the attacker.
- Guards block it; a **parry staggers the swinger** (the prompt 5 hook). Flinches, knockdowns and damage numbers come through the normal damage hooks.
- Slash2 knocks back.
- 35% of hits carry the domain's touch, briefly and weakly: Energy burns, Earth/Water/Gravity slow, Void hexes, Time slows time, Spirit frightens.

**Cost:** 1 + 12% of the spell's reservoir cost per swing. **Finisher:** a client cast within 0.8 s of a Slash2 that landed gets ×1.2 power (`MeleeService:consumeFinisher`, read by CastService).

**XP:** a swing that hits awards practice XP to the attuned branch at 20% of a cast, under the same anti-grind rules. The blade is the spell channelled through the body, so it trains the branch, but slowly enough that it doesn't replace casting.

**Weapons** (`Melee.weaponBonus`, main hand):
- Swords, spears, daggers and axes give their reach (beyond the base 6), speed (`weapon.speed / 1.2`, clamped 0.75–1.5, times attack speed) and damage (+ attackPower).
- A focus (staff, orb, wand) gives ×1.1 spell power instead; the staff also gives its reach and speed.
- Bows give nothing.
- The server publishes the swing speed as the player attribute `MeleeSpeed`, so the client times its combo window to match.

**Feel:**
- The client predicts the clip (`predict` now takes a variant).
- The first hit gets a 0.06 s hit-stop (`AnimationController:hitStop`).
- A Signature-coloured trail runs from the palm past the fist while slashing (AttuneGlowController).

**Not yet:** NPC melee (prompt 11), and a dedicated melee damage type for the item `defense` stat.

**Spec:** `Tests/Melee.spec`.

## 14. Domain strikes: an attack for every domain (written 2026-11-03, not yet run)

**Why.** Sensing (the starting tier) allows only `sense`/`generate`, `touch`/`aura` and power 1. Six domains (Earth, Mind, Void, Space, Time, Reality) had no `harmful` property in their root branch, so they could never build a damaging spell from it. Life could only from Novice. Space and Time couldn't even `generate` (Spatial and Temporal columns are 0). Earth is in the vertical slice, so this blocked it.

**Data.** `Shared/Magic/Data/Strikes` gives every domain one strike: a root-branch property, its verbs (`generate`), point forms (touch, projectile, beam, chain, minus forms blocked for the category), and either:
- `native = "<route>"`: an existing route already makes the attack (Energy and Water: Scorch/Scald → `thermal`; Air: Thunderclap (sound) → `harm`; Gravity: Press (weight) → `harm`; Spirit: Soul Prick (essence) → `harm`); or
- `share` + `rider`: the new `strike` route.

| Domain | Strike | Property | Share | Rider |
|---|---|---|---|---|
| Earth | Stone Shot | hardness | 1.00 | 30%: slowed 1 s |
| Life | Thornlash | growth | 0.90 | 50%: slowed 1.5 s |
| Mind | Psychic Spike | perception | 0.80 | dazed 2 s (walk ×0.85, backfire ×1.5); Mental = unblockable |
| Void | Unmake | aether | 0.85 | strips the longest-lasting beneficial status |
| Space | Shear | distance | 0.90 | shoved sideways (40 studs/s) |
| Time | Hasten Decay | tempo | 0.55 | rot 3 s carrying 0.40 of a hit; Temporal = unblockable |
| Reality | Misfortune | probability | 0.85 | jinxed 4 s (+15% crit chance against them, under critMax) |

Shares are of `DamageModel.base(power)` (a plain `harm` hit is 1.0, Thermal heat 0.8). Exotic domains trade raw damage for a rider; share + DoT always lies in 0.8–1.0 (spec).

**Grammar exception.** `Compatibility.propertyVerb` lets `generate` work on `tempo` and `distance` (efficiency 0.5) while the rest of Spatial/Temporal stays closed. `Registry.verbPropertyEff[verb][property]` is now the one validity/efficiency table (MagicCore, Composer, Grimoire use it).

**Routing.** `Shared/Magic/Strike.find/routed` decide whether a recipe is a strike; the server route `{ id = "strike", strike = true }` sits right after `sense`/`store`, so it wins over `fortune` and `restore` for point forms. Behaviour changes for existing recipes: `generate probability` on a point form is now Misfortune (fortune keeps area forms and every `amplify`), and `generate growth` on a point form is now Thornlash (growth in area forms and every vitality heal stay `restore`). `MagicCore` marks strikes `harmful`, so safe zones, crime judging and NPC witnesses treat them as attacks.

**Resolver.** `Cast/Effects/Strike`: `DamageModel.hit` at the strike's share (crits, resistances, wards, guards and PvP caps apply), then the rider. Riders have diminishing returns: once one lands, the same domain's rider can't land on that target for 2× its duration (min 1.5 s); the damage still lands. Point forms only, so no structure damage, blasts or conduction. A backfire hurts the caster like Impact's.

**UI.** The Composer shows "Strike ⚔ <name> · <rider>".

**Spec:** `Tests/EarlyGame.spec` (every domain attacks at Sensing with touch and at Novice with a projectile, from the root; strikes are harmful; parity; riders exist; existing spells keep their routes; hybrids; strip and jinx).
