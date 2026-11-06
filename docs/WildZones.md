# Wild Zones

Permanent regions where the world's rules are broken. From the ideas round on 2026-11-06, chosen with "Build on wild zones for now". Stage 1, written 2026-11-06, **not yet run**.

## The zones

Each is placed once from the world seed, so it's in the same place on every server. Each also becomes a place on the map (❖) once you've uncovered that ground.

| Zone | Rule | Magic | Guards |
|---|---|---|---|
| The Drifting Vale | Gravity at 30%. Its heart hangs 44 studs up, reached across stepping stones. | Gravity ×1.4, Air ×1.2 | Gust moths |
| The Slow Wood | Everyone moves at 60%, creatures too. Your reservoir refills 3% a second. | Time ×1.4 | Mana wisps |
| The Burning Shore | The water is on fire: swimming burns. Always on a coast. | Energy ×1.4, Water ×0.6, hotter | Ember sprites |
| The Tilting Moor | Every 15 s the ground lets go for 2.5 s and you float up. | Space ×1.3, Gravity ×1.3, storm charge | Glass beetles |
| The Hushed Hollow | Magic density ×0.1: spells are thin and your reservoir barely fills. Bring a weapon. | Void ×1.5 | Gloom rats |
| The Verdant Riot | You heal 1.5% a second. Fire burns and spreads three times as fast. | Life ×1.5, Energy ×1.1, more fuel | Mud crawlers |

## Why go

- **Finding a zone** writes a journal entry.
- **Touching its heart** pays 200 XP, once per zone, ever.
- **Its harvest** gives seeded items once per real day, with a small chance of a relic.
- **Its rules favour some magic,** so a zone can be the best place to practise or fight.
- **Guards** come back 3 minutes after they're gone, and pay like any creature, with the usual anti-grind.

## How it works

| Script | Where (Explorer) | Job |
|---|---|---|
| `World/WildZones` | ReplicatedStorage › Shared | All content and numbers |
| `World/WildZoneRules` | ServerScriptService › Server | Pure decisions, specced |
| `World/WildZoneBuilder` | ServerScriptService › Server | Seeded landmarks |
| `Services/WildZoneService` | ServerScriptService › Server | Runs it all |
| `Controllers/WildZoneController` | StarterPlayerScripts › Client | The card and the tint |
| `Tests/WildZones.spec` | ServerScriptService › Server | Specs |

Touched: `WorldStateService` (a modifier can now carry `bias`, read in `castContext`), `StatusEffects` and `StatusInfo` (`zone_crawl`), `MapData` (the pin and its name), `Flags` (`wild_zones_enabled`), `Schemas` (`wildZones`, filled by reconcile, no schema bump), `Remotes` (`WildZoneState`).

- **Magic** goes through modifiers, the same ones weather events use, so casts, reservoirs and environment facts all read a zone with no zone-specific code. These never expire.
- **Gravity** is a `VectorForce` on your character, as `Cast/FieldEffects` does. It stands aside while you fly, ride or are held, because those control your height themselves.
- **The tide** runs on the synced server clock, so the client's countdown lands on the same moment as the server's force. It stops lifting you at 45 studs and leaves you weightless. There's no fall damage in the open world, so coming down doesn't hurt.
- **A Timestop** pauses a zone's rules on anyone inside it.
- **Cost:** landmarks are 15–30 parts a zone and exist only within 200 studs of the edge. Guards appear only within creature wake range. With nobody near, a zone costs a distance check per player, four times a second.
- **No client intents.** The heart is a server-side prompt, and `WildZoneState` only tells you where you are.
- **Saves:** `data.wildZones` is session-locked, so hopping servers doesn't reset a harvest.

## Admin

`wildzone list`, `wildzone goto <zone>`, `wildzone where`, `wildzone reset` (forgets your visits and harvests). The `flag` command with `wild_zones_enabled false` lifts every rule at once.

## Known gaps

- **Nothing has been played.** Every number is a first guess.
- **The ground isn't reshaped.** A zone is rules and landmarks on ordinary terrain. A valley that truly floats is stage 2.
- **Only players feel gravity.** Creatures and loose props in the Vale and Moor stay on the ground.
- **The Composer's `≈` previews don't know a zone's bias,** so a preview can read differently from what the cast does. The server's number is the real one.
- **Full bags lose a harvest,** and the day is still spent. There's no mail yet.
- **Zones can overlap a Rift portal or a shared event.** Harmless, but the rules still apply there.
- **The Slow Wood stacks with other slows and hastes,** since it's an ordinary status.

## Stage 2 and later

Reshaping the terrain in each zone; rules for creatures and loose objects; more zones, or a share of them chosen per world; quests and rumours pointing at zones; a zone's rule changing with weather or time of day.
