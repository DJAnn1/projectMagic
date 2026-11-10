# Cast poses

The owner asked for this on 2026-11-10: "the different types of spells should have different animations". Built 2026-11-10, not yet run.

## What it does

Before this, every spell played the one `CastSpell` clip. Now the body casts according to what the spell does: the same kinds the Composer tags and Read the cast uses.

| Kind | While charging (gather) | When cast (release) |
|---|---|---|
| attack | arm drawn back, body turned, off hand aiming, a tense tremor | a hard forward thrust |
| heal | both hands cupped in front, breathing | lifted and offered |
| protect | arms crossed in front, braced | palms pushed out |
| boost | hands low and open | flung up |
| control | both arms out, straining | the grip closes, leaning in |
| move | arm wound out to the side, leaning | swept across |
| shape the land | bent low, both hands toward the ground | a heavy push down |
| sense | a hand at the temple, head turning as if listening | the palm sweeps outward |
| utility | a plain raised hand | a reach forward |
| nothing | a limp, uncertain gesture | barely more |

The form changes the pose further:
- **Overhead** (burst, summon): the casting arm, or both arms for two-handed kinds, is raised 65° higher.
- **Ground** (aura, wall, zone, pillar, ritual): the arms reach 40° lower and the body leans toward the ground.
- **Hand** (touch, projectile, beam, chain): as written.

Charging eases the gather pose in. Casting blends gather into release over the first 30%, holds to 70%, then lets go. A channelled spell holds the release pose. The legs are never posed, so you can walk while charging. For the same reason nothing crouches, because a lowered torso on straight legs would sink them into the ground; low and heavy is shown with a lean.

NPC mages cast the same way during their wind-up and bolt.

## How

- `Shared/Magic/Data/CastPoses`: two poses per kind, in the ActivityPoses format, plus the modes and the timing.
- `Client/Controllers/CastPoseController`: tracks player characters and NPC rigs (tag `NpcConjuring`, kept 6 s after). It reads `ActionState` and `AttunedKind`/`AttunedForm` (remembered for NPCs, whose attributes clear as the bolt flies) and poses within 120 studs.
- `Client/Fx/ActivityPoser`, extended:
  - `setPose`/`release` with an owner, so a cast pose wins over an activity pose on the same body;
  - **replace** mode, which overrides the clip's arms, neck and torso (blended by weight) instead of adding to them, so the pose doesn't stack on `CastSpell`'s own raised arm;
  - one shared pose object per body, and a once-per-frame step per body, so ActivityController and CastPoseController can both drive the poser.
- Flag: `cast_poses_enabled` (replicated; off plays only `CastSpell`).
- Spec: `Tests/CastPoses.spec` (5).

## Uploaded clips instead (not done)

These poses are procedural and need no assets. If the owner animates a clip per kind (R6, owned by the place's owner), the plan is to add an optional `clip` per kind in `Data/CastPoses`. AnimationController would then play it in place of `CastSpell` for charging and casting, and CastPoseController would skip that kind.

## Test

1. Ready an attack (a Fire bolt), hold to charge, then release: drawn back, then thrust.
2. A Life heal: cupped hands, lifted on release. A ward: crossed arms, pushed out.
3. A burst (overhead) and a zone (ground) of the same kind: arms raised, and arms low with a lean.
4. Walk while charging: the legs keep walking and nothing sinks.
5. `npcfight` an NPC mage: its wind-up and bolt should use the attack pose.
6. An NPC doing an activity (forging) that's then pulled into a fight: the cast pose should take over and the activity pose come back after.
7. `flag cast_poses_enabled false`: everything plays only `CastSpell`.

## Unverified

- How each pose looks on a real R6 body, including angles that may need tuning.
- Replace mode over the `Hold`/`CastSpell` clips: no popping as the weight eases in and out.
- Two controllers stepping the same poser in one frame.
