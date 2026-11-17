# Smoothness: making casting feel like a showcase

Asked 2026-11-17 ("see how smooth the gameplay is with the animations then make a plan to replicate it", reference: a YouTube elemental showcase Claude couldn't watch, only its title). We copy the feel, never another game's moves or look.

## Gaps found (2026-11-17)

1. **Your own bolt appears late.** `SpellFx.launch` waited for the server's `launch` cue: the hand thrusts, then a round trip later (100–200 ms live) the bolt appears, at the chest.
2. **One cast clip** (`CastSpell`) plus one procedural pose per spell kind for ~200 spells.
3. **Effects aren't tied to the frame** the hand lands; they fire when the server's cue arrives.
4. **No weight on the caster:** hit-stop doesn't freeze your own clip, no lunge, no camera kick toward the move.
5. **No cancel windows:** recovery can't be cut into a dash or the next cast.

## Stages

| # | Stage | State |
|---|---|---|
| 1 | Bolts leave your hand at once | **built 2026-11-17, not yet run** |
| 2 | A motion per move: ~12 archetype timelines (anticipation, strike, follow-through, recovery), upper body only, data per route; or uploaded clips (see "Animation sources") | planned |
| 3 | Effects on the frame: Release/Impact markers drive the caster's bursts, sounds | planned |
| 4 | Weight: attacker hit-stop, small lunges within dash tolerance, camera kick, directional flinches | planned |
| 5 | Moves chain: cancel windows, input buffer, tuned fades, smooth turn to aim | planned |
| 6 | `moveshow <domain>`: casts every spell in a domain at a dummy, for recording | planned |

Recommended order after 1: 4, then 2 + 3, then 5 and 6.

## Stage 1: built

- `Shared/Magic/ShotPlan`: the bolt's speed, gravity, homing, look, worked out as the server does (charge stage speed, `Cast/Shapes.before` lob/homing, the route's `flight` tune, `Delivery.plan`'s `max(g, 20)`). Copies `homingTurn` and `maxLifetime` from server-only `CombatTuning` (a spec checks they still match).
- `Client/Fx/LocalShots.fire`: when the cast completes on the client (`castTime + delay` after the press), a bolt flies from the palm of the right arm toward the aim (a picked target's body, like the server's `currentPoint`).
- `SpellFx.launch`: the server's `launch` for your cast is handed to the oldest waiting local bolt of the same domain (`adopt`). The server path is replayed by the local bolt's age (so it never steps back), then the shown gap closes over 0.18 s. A local bolt that reaches something (spherecast, colliding parts only, water ignored, own body excluded) parks there and waits up to 0.9 s for the server's impact. The server's impact still decides where it bursts and whom it hit.
- Never launched: a refused cast (`LocalShots.drop` from `CastClient.clearPrediction`), a rolled backfire (`resolve` with `backfire` and no `projectileId`), or nothing within `0.6 s + 3 x ping` (max 2 s): it fades quietly, no burst.
- Other players see exactly what they saw before. Echoes, splits, reflections and bends are drawn from the server's cues as before.
- Flag `local_shots_enabled` (replicated). Spec `Tests/ShotPlan.spec` (4).

**To test:** Studio, File › Studio Settings › Network › Incoming Replication Lag 0.15. Cast a Fire bolt (Kindle) at a dummy: the bolt should leave the hand when the cast finishes, with no second bolt and no jump at the start. Then an Earth bolt (it lobs), a charged release (faster), a homing bolt on a target, a bolt into a wall at point blank, and a cast refused for range. With `flag local_shots_enabled false` the old behaviour returns. A second client should see no change.

**Unverified:** how the blend reads at real ping; whether the right arm's palm is where the cast pose's hand is at release (a left-handed pose would need the left arm); spherecasts against T1 NPC bodies.

## Animation sources (for stage 2)

A clip only plays in live servers if the place's owner (your account or group) owns it. So the useful free finds are **clips-only models** (KeyframeSequences, no scripts) that you open in the Animation Editor and publish under your own account. Found 2026-11-17 in the Creator Store (Toolbox → Models), listed with no price:

- **R6 Fireball Magic Spell Animation Pack x24** (Lukami_th, 139756676371748): 12 spells × standing/walking: MageStance, FireballCharge, FireballBlast, PalmBolt, ArcaneVolley, MeteorCall, RuneCircle, HealAlly, HealPulse, ArcaneWard, DispelSweep, ManaFocus. The walking set is upper body only. Best fit.
- **R6 Battlegrounds Combat Animation Pack** (Lukami_th, 132799339291286): stance, 4-hit M1 chain, 4 dashes, StompSlam, guard break.
- **R6 Character Animation Pack Movement Combat** (Lukami_th, 130499235842441): idle, walk, run, jump, fall, land, hit react, block, punches.
- **R6 Parkour Animation Pack** (frchrono, 135084202024038): 54 clips incl. 10 dashes, rolls, slides (has 1 script: read it before inserting).
- Free sample (30 clips, no spells) of BeanyStudios' R6/R15 pack on itch.io (DevForum post 4990876).

Paid, if those aren't enough: BuiltByBit "Magic Pack - 89 Animations" (R6+R15).
