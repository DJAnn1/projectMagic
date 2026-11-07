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

**Collapsed buildings.** A town building that comes down, whatever caused it (quake, tsunami, Titan, spell), is rebuilt with its own pieces. `WorldStateService.setCollapseHook` records where every piece belongs just before it falls. After 2 minutes for the rubble to settle, it goes back up from the ground, one piece every 8 seconds with someone on it, or every 40 with nobody around, so a house takes many minutes and, with nobody there, about an hour. When the last piece is in it's checked: anything knocked out again goes back on the list. Then it's a real building again, with full integrity, and its damage comes off the town's record. Anything already charred gets repaired along with it.

**The look of it.** Scaffolding goes up around a rebuild (`Towns/Scaffold`, 6 at most at once; nothing in it collides). Pieces rise a couple of studs into place, not fly across town. Workers stand outside the footprint, which is the lot's own size from the layout (`SettlementService.lotBox`), and move round to another side every 6 pieces. Others are sent out of the footprint every 5 seconds, so nobody gets walled in.

**The people.** When a building falls, whoever lives or works there says something and goes elsewhere straight away (`NPCService.setLotDown`). People who live there go to their closest friend's house in town, or failing that the tavern, and can open that friend's door. People who work there make do at their district's usual spot. When it's rebuilt, they go home and say so. At most 3 of them speak per building.

**Damaged but standing.** A building that's been hurt but hasn't fallen regains 1 integrity every 30 seconds by itself, off the town's record as it goes.

Fighting, a quest needing that NPC, or walking out of range ends the job, and someone else picks it up later.

**Saved.** Nothing. A town recovers on the server it burned on, and a restart puts it back as new.

## Admin

`townrepair status | burn | scar | heal | collapse | rush`. `burn` chars up to 12 town parts within 30 studs of you. `scar` burns the grass around you. `heal` regrows every scar at once. `collapse` brings down the buildings within 40 studs. `rush` toggles no settling and a piece a second, to test a rebuild without waiting.

## Log lines

`town_collapse_noted`, `town_repair_started`, `town_repaired`, `town_rebuilt`, `town_repair_failed`, `collapse_hook_failed`.

## Known limits

- **A piece that's been destroyed stays missing.** Anything that fell out of the world leaves a hole in the rebuilt house.
- **Rubble is only the building's own.** A piece can settle into place on top of someone standing there, and they get pushed out by physics.
- **Buildings outside a town** aren't rebuilt.
- **Terrain isn't repaired.** A quake's ruptures and a tsunami's erosion stay, as they're saved. A rebuilt house's interior is cleared, but its yard may not match any more.
- **Anything outside a town** stays charred, trees included.
- **Ordinary fires** still leave their permanent saved scorch. Only unsaved fires leave a scar that heals.
- **A scar's box can turn natural bare ground to grass** when it regrows, if the box caught some.
- **A Titan's trail** is a separate unhealing edit from its fires' scars, so its road stays marked until the chunk rebuilds.
- **Repair doesn't care how a part burned.** A building in a duel gets the same treatment as one a loose spell lit.
- **A worker can stand at a bad spot:** the spot is 4 studs outside the building with no check for a wall or drop. If they can't get there in 35 seconds, they work from wherever they stopped.
- **Scaffolding only goes up on 6 buildings at a time.** After a big quake, the rest get rebuilt without it, and they don't gain one until they're next looked at.
- **A player can still be walled in.** Only NPCs are sent out of the footprint.
- **A district's other buildings** may still send someone towards a collapsed one: only homes and named workplaces are handled.

## Ideas for later (nothing chosen)

Repairs using up the town's materials or depending on its prosperity. Players helping, and being remembered for it.
