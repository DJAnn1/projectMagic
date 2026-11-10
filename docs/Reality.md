# Reality powers

The owner's brief (2026-11-09): "make reality more powerful and have many more utilities like the recent changes to gravity and time." Built 2026-11-09, not yet run. Every number is a first guess.

Data: `Shared/Magic/Data/RealityTuning`. Rules: `Shared/Magic/RealityRules`. Routes: `Shared/Magic/Data/EffectLibrary`. Resolver: `Cast/Effects/RealityPower`. Runtime: `Cast/RealityRuntime`, stepped by `Services/RealityService`. Client: `Fx/RealityFx`. Specs: `Tests/Reality.spec`. Flag: `reality_powers_enabled`.

No keys, no panel and no remote: every power is an ordinary cast.

## The powers

These are ordinary recipes from the grammar, on branches that already existed. Tiers are mastery in the spell's branch, 1 (Sensing) to 8 (Transcendent).

| Power | Recipe | What it does | Tier 1 to tier 8 |
|---|---|---|---|
| **Favor** | fortune (or fatebending), probability, amplify, aura | Your hits crit more (past the usual cap), some direct hits on you graze off, you backfire less (×0.4) | +5% to +35% crit, 0 to 25% graze, 15 to 50 s |
| **Doom** | fatebending, probability, reduce, touch, projectile, beam or chain | Their luck turns: hits on them crit more, their direct hits sometimes miss, they backfire more (×2) | +8% to +40% crit, 5 to 40% miss, 5 to 15 s |
| **Certainty** | fatebending, probability, bind, touch or beam | Your next hits on them are certain to crit | 1 to 6 hits, within 15 s |
| **Twist of Fate** | fatebending, probability, transmute, aura | Charges: a direct blow on you is cancelled, and a share of it lands on whoever dealt it | 1 to 5 charges, 25% to 150% sent back, 15 to 60 s |
| **Conjure** | conjuration, substance, generate | Solid matter from nothing, by form: **touch** a step under your feet (stand on air), **beam** a bridge to where you aim, **wall** a wall, **pillar** a pillar (under your feet, it carries you up), **zone, burst or ritual** a bastion (a ring of walls with a roof) | Lasts 8 to 60 s. Bridge 20 to 150 studs, wall 10×8 to 40×24, pillar 6 to 40 high, bastion radius 6 to 20. 4 shapes per caster |
| **Cage** | conjuration, substance, bind, touch, projectile, beam or chain | A solid box around a target | 2 to 10 s |
| **Unmake** | unmaking, substance, reduce, any form | Walls, doors, crates and cover in reach stop existing for a while. People it reaches lose helpful statuses (wards first) and take a hit | 4 to 40 parts, 4 to 25 s, 0.6 to 1.7 hits, 1 to 4 statuses stripped |
| **Undying** | conjuration or unmaking, persistence, bind, aura | Nothing can take you below 1 health | 2 to 8 s, cooldown 90 to 20 s |
| **Fray** | substantiation (and below), persistence, reduce, touch, projectile or beam | They take more damage | ×1.1 to ×1.75, 5 to 15 s |
| **Polymorph** | polymorphy, identity, transmute, touch, projectile, beam or chain | They become a small creature: no casting, no attacks or dashes, slower. With nobody there, it changes what things are made of, as Transmute always did | 2 to 8 s, then 4 s before it can land again |
| **Exchange** | lawcraft (and below), identity, transfer, touch, beam or chain | You and the target swap health percentages. Refused if you'd gain nothing. Never kills | Cooldown 90 to 20 s |
| **Edicts** | edict, law, zone, burst, aura or ritual; the verb picks the law | **reduce: Hush**, nobody you could harm may cast. **amplify: Sanctuary**, nobody inside takes harm except from you. **bind: Severance**, hostile projectiles stop existing. **transmute: Reversal**, harm on you and your allies heals instead | Radius 10 to 40, 6 to 24 s, Reversal heals 50% to 120%. One edict per caster; an aura follows you |
| **Worldlaw** | worldlaw, law, ritual, power 9+, same verbs | An edict over a region | Radius 150 to 400 studs, 90 s to 10 min. One on the server at a time; 15 min per caster |

The existing spells stay where they were: Slick Edict (polymorphy, law, transmute), Unweave (substantiation, substance, reduce), Raw Reality's plain Fortune (generate), Misfortune (the strike), and an edict's `generate` (the old reality field).

## How it fits in

- **Damage:** `Damage.interceptor` is chained, not replaced. Reality goes first (Sanctuary, Reversal, Twist, graze, Doom's miss, Fray), then Time (Last Moment, wounds, Future Sight), then Reality's Undying caps what's left. `RealityService` depends on `TimeService` and `GravityService` so the chain is built in that order.
- **Direct blows only:** Twist, graze and Doom's miss answer only hits with a direction (`info.from`), never burning, poison or damage over time. Sanctuary and Reversal cover everything except overdraw.
- **Crits:** `DamageModel.critBonus` adds Favor's and Doom's bonus, which also lifts the cap. A bonus of 1 is certain (Certainty). `RealityRules.critChance` is the one formula.
- **Projectiles:** Severance hooks `Delivery.interceptor` ahead of Gravity's, with a new action, `erase`: the flight ends in the air with no splash.
- **Statuses are the truth:** each personal effect has a status (`reality_favored`, `reality_doomed`, `reality_sealed`, `reality_fated`, `reality_undying`, `reality_frayed`, `reality_polymorphed`). Dispel and Cleanse remove the status, and the effect ends with it. A Time recall doesn't bring a polymorph back.
- **Polymorph:** the body's parts and face turn invisible on the server and a small welded creature appears; `Polymorphed` on the model stops attacks and dashes (`ActionState.can`) and NPC fighting (`NPCCombat`).
- **Who can be targeted:** `Targeting.canHarm`, as for Time and Gravity.

## Unmake's guardrails

Every change goes in a ledger and is put back on expiry, on Dispel and at server shutdown (`BindToClose`). It never touches:
- characters, Terrain, anything tagged `Protected` or `NoMagicEdit` (or inside something tagged so), effect parts, already invisible parts, or anything larger than 200 studs across;
- a part someone is standing on;
- floors: flat parts (under 2.5 thick, 30+ square studs) at or below the spell's height.

Unlike the old reality field, it does touch buildings: that's how you open a wall. An unanchored part is held in place while it's gone. At most 300 parts are unmade on a server.

## Budgets

- **Edicts:** at most 8 on the server plus one Worldlaw. Hush checks at most 40 people (60 for a Worldlaw) every 0.5 s. Sanctuary, Reversal and Severance cost one distance check per edict per hit or flight step, and nothing at all with no edict running.
- **Conjured matter:** every part is charged to `EffectBudget.takeParts`; 4 shapes per caster, the oldest goes.
- **Personal effects:** one table lookup per hit for people with nothing active.

## Known limits and unverified behaviour

Couldn't be checked without running it:
- Hiding a player's body by setting transparency on the server, and the welded creature, while their client animates them.
- Lifting yourself onto a pillar with `PivotTo` on a client-owned character.
- How the edict boundary and shells look.

Known gaps:
- **A wall that comes back with someone inside it** pushes them out with physics, or traps them. Not handled.
- **Doors:** a door opened or closed while unmade gets its old state back when it returns.
- **Crimes:** like Time and Gravity, later hits (a Twist's return, an Exchange) aren't judged as cast crimes; damage still reaches `FactionService`.
- **Not built:** the Convergence resource and Paradox (`docs/InnateProfiles.md` §6.3), Seams, anchored edicts that outlast a server.
- **Audio:** there are no Reality sounds yet.

## Testing

In Studio, F2:

```
testmage 7 reality
cheat all
cast fortune probability amplify aura 5
cast fatebending probability reduce beam 6
cast fatebending probability bind touch 6
cast fatebending probability transmute aura 6
cast conjuration substance generate beam 6
cast conjuration substance generate zone 6
cast conjuration substance bind projectile 6
cast unmaking substance reduce burst 6
cast conjuration persistence bind aura 6
cast polymorphy identity transmute beam 6
cast lawcraft identity transfer beam 5
cast edict law amplify zone 7
cast worldlaw law reduce ritual 10
realitystate
```

Use an NPC or `creature spawn` for a target (a dummy is anchored). For Exchange, take some damage first. For Unmake, stand next to a house wall. For Reversal and Sanctuary, stand in the edict and let something hit you.
