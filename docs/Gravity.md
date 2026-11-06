# Gravity powers

The owner's brief (2026-11-06): make Gravity feel powerful, scaling with skill, with flight and crushing people to death. "Time is supposed to be overpowered so don't hold back on the abilities. Same with gravity." Built 2026-11-06, not yet run. Every number is a first guess.

Data: `Shared/Magic/Data/GravityTuning`. Rules: `Shared/Magic/GravityRules`. Routes: `Data/EffectLibrary`. Resolver: `Cast/Effects/GravityPower`. Runtime: `Cast/GravityRuntime`, stepped by `Services/GravityService`. Client: `Controllers/GravityClient` (flying), `Fx/GravityFx`. Specs: `Tests/Gravity.spec`. Flag: `gravity_powers_enabled`.

## The powers

These are ordinary recipes from the grammar. Tiers are mastery in the spell's branch, 1 (Sensing) to 8 (Transcendent).

| Power | Recipe | What it does | Tier 1 to tier 8 |
|---|---|---|---|
| **Flight** (Skyward) | levitation, buoyancy, generate or amplify, aura | Fly where the camera looks. Drains reservoir per second | 16 to 110 studs/s, ceiling 8 to 500 studs, drain 8% to 0.2% of max per second (below regen at the top) |
| **Meteor Landing** | U, while flying | Dive from the air and hit everything where you land | Master+. Damage and radius grow with the height fallen, up to 2.8 hits and 42 studs |
| **Crushing Grip** (Crush) | crushing, weight, generate, amplify or bind, touch or beam | Pin one target and tighten. It ends if you lose sight of them or they get too far | 2 to 9 s. Finishes them below 0 to 30% health (from Expert) |
| **Lift and Slam** | vectoring, momentum or orientation, redirect or transfer, touch or beam | Raise a target, then drive it into the ground where you aimed, with splash | 6 to 80 studs high, thrown 0 to 100 studs |
| **Gravity Well** | attraction, weight or cohesion, generate or amplify, zone, burst or ritual | Drags everyone toward a point and crushes at the middle | 8 to 38 studs/s pull (walking is 16), 5 to 20 s |
| **Singularity** | collapse, weight or cohesion, generate or amplify, zone, burst or ritual, power 7+ | Holds up to 12 people, pulls them together, detonates after 3 s and throws them out | Blast 1.35 to 2.4 hits, plus 0.2 hits every 0.5 s |
| **Orbit Shield** | orbitcraft, weight or cohesion, generate, amplify or bind, aura | Debris circles you. Each piece stops one hostile projectile | 1 to 8 pieces, 16 to 44 s |
| **Bend Path** | vectoring, momentum or orientation, redirect or transmute, aura | Hostile projectiles curve away, or come back at the thrower | Reflect chance 0 to 80%, radius 18.5 to 36 studs |
| **Mass Shift** | weightcraft, density, amplify or reduce, aura or touch | Heavy: resist damage, ignore knockback, spells hit harder, slower. Light: faster, 2.5× jump | Heavy: 10 to 50% resist and damage. 20 to 55 s |

Plain gravity fields are stronger too: heavy ground goes from 2.2× to 6× gravity, and its crush from 15% to 55% of a hit per second.

For scale, a full hit is about 17 at power 3, 26 at power 6 and 36 at power 10, and a player has about 100 health.

Low-power spells on the collapse branch stay Gravity Wells, and a thrown crush (projectile form) stays a plain hit.

## How holding works

The server anchors the victim's root, the same way `CharacterSafety.holdArea` freezes people during a chunk rebuild, so nothing their client does can get them out. While held they have the `gravity_held` status (no casting) and the `GravityHeld` attribute (`ActionState.can` refuses dashes and attacks). A held body moved by a power is moved with `PivotTo`, about 20 times a second as other clients see it.

- **Immunity:** 1.5 s after a hold ends before another can start. That's the one thing stopping someone being held forever. Casting Crushing Grip again on the person you already hold keeps them and doesn't count as a new hold.
- **Who can be held:** only people you may harm (`Targeting.canHarm`: duels, parties, the PvP flag), checked again each tick. A quest NPC warded for someone else can't be held.
- **Already anchored things** (dummies, storm nodes) take the damage but never move.
- **Counters:** Dispel ends other people's grips, wells and shields. Guards reduce grip damage, but Crushing Grip's finishing blow ignores guards.

## Flight

Players own their characters' physics, so the client flies (a `LinearVelocity` and `AlignOrientation`, Humanoid in its Physics state) and the server checks it four times a second:

- **Drain:** from the reservoir. Empty ends it.
- **Speed and height:** speed × 1.5 + 30 studs/s, and ceiling × 1.2 + 30 studs. Three checks in a row over the limit ends flight and logs `flight_violation`.
- **Knocked out of the air:** being held, silenced or knocked down ends flight.
- **Landing:** Y, or touching down with nothing held for 0.8 s (after a 2.5 s grace from takeoff).

Space climbs and Shift sinks. Touch and gamepad players get a button panel.

## Wells and players

A well drags a player on their own client (the `gravity_pull` cue). A cheating client could ignore the drag, but not the crush, which the server applies. NPCs and loose parts are moved by the server. Singularity and Grip use real holds, so they can't be ignored.

## Also fixed

`StatusEffects` unanchored any non-player whenever a status changed, so one status would drop a shared event's static node or shard, or a practice dummy. Stasis now lets go only of what it anchored itself (`StasisAnchored`).

## Budgets

- **Holds:** at most 40 on the server.
- **Wells and singularities:** each takes a mythic field slot and an active-effect slot, and a full budget refuses before payment.
- **Well:** one area query every 0.25 s, at most 24 targets and 20 loose parts.
- **Projectiles:** one interceptor call per flight per step, looping over active shields and bends only.
- **Flight:** one check per flyer, 4 Hz, and one client ray per frame.

## Known limits and unverified behaviour

Couldn't be checked without running it:
- Anchoring and `PivotTo` on a client-owned character, while its client still runs animations.
- The Humanoid Physics state with `LinearVelocity` and `AlignOrientation` for flight: how it feels, and whether anything fights it.
- Dragging a player through client `CFrame` nudges in a well while they try to walk away.

Known gaps:
- **Crimes:** settlement law only sees the first hit of a power (the one on the resolving thread). Later hits and Meteor Landing reach `FactionService` through `TargetDamaged` but aren't judged as cast crimes.
- **Lift through ceilings:** a lifted target passes through a roof, then lands on top of it.
- **No terrain changes:** Meteor Landing and Singularity leave no craters. Collapse's "fold a landscape" is still to come.
- **Discovery:** nothing in the game tells a player these recipes exist except the Composer's own grammar and `SpellExamples`.
- **Not built:** wall-walking (Inversion's character "down"). `docs/InnateProfiles.md` §6.2's Pinnacle "vector an area" ritual.

## Testing

In Studio, F2:

```
testmage 7 gravity
cheat all
cast levitation buoyancy amplify aura 5
cast crushing weight amplify beam 7
cast attraction weight amplify zone 5
cast vectoring orientation redirect beam 5
cast collapse weight generate ritual 8
cast orbitcraft weight amplify aura 6
cast vectoring momentum redirect aura 5
cast weightcraft density amplify aura 4
gravitystate
```

`testspells 10 gravity` puts the eight strongest examples on the hotbar. Use `npcspawn`-style targets or `dummy` for something to hit. `setmastery all <tier>` shows the scaling. `flightend` brings a flyer down.
