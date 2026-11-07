# Town repair: places recover

Fire leaves a mark, and the town deals with it. Built 2026-11-07 on "build next", not yet run. Every number is a first guess.

Specs: `Tests/TownRepair.spec`. There's no interface, in keeping with the owner's rule that systems should feel like part of the world.

## Where it lives

| What | Where |
|---|---|
| Numbers and words | `Towns/Data/Repair` |
| Decisions (pure) | `Towns/RepairRules` |
| Running it | `Services/TownRepairService` |
| Where it hears about fire | `FireSim.onCharred`, `FireSim.onBurnedOut` |

Flag: `town_repair_enabled`.

## How it works

**Burned ground.** A fire that isn't saved (a loose spell's or a Titan's) leaves grass burned bare, in 8-stud patches. Each patch grows back a quarter at a time, 10 to 20 minutes later. It only touches grass, and it goes through `TerrainBuilder.applyOp` directly so it never reaches the saved terrain. At most 150 scars at once; past that, new fires leave no mark.

**Charred buildings.** Any fire that chars part of a town is recorded, whatever started it. Up to 400 parts per server.

- **With a player near:** someone from that town walks over and works on it, playing the hammer clip and repairing one part every 5 seconds. A builder comes first, then a smith, then people with trades, then anyone. Children, the retired and guards aren't asked.
- **With nobody to see:** it still gets done, one part every 25 seconds.
- **Afterwards:** a repaired part is slightly paler than it was, so a patched building looks patched.
- **Living things** (`tree`, `hedge` and so on, by model name) aren't worked on. They grow back by themselves, one part every 150 seconds, looking as they did.

Fighting, a quest needing that NPC, or walking out of range ends the job, and someone else picks it up later.

**Saved.** Nothing. A town recovers on the server it burned on, and a restart puts it back as new.

## Admin

`townrepair status | burn | scar | heal`. `burn` chars up to 12 town parts within 30 studs of you. `scar` burns the grass around you. `heal` regrows every scar at once.

## Log lines

`town_repair_started`, `town_repaired`, `town_repair_failed`.

## Known limits

- **Collapsed buildings aren't rebuilt.** `Rubble` stays. That's a bigger job, and fire doesn't collapse anything, so loose spells can't cause it.
- **Anything outside a town** stays charred, trees included.
- **Ordinary fires** still leave their permanent saved scorch. Only unsaved fires leave a scar that heals.
- **A scar's box can turn natural bare ground to grass** when it regrows, if the box caught some.
- **A Titan's trail** is a separate unhealing edit from its fires' scars, so its road stays marked until the chunk rebuilds.
- **Repair doesn't care how a part burned.** A building in a duel gets the same treatment as one a loose spell lit.
- **A worker can stand at a bad spot:** the spot is 5 studs from the part on their side, with no check for a wall or drop. If they can't get there in 35 seconds, they work from wherever they stopped.

## Ideas for later (nothing chosen)

Rebuilding collapsed buildings, with scaffolding. Repairs using up the town's materials or depending on its prosperity. Players helping, and being remembered for it.
