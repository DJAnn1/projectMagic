# Titans

Huge bosses that cross the island, damaging what they pass, and leave a landmark where they fall. From the ideas round on 2026-11-06, chosen with "Build that next". Written 2026-11-06, **not yet run**.

## What happens

1. **A warning.** Every 2 hours one Titan, chosen by seed, is 3 minutes from wading ashore. The panel names the towns on its road, and it has a marker and a map pin that move with it.
2. **It walks** coast to coast through two towns: at least 8 minutes, and up to about 20 on a slow Titan with a long detour. Every server sends the same Titan down the same road at the same time. Each server fights its own.
3. **You stop it, or you don't.** If it reaches the far coast it walks into the sea, and fighters are paid a share.
4. **If it falls,** the first server to kill that Titan writes the fall to a world store. Every server then shows a crater, its bones and a map pin, with the top fighter's name on the bones.

| Titan | Speed | Rider | Weak to |
|---|---|---|---|
| The Ashwalker | 6.5 | Each footfall starts a real fire | Water |
| The Stonefather | 5 | Hits buildings twice as hard, over a wider area | Air |
| The Stormcrown | 7 | Calls lightning on anyone within 450 studs | Earth |

## The fight

Raw damage is slow. It has 5,000 base health, and rises with who's fighting and how strong they are, using the same scaling as Rift enemies.

- **Three weak points** move with it: two knees and a crown 33 studs above its centre, so you need range or flight. Breaking one takes 8% of its health and makes it **stumble and stop for 14 s**. Stopping it matters, because the clock is how far it walks.
- **Any status on it** takes 1.2% of its health, once per 10 s per kind of status.
- **A magic reaction beside it** takes 3% and makes it stumble for 4 s, limited by the reaction's own cooldown.
- **Its attacks are all telegraphed:** footfalls landing ahead of it, stomps at the nearest person in reach, and the Stormcrown's lightning.

## What it does to the world

Only with a player within 450 studs, so nothing dies unseen.

- **Footfalls** hurt players and NPCs and damage structures, including a town's persistent damage record.
- **Collapses are capped at 6 per Titan per server,** because rubble is physics.
- **The scorched trail** is applied directly and never saved: it's that server's, until it restarts.
- **The Ashwalker's fires** are real, and spread through `FireSim`.

## What every server keeps

`Schemas.TitanFalls`, one record per world under `scopedKey`, so a reseed starts clean.

- **First server wins.** `store:update` adds a fall only if that Titan's id isn't already there. Only the winner digs the crater, which goes through the normal terrain log, so other servers receive it.
- **At most 20 falls, oldest out.** With a Titan every 2 hours, that's at least 40 hours even if every one dies. **A faded fall's crater stays,** and only its bones and pin go.
- **Never in a town.** A fall in one is moved 25 studs past the edge, because a permanent carcass and crater couldn't be mended under streets. A fall in water uses the last dry place it stood.
- **Other servers hear** by `MessagingService` when `world_messaging` is on, and re-read every 5 minutes in case they miss it.
- **Bones** are about 20 parts, only within 500 studs of a player. Reading them gives a journal line and 60 XP, once per fall.

**A player's name is in this store.** For an erasure request, run `titan forget any <userId>` as well as `DataService.eraseUser`: the bones stay, and the name becomes "someone". See Backend.md.

## Scripts

| Script | Where (Explorer) | Job |
|---|---|---|
| `Titans/Data/Titans` | ReplicatedStorage › Shared | Kinds, schedule, rewards, numbers |
| `Titans/TitanRules` | ServerScriptService › Server | Pure decisions, specced |
| `Titans/Data/TitanBodies` | ServerScriptService › Server | Bodies, weak points, attacks |
| `Titans/TitanBuilder` | ServerScriptService › Server | The bones |
| `Services/TitanService` | ServerScriptService › Server | Runs it all |
| `Controllers/TitanController` | StarterPlayerScripts › Client | Panel, marker, recap |
| `Tests/Titans.spec` | ServerScriptService › Server | 32 specs |

Touched: `Schemas` (`TitanFalls`, and `titans` in the player save, filled by reconcile, no schema bump), `Flags` (`titans_enabled`), `Topics`, `Remotes`, `MapData` and `MapController` (pins), `WorldStateService.removePOI`.

## Rewards

The same tiers as shared events, claimed once per Titan in the session-locked save. Gold pays 800 XP, 200 coins, items, a 12% chance of each relic, and epic gear (10% legendary). Silver gets rare gear. If it walks into the sea, fighters get 30% of the XP and coins, and no items.

## Admin

- `titan start [any | kind]`: comes ashore 150 studs in front of you after 30 s, then walks away across the world.
- `titan goto`, `titan status`, `titan schedule`, `titan falls`.
- `titan win`: ends it, pays out and leaves bones.
- `titan end`: ends it with no rewards.
- `titan forget any <userId>`: takes a name off the bones.
- `titan clearfalls`: Studio only.

Studio's mock store forgets falls when you stop playing, so testing never touches live bones.

## Known gaps

- **Nothing has been played.** Every number is a first guess, and health assumes a group.
- **It doesn't really walk.** It's a rigid body carried along the road with a small bob, because animating a rig this size is a job of its own. There's no death animation either: it fades after 2 s.
- **It passes through terrain and buildings.** It's carried at ground height with no collision, and hits what's near each footfall.
- **Winning on a second server leaves no bones there.** The fall that counts is the first; a later win pays but digs nothing.
- **Guards don't fight it.** NPCs are hurt by footfalls, but only flee or react as they would to any damage.
- **Town damage is shared.** Every server a Titan passes through with a player near adds to a town's persistent damage record.
- **A low-level player can't do this alone,** and isn't meant to. They still earn a share for what they do, if they've been there long enough.
- **Map pins for a faded fall** stay on a client until it reloads the map.

## Later

A real walk cycle and a death animation; guards and mages fighting back; a town's repair after a passage; Titans drawn to whoever is casting the most; rare bosses that stop at a Wild Zone and take on its rule.
