# Procedural Settlements

Streets, lots and buildings generated from the world seed, built from Parts and WedgeParts (no assets), with terrain levelled under them.

Status (2026-11-02): Steps 1–3 are done. Every building type has a generator, and all pass `rojo build` and luau-lsp. **The new types haven't run in Studio yet.**

## 1. Pipeline

```
WorldStateService.start
  └─ POIPlacer.place
       ├─ coarse settlement pick (POIRules: flat, dry, coast, moisture; 14 best, 420+ studs apart)
       └─ SettlementSites.refine: scans the seeded height field within 96 studs for the best
          open, flat, dry centre (flatness ×4, water nearby, ore, forest)
SettlementService.init   registers the generated-ops provider with WorldStateService
SettlementService.start  SettlementLayout.generate for every settlement (Scheduler job) → summary
Chunk built   generated ops (plaza, streets, lot pads) + saved edits are applied with the chunk
ChunkBuilt    buildings whose lot centre is in that chunk → BuildingGenerator (Scheduler job)
```

**Everything is deterministic:**

- the site comes from the seed and the coarse pick;
- the layout comes from `Seed.random(worldSeed, settlementId, "settlement.layout")`;
- each building comes from `Seed.derive(worldSeed, lotId, "building")`.

Nothing about settlements is saved, so every server builds the same towns.

## 2. Tiers

The size ids are permanent; the labels are what players see.

| Size id | Label | Buildings | Radius | Plaza | Main roads | Side streets |
|---|---|---|---|---|---|---|
| `village` | Hamlet | 4–8 | 75 | 9 | 2 | none |
| `town` | Village | 10–25 | 115 | 13 | 3–4 | every 44 studs |
| `city` | Town | 30–60 | 165 | 18 | 4–5 | every 36 studs |

## 3. Layout rules (`SettlementLayout`)

- **Plaza:** a square at the mean ground height. Its centre holds the well or shrine.
- **Main roads:**
  - The first ones point at the roads to neighbouring settlements; the rest take seeded bearings, spread apart.
  - They walk outward in 10-stud steps. Each step takes the heading (straight, or 14° either way) that climbs least, so roads follow contours.
  - They stop at the radius or at water. Heights are smoothed.
- **Side streets** branch off main roads, alternating sides, and stop near other roads.
- **Lots:**
  - Each building goes on the street frontage whose next spot is nearest the plaza.
  - It's set back 2–4 studs from the street edge and faces it.
  - A spot is rejected, and the cursor nudged 4 studs on (6 tries per frontage), if the lot leaves the radius, touches the plaza, another lot (separating-axis test) or any road including the inter-settlement roads, stands in water, or its 9 height samples vary by more than the tier's tolerance (6–7 studs).
  - Unplaced buildings are logged as `settlement_lot_failed`.
- **Terrain ops** (`block` only, ids `<settlementId>:g<n>`):
  - the plaza is paved in the culture's plaza material;
  - streets are paved in its street material, with air cleared above;
  - every lot is levelled to its average height, using the biome's top material.

  They're applied when the chunks they touch are built, before saved player edits.

## 4. Buildings (`BuildingGenerator`)

**Every type except the small house** is built on a shared `shell`:

- **Base:** a sunk foundation and a floor.
- **Walls:** built as segments around a door (or a wide opening) and evenly spaced windows on each wall.
- **Upper storey (optional):** a second floor with a stairwell, and stairs along the right wall.
- **Roof:** the culture's choice of gabled, flat or domed.

| Type | What makes it that type | Lights |
|---|---|---|
| house_medium | Partition wall with a doorway, 2 beds, table for four, shelf, chimney by culture | none |
| house_large | Two storeys, stairs, 3 beds upstairs, chimney | none |
| smithy | Wide open front, forge with glowing coals and a stack, anvil, quench trough, tool rack, ingots | forge |
| tavern | Two storeys, bar counter, barrels, 3 tables, hearth, rooms upstairs; hanging sign with a seeded name (SurfaceGui), stored as `DisplayName` | lantern |
| market_stall | 4 posts, sloped canvas, counter with goods, crate, barrel | none |
| well | Octagonal stone ring, water, posts, crossbeam, bucket, little roof | none |
| watchtower | Stone pillars, walled base, climbable truss to a hatch, crenellated platform, roof | brazier |
| barn | 8-stud doorway with open double doors, steep roof, stalls, hay, trough | none |
| magic_school | Tall hall (domed for flat-roof cultures), stone tower with stepped cap, floating crystal, lectern, benches, bookcases, orb | crystal + orb |
| shrine | Stepped platform, pillars, gabled roof or dome, altar, bowl, crystal | crystal |

Lights come from a server-wide budget (`BuildingGenerator.setLightBudget`, default 160). When it's used up, the Neon glow stays and only the PointLight is skipped.

**Anchors:**

- `NPCHome`: one per bed.
- `NPCWork`: where the job happens (the anvil, behind the bar or counter, the guard platform, the lectern, beside the altar).
- `BuildingEntrance`: outside the door.

**Tags:** each kind has its own tag (`House`, `Smithy`, `Tavern`, …), and workplaces also get `Workplace`.

**`Settlement.spec`** builds every type in every culture and checks:
- the part budget;
- PrimaryPart and anchoring;
- tags and anchors;
- that any door leaf doesn't block movement.

### The small house

**Small house** (about 50–70 parts):

- **Shell:** a sunk foundation and a floor. Walls are built as segments around the openings: an off-centre door, 1–2 front windows, and one window in the back and in each side. Window openings have glass panes.
- **Door:** an open door leaf with `CanCollide` off, and a front step.
- **Roof:** gabled, as two WedgeParts with the ridge along the longer side, plus a ridge beam. Loreseat houses get a flat roof with a parapet instead.
- **Chimney:** by culture odds, with a cap, a hearth and glowing embers. There are no lights; lamps will come with the light budget.
- **Optional details:** shutters and timber framing, by culture.
- **Furniture:** a bed with mattress and pillow, a chest, a table, two chairs, a shelf with books and a rug.
- **Model setup:**
  - PrimaryPart = Foundation; `ModelStreamingMode = Atomic`;
  - tags `Building`, `Structure` (quakes damage it) and `House`;
  - attributes BuildingType, Culture, SettlementId, LotId, OwnerNPCId (empty for now), Integrity and Robustness.
- **Anchors:** Attachments `NPCHome` (beside the bed) and `Entrance` (outside the door), tagged `NPCHome` / `BuildingEntrance`.
- **Where it goes:** `Workspace.Settlements.<SettlementName>.House_NN`.

**Culture palettes** (`SettlementStyles.cultures`) set wall, roof, foundation and floor materials and colours, roof style and pitch, chimney odds, shutters, timber framing, street and plaza materials, and which trades the culture adds. Each house varies its colours slightly and its size within the lot.

## 5. Debugging

| Tool | What |
|---|---|
| Boot | `settlements_ready` (settlements, lots, failed, ops, ms) plus a summary table; one `settlement_lot_failed` warning per failure; `settlement_buildings` 20 s later |
| `settlements` | Per settlement: tier, culture, lots placed / wanted, failed, buildable, built, parts, roads |
| `settlementinfo <settlement>` | Lots by type, terrain op count, every failure with its reason and position |
| `buildsettlement <settlement>` | Builds its terrain and buildings now |
| `tp settlement` / `tpsettlement <name>` | Teleport to the nearest settlement, or a named one |
| `overlay lots` | Lot outlines by type (solid = built, faint = planned), street lines, plaza, failed lots in red |
| `buildingcheck` / `buildingaudit` | Now include the foundation report (floor top, lot ground, highest terrain under the floor, rays hitting terrain, grass voxels) |
| Log | `foundation_failed` (once per building per failure), `foundation_fixed`; `settlement_buildings` carries `foundationsChecked` / `foundationsFailed` |
| Studio markers | Red neon pins in `Workspace.FoundationFlags.<lotId>` where a ray met terrain; a beacon over the roof for grass under the floor (flag `foundation_markers`) |

## 5b. Foundations (`FoundationBuilder`, 2026-11-03)

The fix for grass sticking up through floors. **Cause:** lots were levelled with the biome's top material (usually Grass) exactly up to the lot level. The floor was a 0.4-stud slab whose top sat 1.25 studs above that grass, and grass decoration renders through Parts. The levelling boxes were also unsnapped and axis-aligned (so rotated lots' boxes overlapped their neighbours), and a chunk built later replayed whole boxes over neighbouring floors.

**Ops** (pure, appended after all paving and levelling ops): each lot is rasterised into 4-stud voxel columns, snapped outward.

| Zone | What |
|---|---|
| Core | Columns touching the lot rectangle. Air from 8 studs below the lot level to 24 above it, then the culture's foundation stone up to level − 0.25 |
| Yard | Within 4 studs of the lot. The same heights, in the culture's street material (never grass) |
| Steps | Only on lots whose lowest ground is more than 2 studs below the level: up to 2 stone rings, each 2 studs lower, and only where the ground falls away |

Yards and steps skip roads, the plaza, the sea and any other lot.

**Chunk clipping:** every generated op has `c = true`, so `TerrainBuilder.applyOp(op, clip)` writes only the part inside the chunk being built. Chunk borders lie on the voxel grid, so the result is identical whatever order chunks build in, with no seams.

**Heights (lot-local):**
- terrain top −0.25;
- floor slab 1.2 thick, from +0.35 to +1.55;
- plinth from −2 (or below the lowest ground on slopes) up to +1.5;
- door steps of at most 0.6 each, from the yard up to the threshold.

**Verification** runs after every build and again after any later chunk build nearby:
- terrain-only rays every 2 studs across the interior, starting 6 studs above the floor. Terrain more than 0.6 studs above the floor TOP fails (`SHOW_THROUGH`). Terrain inside the slab is hidden by it, and smooth terrain lands up to ~0.5 stud off its fill target. (The first rule, "anything above the floor bottom", failed all 27 buildings on 2026-11-05 although every floor looked clean in play.)
- `ReadVoxels` in a band around the floor. Any grass fails.

There are no cellars yet. Upper floors sit inside the cleared interior box, so terrain can't reach them.

## 5c. Ground (`SettlementGround`, 2026-11-03)

The fix for towns carpeted in grass. A pure plan per settlement, seeded from `(worldSeed, settlementId, "settlement.ground")`.

**The mask** has three rings round the plaza (R = the tier's radius). Each radius wobbles by ±15% with seeded noise, so the edges aren't circles.

| Zone | Out to | Ground | May replace |
|---|---|---|---|
| Core | max(plaza + 10, 0.36 R) | The culture's plaza material, blended with its street material and packed earth. Limestone or brick within 10 studs of a magic school or large house | Any natural top (grass, leafy grass, ground, mud, sand, snow) |
| Inner | 0.8 R | Packed earth with worn patches; about a third stays grass | Grass only |
| Outer | R + 24 | Dirt patches thinning out toward the biome | Grass only |

The earth and worn materials follow the biome's top: grassy → Ground/Mud, sand → Sand/Sandstone, mud → Mud/Ground, snow and rock → Ground/Slate.

**Left alone:** road paint, the plaza, every lot's foundation and yard apron, water, and anything that isn't natural ground.

**Added on the ground:**
- worn road shoulders (1.5–4.5 studs, varying with noise);
- desire paths from homes and workplaces to the nearest well, stall or shrine (else the plaza).

**Deliberate grass**, only in grassy biomes, always painted grass:
- a village green by the plaza (a shade tree and a bench);
- kitchen gardens behind some houses (fenced, with crop rows);
- orchards in the outer ring for verdant, wayfarer and frostfolk towns (fenced, 3 × 3 fruit trees).

**Props (SettlementDecor):**
- plaza curbs, with gaps where streets leave;
- planted street trees in stone rings along main roads in the inner ring;
- hay by barns;
- puddles on street shoulders: tag `Puddle`, shown while `WorldStateService.wetnessAt` > 0.15 (storm events), always shown in wet biomes;
- cart tracks along packed-earth main streets;
- flagstones in front of most homes in the core and inner ring (BuildingGenerator, `spec.path`).

**Wild trees:** none in the core, one in four in the inner ring, unrestricted in the outer ring, never in a patch.

**Painting:** `SettlementService` registers a ground pass with `WorldStateService.setGroundPass`. Inside each chunk job, `TerrainBuilder.applyChunkOps` runs:
1. the generated ops (clipped to the chunk);
2. every touching settlement's `SettlementGround.paint` (clipped to the chunk);
3. the saved edits.

`paint` works per 128-stud tile:
1. Decide every column (pure; may yield).
2. Read the surface band once.
3. Swap the top solid voxel, and the one under it, where the mode allows. Occupancy is never changed.
4. Write back only if something changed.

Grass decoration only grows on Grass, so the blades go with the material.

## 5d. Order of operations (per chunk)

| Step | Where |
|---|---|
| (a) Base terrain | `TerrainBuilder.buildChunk` steps 1–4: WriteVoxels slabs (highways painted here) |
| (b) Settlement paving | Generated ops: the plaza, then streets |
| (c) Lot levelling | Generated ops: each lot's air and fill box |
| (d) Interior clearing and foundation | Generated ops: FoundationBuilder's core, yard and steps (always after every levelling op) |
| (e) Ground mask material pass | `SettlementGround.paint`, after all generated ops |
| (f) Saved edits | Players and disasters, last |
| (g) Building placement | `ChunkBuilt` → `buildLot` → clear the interior → verify the foundation |
| (h) Decoration, props and vegetation | `ChunkBuilt` → decor items, planned against the same mask |

Roads are part of (b), not a separate later pass, so no step ever paints over another.

**No seams:** generated ops and painters are clipped to the chunk being built. Every column is written only by its own chunk, in the same order, whichever neighbour builds first.

**StreamingEnabled:** buildings and props are Atomic models built server-side with their chunk. Terrain replicates on its own.

## 6. Decoration (`SettlementDecor`, Step 4)

`SettlementDecor.plan` is pure and seeded (`"settlement.decor"`). It runs once per layout; items are built when their chunk is built, into `<Settlement>/Decor`, each as an Atomic Model tagged `Decor` plus its kind's tag.

Each candidate spot is checked against the padded lots, the roads, the plaza, the sea and other props, using SettlementLayout's geometry, so nothing blocks a door or a street.

| Item | Where | Notes |
|---|---|---|
| `anchor` | Plaza centre | An invisible part tagged `Settlement`, holding four `NPCSpawn` attachments |
| `lamp` | Every street, alternating sides, every 26 studs (main roads) or 32 (side streets) | The first 2, 6 or 10 per Hamlet, Village or Town get a PointLight; the rest just glow |
| `fence` | Back and sides of some house lots | Chance by culture (verdant 70% … loreseat 15%); the front stays open |
| `goods` | Beside smithies, taverns, stalls and barns; plaza corners | Barrels and crates |
| `forge` | Plaza corners, forgehold and emberclan | Open-air hearth (glowing) and anvil |
| `spire` | Plaza corners, plus a ring of tall spires around the town (loreseat) | Glass crystal with a glowing tip |
| `flowers` / `banner` / `brazier` / `cart` | Plaza corners: verdant / skywarden / frostfolk / wayfarer | Braziers glow |
| `dock` | Where a main road meets deep water: always up to 2 for tidecall, 35% chance of one elsewhere | Pier on piles, bollards, lantern, a moored boat |
| `tree` / `rock` | In and around the town, within radius + 25 | Counts by tier and biome (forests have more trees, mountains more rocks); conifers in cold biomes |

Every PointLight, in buildings and decor, comes from the one budget in `BuildingGenerator` (160). The `settlements` summary shows how many are in use.

Canals aren't built: they'd mean carving water channels through the terrain, which is a much larger change than placing props.

## 7. Spawn

Players spawn on the spawn city's paved plaza, off-centre toward the first street.

- **`findDryLand` never returns water:**
  1. gentle ground 6+ studs above the sea;
  2. then any ground 3+ studs above the sea;
  3. then the nearest dry cell of the coarse world grid.
- **The spawn is checked on the built terrain:** the point and four points a pad-width away must all be solid ground. The spawn pad is 6 × 6.
- **The plaza move only happens if that check passes** (`WorldStateService:setSpawn`).
- **A respawn guard catches the rest:** 1 s and 3 s after every spawn, anyone in water is moved to the spawn point (`CharacterSafety.guardSpawns`, logged as `character_rescued`).

## 8. Known gaps

- Linking NPC homes to houses isn't done yet (`OwnerNPCId`, ScheduleService spots → `NPCHome` anchors).
- Lot pads are levelled as axis-aligned boxes, so rotated lots level a little more ground than they cover.
