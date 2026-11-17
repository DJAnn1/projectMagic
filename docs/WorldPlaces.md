# World Places: dungeons, ruins and places worth finding

Plan only, written 2026-11-17 on the owner's "make the world more interesting with bigger dungeons and more spots in the world such as buildings with cool findings and enemies. Make a plan for this". Nothing is built yet.

## 1. Audit: what the world has today

- **Most places are invisible.** `POIRules` places 64 points of interest, but apart from settlements they're dwell circles in `POIService`: stand there long enough and you get a primer, insight or catalyst. Nothing is built at 3 academies, 6 hermit towers, 5 ruined libraries, 8 mines, 2 vents, 9 shrines or the **10 "Dungeon" POIs**, which say "encounters: future" in World.md §6.
- **Rumours point at nothing.** `RumorRules.POI_KINDS` has `dungeon = "dungeon"`, so townspeople can send you to a dungeon that's an empty hillside. This is the first thing to fix.
- **The only real dungeon is temporary.** Rifts are seeded, last 10 minutes, have 3 rooms and about 110 parts, and are built in a pocket off the island. Their room logic (`RiftRules.classify`: clever answers from interaction tags, all 12 domains enforced by a spec) is the best thing to reuse.
- **The wilds have fighters but few places.** Wildborn haunts (up to 40) and 7 lairs are rings of standing stones, plus creature dens and game herds. None of them has a building, an inside or a findable object.
- **Containers exist only in towns.** `ContainerLoot` has household tables (bread, fish, old coins) with seeded restocks. Its own header says a loot stage "replaces them with full weighted, conditional loot tables". That stage was never built.
- **Caves exist only as terrain.** `TerrainBuilder` carves 3D-noise caves in cavern hosts (mountains, badlands, frostpeaks), with nothing in them.

So a player walking out of town crosses about 4,000 studs of land where the only things to find are enemies and dens. The parts needed to fix that are already built: the seeded POI placer, BuildingGenerator's shells, Rift room logic, Wildborn rigs and moves, the container system, rumours, the map, the Chronicle and Sense sight.

## 2. The idea: places with a past

This has to pass the design rule: part of a simulated world, not a game system laid on top of it. So **every site is generated from a seeded history, and the history decides everything else.**

```
Seed.random(worldSeed, "site:<poiId>", "history")
  -> who built it      (a culture, an academy, miners, a hermit, Wildborn, nobody)
  -> what happened     (abandoned, burned, flooded, overrun, sealed on purpose, collapsed)
  -> who's there now   (nobody, creatures, Wildborn, robbers, a ward still running, a survivor)
  -> what's left       (their belongings, their letters, what killed them, what they guarded)
```

A flooded mine has miners' tools, a foreman's ledger, water in the lower galleries and drowned lamps. A burned hermit tower has scorched treatises, a half-melted focus and, upstairs, the Wildborn the fire made. The same history feeds the loot table, the enemies, the room kinds and what townspeople say about the place. Nothing is "a dungeon level 12": it's *the old Varrow mine, where the water came up*.

**How you hear about places:** what NPCs say, Journal lines, what's visible from a distance (smoke, a tower on a ridge, a cave mouth with bones outside), Sense sight and omens. There are no map pins until you've heard of a place or seen it, no quest markers, no "Dungeon cleared!" card, no level numbers.

## 3. Three sizes of place

| Size | What it is | How many | Parts | Built when |
|---|---|---|---|---|
| **Wayside** | one structure or spot: a farmstead, a watchtower, a shipwreck, a camp, a burial mound, a collapsed bridge, a hunter's cabin, an old battlefield, a shrine stone, a cart wreck | ~70 across the island, spacing 180 | 15–60 | with its chunk, like settlement decor |
| **Site** | the existing POIs given bodies: ruined libraries, hermit towers (3–5 climbable floors), mine entrances with a first gallery, academies, domain shrines, small caves | the existing 33 + ~12 small caves | 60–200 | with its chunk (outside); inside on approach |
| **Deep place** | the 10 dungeons, made big: a surface entrance and 2–3 depths underground, 15–30 rooms | 10 (the existing dungeon POIs) | up to ~600 inside | interior only when a player is within ~120 studs of the entrance; torn down 3 min after the last player leaves |

### Deep place kinds (seeded by biome and history)

| Kind | Biomes | Inside |
|---|---|---|
| The sunken keep | swamp, forest | flooded halls, rotted floors you can fall through, a drowned lord's vault |
| The old works | mountains, badlands | mine galleries, cart rails, shafts, gas pockets that catch fire for real (FireSim) |
| The buried temple | ruinlands, desert | sealed doors, warded rooms that answer to one domain, a crypt |
| The warren | any Wildborn biome | a Wildborn den grown into a hive, with a boss of that theme at the bottom |
| The failed academy | dense magic | a mage school sealed after an accident: feral spells still roaming, broken wards, a library |
| The cistern | near old towns | water channels, a current, things that came up from the sea |
| The ice hall | frostpeaks | frozen corridors, a thaw puzzle, a figure frozen mid-cast |
| The vent forge | volcanic | heat rooms (ThermalSim), lava channels, a forge with a recipe nobody uses now |

## 4. Inside a deep place

- **Layout generator** (`Places/PlaceLayout`, pure and spec-tested): a seeded room graph. One spine from the entrance to the deepest room, side branches and one or two loops so it isn't a corridor, depths joined by stairs, shafts or a collapse. Room size, doorway width (8 studs or more, to suit both pathfinding and Wildborn) and spacing come from data.
- **Built from parts below the real terrain.** Like Rift rooms, the walls are anchored and tagged `NoMagicEdit`. Terrain over the interior is cleared the way `SettlementService.clearInterior` clears house floors. That avoids saving voxel edits for 10 dungeons, and the interior can be destroyed when nobody's near.
- **Room kinds come from Rift rooms**, rethemed to match the history: barricades (they really burn), chasms, the eye gallery (now old ward stones), the long dark (dead lamps), the vigil, the cold engine (now a broken construct). `RiftRules.classify` and its rule that every room accepts all 12 domains carry over, so any player's magic can answer any room. New kinds for this:
  - **flooded rooms**: drain, freeze, part or swim them;
  - **sealed doors**: one domain opens them cleanly, any other forces them slowly;
  - **traps**: pressure plates and rune traps, which Sense sight shows;
  - **collapse**: the room falls in behind you and you dig, blink or lift your way out.
- **Enemies.** Everything humanoid is an R6 rig (the owner's rule). There are 2–4 fights per depth:
  - Wildborn of the place's theme, using `WildbornMoves`;
  - creatures from `CreatureService`;
  - ward constructs, which are turrets, not bodies;
  - feral spells in the failed academy.
  
  The deepest room has a **keeper**: a boss built from the Wildborn boss move sets, with a name from the history ("the drowned reeve"). How strong things are depends on depth and the place's seeded danger, and is told by what you see (bones at the mouth, claw marks, how old the scorch is), not by a number.
- **Findings, which are the point:**
  - **Belongings that fit the history**, in containers and on remains: tools, coins, food, gear from new loot tables (`Places/Data/PlaceLoot`) that replace the household tables' role out here. Deeper means better, and the keeper's vault holds the best.
  - **Letters, ledgers and journals.** Seeded text from a grammar like DialogueEngine's. Some name a **real NPC in a real town** ("tell my sister in Glenhold..."). Bringing it to them is a real conversation and a memory they keep, not a quest.
  - **Spell pages** (build queue #24): a recipe you don't know, written in the dead owner's words. You learn it by casting it once.
  - **Maps and keys**: a scrawled map reveals another place on your map, and a key opens a sealed door somewhere else. These link places together.
  - **Lore hints** toward the mythic sites (libraries and shrines already grant these; deep places add a few more).
  - **Rare things**: relics and the odd legendary, in the keeper's vault only.
  - **Remains with a story**: if the Chronicle says an NPC died in the wilds, their body and belongings can be found in the place that killed them.
- **Getting there your own way.** Earth magic can dig to a lower room from the surface, Space can gate inside once you've seen it, and Void can phase a wall. Default: allowed and counted as clever, with two limits. The vault opens only for someone who has been in the keeper's room while it fought. The outer shell stops `Unmake` so the interior can't be deleted.

## 5. A world that uses its places

- **Per-server state** (the owner's rule for fallen towns): each place has `state` (`untouched`, `entered`, `cleared`, `resettled`) and a time. A cleared place stays cleared on that server. After a seeded number of real hours, something new moves in. A cleared mine might get robbers (they take coins only, per the owner) or the Wildborn of the next haunt. The history then gains a line, and what's inside changes to match.
- **Personal state** (saved, `data.places` under `WorldService:progressKey()`, added to `DataService.eraseUser`): places you've found, first clears, letters read. First clear of a deep place gives XP, a Journal line and a `DeedDone` to the Chronicle, so big clears can become legends people tell. Every server rolls loot the same way, so hopping servers to re-loot a vault gets a smaller roll (first find per player per place pays in full).
- **NPCs who go there.** Living History stage 4: now and then a town's hunters or fighters set out for a nearby place. Some come back with something and a story for evening talk. Some don't come back (rare, and only for big events, per the owner), and their remains are inside.
- **Rumours** get real targets: "the old works past the ridge, nobody's come out of there since the flood" with a direction. Places join `RumorService`'s sources. Omens can come from deep places (smoke from a shaft before something moves in).

## 6. Budget and performance

- **Parts.** Wayside places cost about 4,000 parts in total across the island, but chunk streaming means only the nearby ones exist. Sites build their interiors on approach. Deep places are capped at **3 interiors built at once per server** (a 4th waits for one to close) and about 600 parts each.
- **Enemies.** A deep place spawns a depth's enemies when someone enters that depth. They share the Wildborn alive cap, raised to fit, plus their own cap of 12 per place.
- **Building happens in Scheduler jobs** with checkpoints. Building an interior is the only heavy step, and the player hears and sees the entrance (a door unbarring, dust) while it runs.
- **Server load.** 30–60 players spread over 10 deep places and ~50 sites is fine. The risk is all 60 piling into one place: past 12 players inside, enemy counts stop growing.

## 7. Stages (each one commit, playtest between)

| # | Stage | What you'd see |
|---|---|---|
| 0 | **Site framework + histories.** `Places/PlaceHistory` (seeded histories), `Places/Data/PlaceKinds`, `Services/PlaceService` (state, streaming, caps), admin `places`, `place goto`, `placehistory`. Fix the rumour that points to an empty hillside. | Nothing new to see yet; `places` lists every place with its history. |
| 1 | **Wayside places.** ~70 small seeded spots with remains, containers and letters; `PlaceLoot` tables; a few with a camp of robbers or a creature. | Walking between towns, you keep finding things. |
| 2 | **Sites get bodies.** Libraries, hermit towers, mine entrances, shrines, academies and small caves built, with their existing grants moved onto real objects (read a treatise on a desk instead of standing in a circle). | The places NPCs already talk about are real. |
| 3 | **Deep places, structure.** Layout generator, underground interiors, room kinds from Rifts plus the new ones, streaming, the 3-at-once cap. No keeper yet. | 10 big dungeons you can explore. |
| 4 | **Deep places, life.** Enemies by depth, keepers, vaults, findings (letters to real NPCs, maps, keys, spell pages), first-clear Journal and Chronicle. | Bosses and loot worth going down for. |
| 5 | **The world uses them.** Per-server cleared/resettled, NPC expeditions, remains of the dead, rumours and omens from places. | Places change while you're away. |

Stages 1 and 2 are small and give the fastest result: the world stops being empty within a session or two. Stage 3 is the largest.

## 8. Where it lives (Explorer)

```
ServerScriptService/Server
  Places/
    PlaceHistory.luau        seeded history for any place (pure)
    PlaceLayout.luau         room graph for deep places (pure)
    PlaceBuilder.luau        parts for wayside spots, sites and interiors
    PlaceRooms.luau          room kinds (reuses Rifts/RiftRules.classify)
    Data/PlaceKinds.luau     kinds, biomes, histories, what each leaves behind
    Data/PlaceLoot.luau      loot tables keyed by history
    Data/PlaceLetters.luau   letter and ledger grammar
  Services/PlaceService.luau state, streaming, caps, first finds, admin
  World/POIRules.luau        + wayside rules, small caves
  Tests/Places.spec.luau     histories deterministic, layouts connected, every room answers 12 domains
ReplicatedStorage/Shared
  Places/Data/PlaceLooks.luau  palettes and props per culture/kind (client-safe, no secrets)
StarterPlayerScripts/Client
  Controllers/PlaceController.luau  dust, light shafts, ambience on entering a deep place
```

## 9. Risks

- **Exploits:**
  - server-hopping to re-loot (first find per player pays in full, later finds get smaller rolls);
  - teleporting or blinking into a vault (the vault needs keeper presence, checked on the server);
  - the client claiming to open containers from range (`PromptRouter` already checks reach and sight);
  - container duplication (only `InventoryService:transact`).
- **Pathfinding.** The pinned NPC pathfinding problem (sealed rooms) can hit Wildborn in interiors. Mitigation: wide doorways, flat floors, no furniture in fight rooms, and Wildborn moving straight at targets inside a room (they mostly do already).
- **Terrain.** Clearing terrain over interiors on chunk rebuilds must run after every nearby chunk build (the same bug floors had). Spells that write terrain (earthquakes, Shape Stone) could fill a corridor: walls are `NoMagicEdit` and `CharacterSafety` lifts anyone embedded.
- **Feels like a game.** Room puzzles taken straight from Rifts can read as "puzzle rooms". They have to look like the history: a burned door, a flooded hall, a ward that's still running. Flag each room kind that doesn't.
- **Scale of work.** Stage 3 alone is about the size of Rifts' stages 1 and 2 together.

## 10. Open questions

1. **Underground or above ground?** Default: deep places go down. Some buried temples and keeps could be big surface ruins instead.
2. **How hard?** Default: danger is seeded per place and readable from what you see, with no level gate. A novice can walk into the warren and die.
3. **Respawn.** Default: a cleared place stays cleared on that server until something new moves in after 4–10 real hours. Faster for wayside camps?
4. **Shared or instanced?** Default: shared and open world, so anyone can follow you in. Should a party get its own copy instead?
5. **Digging in.** Default: Earth, Space and Void can get you inside, but the vault still needs the keeper. Agree?
6. **How many?** About 70 wayside places, 45 sites and 10 deep places. More deep places (20)?
