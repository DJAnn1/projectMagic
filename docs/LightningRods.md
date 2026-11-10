# Lightning rods

Idea #19 from the 2026-11-07 ideas list, picked by the owner 2026-11-09. Built 2026-11-10, not yet run.

## What it does

Metal draws lightning. When a charge spell lands (projectile, burst, zone, pillar or chain), metal nearby competes with the spot it was aimed at, and the bolt goes to the strongest pull:

- **A metal part** (a lamp post, an anvil, a metal construct): the spell lands on its top with no direct target. Conduction then runs the current along the metal into anyone touching or standing next to it. A rod protects the person the bolt was aimed at, and standing against the rod is a bad idea.
- **A person wearing metal** (a guard in chain mail, a miner in a metal helm): the spell lands on them instead.

You see the bolt jump from where it was aimed to what took it. The first time your lightning bends into metal, swerves into someone in armour, or is drawn onto you by what you wear, you write about it in your Journal (☁, once per kind).

What doesn't bend:
- a projectile that struck someone directly (you hit them);
- touch, beam, aura, wall, summon and ritual spells;
- backfires;
- your own spell into your own armour.

## Numbers (`Server/Magic/Data/LightningRods`)

- **Reach:** `9 + 1.5 × (power − 1)` studs. A full storm stretches it up to +60% (WeatherFuel's `stormCharge`). The cap is 30.
- **Stay (where it was aimed):** 0.6, plus the pull of the aimed-at person's own metal.
- **Attractor:** `pull × (1 − distance / reach)`.
- **Metal part pull:** height ÷ 4, clamped to 0.4–3. Parts under 1.5 cubic studs (nails, hinges) don't count. A 6-stud lamp post pulls 1.5 and wins out to half its reach.
- **Person pull:** the summed weight of worn `metal`-tagged items ÷ 6, up to 2, and nothing under weight 2. Chain mail (weight 9) pulls 1.5.

## Code

- `Server/Magic/Cast/LightningRods`: `bend(ctx, direct)`, plus the pure helpers `radiusFor`, `partPull`, `weightPull`, `score`, and `metalWeight(model)`. Metal weight is read from NPC `Gear_<slot>` attributes, the player provider and a manual `MetalCarried` attribute.
- `CastService.strike`: calls `bend` after the flight and before the resolver. It sends a `chain` cue (a lightning arc) from the old point to the new one, moves the point and target, and passes `bentTo` and `bentOnto` on `SpellResolved`.
- `Services/LightningRodService`: reports players' worn metal (equipped items) and writes the Journal. Notes are stored in `data.weather.noted` under `rod_metal`, `rod_person` and `rod_drawn`.
- Flag: `lightning_rods_enabled`. Admin: `rods [power] [player]`. Log: `lightning_bent`.
- Spec: `Tests/LightningRods.spec` (8).

## Test

1. Stand near a lamp post in town and run `rods 4`. The post should be listed with a score above the stay value.
2. Aim a charge projectile at the ground just past the post. The bolt should jump to the post; read the Journal.
3. `gear <npc or player> body chain_mail` on a second character (or walk near a town guard: guards wear chain mail). Then cast a lightning burst at the ground beside them: it should land on them. Watch out, because hitting a guard is a crime.
4. In a `startevent tempest`, `rods` should report a longer reach.
5. `flag lightning_rods_enabled false`: bolts land where they were aimed.

## Edge cases and open questions

- A bolt drawn onto a guard counts as you hurting them, so it can be a crime. That seems right in a realistic world: casting lightning beside armoured guards is reckless. Should it be judged more leniently, as an accident?
- Not yet: NPC lightning (`NPCCombat`) isn't bent; metal Rift props are; a player can't yet raise a rod on purpose (a Metallurgy construct would, if it builds with a metal material).
- Is the reach right? At power 4 it's 13.5 studs, about a street's width.
