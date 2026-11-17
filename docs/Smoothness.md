# Smoothness: making casting feel like a showcase

Asked 2026-11-17: "see how smooth the gameplay is with the animations then make a plan to replicate it". The reference is an elemental showcase video (`elemental_showcase.mkv` in the repo root, untracked; 18:55). The plan was first written blind, from the title only. It was **redone the same day around what the video actually shows** (owner: "redo the plan around that, make sure you really understand the visuals"). We copy the *feel* and the techniques, never that game's moves, sigil designs or look.

## What the video shows (studied at 3 fps, 2026-11-17)

Seven segments were sampled evenly (1:00–1:42 Fire, 5:38–5:50 Darkness, 6:44–6:56 Light, 7:40–7:55 Eclipse, 14:52–15:02 Time, 17:24–17:40 Reality), plus 100 scene frames across the whole video.

### Beat by beat

| Time | Move | What happens, in order |
|---|---|---|
| 1:03.3–1:06.7 | Fire, tap bolt | The arm goes up and a thin white ring arcs round the shoulder (1:03.3). A star flare blooms at the palm (1:04.7). About 1.3 s after the press the ball leaves (1:05.3): a small, fast orange ball with a short flame tail. It bursts small at range and leaves a smoke wisp. |
| 1:07.7–1:11.7 | Fire, held bolt | A star flare at the hand (1:07.7), then a **golden rune disc stands in front of the hand and grows for about 3 s** (1:08–1:10.3). On release (1:10.7) it fans out **5 orange streaks**. Each one lands on a **golden rune disc marking the spot**, then a fire pillar and a translucent orange dome rise there (1:11.3). |
| 1:20 | Fire, second | A tall translucent orange column at the target. |
| 1:22–1:26 | Fire, third | A glowing lava-crack pattern spreads out as a dome around the player (1:22). A yellow orb surrounds them (1:23). **White crescent slashes whirl round the body** (1:23.5–1:24). A **molten sphere expands past the camera, filling the screen** (1:24.5), then fades (1:25.5). |
| 1:29.5–1:41.5 | Fire, fourth (ultimate) | The arms go up and a **small golden swirl sigil at the feet grows** (1:29.5–1:31.5) as **rays shoot up** (1:31). A red edge flash (1:32), then a **red sphere bursts** (1:33). **About 2 s of quiet** follow (1:33.5–1:35). Then a **field-wide lava-crack pattern lights up all at once** (1:35.5–1:37), red ring arcs sweep across it (1:37–1:37.5), and **molten gold floods everything under a red-tinted sky** for 3+ s (1:38–1:41.5). |
| 5:41–5:45 | Darkness, first | Crouch, arms pulled in. A **navy cracked-web sigil appears at the feet** (5:41.3) and grows over about 2.7 s while the pose is held. Then the pose breaks into a lunge (5:44.3), a **pale mist shockwave sweeps across the ground** and a violet light column rises. Gone by 5:45.3. |
| 5:48–5:49.7 | Darkness, second | A small dark sigil appears at the target spot, then a violet orb rises from it. |
| 6:44.3 | Light, first | **Horizontal light lines streak across the screen**, then a vertical beam line. |
| 6:45.7–6:49 | Light, second | A small gold sigil (a star centre in a web) at the feet (6:45.7). It **snaps out to about 20× its size** (6:46) as **god rays** shoot up. It's held 2 s, flashes white and collapses (6:48.7). **The scene then looks darker for a moment** (6:49–6:50.3), like an exposure dip. |
| 6:51.7–6:53 | Light, second again | Sigil, then a **glass sphere bursts** with streaks (6:52.7). |
| 6:55–6:56 | Light, third | A **star glint at a distant target**, then a sigil ring there and a light pillar bursting up. |
| 7:42.3–7:48.7 | Eclipse, second (tap) | A white flash with a **star burst and black crescent painted on the ground**. Then a **zone of about 6 s: thick white rings born at the feet, rippling outward one after another**, inside a faint glass dome. It ends with a white sphere pop. |
| 7:50.7–7:53.3 | Eclipse, second (hold) | Flash. A field-sized sigil (outer rune band, star, crescent) is drawn. A **white flash, then a black sphere collapses inward and explodes outward** with black shards and **black arcs sweeping past the camera**. Clear by 7:53.7. |
| 14:52–14:56 | Time, third (Time Bomb) | A **vertical clock-rune disc stands in front of the hand**, turning, with green nodes (14:52–14:54). Lightning crackles round its rim (14:54). It **bursts into a white sphere with green shards** (14:54.7), then a **huge clock face with Roman numerals sweeps out across the ground** (14:55–14:56). |
| 14:57.7–15:01.7 | Time, third + E | The same disc and burst, then a spiky white ring shoots out. A clock ring at the feet, a **small clock disc appears at the enemy, and a white slash crosses to it**. |
| 17:24.5–17:39 | Reality, third | Green laser lines cross the screen. A **cut to black** (17:26–17:30.5): the player stands in a **void with a starry gradient sky, drifting white shards and horizontal ring slashes** (17:31–17:36). Then a **return to the world in a burst of white flakes** (17:37–17:39). |

Coloured bars and RGB smears at cuts (1:27, 5:45.7, 7:49, 14:56, 17:39) are the video editor's transitions, not gameplay. The big "First Skill" captions are editing too.

### The visual language behind it

1. **Sigils carry everything.** Almost every move draws a crisp, bright, flat pattern: cracks, a web, a clock, a sun or star. Each element has its own family. It's **vector-clean, not a particle smudge**, and emissive enough that bloom makes it glow.
2. **Sigils are placed by what the move does:** at the feet (area), standing in front of the hand (bolts, bombs), or at the target spot (ranged strikes and every bolt's landing).
3. **Sigils grow on a curve:** small, then a snap to full size (Light snaps out to 20× in one frame), or a steady grow while held (Fire hold, Darkness). Full size ranges from body size to the whole field.
4. **Volumes, not sprites:** translucent glass-like domes and spheres with bright edges. They expand **through the camera**, so the screen fills with the element's colour for a beat.
5. **Rings:** thick white rings travelling along the ground, either one shockwave or a stream of pulses for a lingering zone.
6. **God rays:** light shafts beaming up from a sigil.
7. **One flash per release:** white or tinted, sometimes just at the screen edges, then a short darkening after big ones.
8. **The rhythm:** build (0.5–3 s, growing) → (for ultimates) a pause → release flash → expanding volume → linger (1–6 s) → a quick fade. Nothing just pops in and out.
9. **The world changes for ultimates:** a red sky, night with stars, a pocket void.
10. **Bodies barely animate.** The poses are simple and held: arm up, crouch, arms spread. The pose **holds through the build and breaks on release**. Smoothness comes from the effects' timing, not from detailed clips.
11. **Few particles, big shapes:** most frames read as 2–4 large clean shapes with gradients, plus a few streaks and shards.

## What we have, against that (2026-11-17)

| Video | projectMagic today |
|---|---|
| Crisp per-element sigils | `FxLayers.castCircle`: one rotating Kenney `magic_0x` particle (the same circle for every domain, just tinted), at about the spell radius |
| Placement at feet, hand or target | Only at the feet (cast circle); impacts get a burst plus `groundMark` (scorch, crack, puddle, frost) |
| Growth with the hold | The charge glow grows (`AttuneGlowController`, `Fx/Conjure`); the circle doesn't |
| Glass domes through the camera | Neon/Ball anchors in a few looks; zones linger 5 s (shapes) with no visible volume |
| Ring streams | `FxLayers.shockwave`, one flat particle ring |
| God rays, flashes, exposure dip | Not there (backlash and Time have a ColorCorrection; nothing generic) |
| World changes for ultimates | Not there (stage 5 ultimates use `ShapeFx` warns and rains) |
| Held pose, break on release | `charging` freezes CastSpell at Release, which is already the right idea; poses per kind from CastPoses |
| Bolt from the hand at once | **Stage 1 (built)** |

## The plan (redone 2026-11-17)

Every stage is client-side visuals only. The server's cues already say when a spell begins, charges, launches and lands, and the effects hang off those beats. **The flash always lands on the server's resolve**, so no effect promises a hit before it happens. Everything is data-driven, and a caster's sigil details are seeded from their spell hand (`SpellHand`, `Seed.random(worldSeed, "player:<id>", "hand")`), so every mage's circles are their own.

| # | Stage | What it does | State |
|---|---|---|---|
| 1 | Bolts leave your hand at once | (see below) | **built 2026-11-17, not yet run** |
| 2 | **Sigils** | A procedural sigil drawer: a flat Part carrying a SurfaceGui, drawn from frames, `UIStroke` rings and rotated lines, numeral and glyph labels. Each domain gets its own pattern family (below); the property tints it and adds one motif; mastery tier adds detail (rings, a rune band, numerals); the caster's hand seeds the variations. Bolts and bombs get a disc standing at the hand, area spells one at the feet, strikes one at the target, and every landing one at the impact. It grows with charge stages (snaps one size per stage) and snaps out on release. Replaces `castCircle`. Admin `sigil <domain> [tier] [size]` previews one in front of you. | planned |
| 3 | **Staged effects** | A data timeline per form × power band: `sigil`, `dome`/`sphere` (ForceField-like glass, tweened scale, allowed through the camera), `rings` (one or a stream), `rays`, `slashes` (crescent arcs round the body), `shards`, `pillar`, `flash`, `linger`, `fade`. Build beats run while casting or charging, the flash on resolve, the linger after. Projectile impacts get a target sigil plus a small dome. Ultimates (`Data/Ultimates`) get the long form: build → pause → field-wide reveal → engulf. It reuses existing pieces (`FxLayers`, `ShapeFx`) wherever they fit. | planned |
| 4 | **Screen and world** | One flash per release: tint, brightness and bloom pulse, then a short exposure dip after big ones (`ColorCorrectionEffect`, client only), with an edge-only variant for small ones. Ultimates: sky tint or night for nearby clients (Lighting, client-side, distance-faded); Reality and Space ultimates can open a pocket void around the caster. Camera kick on release. Strong caps for others' spells and for the **Reduce motion / Reduce spell effects** settings (no full-screen flashes there; flash frequency capped for everyone). | planned |
| 5 | **Held poses** | Charging holds a pose per kind (arm raised, crouched gather, arms spread, palm forward) and breaks into a short release motion on the flash (`Data/CastPoses`, ActivityPoser). Optionally use uploaded clips (see "Animation sources") instead of procedural poses. | planned |
| 6 | **Weight and flow** | Attacker hit-stop, a small lunge within dash tolerance, directional flinches, cancel windows, input buffer, smooth turn to aim (the old stages 4 and 5). | planned |
| 7 | **Showcase tool** | `moveshow <domain>` casts every spell in a domain at a dummy in turn, for recording and comparing. | planned |

**Recommended order:** 2, then 3, then 4. These three are where the video's look comes from. Then 5, 6, 7.

### Sigil families (our own designs, drawn procedurally)

| Domain | Pattern family |
|---|---|
| Energy | branching fork-lightning lattice; fire properties turn it into glowing ember cracks |
| Earth | hex stone plates with fault lines, a heavy outer band |
| Water | interfering ripple rings and curling wave arcs |
| Air | spirals and feathered streak lines that turn |
| Life | a petal and vine rosette that unfurls |
| Mind | nested rotating polygons round an iris |
| Spirit | a glyph band with spokes and flame-wisp tips |
| Void | a hairline cracked web round a black core |
| Space | star points joined by constellation lines, orbit ellipses |
| Time | a dial with ticks and numerals, hands that sweep |
| Gravity | concentric rings that squeeze inward, a warped grid |
| Reality | a shifting tessellation that re-tiles while you watch |

Verb adds motion (amplify pushes outward, reduce draws inward, redirect spins, bind locks rings together, transmute re-tiles). Power and tier add size and layers.

### Risks
- **SurfaceGui cost:** each one is a render surface. Cap high-detail sigils at about 10 on screen and fall back to a single textured particle past 120 studs. Pool and reuse sigil Parts.
- **Bystanders' screens:** someone else's dome filling your camera is honest (it's really there), but its opacity is capped while your camera is inside it, and flashes from others are weaker.
- **Photosensitivity:** cap flashes at one per 0.6 s on any client, and turn off full-screen flashes under Reduce spell effects.
- **Sigils on slopes:** a flat Part clips into hills (the video has the same). Accept it, or tilt the Part to the ground normal (`FxLayers.ground` already samples it).
- **Copying:** keep our sigil designs our own (table above). Don't reuse the video's star-and-crescent, clock-face or lava-crack drawings line for line.
- **World over game:** sigils, domes and sky changes are things that are really there in the world, and nearby NPCs already notice big spells (Noticing). No captions, labels or UI flourishes.

### Unverified (Roblox behaviour to check when building)
- `SurfaceGui.Brightness` above 1 with `LightInfluence = 0` glowing under the project's Bloom.
- How many SurfaceGuis can animate at once before the frame rate drops.
- `Rotation` on frames inside a SurfaceGui staying crisp when the Part is scaled.
- A ForceField-material sphere reading as glass from inside.

## Stage 1: built

- `Shared/Magic/ShotPlan`: the bolt's speed, gravity, homing, look, worked out as the server does (charge stage speed, `Cast/Shapes.before` lob/homing, the route's `flight` tune, `Delivery.plan`'s `max(g, 20)`). Copies `homingTurn` and `maxLifetime` from server-only `CombatTuning` (a spec checks they still match).
- `Client/Fx/LocalShots.fire`: when the cast completes on the client (`castTime + delay` after the press), a bolt flies from the palm of the right arm toward the aim (a picked target's body, like the server's `currentPoint`).
- `SpellFx.launch`: the server's `launch` for your cast is handed to the oldest waiting local bolt of the same domain (`adopt`). The server path is replayed by the local bolt's age (so it never steps back), then the shown gap closes over 0.18 s. A local bolt that reaches something (spherecast, colliding parts only, water ignored, own body excluded) parks there and waits up to 0.9 s for the server's impact. The server's impact still decides where it bursts and whom it hit.
- Never launched: a refused cast (`LocalShots.drop` from `CastClient.clearPrediction`), a rolled backfire (`resolve` with `backfire` and no `projectileId`), or nothing within `0.6 s + 3 x ping` (max 2 s): it fades quietly, no burst.
- Other players see exactly what they saw before. Echoes, splits, reflections and bends are drawn from the server's cues as before.
- Flag `local_shots_enabled` (replicated). Spec `Tests/ShotPlan.spec` (4).

**To test:** Studio, File › Studio Settings › Network › Incoming Replication Lag 0.15. Cast a Fire bolt (Kindle) at a dummy: the bolt should leave the hand when the cast finishes, with no second bolt and no jump at the start. Then an Earth bolt (it lobs), a charged release (faster), a homing bolt on a target, a bolt into a wall at point blank, and a cast refused for range. With `flag local_shots_enabled false` the old behaviour returns. A second client should see no change.

**Unverified:** how the blend reads at real ping; whether the right arm's palm is where the cast pose's hand is at release (a left-handed pose would need the left arm); spherecasts against T1 NPC bodies.

## Animation sources (for stage 5)

A clip only plays in live servers if the place's owner (your account or group) owns it. So the useful free finds are **clips-only models** (KeyframeSequences, no scripts) that you open in the Animation Editor and publish under your own account. Found 2026-11-17 in the Creator Store (Toolbox → Models), listed with no price:

- **R6 Fireball Magic Spell Animation Pack x24** (Lukami_th, 139756676371748): 12 spells × standing/walking: MageStance, FireballCharge, FireballBlast, PalmBolt, ArcaneVolley, MeteorCall, RuneCircle, HealAlly, HealPulse, ArcaneWard, DispelSweep, ManaFocus. The walking set is upper body only. Best fit.
- **R6 Battlegrounds Combat Animation Pack** (Lukami_th, 132799339291286): stance, 4-hit M1 chain, 4 dashes, StompSlam, guard break.
- **R6 Character Animation Pack Movement Combat** (Lukami_th, 130499235842441): idle, walk, run, jump, fall, land, hit react, block, punches.
- **R6 Parkour Animation Pack** (frchrono, 135084202024038): 54 clips incl. 10 dashes, rolls, slides (has 1 script: read it before inserting).
- Free sample (30 clips, no spells) of BeanyStudios' R6/R15 pack on itch.io (DevForum post 4990876).

Paid, if those aren't enough: BuiltByBit "Magic Pack - 89 Animations" (R6+R15).
