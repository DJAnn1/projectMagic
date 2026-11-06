# Time powers

The owner's brief (2026-11-06): "Time is supposed to be overpowered so don't hold back on the abilities." Timelines of yourself and others, timestop, and more, scaling with skill. "Have self timeline restore everything, and let it save you from death at grandmaster." Built 2026-11-06. First run the same day: Self Timeline's recall and Timestop ran with no errors in the log; how they look hasn't been reported, and the other powers haven't been seen in a log. Every number is a first guess.

Data: `Shared/Magic/Data/TimeTuning`. Rules: `Shared/Magic/TimeRules`. Routes: `Data/EffectLibrary`. Resolver: `Cast/Effects/TimePower`. Runtime: `Cast/TimeRuntime`, stepped by `Services/TimeService`. Client: `Controllers/TimeClient`, `Fx/TimeFx`. Specs: `Tests/Time.spec`. Flag: `time_powers_enabled`.

## The powers

These are ordinary recipes from the grammar. Tiers are mastery in the spell's branch, 1 (Sensing) to 8 (Transcendent).

| Power | Recipe | What it does | Tier 1 to tier 8 |
|---|---|---|---|
| **Self Timeline** | rewind, sequence, store, aura | Mark this moment; **N** returns you to it, with an afterimage while it lasts | Mark lasts 6 to 45 s, recall cooldown 60 to 6 s |
| **Last Moment** | automatic, with a live Self Timeline | A killing blow recalls you instead | Grandmaster up. Once per 180 s (tier 7), 90 s (tier 8) |
| **Target Timeline** | rewind, sequence, bind, touch or beam | Mark someone; **L** snaps them back to that spot, stunned and hurt | 1 to 6 people, stun 0.5 to 3 s, mark 6 to 45 s |
| **Stored Moment** | rewind, sequence, bind, aura | Your projectiles hang in the air; **L** sends them all | 2 to 8 held, 4 to 20 s |
| **Timestop** | stasis, tempo, reduce or bind, zone, burst, aura or ritual, power 7+ | Everyone you can harm in the zone freezes, and every projectile in it hangs, yours too | 0.5 to 5 s, radius 20 to 90 studs, cooldown 120 to 40 s |
| **Borrowed Wound** | causality, sequence, amplify, touch or beam | Hits on them wait, then all land together, harder | 3 to 8 s, 1.1× to 2.2× |
| **Deferred Pain** | causality, sequence, reduce, aura | Hits on you wait, and you pay less of them | 3 to 8 s, 0.9× to 0.25× |
| **Future Sight** | precognition, foresight, amplify, aura or touch | See where nearby spells are aimed, and some hits miss you | 8 to 40 s, dodge 0 to 40% |
| **Time Loop** | rewind, sequence, redirect, touch or beam | They keep snapping back to where they stood, hurt and briefly stunned | 2 to 8 times, every 2 s |

Below power 7, a stasis zone stays a slow field. **Rewind Dodge** already exists as the Time dash (`Movement.dashFor`: a readied Time spell makes the dash rewind you 1 s).

**The combo:** Stored Moment, hang your spells, mark someone with Target Timeline, then press L. They snap back and the spells steer into them.

## What a recall restores

Position, health, reservoir with strain, burnout and lockouts, stamina, dash charges, statuses and spell cooldowns. What you caught since is gone, what you had is back. It also frees you from a gravity hold, and clears any wound you owed.

**Never restored:** items, coins, XP, quests, reputation, crimes. Those reach a DataStore, so rewinding them would let people duplicate things.

**The only limit on the loop** of marking at full, spending everything and recalling is the recall's own cooldown. That's the owner's decision: everything comes back.

**Refused:** during a duel (a result can't be undone), while time is stopped around you, during a Meteor dive, or with no live mark. A new body drops your mark.

## Saved from death

`Damage.interceptor` runs inside `Damage.apply`, after wards, guards and a duel's floor. If what's about to land would kill a player with a live mark at Grandmaster or above, the mark fires instead and the blow does nothing. `Damage.internal` gives overdraw backlash the same check.

**Not covered:** a Life spell's health cost, which is already refused when it would kill, and anything outside magic damage such as falling out of the world.

## Freezing

Timestop, a recall's stun and Time Loop use `GravityRuntime.hold`: the server anchors the body, which also blocks casts, dashes and attacks, and the same 1.5 s immunity applies. Timestop adds Stasis, which greys out a frozen player's screen. Clients freeze the animations of everyone in the zone but the caster.

Parties and duels hold: `Targeting.canHarm` decides who can be frozen, marked or looped.

## Budgets

- **No recording:** a mark snapshots when you make it, so nothing is recorded for people not using Time. That's why there's no ring buffer, unlike the plan in the prompt pack.
- **Flights:** one extra call per flight per step while any exist; a hanging flight does no raycasts. They count toward Delivery's 160-flight cap.
- **Timestop:** one area query every 0.25 s, at most 40 targets.
- **Damage:** one table lookup per hit for people with nothing active.
- **Afterimages:** one local copy per mark, of the body's direct parts only.

## Craters (Gravity)

Meteor Landing and Singularity now leave craters: `GravityRuntime.crater`, with numbers in `GravityTuning.crater`.

- **Permanent, on every server:** a bowl, a scorched floor and a rim of ground, saved through `TerrainDeform.commit`, like a quake's rupture. Radius 6 to 26 studs.
- **In towns, a scorch mark instead of a hole.** A permanent pit under streets and foundations couldn't be mended.
- **Not under the sea,** or low enough to flood.
- **Limits:** a repeat within the same 24-stud cell is skipped for 10 minutes, and there's a 3 s gap between craters on a server. Otherwise one player could fill the world's saved edits.

## Known limits and unverified behaviour

Couldn't be checked without running it:
- `PivotTo` on a held, client-owned character, and how a recall looks on other people's screens.
- Freezing animations with `AdjustSpeed(0)` on tracks a client didn't start.
- How a hanging projectile looks. The client redraws it as a near-still flight, with a small pop when it hangs and when it's released.

Known gaps:
- **Crimes:** Time's spells aren't "harmful" to settlement law, so freezing or looping an NPC in town isn't judged as a cast crime. Damage still reaches `FactionService`.
- **Weapons:** arrows hang and release correctly but aren't redrawn while hanging, because only spells re-cue their flight.
- **Fields and fire keep running in a Timestop,** and frozen people still take damage. Only people and projectiles stop.
- **Dispel** ends a Timestop and makes wounds land now, but doesn't remove marks or Stored Moment.
- **Audio:** there are no Time sounds yet.
- **Unhappening** (undoing a physical event) isn't built.

## Testing

In Studio, F2:

```
testmage 7 time
cheat all
cast rewind sequence store aura 5
cast rewind sequence bind beam 5
cast rewind sequence bind aura 5
cast stasis tempo reduce zone 7
cast causality sequence amplify beam 5
cast causality sequence reduce aura 5
cast precognition foresight amplify aura 5
cast rewind sequence redirect beam 5
timestate
```

`N` recalls, `L` releases. To see Last Moment: `testmage 7 time`, mark yourself, then take a killing blow from something, such as your own overdraw with `cheat none`. `testmage 6 time` should die instead. Use an NPC or `creature spawn` for a target that can move; a dummy is anchored.
