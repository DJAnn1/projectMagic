# Sense shows the world (idea #11)

Built 2026-11-12. Sense spells used to answer in a few words ("The air feels warm"). Now a Sense spell whose property can *see* something shows it in the world, to the caster only, for a few seconds. There's no card and no popup: you see it, and the first time you see each kind you write about it in your Journal.

## What each property shows

| Kind | Properties | What you see |
|---|---|---|
| Heat | temperature, combustion | Warm bodies (people and beasts) glow orange **through walls**. Fires, lit lamps and hearths, and parts hotter than 45 °C show as orange spheres; parts at or below 0 °C show pale blue. The world dims and greys a little while it lasts. |
| Metal | magnetism, purity, density | Parts of a conducting metal (the same list Lightning Rods uses) and people wearing ≥ 2 weight of metal glow steel-white **through walls**. |
| Ley | aether, presence | The ley line's seam along the ground in its domain's colour, clipped to your reach, and a faint column at a nexus inside it. With no line near, the line says so and how rich the ambient magic is. |
| Tracks | perception, instinct, memory, age | Footprints of people and beasts from the last 90 s, alternating left and right in the direction they went, fainter the older they are. Not through walls. Your own aren't shown. |

Every other property keeps its old one-line answer. The line to the caster also says whether anything showed ("Warmth stands out around you." / "You feel for warmth, but nothing near you is warmer than the air.").

**Reach:** 24 + 6 × power studs (90 at most; a wider spell area wins). **Duration:** 6 + 1.5 × power seconds (20 at most). The centre is where the spell lands: yourself for an aura, the target point for a projectile or beam. Numbers live in `Shared/Magic/Data/SenseSight`.

## How it works

- `Cast/Effects/Sense` asks `SenseRules.kindFor(property)`. With a kind (and the flag on), `Cast/SenseSight.reveal` gathers what is really there inside the circle and sends it to the caster alone (remote `SenseReveal`). Nothing outside the radius and nothing to anyone else.
- **Tracks:** `SenseService` samples every player, every NPC rig in `workspace.NPCs` and every creature in `workspace.Creatures` once a second. A mover that has gone 2.5 studs on the ground since its last print leaves one (flying, falling and swimming leave none). Prints live 90 s on a 16-stud grid, 40 per cell at most (`SenseRules` TrackStore). NPCs simulated far away without a rig leave none.
- **Client:** `Controllers/SenseController` draws HandleAdornments, Attachments and Beams under the camera or on Terrain, never anything the server knows about, and fades them in and out. A new reveal of the same kind replaces the old one.
- **Journal:** the first time each kind shows you something, a first-person line (◉) goes into your Journal, once ever (`data.sight.noted`).
- **Composer:** a Sense spell's summary now says what it shows (`RouteSummaries` sense `byProperty`; `SpellOutcome` applies `byVerb`, then `byProperty`, then `byForm`).

Caps per reveal: 24 bodies, 40 spots, 40 metal parts, 8 ley lines, 3 nexuses, 160 prints; one `GetPartBoundsInRadius` (400 parts).

## Testing

Expected boot line: `specs 1042/1043` (6 new in `Tests/SenseSight.spec`; the one failure is the known Shine Pass "Standing room" item).

- Admin `sensesight heat` near Glenhold's townspeople and a lit hearth (`time 21` lights lamps), then `sensesight metal` by the smithy or a guard, `sensesight ley` (use `overlay ley` to stand on a line first), and `sensesight tracks` after walking around with others nearby (`sensetracks` counts prints).
- Then a real cast: compose a Sense spell with Temperature (Fire), Perception (Mind) or Aether, cast it, and read the Composer's summary first.
- `sensenotes` lists the Journal lines written; `sensenotes me clear` lets them be written again.
- Log: `sense_noticed` (first time per kind), `sense_sample_failed` (should never appear).
- Kill switch: `flag sense_sight_enabled false`.

## Unverified

- How the glows read in game (colours, transparency), and whether body boxes from `GetBoundingBox` sit right on R6 rigs and on creatures.
- Beams with `FaceCamera` along the ground for ley seams.
- Footprint height on town ground (the print is placed at root minus hip height).

## Open questions

- **Buried metal:** the world has no ore veins and nothing mines (ore only comes from containers, though the Iron Pickaxe promises veins). Metal sight shows the metal that exists. Seeded veins under the ground, shown by metal sight and dug out with Earth magic or the pickaxe, would be its own piece. Build it?
- Heat and metal show other players through walls. Fine for PvP, or should players be hidden from it?
- Should NPC mages use Sense too (a hunter reading your tracks, a guard sensing heat)?
