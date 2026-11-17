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
| 1 | Bolts leave your hand at once | (see below) | **built 2026-11-17** (boot confirmed `specs 1198/1199`) |
| 2 | **Sigils** (see "Stage 2: built") | A procedural sigil drawer: a flat Part carrying a SurfaceGui, drawn from frames, `UIStroke` rings and rotated lines, numeral and glyph labels. Each domain gets its own pattern family (below); the property tints it and adds one motif; mastery tier adds detail (rings, a rune band, numerals); the caster's hand seeds the variations. Bolts and bombs get a disc standing at the hand, area spells one at the feet, strikes one at the target, and every landing one at the impact. It grows with charge stages (snaps one size per stage) and snaps out on release. Replaces `castCircle`. Admin `sigil <domain> [tier] [size]` previews one in front of you. | **confirmed 2026-11-17** (owner: "everything looks good", after the grass fix) |
| 3 | **Staged effects** (see "Stage 3: built") | A data timeline per form × power band: `sigil`, `dome`/`sphere` (ForceField-like glass, tweened scale, allowed through the camera), `rings` (one or a stream), `rays`, `slashes` (crescent arcs round the body), `shards`, `pillar`, `flash`, `linger`, `fade`. Build beats run while casting or charging, the flash on resolve, the linger after. Projectile impacts get a target sigil plus a small dome. Ultimates (`Data/Ultimates`) get the long form: build → pause → field-wide reveal → engulf. It reuses existing pieces (`FxLayers`, `ShapeFx`) wherever they fit. | **built 2026-11-17, not yet run** |
| 4 | **Screen and world** | One flash per release: tint, brightness and bloom pulse, then a short exposure dip after big ones (`ColorCorrectionEffect`, client only), with an edge-only variant for small ones. Ultimates: sky tint or night for nearby clients (Lighting, client-side, distance-faded); Reality and Space ultimates can open a pocket void around the caster. Camera kick on release. Strong caps for others' spells and for the **Reduce motion / Reduce spell effects** settings (no full-screen flashes there; flash frequency capped for everyone). | **built 2026-11-17, not yet run** (see "Stage 4: built"; the pocket void is a near-black, drained tint, not a separate place) |
| 5 | **Held poses** | Charging holds a pose per kind (arm raised, crouched gather, arms spread, palm forward) and breaks into a short release motion on the flash (`Data/CastPoses`, ActivityPoser). Optionally use uploaded clips (see "Animation sources") instead of procedural poses. | **built 2026-11-17, not yet run** (see "Stage 5: built"; procedural, no clips uploaded) |
| 6 | **Weight and flow** | Attacker hit-stop, a small lunge within dash tolerance, directional flinches, cancel windows, input buffer, smooth turn to aim (the old stages 4 and 5). | **built 2026-11-17, not yet run** (see "Stage 6: built"; no camera turning) |
| 7 | **Showcase tool** | `moveshow <domain>` casts every spell in a domain at a dummy in turn, for recording and comparing. | **built 2026-11-17, not yet run** (see "Stage 7: built") |

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

## Stage 7: built (2026-11-17, owner: "go"), not yet run. All seven stages are now built.

- Admin `moveshow <domain> [gap 3.5] [maxPower 10] [from 1] [stop false]` (Server/Admin/Commands/Spells): spawns a 1,000,000 hp dummy 18 studs ahead and casts every example spell of the domain (`Data/SpellExamples`, weakest first, then by name; 10 to 36 per domain) at it through the real pipeline (`CastService.castAs`: knowledge, tier and caps waived), one every `gap` seconds, healing the dummy before each. The spell's number, name, power and form show over the dummy, with the refusal reason if one is refused. Cooldowns are off for you while it runs and restored after; use `cheat all on` for the reservoir. `from` starts part way down the list; `moveshow <domain> stop true` (or starting another show) ends one at its next spell. The dummy goes 2 s after the end. Real casts: everyone nearby sees them, and casting crimes still apply in towns (do it in the wilds).

**To test:** `testmage 8 all`, `cheat all on`, walk out of town, `moveshow energy`, then `moveshow time 2.5`, `moveshow earth 3 10 15`, and `moveshow earth stop true` part way.

## Stage 6: built (2026-11-17, owner: "go"); not yet run

Nothing in this stage turns the camera (owner's rule after stage 4's kick).
- **Free when the cast completes:** the client used to hold "You're still casting" until the server's `resolved`, which for a bolt comes when it LANDS (a 1.5 s flight locked the next cast for 1.5 s, though the server was free at the cast time). `CastClient.casting` now clears itself at cast time + delay (a channel keeps it). Answers are counted per spell key (`outstanding`), so a late `resolved` for an earlier cast of the same spell doesn't clear the newer one; another spell's answer no longer clears anything; the 3 s no-answer timeout skips accepted casts.
- **Input buffer** (`Data/Weight` buffer 0.3 s): a cast pressed in the last 0.3 s of the one before is kept and cast the moment you're free; in equip mode a buffered press starts the charge if the button is still down, else it's a tap.
- **Cancel window:** `Data/CombatAnimations` casting `cancelLast` (last 0.15 s: dash, block, slash), read by `ActionRules.allowsAt` on the client (dash, slash, block checks) and in the server's `ActionState.can`. Casting can now be interrupted by blocking and slashing too. The spell still goes.
- **Attacker hit-stop:** your own spell landing (not damage over time) freezes your own animation for 0.035 s + 0.15 × the share it took, at most 0.09 s (`CombatFeedback` → `AnimationController:hitStop`, injected by WorldEffectController).
- **Directional flinch:** `Client/Fx/Flinch`: a player hit by a spell tilts away from where it came from at the root joint (up to 14° at 25% of their health, 0.3 s), on every client from the hit cue, which now carries `from`. Not while down or ragdolled, not under Reduce motion. NPCs keep their server flinch.
- **Step:** your own touch spells carry you about 2 studs forward as they land (16 studs/s for 0.12 s; `Data/Weight` step, `enabled` to turn off). Not under Reduce motion.
- Spec `Tests/Weight.spec` (2).

**To test:** a slow bolt at something far: cast again as soon as the first leaves (it should go, not "still casting"); mash the cast key near the end of a cast (the next one comes out by itself); dash in the last instant of a cast; hit a dummy and feel the catch on hits; get hit from the side by a second player (you lean away); a touch spell (a small step in).

**Unverified (watch for):** the hit-stop clashing with the release follow-through; the flinch fighting the walk animation; whether the step feels good or should go (one data switch).

## Stage 5: built (2026-11-17, owner: "go"); boot confirmed `specs 1207/1208`

The cast poses (docs/CastPoses.md: a gather and a release pose per spell kind, shifted by form, legs never posed) already held a pose while charging. Stage 5 changes their timing in `Controllers/CastPoseController` (numbers in `Data/CastPoses`):
- **The hold builds:** while charging, the gather pose deepens with the charge (60% of it at the first stage, all of it at full charge, read from `ChargeStart`/`ChargeStep`), and both arms tremble when overcharged (3°, 0.12 s).
- **The release lands with the spell:** the gather is held through the whole cast and only snaps to the release in its last 0.12 s, so the thrust comes as the spell leaves (before, it peaked 30% of the way into the cast).
- **Follow-through:** after a cast or a channel the body swings 12% past the release and eases back over 0.28 s, then settles over 0.3 s. A dropped charge just lets go, with no thrust.
- Spec: `CastPoses.spec` checks the new timings (`reachAt`, `holdTo`, `tail` are gone). Players and NPC mages alike.

**To test:** `testmage 8 all`, equip-mode: hold a bolt through every stage (the pose deepens, trembles when overcharged), release (the thrust with the bolt, a beat of follow-through); a quick-mode spell with a long cast (held until the very end); drop a charge (stow: no thrust); a channel; an NPC mage in a fight.

**Unverified (watch for):** the overshoot looking like a jerk rather than weight; poses fighting the walk at low frame rates.

## Stage 4: built (2026-11-17, owner: "go next stage"); boot confirmed `specs 1207/1208`; the camera kick was turned off after the owner found it annoying

- **Data** `Shared/Magic/Data/ScreenFx`: flash (your own from power 3, others' from power 7 within 70 studs at 0.45 strength fading with distance; +0.035 brightness per power, capped at 0.35; tint 0.35; 0.05 s rise, 0.35 s fall; at least 0.6 s between flashes; a −0.12 dip for 0.6 s after your own power 8+ and every ultimate), kick (0.35° per power, max 3°, settles in 0.22 s), sky per domain for ultimates (tint, brightness, saturation, contrast; full within 80 studs, gone at 260; Void, Space and Reality drain almost to black).
- **Player** `Client/Fx/ScreenFx`: its own `SpellFlash` and `SpellSky` ColorCorrectionEffects in Lighting (they stack with weather and other effects, never overwrite them), one RenderStepped loop while anything shows, the kick bound after the camera (Camera + 2) so it never accumulates. `release`, `kick`, `ultimate`, `sky`.
- **Camera kick turned OFF 2026-11-17** (owner: "the camera movement is annoying as I keep having to readjust the camera"): turning the camera after the camera scripts drifted the view, because Roblox's camera reads its own direction back each frame. `Data/ScreenFx` `kick.enabled = false`; spells never turn the camera.
- **Wiring:** every resolve (not expired, not an ultimate's own, not a repeat channel pulse) calls `ScreenFx.release`. Your own non-bolt spells kick on resolve; your bolts kick when they leave your hand (the local shot, or a launch within 6 studs of you; a turned or bent bolt doesn't). An ultimate turns the sky from the start of its build to its end, and flashes on its reveal (`Staging.ultimate` gained a `domain`).
- **Reduce spell effects / Reduce motion:** a faint tint instead of a flash, no dip, no kick, the sky at 40%.
- Flag `screen_fx_enabled` (replicated). Spec `Tests/ScreenFx.spec` (3).

**To test:** `testmage 8 all`: cast power 3, 6 and 9 spells (bigger flash each time, a dip after 9, a small camera recoil); a bolt (the kick when it leaves your hand); stand near someone else's strong spell (a weaker flash); an ultimate in each of Energy (warm tint) and Void or Reality (the near-black drain), from close and from ~150 studs; Reduce motion on (no kick, faint tint); spam casts (no more than one flash every 0.6 s).

**Unverified (watch for):** whether the flash reads as light or as a washed-out screen; the kick fighting shift-lock or first person; how the sky drains look over the project's own Atmosphere and ColorCorrection.

## Ragdoll on knockdown (2026-11-17, owner: "ragdoll physics ... after certain spells knock a player down"); boot confirmed `specs 1204/1205`, `knockdown me 4 60` ran

- Every knockdown already goes through the `knockdown` status (HitReactions' heavy and kinetic hits; Earth, Energy and Water arts; spell struggles; admin `knockdown`). StatusEffects now calls `Server/Magic/Cast/Ragdoll.set(humanoid, down)` whenever that changes, for players, NPCs and Wildborn alike.
- **Limp:** every Motor6D except the root joint is disabled and replaced by a BallSocketConstraint at the joint's C0/C1, with cone and twist limits per joint (`CombatTuning.reactions.ragdoll`: neck 30/40, shoulders 80/60, hips 60/30, others 45/25). Each limb gets an invisible massless collider (85% of the limb) welded on, so limbs rest on the ground instead of sinking, with a NoCollisionConstraint against the torso. RequiresNeck and BreakJointsOnDeath are off while limp.
- It's done on the server, so everyone sees it. A player's own client still simulates their body and takes the knockback push, so the push throws a limp body.
- **Getting up:** the motors come back, everything added is removed, the humanoid's settings are restored, then GettingUp (StatusEffects for NPCs, the client for players). A body that dies while limp stays a ragdoll.
- Skipped: anchored bodies (far NPC rigs, stasis, dummies) and bodies with no motors (creatures).
- Admin `knockdown [player] [seconds] [launch]`: `knockdown me 4 60` throws you back and up for 4 s.
- Flag `ragdoll_enabled` (server). Spec `Tests/Ragdoll.spec` (3, on a rig it builds).

**To test:** `knockdown me 4 60`; a heavy kinetic spell (momentum or weight at power 4+) on an NPC and on a Wildborn; a second client watching you go limp; dying while down.

**Unverified (watch for):** whether the client's own simulation picks up the server's joint changes at once (if your body stays stiff for a moment, the client may need to switch the humanoid to the Physics state); joint limits looking natural on R6 (the attachment axes come from the motors' C0/C1); limbs snagging or jittering against the ground; getting up cleanly upright.

## Sustained circles (2026-11-17, owner: "I want the sustained spells to keep the circles until the spell finishes"), not yet run

Stage 3 looked good to the owner. Spells that keep going now keep their sigil until they end:
- **Lingering zones and barriers** (ShapeFx `zone` → `zoneEnd`, from spell shapes and ultimates' zone beats): a sigil 2.1 × the zone's radius holds on the spot and snaps out on `zoneEnd`.
- **Durational fields** (EffectRunner `field` → `fieldEnd`: time, gravity, water current, reality): the domain's sigil holds under the field for its duration and rides on the caster when the field follows them. The field cue now carries `caster`.
- **Channels:** cast cues carry `channeled`. On the first pulse the caster's casting disc is kept (or a new one stands at the hand) and stays up while their ActionState is `channeling`, then snaps out. Later pulses draw no new landing marks or staging beats.
- `Sigils.sustain(key, spec, position, normal, diameter, seconds, follow?)` / `Sigils.release(key, burst?)`: a held circle with a safety end. If the spell's landing mark was stamped on the same spot in the last 1.5 s, that mark is kept and grows into the held circle, so there's never a second circle beside it. `Sigils.target` now also retargets a grow-in still running.

**To test:** a zone spell (its circle stays the whole 5 s linger, then snaps out), a Time or Gravity field (the circle stays for the field's life, and moves with you if it follows you), a channelled beam held down (the disc at your hand stays until you let go, with no new marks each pulse), and a Water ultimate with a lingering beat.

## Stage 3: built (2026-11-17, owner: "everything looks good, go stage 3")

Owner's answers the same day: landing marks stay at one per landing ("a normal amount"); NPC mages' sigils are as detailed as players' (now their real tier: `NPCCombat` sets `ConjureTier` and `AttunedVerb`, AttuneGlowController passes them to Conjure; their spell cues already carried the tier).

- **Data** `Shared/Magic/Data/Stagings`: a beat list per form (all 11), each beat a kind (`dome`, `rings`, `rays`, `slashes`, `shards`, `flash`) with timing, scale (× the spell's area, or the impact radius) and a `minPower`; the ultimate sequence (pause 0.55 s, sigil 2.4 × reach, 6 build rays, dome 1.25 × reach, a ring every 0.55 s, 30 reveal shards, at least 0.6 s of build); piece sizes; caps (10 domes, 28 rings, 260 studs, inside tint 0.3, 0.1 under Reduce spell effects).
- **Player** `Client/Fx/Staging`:
  - `dome`: a ForceField-material ball centred on the ground (a dome above it), grown, held, faded. Standing inside one tints the view toward its colour (one ColorCorrectionEffect `StagingTint`, capped), because a ball isn't drawn from inside.
  - `rings`: a flat part with a SurfaceGui ring running out and fading, lifted above grass like sigils.
  - `rays`: pooled Beams from the spot, rising then fading.
  - `slashes`: SlashFx crescents round the caster.
  - `shards`: the domain's spark texture thrown out.
  - `flash`: FxLayers.flash.
- **Forms** (`SpellFx` on resolve, after the stamp, at the landing spot or round the caster for auras): burst = flash, dome (P3+), a ring, shards (P4+); zone = dome (P3+), 4 rings, rays (P5+); aura = 2 rings, slashes (P3+), dome (P5+); pillar = rays (P3+), a ring; ritual = flash, 7 rays, a big dome, 3 rings, shards; wall = a ring; summon = rays, 2 rings; touch = a slash (P4+); projectile = a ring (P4+), a dome (P6+); beam = a ring (P5+); chain = nothing extra.
- **Ultimates:** `Ultimate.resolve` sends one `shape` cue, stage `ultimate` (reveal = the first beat's hit time, length, reach, verb). `ShapeFx` plays `Staging.ultimate`: the caster's sigil spreads under it while rays rise (BUILD), they stop short of the first hit (PAUSE), then a flash, the field-sized dome held to the end and a ring stream (REVEAL, LINGER), then the sigil snaps out. The cast's own resolve cue carries `ultimate = true`, so the plain ritual staging doesn't also play.
- Flag `staging_enabled` (replicated). Spec `Tests/Stagings.spec` (3).

**To test:** `testmage 8 all`, then cast and watch: a burst at power 5 (flash, dome, ring, shards), a zone (dome, a stream of 4 rings, rays at P5+), an aura (rings round you, crescents), a pillar, a ritual, a bolt at P6+ (ring and small dome where it lands), a touch at P4+ (a slash). Walk into a big dome (the view tints toward its colour). An ultimate (a Ritual at power 8+ in a domain's own magic, e.g. Energy, with `cheat nocooldown`): the sigil spreads and rays rise, a beat of stillness, then the reveal on the first hit and the dome holding to the end. Reduce spell effects on: fewer pieces, weaker tint. `flag staging_enabled false` turns it all off.

**Unverified (watch for):** how a ForceField ball reads as glass, from outside and as you walk in; whether the inside tint feels right or too strong; beams with no texture reading as light shafts; how the beats line up with the ultimates' own ground warnings; frame cost in a crowded fight.

## Stage 2: built (2026-11-17, owner: "everything is fine go stage 2")

- **Data** `Shared/Magic/Data/Sigils`: 12 families (pattern, band, core, spin, line weight), property category → motif (8 motifs), verb → motion (spin, breathing, drawn out or in), tier → detail (ring at 1, motif at 2, band at 3, counter-turning inner ring at 5, crown at 7; Reduce spell effects caps it at 3), sizes, timings, caps (14 live, 16 pooled, 160 studs, canvas 512, brightness 2.2).
- **Drawer** `Client/Fx/Sigils`: a flat invisible Part with a SurfaceGui (FixedSize canvas, LightInfluence 0, Brightness 2.2), drawn from Frames (lines), UIStroke rings, dots and Antique-font numerals, in layers that spin at their own speeds. Each one is seeded from the caster's UserId and spell hand (`Sigils.seedFor`, a djb2 hash, the same on every client; no world seed is involved). Finished drawings go back to a pool keyed by their look. One RenderStepped loop runs while any sigil lives. API: `create`, `place`, `follow`, `target` (snap to a size), `grow`, `burst` (release), `fade` (cancel), `stamp` (where a spell lands).
- **Charging** (`Fx/Conjure`, players and NPC mages): the sigil replaces the Kenney rune discs (which stay as the fallback). It stands at the hand (both faces drawn) or lies at the feet by form, snaps one size per charge stage (`chargeStages` 0.55 / 0.8 / 1 / 1.12 of full), bursts on release and fades on cancel. New attribute `AttunedVerb` (AttunementService) sets its motion.
- **Timed casts** (`SpellFx.casting`, casts of 0.25 s or more; instants and charged releases skip it): area forms grow a sigil at the feet over the cast time (4 + 0.8 per power + 0.25 per tier studs across); bolts, beams, touch and chains get a disc standing at the palm that follows the caster. The old rune circle is the fallback. `SpellFx.casting` gained an `opts` (caster, form, verb, tier); CastClient and the `begin` cue pass it.
- **Release:** the casting sigil snaps out on `launch` (bolts, including your local bolt from stage 1) or on `resolve` (to 2.2 × the spell's area for area forms); a backfire breaks it instead.
- **Landing:** every resolve stamps a sigil on the ground at the point (2.4 × impact radius, or 2.1 × area for area forms), held 0.35 s + 0.05 per power, then faded. It's skipped when the snapped-out casting sigil already marks the spot, for expired bolts, in mid-air, and for small hits under Reduce spell effects.
- **Admin** `sigil <domain> [tier] [size] [property] [verb] [standing]`: one sigil in front of you for 6 s, then snapped out. `fxpreview` now shows sigils too.
- Flag `sigils_enabled` (replicated). Spec `Tests/Sigils.spec` (4).

**To test:** `sigil energy 8 20` then each domain (12) at tier 8, flat and with `standing true`; `sigil time 1` vs `sigil time 8` (detail); `sigil earth 5 14 hardness` (motif). Then real casts: `testmage 8 all`, a quick-mode area spell (a sigil grows at the feet, snaps out to the area), an equip-mode bolt held through all stages (the disc at the hand snaps up each stage, bursts on release, a stamp where it lands), a refused cast (it fades), and another player or NPC mage casting. `flag sigils_enabled false` brings back the old circles.

**Fix 2026-11-17 (owner: "the grass terrain obscures the sigils"):** ground sigils sat 0.06–0.08 studs up, under the grass blades. `Sigils.groundLift` now lifts them by `Terrain.GrassLength` + 0.15 on Grass / LeafyGrass (flush elsewhere), in casting, landing marks and Conjure (`Data/Sigils` `lift`). Not yet re-run.

**Unverified (watch for):** whether children of a rotated Frame turn with it inside a SurfaceGui (if not, the drawings stay still but still show); how bright Brightness 2.2 looks under the project's Bloom; the frame cost at 14 live sigils; whether thin 2–3 px lines vanish on small, far stamps; `[Sigils]` warnings in the Output.

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
