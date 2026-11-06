# Moments: Borrowed Power and Surge

From the ideas round on 2026-11-06, the first two the owner approved with "go". Time and Gravity are so rare that almost nobody would ever touch them, and fights had nothing that felt like a peak. Built 2026-11-06, not yet run. Every number is a first guess.

Specs: `Tests/Moments.spec`.

## Borrowed Power

A relic gives anyone one minute of a mythic domain. Rare, and meant to be remembered.

Data: `Shared/Magic/Data/BorrowedPowers`. Runtime: `Services/BorrowedPowerService`. Item effect: `borrow` in `Items/ItemUse`. Client: `Controllers/MomentsClient`. Flag: `borrowed_powers_enabled`.

| Relic | Item | Powers (keys 9, 0, -) |
|---|---|---|
| **Borrowed Time** | Stopped Clock (`time_relic`) | Stop Time, Mark Yourself (then N), Hang Your Spells (then L) |
| **Borrowed Gravity** | Weightless Stone (`gravity_relic`) | Take Flight (with Meteor dive), Crush, Gravity Well |

- **They're real spells,** through `CastService.castBorrowed`: knowledge and tier waived, counted as Grandmaster (tier 7), free, no backlash. Aim, range, line of sight, cooldowns and budgets all still apply.
- **At tier 7:** Timestop lasts 3 s, and a mark can save you from death.
- **It teaches nothing:** no XP, discoveries, or mythic notoriety. The Quiet Hand doesn't come for someone who once held a relic.
- **Afterwards:** a borrowed flight ends with the minute. A mark or stored moment you made runs its own course.
- **Other spells stay yours:** only relic powers are free.

### Where relics come from

| Source | Chance of each relic |
|---|---|
| **Your first gold in a won shared event** | One relic guaranteed, chosen by seed, once per save (`sharedEvents.firstRelic`) |
| Later gold in a won event | 6% |
| Silver in a won event | 2% |
| A successful crisis quest | 1% |

The guarantee is what gets most players the moment at least once. It's only marked as given once the item is really in your bags, so full bags don't use it up.

Admin: `give me time_relic`, `borrowed time`, `borrowed gravity`, `borrowed end`.

## Surge

Fighting fills a meter, and a full meter lets you transform.

Data: `Shared/Magic/Data/SurgeTuning`. Rules: `Shared/Magic/SurgeRules`. Runtime: `Services/SurgeService`. Client: `Controllers/MomentsClient`, `Fx/SurgeFx`. Flag: `surge_enabled`.

**The meter:** damage you deal and take. About 15–25 hits fill it at any level. No single hit gives more than 12%. Practice dummies and hurting yourself don't count. It fades after 20 s without fighting.

**K with a full meter:**

| | Tier 1 to tier 8 (your best mastery) |
|---|---|
| Lasts | 12 to 25 s |
| Your spells hit harder | +15% to +60% |
| Resist all damage | 10% to 40% |
| Spells cost | 80% to 40% |
| Also | 25% faster, 15% of your health and 40% of your reservoir back |

The domain is the one you've dealt the most damage with since your last Surge, or Energy if none. Everyone sees your outline, aura and light in that domain's colour.

**K again while surging is the finisher:** it ends the Surge with a blast around you, 1 to 3 full hits at the centre, half at the rim, radius 14 to 40 studs.

| Domain | Finisher | Rider |
|---|---|---|
| Energy | Solar Flare | burning |
| Earth | Worldbreaker | thrown |
| Water | Deluge | slowed |
| Air | Cyclone | thrown far |
| Life | Overgrowth | rooted |
| Spirit | Soulfire | hexed |
| Mind | Mindbreak | dazed |
| Void | Annihilation | silenced |
| Space | Fold | jinxed, thrown |
| Time | Last Second | time slowed |
| Gravity | Collapse | rooted, thrown |
| Reality | Unwrite | jinxed |

Letting a Surge run out gives no blast. You can't start one or fire the finisher while held or frozen, and being frozen stops its clock. Dying ends it and empties the meter. A recall won't restore it.

Admin: `surge fill`, `surge start`, `surge end`.

## Known limits

- **Griefing:** relics put Timestop and Crush in the hands of ordinary players, under the same open PvP rule as everything else.
- **Town law:** the finisher isn't a cast, so it isn't judged as a cast crime. Damage still reaches `FactionService`.
- **Meter farming:** two friends trading hits could fill it, but it only gives a short state, so this seems harmless.
- **Relic powers and the Composer:** they're panel buttons, not spellbook entries.
- **Audio:** the transformation reuses the knockdown sound. It deserves its own.
- **Gamepad:** Surge and relic powers are panel buttons, with no dedicated buttons left free.

## Testing

In Studio, F2:

```
borrowed time
borrowed end
borrowed gravity
surge fill
surge start
```

Then 9, 0 and - use the relic's powers, and K transforms and fires the finisher. To test the meter, fight a creature (`creature spawn`), not a dummy.
