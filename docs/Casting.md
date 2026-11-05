# Casting

How a spell goes from a hotbar press to an effect in the world.
Code: `Services/CastService.luau`, `Magic/Cast/*` (Targeting, Constructs, Effects/*), `Magic/Data/CastTuning.luau`, `Magic/Data/EffectLibrary.luau`.
Everything after the cast resolves (fields, fire, heat, statuses, interactions, budgets, backlash, VFX) is in [Runtime.md](Runtime.md).

## 1. Pipeline

The client sends `CastIntent(recipe, aimPoint, target?)`. The server recomputes everything from the player's real caster profile and from the world as it measures it. Nothing is paid until every check passes.

| # | Step | Refusal codes |
|---|---|---|
| 1 | Gates: casting enabled, data loaded, alive, not mid-cast, global cooldown (0.35 s) | `CASTING_DISABLED` `NOT_LOADED` `DEAD` `BUSY` |
| 2 | `MagicCore.validateRecipe` with the real caster | MagicCore codes (`BRANCH_LOCKED`, `POWER_OVER_CAP`, …) |
| 3 | Per-recipe cooldown | `ON_COOLDOWN` (+ `cooldownUntil`) |
| 4 | Aim: range ×1.1 + 6 studs; target within area + 12 studs of the aim; line of sight from the head (aura and ritual skip it) | `OUT_OF_RANGE` `NO_LINE_OF_SIGHT` |
| 5 | Route → resolver (§2) | |
| 6 | Measure the world: `castContext` at the resolver's `measure` point (Tsunami: the open sea) | `ENVIRONMENT_BLOCKED` |
| 7 | `computeStats` with that context; EnvironmentRules can block | `ENVIRONMENT_BLOCKED` (+ rule id in `detail`) |
| 8 | Verb requirement (Target/Source: a character or a surface; Stored: a held charge); heavy budget (≤ 2 effects of P8+ per server); enough HP for a Vital price | `NO_TARGET` `NOTHING_STORED` `WORLD_STRAINED` `TOO_WEAK` |
| 9 | **Pay:** `Reservoir.trySpend` with `Seed.random(worldSeed, "player:<id>", "cast", castCounter)`; Vital HP; backlash damage; burnout and lockouts | `INSUFFICIENT_RESERVOIR` `BURNED_OUT` `DOMAIN_LOCKED` |
| 10 | Commit: cooldown = castTime + delay + cooldown; settlement law (`judgeCast`); CastResult `accepted` | |
| 11 | After castTime (+ the Delayed modifier): interrupted if the caster died or respawned. Backfire roll (same seeded Random); resolver; echoes; channel pulses | |
| 12 | Magic pressure, EventDirector relief, practice XP, discovery log, spellbook cast count, observation XP (≤ 60 studs), survival facts; CastResult `resolved` | |

The cast counter is saved (`data.stats.casts`), so the seeded rolls never repeat across sessions.

**Under real danger** (challenge XP, challenge feats for breakthroughs) means the caster is overdrawn after paying, at or below 35% health, or inside an active world event.

## 2. Routes and resolvers

Routes live in `Magic/Data/EffectLibrary.luau`: about 40 of them, tried in order, first match wins, `manifest` last.
- Each route names a resolver in `Magic/Cast/Effects/` and passes it params.
- Every domain's example spells and the effect each reaches are in `Shared/Magic/Data/SpellExamples.luau`, checked by `Tests/Cast.spec`.
- Use the console `route <branch> <property> <verb> <form> <power>` to see where any recipe goes.

The full effect catalogue, interaction table and worked walkthroughs are in Runtime.md §2, §4 and §6.

New refusal codes since the first version:
- `SILENCED` (Silence status);
- `BAD_AIM` (an aim point more than 40 studs under the surface);
- `WORLD_STRAINED` from resolver prechecks (field and light budgets), checked **before payment**.

## 3. Budgets
The full table is in Runtime.md §3 (`CastTuning.budget`, enforced by `Magic/Cast/EffectBudget`). In brief:
- 2 heavy effects at a time;
- 4 fields (2 mythic);
- 600 part-touches/s and 80 terrain ops/s, server-wide;
- 40 dynamic lights;
- cues fanned out by distance (near / mid / far).

## 4. Admin
- Runtime: `effects`, `budget`, `clearfx [radius]`, `route <recipe>` (Runtime.md §7).
- `castinfo [player]`: reservoir, busy time, cooldowns, stored charges, heavy budget.
- `refill [player]`: full reservoir; clears strain, burnout, lockouts and cooldowns.

## 5. Known gaps
- **Mutation rolls** are logged (`mutation_rolled`) but do nothing yet.
- ~~Channeling is fixed-length~~: hold-to-channel and release now exist (§8).
- **No client VFX** for `spell`/`quake`/`tsunami` cues yet: WorldEffectController only applies knockback. There is no cast bar for long cast times either.
- **Status effects:** Mental, Spiritual, Temporal and Metaphysical spells go to Manifest (a marker only).
- **NPC casters** need the same pipeline without a Player. The resolvers already take characters, but CastService assumes a Player for payment and messages.

## 6. Equip mode: attuning a spell (written 2026-11-03, not yet run)

**Setting:** `castMode` in `Shared/UI/Settings`: **Equip** (default) or **Quick** (the old behaviour, where a hotbar key casts at once).

**Controls in equip mode:**

| Input | Keyboard and mouse | Gamepad | Touch |
|---|---|---|---|
| Attune a spell | Its hotbar key (1–8) | D-pad picks a slot, L2 attunes it | Tap the slot |
| Cast | Left click | R2 (attunes the selected slot when nothing is held) | The HUD's **Cast** button |
| Swap | Another key, or the mouse wheel (it doesn't zoom while attuned) | D-pad while attuned | Tap another slot |
| Stow | The same key again, or Q | L2 on the held slot | The HUD's **Stow** button |

**While a spell is attuned:**
- The character plays Equip, then loops Hold, and returns to Hold after every cast.
- The character turns to face the aim (AutoRotate off, a smooth turn each frame) and doesn't turn while knocked down or seated.
- The cursor becomes the shift-lock crosshair.
- Walk speed is ×`CastTuning.attunedWalkMult` (0.85), through `StatusEffects.setWalkMultiplier`, which stacks with statuses.
- The HUD outlines the slot and marks it ✋.
- Every client draws a hand glow in the caster's Signature colours (`Controllers/AttuneGlowController`, local only, at most 24 glows, only within 150 studs).

**Server (`Services/AttunementService`):**
- `AttuneSpell(slot)` (slot 0 stows) takes the key from the player's own saved hotbar and spellbook.
- It refuses `QUICK_MODE`, `TOO_FAST` (`attuneSwapCooldown` 0.25 s, on top of the remote's rate limit), `DEAD`, `BUSY` (the action state doesn't allow `equip`: mid-cast, knocked down, dashing), `EMPTY_SLOT` and `NO_SUCH_SPELL`.
- It sets `AttunedDomain`/`AttunedForm` on the character and the `equipping` action state. When any action ends at `idle`, an attuned body goes back to `holding`.
- Death, respawn and leaving clear it.
- CastService refuses a CastIntent in equip mode unless it's the attuned spell (`NOT_ATTUNED`). Scroll casts (`castFromItem`) and admin `castAs` are exempt.
- A player who switches to Quick while attuned is stowed, by the client and on the server's next cast.

**Client (`CastClient`):** attuning is predicted (the attuned value and the Equip clip) and reverted when `AttuneSpell` refuses. A newer request makes an older answer void.

**Not yet:**
- Right-click (and gamepad LB) block: prompt 5.
- Form-aware reticles: prompt 3.
- A touch Block button.

## 7. Aim, reticles and soft lock-on (written 2026-11-03, not yet run)

**One set of aim maths:** `Shared/Magic/Aim`, used by the server (CastService's range and sight checks, Cast/Delivery's flights, Cast/Targeting's line of sight and chain hops) and the client (AimController, ReticleController).
- `CombatTuning.projectile/beam/touch/chain` and `CastTuning.rangeTolerance/rangeSlack/losTolerance/selfCentred/noLineOfSight` now read their values from `Aim.tuning`. Change them there.
- **Origin:** the muzzle, 1.5 studs above the HumanoidRootPart.
  - Range is measured from it, projectiles launch from it and beams start at it.
  - The server used to measure range from the root; the difference is 1.5 studs, vertical.
  - The animated hand isn't used, because the server can't see animation poses. The hand glow is cosmetic.
  - Line of sight still starts at the head (`Aim.eye`).

**AimController (client):**
- A camera ray through the mouse (keyboard) or the screen centre (gamepad, touch).
- `sample()` casts fresh when a cast is sent; `current()` is refreshed at 30 Hz for the reticle and for turning to face the aim.
- **Soft lock-on:**
  - Keyboard: hold Left Alt or the middle mouse button. Gamepad: R3 toggles it.
  - It picks the living character nearest the cursor within 18% of the screen height and 220 studs.
  - While locked, the aim is the target's chest and the cast names the target.
  - It breaks on death, beyond 300 studs, or after 1 s out of sight.
  - The server re-validates everything as before (`targetSlack`, range, sight).

**ReticleController (client), while a spell is attuned and Settings › Aim guide is On:**

| Forms | Reticle |
|---|---|
| projectile | The dotted ballistic path (the same launch velocity and gravity as Delivery) to where it would hit (NPCs included), with a ring the size of the hit sphere. It just ends where the flight would fizzle. |
| beam | A line from the muzzle to the aim, faded past max range. |
| chain | The line to the first target, then ghost dots to the next hops (nearest characters within `Aim.chainJump`, up to `maxTargets`, at most 4), each outlined. There's no sight check per hop, so it's an estimate. |
| touch | The wedge (reach, ±`coneDegrees`) on the ground in front of you. |
| burst, zone, pillar, summon, ritual | A ring of the spell's area at the aim point. Each dot drops onto the terrain, so it follows slopes. |
| wall | A line across the aim, the wall's full length. |
| aura | A ring of the area around you. |

- **States:** in range and in sight, the dots use your Signature colour. Otherwise they use the danger/warn colour, plus a label by the cursor ("✕ Out of range", "◌ No line of sight"). A soft-locked target shows a ◎ marker and its name.
- **Budget:** one reticle; at most 64 pooled dots (anchored, non-colliding, `CanQuery = false`) in `workspace.AimReticle`, moved with one `BulkMoveTo`; recomputed at 20 Hz, about 40 short rays per tick at most. The spell's preview is cached for 1 s per key.
- **Spec:** `Tests/Aim.spec`.

## 8. Hold to charge, hold to channel (written 2026-11-03, not yet run)

**Data and maths:** `Shared/Magic/Data/ChargeTuning` and `Shared/Magic/Charge`, used by the server (which applies them) and the client (which predicts and shows them).

**Equip mode only.** Quick mode casts exactly as before (the same as the Charged stage, with no tap penalty), so its balance doesn't change.

**Stages.** A spell's step is `max(castTime, 0.35 s)`.

| Stage | Hold | Power | Other effects |
|---|---|---|---|
| · Quick | under 1 step | ×0.75 | Waits half its cast time, minus what was held |
| ◆ Charged | 1 step | ×1 | Exactly today's cast. After release, only the 0.15 s release motion remains. |
| ◆◆ Full | 2 steps | ×1.25 | Area ×1.15, projectile speed ×1.1, chain +1 target |
| ⚠ Overcharged | 3 steps | ×1.5 | Area ×1.3, speed ×1.2, +1 target, cost ×1.5, backfire +0.12. A backfire goes through BacklashService as usual. |

- Which forms take area, speed or targets is set in `formScales`.
- Spells slower than 3 s (rituals, quakes) don't charge; their cast time already is the wind-up. Channelled spells don't charge either.

**Wire protocol:**
- `CastHold("begin")` is a reliable event, rate 6 burst / 4 per s. It starts a charge of the attuned spell, timed on the server's clock.
- Begin is refused (with a CastResult refused, so the client drops its prediction) when the spell is silenced, staggered, busy, inside the global cooldown, or **on cooldown**. That last check stops a charge being built during a cooldown and released the instant it ends.
- The release is the normal `CastIntent`. The server takes the charge first, so a refused release also ends it. It counts `held = clamp(now − begin, 0, maxHold)`, applies `Charge.apply` after the item modifiers, and reports `charge = <stage id>` in CastResult "accepted".
- A release without a begin is a tap.
- `CastHold("cancel")` drops a charge: no cost, no cooldown.
- A charge nobody releases within `maxHold + 1 s` fizzles on the server.
- A knockdown (`staggered`) or a dash cancels the charge.
- A begin/cancel loop gains nothing: cooldowns only start on a committed cast, and begin is refused during them.

**While charging:**
- The `charging` action state freezes CastSpell at its Release pose (`holdAt`); the release resumes the clip from that pose (AnimationController and NPCLOD).
- Walk speed is ×0.6.
- The character carries `ChargeStart`/`ChargeStep` attributes. Every client works the stage out from the server clock: the glow brightens, a hum rises in pitch, and at overcharge the hand glow shakes and the sparks crackle.
- The HUD cast bar fills over the whole hold, with a tick per stage and the stage's glyph and name.
- The aim guide grows with the stage.
- The client releases on its own at `maxHold`.

**Channelled spells** (the `channeled` modifier):
- Press casts; holding keeps pulsing (the `channeling` state, a Hold loop).
- Releasing (`CastHold("release")`, which in quick mode means lifting the slot key) ends it early, as do running dry and `maxChannelTime`.
- While held, the client sends `ChannelAim` (unreliable, 10 Hz). Pulses without a target sweep toward it at up to 90°/s, never beyond the spell's range.

**NPCs (NPCCombat):** before each bolt, an NPC telegraphs with the `charging` pose for its stage's hold, then fires at that stage's power and speed.
- The stage comes from a seeded roll: 10% Quick; Full at 20% + 6% per mastery tier; the rest Charged. NPCs never overcharge.
- A knockdown during the wind-up drops the bolt.

**Spec:** `Tests/Charge.spec`.
