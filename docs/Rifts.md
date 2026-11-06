# Rifts

Seeded dungeons that open in the world. Each run takes up to 10 minutes and has one twist. Creative spell use solves the rooms, and a boss at the end drops the best loot. From the ideas round on 2026-11-06, approved with "build rifts". Stage 1 of a staged build, written 2026-11-06, **not yet run**.

## What a run is

1. **A portal opens.** Every 25 minutes, near a town chosen by seed. All servers open the same Rift at the same time without talking to each other. It's on the map (✧) and has a world marker. It stays open for 15 minutes.
2. **You step in.** The first person in starts a 10-minute clock. Anyone can follow while it runs.
3. **Three rooms**, drawn from four, each behind a locked door.
4. **The Warden**, the boss. It flinches from one seeded domain, and any status you land on it hurts it.
5. **The recap.** You get your tier and rewards, then 25 seconds to leave before you're put back at the portal.

## Rewarding creativity

This is the design's main risk: without it, Rifts become a combat grind.

- A cast that lands in the current room is sorted by `RiftRules.classify`, using its interaction tags (`InteractionMatrix.tagsFor`), the same tags quests use.
- **A clever answer** makes about 0.34 of a room's progress per cast at power 2. **Anything else** makes about 0.06, so it's roughly six times slower but never a dead end. This respects "I don't want to restrict anything for the player".
- **A plain domain strike is never clever**, whatever its tags: it's the attack you'd use on anything.
- **`Tests/Rifts.spec` enforces that every room has an approach for all 12 domains.** The whole point is that your magic, whatever it is, has an answer.
- A room counts as solved cleverly if at least half the work on it was clever. Each clever room adds 20% XP and raises the boss's gift: rare by default, epic at 2 clever rooms, and a 35% chance of legendary at 3 clever rooms with gold.

## Rooms

| Room | Kind | How it works |
|---|---|---|
| The Thornwall | barrier | Real burnable planks. Fire spells light them through FireSim and the flames spread for real, including onto you. Other approaches remove pieces directly. |
| The Drop | chasm | A bridge appears as you earn it. Getting across any other way (a blink, flight) solves it too, and counts as clever. Falling costs 10% of your health and puts you back at the room's start. |
| The Watching Gallery | eyes | Three turrets. A clever cast within 14 studs shuts an eye instantly. Or break them, slowly. |
| The Cold Engine | coils | Fill the meter while the coils discharge at you. |

## Twists

| Twist | Effect |
|---|---|
| Wildfire | Fire burns and spreads twice as fast (the real `FireSim.boost`) |
| Glass | Enemies have 60% health and deal 160% damage |
| Stubborn | Brute force at 40%, clever answers at 125% |
| Swarm | Three more enemies in every room |

## Where it lives

The inside is built at x = 6000, off the 4,096-stud island, when the first person enters, and it's destroyed afterwards. About 110 parts, plus enemies.

- No chunk is built there, because `chunksAround` clips to the island.
- Terrain changes there aren't saved, because `chunksForOp` clips too.
- No town judges you, and no NPC witnesses anything.
- Walls, floors and doors carry `NoMagicEdit`, so fields can't phase or move them.

| Script | Where (Explorer) | Job |
|---|---|---|
| `Rifts/Data/RiftData` | ReplicatedStorage › Shared | All content and numbers |
| `Rifts/RiftRules` | ServerScriptService › Server | Pure decisions, specced |
| `Rifts/Data/RiftEnemies` | ServerScriptService › Server | Riftling, eye, Warden |
| `Rifts/RiftBuilder` | ServerScriptService › Server | The parts |
| `Services/RiftService` | ServerScriptService › Server | Runs it all |
| `Controllers/RiftController` | StarterPlayerScripts › Client | Panel, marker, recap |
| `Tests/Rifts.spec` | ServerScriptService › Server | 38 specs |

Touched: `Net/Remotes`, `Core/Topics`, `Config/Flags` (`rifts_enabled`), `Persistence/Schemas` (`rifts.claimed`, filled by reconcile, no schema bump), `MapController` (the pin), `WorldStateService.edit` (a comment recording why the pocket isn't saved).

## Rules worth knowing

- **PvP stays on inside.** The owner chose no safe zones on 2026-11-06, so one player can attack another mid-puzzle.
- **No client intents.** Entering and leaving are server-side ProximityPrompts, and the server moves you. The only client remote asks for state.
- **Paid once per Rift.** `data.rifts.claimed[id]`, in the session-locked save, so hopping servers can't pay twice. Each server's run is separate, so you can play the same Rift on another server, but only the first reward counts.
- **Leaving the Rift keeps your score; leaving the server doesn't.** You're only paid if you're online at the end. Standing inside scores nothing unless you acted in the last 30 s.
- **Dying** sends you to your normal spawn. You can walk back in while the clock runs.

## Admin

- `rift open [twist]`: a portal in front of you, with its own 10-minute clock. It cancels any Rift already running.
- `rift enter`: straight inside.
- `rift solve`: opens the current room, counted as clever.
- `rift win`: ends it and pays out.
- `rift close`: ends it with no rewards.
- `rift status`, `rift schedule`.

## Known gaps

- **World-scale spells inside a Rift are unverified.** Quakes and tsunamis read generated height, which is sea floor out there. They should do little, but a quake's stress and magic pressure land on the island's nearest edge region, because region lookups clamp.
- **Full bags lose loot.** The recap says so, but there's no mail yet, the same as shared events.
- **Fire needs the `burningParts` budget.** If the server is out, a fire spell removes planks directly instead.
- **Nothing here has been played.** Every number is a first guess, and the panel's position (top right, 120 down) hasn't been seen against the rest of the HUD.

## Stage 2 and later

More rooms and twists; reactions as answers (a steam cloud solving the Gallery); a Rift pool per biome; a journal entry for clever solutions; boss variety; bigger parties scaling room puzzles, not just health; rooms that remember which approach you used last so repeating yourself earns less.
