# Wild Zones

Permanent regions where the world's rules are broken. From the ideas round on 2026-11-06, chosen with "Build on wild zones for now".

- **Stage 1 confirmed 2026-11-06:** `specs 731/731`, six zones placed. The owner played the Vale, Hollow, Moor and Shore and said everything but the Moor seemed good. The Riot woke but wasn't entered, and the Slow Wood wasn't visited.
- **Stage 2 and the Moor fix, written 2026-11-06, not yet run:** real terrain, creatures and loose objects obeying the rules, rumours, and full bags no longer spending a harvest.

**Why the Moor did nothing:** its rule was a net lift of 10% of gravity, but a Humanoid standing on the ground pins itself there far harder than that. This is my reading of the code, not something measured; the Vale working points the same way, since low gravity shows up when you jump. Now the client knocks you into freefall with a small push at that moment, and the server holds you weightless for 2.5 s: about 40 studs up, then you fall.

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

## The ground

Terrain ops applied as each chunk builds, the same on every server and never saved, so a player's craters and edits still land on top. They only add or recolour, never lower the ground, so the generator's height stays safe to stand landmarks on.

| Zone | Ground | Features |
|---|---|---|
| The Drifting Vale | Unchanged | 7 floating rock islands with grass tops, and one holding up the heart |
| The Slow Wood | Ground | Leafy hummocks |
| The Burning Shore | Cracked lava | Basalt stacks |
| The Tilting Moor | Slate | Slate tors |
| The Hushed Hollow | Salt | Limestone stacks |
| The Verdant Riot | Leafy grass, the most flammable ground `FireSim` knows | Grassy mounds |

Paint is done in 32-stud squares, so a zone's edge is blocky up close. Each zone is at most about 350 ops, spread across the chunks it covers.

## Rumours

Ask a townsperson for rumours and they may tell you about the nearest zone you neither know nor have heard of, with a direction. It writes a journal entry and uncovers that spot on your map. Whether a person knows is seeded per person and per player (half do), so asking again changes nothing: you find out by asking someone else.

## Everything obeys

Creatures in a zone feel its gravity, crawl and healing. When the Moor lets go, creatures float up with you, and up to 30 loose objects hop. NPCs and shared-event enemies aren't affected.

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
- **The tide** runs on the synced server clock, so the client's countdown and push land on the same moment as the server's force. There's no fall damage in the open world, so coming down doesn't hurt.
- **A Timestop** pauses a zone's rules on anyone inside it.
- **Cost:** landmarks are 15–30 parts a zone and exist only within 200 studs of the edge. Guards appear only within creature wake range. With nobody near, a zone costs a distance check per player, four times a second.
- **No client intents.** The heart is a server-side prompt, and `WildZoneState` only tells you where you are.
- **Saves:** `data.wildZones` is session-locked, so hopping servers doesn't reset a harvest.

## Admin

`wildzone list`, `wildzone goto <zone>`, `wildzone where`, `wildzone reset` (forgets your visits and harvests). The `flag` command with `wild_zones_enabled false` lifts every rule at once.

## Known gaps

- **Every number is still a first guess.**
- **The Vale's islands can end a ride.** Travel measures height from the generated ground, so riding across a high island reads as flying too high. Flight has more room. Walking and jumping are fine.
- **The flag doesn't undo terrain already built.** `wild_zones_enabled` off lifts the rules and stops new chunks being shaped; built chunks stay as they are until the server restarts.
- **Moving a zone moves its terrain.** It's generated, not saved, so changing the zone list or a zone's radius reshapes it everywhere with no migration needed. Players' saved edits stay where they were.
- **The Composer's `≈` previews don't know a zone's bias,** so a preview can read differently from what the cast does. The server's number is the real one.
- **Partly full bags lose what doesn't fit.** If nothing fits, the day isn't spent. If something does, the rest is lost. There's no mail yet.
- **Zones can overlap a Rift portal or a shared event.** Harmless, but the rules still apply there.
- **The Slow Wood stacks with other slows and hastes,** since it's an ordinary status.

## Stage 3 and later

Quests pointing at zones (they need their own situations and templates); more zones, or a share of them chosen per world; a zone's rule changing with weather or time of day; lowering the ground as well as raising it, for real bowls and sinkholes.
