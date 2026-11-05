# World Design Bible (v1)

**One sentence:** a deterministic island continent where the land's shape, climate, tectonic stress and magic are all generated from the world seed, and where big magic both depends on the land and changes it.

The code is in `src/server/World/` (WorldGen, Noise, Biomes, MagicMap, WorldIndex, TerrainBuilder, POIRules, POIPlacer, Settlements, EventDefs, and the Effects for earthquakes and tsunamis) and in three services under `src/server/Services/`: WorldStateService, EventDirector and POIService.

---

## 1. Scale and chunking

| | Value | Why |
|---|---|---|
| World | **4,096 × 4,096 studs**, an island continent centred on the origin | About 1.1 km across. Big enough to need travel and to hide things; small enough that a 60-player server isn't empty, that terrain memory stays reasonable, and that every chunk can eventually exist on one server |
| Chunk | 256 studs (64 voxels), 16 × 16 = 256 chunks | The build unit. One chunk is about 10–40 frames of work at a 4 ms budget |
| Region | 128 studs, 32 × 32 = 1,024 regions | Environment state: stress, vegetation, ore, magic pressure |
| Voxel | 4 studs | Roblox terrain resolution |
| Height | bedrock −64 … sea 48 … peaks ~480 | The detail band only covers where the surface actually is |
| Streaming | `StreamingEnabled`, min 256, target 1,024 studs | Clients only receive what's near them; the server streams terrain automatically |

**Why not bigger?** Terrain memory grows with surface area, and each chunk costs about 30 ms of generation. 16 km² would take minutes of background build and much more memory per server. Room for growth comes from *depth*: caverns, floating islands, and an ocean floor worth exploring.

### What happens when

| When | What | Cost |
|---|---|---|
| **Server start** | Noise layers, ley network (MagicMap), the 32×32 WorldIndex (ocean mask, open-sea flood fill, coast distance), all POIs, settlements, roads and lore hints, saved region state, and the **spawn area** (3×3 chunks). Characters don't load until the spawn area is built | Index and POIs: a few hundred ms spread across frames. Spawn area: ~5–10 s |
| **On demand** | Chunks within 3 of any player, nearest first, at most 2 in flight. A chunk's saved edits are fetched just before it builds | ~30 ms per chunk, spread over frames |
| **Cached in memory** | WorldIndex, POI placement, built-chunk set, region state, magic pressure, event modifiers | |
| **Saved** | Terrain edits per chunk, region state (stress/vegetation/ore), settlement deltas, the world chronicle | §8 |
| **Client only** | Decorations (trees, rocks, grass), ley-line beams, weather, sky and camera shake | §11 |

**Baking (optional).** WorldGen is pure, so you can build all 256 chunks once in Studio and save the place. Set the flag `terrain_generate_at_runtime = false` and servers then only replay edits. This trades place-file size for instant starts. The bake must use the same seed the live World store holds.

---

## 2. Noise layers

All layers are `math.noise` with seed-derived offsets. That means no permutation tables to store, and identical results on every server. The terrain seed is *derived* from the world seed and never sent to clients (a 32-bit seed could otherwise be brute-forced, which would expose everyone's hidden innate potential).

| Layer | Scale | Octaves | Use |
|---|---|---|---|
| warp | 1/900 | 2 | domain warp (±180 studs) so coasts and ridges meander |
| continent | 1/2200 | 4 | land vs sea; the edges sink to make an island |
| hills | 1/260 | 3 | rolling terrain, stronger inland |
| ridges | 1/900 | 4 (ridged) | mountain ranges, cubed for sharp peaks |
| temperature | 1/1800 | 2 | plus latitude (north cold, south hot), minus altitude lapse |
| moisture | 1/1300 | 3 | plus a coastal bonus |
| magic | 1/1100 | 3 | raw magic texture |
| faults | 1/1400 | 3 (ridged) | fault lines, giving tectonic stress |
| ancient | 1/1600 | 2 | where the old civilization lived (ruins) |
| caves | 1/48 | 2 (3D) | cavern carving under mountains and badlands |

**Height** = `sea + 2 + land·90 + hills·(0.4+land) + ridge³·330·mountainMask`. Ocean floor falls with distance offshore, down to −40.

---

## 3. Biomes

Rules are checked top to bottom; the first match wins (`WorldGen.biomeFor`).

| # | Biome | Rule | Surface | Density | Resonance (aligned ▲ / opposed ▼) | Fuel | Ore | Stress | Insight |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Open Ocean | height < sea − 6 | sand/rock | 0.9 | ▲Water 1.4, Air 1.1 ▼Energy 0.7, Earth 0.85 | 0 | 0 | 0 | ocean trench |
| 2 | Tidal Flats | coast, temp ≥ 0.3 | sand/mud | 1.0 | ▲Water 1.25, Life 1.1 ▼Energy 0.85 | .1 | .05 | 0 | |
| 3 | Frozen Coast | coast, temp < 0.3 | snow/ice | 0.9 | ▲Water 1.3, Air 1.15 ▼Energy .75, Life .85 | 0 | .1 | 0 | |
| 4 | Frostpeaks | height > 240, temp < 0.42 | snow/glacier | 1.1 | ▲Air 1.2, Water 1.15 ▼Energy .75, Life .8 | 0 | .4 | +.1 | |
| 5 | Volcanic Highlands | height > 240 and fault > 0.55, or fault > 0.58 and height > 90; hot (temp > 0.55–0.6) | basalt/cracked lava | 1.35 | ▲Energy 1.35, Earth 1.25 ▼Water .7, Life .75 | .1 | .8 | +.35 | volcanic vent |
| 6 | Mountain Range | height > 240 (or > 180 further down the rule list) | rock/slate | 1.05 | ▲Earth 1.25, Air 1.1 ▼Water .9 | .15 | .7 | +.15 | fault zone |
| 7 | Skyreach | magic > 0.78, height > 130 | grass/limestone + **floating islands** | 1.9 | ▲Air 1.35, Gravity 1.3, Space 1.2 ▼Earth .8 | .3 | .2 | 0 | storm eye |
| 8 | Tundra | temp < 0.24 | snow/ground | 0.7 | ▲Void 1.15, Water 1.1 ▼Life .8, Energy .85 | .1 | .2 | 0 | |
| 9 | Desert Dunes | temp > 0.66, moisture < 0.32 | sand/sandstone | 0.8 | ▲Energy 1.2, Earth 1.1, Air 1.1 ▼Water .6, Life .75 | .05 | .3 | +.05 | |
| 10 | Red Badlands | temp > 0.58, moisture < 0.45 | sandstone | 0.85 | ▲Earth 1.15, Energy 1.1 ▼Life .7 | .1 | .6 | +.1 | |
| 11 | Swamp | moisture > 0.74, low, warm | mud | 1.15 | ▲Water 1.2, Life 1.2, Mind 1.1 ▼Energy .8 | .35 | .05 | 0 | |
| 12 | Deep Forest | moisture > 0.56 | leafy grass | 1.25 | ▲Life 1.35, Spirit 1.15 ▼Energy .85, Void .8 | .85 | .05 | 0 | |
| 13 | Ancient Ruinlands | ancient > 0.8 | grass/cobblestone | 1.3 | ▲Spirit 1.3, Mind 1.2, Time 1.15, Reality 1.1 ▼Life .9 | .3 | .15 | 0 | |
| 14 | Grasslands | default | grass/ground | 1.0 | Life 1.05, Air 1.05 | .4 | .1 | 0 | |
| 15 | Crystalline Caverns | **underground** under mountains, badlands, frostpeaks (3D cave noise) | glacier/salt | 1.6 | ▲Earth 1.35, Void 1.15, Mind 1.1 ▼Air .75 | 0 | .9 | 0 | singing caverns |

**Resonance in play** (`MagicCore`, `Tuning.resonance`):
- Spell power is multiplied by `clamp(bias^0.5, 0.75, 1.25)`.
- The same bias scales local density for that domain, which affects the cost of drawing on ambient magic.
- Examples: Energy in volcanic highlands gets **×1.16 power**; Water there gets **×0.84**.
- When a domain resonates strongly (≥ 1.25), the domains that oppose it are set to 0.85 unless the biome already defines them.

---

## 4. The magical layer

```
density = biome.density · (0.4 + 1.2·magicNoise)       regional texture
        + 0.7 · lineFalloff  + 1.6 · nexusFalloff         ley network
        · active event modifiers                          storms, surges, droughts
        clamp 0..3; magicNoise < 0.18 far from the network fades to 0 (barren zones)
```

**Ley network:**
- **Nexuses:** one candidate per 560-stud jittered cell (7 × 7 = 49 candidates), kept if the land isn't ocean and its magic is ≥ 0.45. That gives about 15–20 nexuses.
- **Connections:** a minimum spanning tree, plus short extra edges (25% chance under 1,500 studs) so the network has loops.
- **Domains:** each line carries the dominant domain of its stronger nexus, and boosts that domain's resonance by up to +20% near the line.

**What density does:**
- **Ambient cost:** density below 1 makes spells cost more (Reservoir scarcity).
- **Ambient draw:** the Ambient cost profile draws more from dense places (up to 60% of the cost).
- **Regeneration:** `regen ∝ √density`.
- **Awakening dwell time:** a site needs `dwell / max(0.5, density)` seconds, so dense places awaken people faster.
- **Ley surges** double density near a nexus.

---

## 5. Environment state that magic reads

| Fact | Source | Used by |
|---|---|---|
| `seismicStress` | Per region: equilibrium `0.1 + 0.75·fault² + biome.stressBias`. Saved as `(value, timestamp)`; regenerates at **0.08/day**, computed lazily on read, so it costs nothing while untouched | quake rules (`fault_stress`), Earthquake |
| `groundMass` | `ReadVoxels` of a block up to 32 studs around and 40 studs below the cast; solid share | `ground_mass`, quakes and earth shaping |
| `waterVolume` | Coarse: Σ over ocean cells in range of `(sea − floor) × 128²`. Fine: `ReadVoxels` water count for radius ≤ 64 (ponds) | `water_source`, `great_wave`, Tsunami |
| `fuel` | `biome.fuel × vegetation × (1 − 0.5·moisture) + event modifiers` | `fuel` (great fires) |
| `stormCharge` | `biome.storm` + event modifiers (tempest, magic storm) | `sky_charge` (Stormcalling) |
| temperature, moisture | WorldGen + event modifiers | events, future ecology |
| vegetation | per region, saved; burned or salted land recovers +0.1/day | fuel, salted fields after a tsunami |
| ore | per region, saved remaining share (depletion is a future hook) | mines, Metallurgy |

`WorldStateService:castContext(position, radius)` gathers all of this into a `CastContext`: density, resonance (as `ambientBias`), and environment facts. **The client never supplies any of it.**

---

## 6. Points of interest

Placement (`POIPlacer`) uses every WorldIndex cell as a candidate. Each rule filters and scores the candidates, then greedily keeps the best ones that respect its spacing. Rules run rarest-first. Everything is seeded and deterministic.

| Type | Count | Where | Spacing | Grants |
|---|---|---|---|---|
| **Mythic: Stopped Clock** | 1, hidden | ruinlands/grasslands, most ancient + dense | — | Time awakening, *during an eclipse*, with ≥ 2 lore hints |
| **Mythic: Starfall Crater** | 1, hidden | remote badlands/desert/tundra | — | Gravity awakening, *during a starfall*, with ≥ 2 hints |
| **Mythic: The Seam** | 1, hidden | the single most magical land cell | — | Reality awakening, with ≥ 3 hints |
| Settlement | 14 | flat, temperate, near the coast; not peaks/vents/skyreach | 420 | culture, laws, guilds (§7) |
| Academy | 3 | dense, flat | 1,000 | primers for the next branch on your paths |
| Hermit tower | 6 | high, magical, remote | 500 | treatises; 10% chance of the Rite of Unbinding |
| Ruined library | 5 | ancient > 0.62 | 450 | treatises + **mythic lore hints** |
| Mine | 8 | ore-rich mountains/badlands/volcanic/frostpeaks | 350 | catalyst `exposure:ore` |
| Volcanic vent | 2 | volcanic, highest fault | 600 | insight `energy:volcanic_vent`, catalyst `heat` |
| Fault zone | 2 | fault > 0.8 | 800 | insight `earth:fault_zone` (Earth Master breakthrough; Cataclysm unlock) |
| Ocean trench | 1 | deepest open sea | — | insight `water:ocean_trench` |
| Singing Caverns | 1 | crystal-cave hosts, ore + density | — | awakening, insight, catalyst `geode` |
| Hollow Grove | 1 | forest/swamp with the lowest magic | — | awakening |
| Sunken Shrine | 1 | coastal shallows | — | awakening |
| The Quiet Place | 1 | lowest density on land | — | awakening (only if density < 0.2) |
| Shrine of each domain | 9 | where that domain resonates most | — | primers for that domain + **lore hints** |
| Dungeon | 10 | mountains, badlands, swamp, forest, frostpeaks, volcanic | 300 | (encounters: future) |

**Roads** connect settlements: a minimum spanning tree plus some links under 900 studs. They're painted onto the terrain as cobblestone while chunks build.

**Lore hints.** Each mythic site seeds 4 hints, scattered across libraries, shrines and hermit towers. A hint gives only a compass bearing, a rough distance band and the target biome. Mythic sites are **never** sent to clients, and they ignore anyone without enough hints.

---

## 7. Settlements and cultures

| Culture | Reveres | Prefers | Casting in town | Bans | Guilds | Openness |
|---|---|---|---|---|---|---|
| Forgehold Guild-City | Earth 1.5, Energy 1.2 | mountains, badlands, volcanic | licensed | forbidden tags | Smiths, Miners, Assayers | .45 |
| Tide-Priest Port | Water 1.5, Spirit 1.15 | coast | licensed | Void | Tide Priests, Shipwrights | .7 |
| Scholar Enclave | Mind 1.4, Time 1.3, Spirit, Reality | ruinlands, grasslands | free | forbidden tags | Archivists, Collegium | .8 |
| Verdant Circle | Life 1.5 | forest, swamp | licensed | forbidden tags | Wardens of the Green | .5 |
| Ember Clans | Energy 1.5, Earth 1.2 | volcanic, badlands, desert | free (duels legal) | Water | Flamekeepers | .35 |
| Skywarden Aerie | Air 1.5, Gravity 1.4, Space | skyreach, mountains | licensed | forbidden tags | Windriders | .45 |
| Frostfolk Hold | Water 1.3, Air 1.2, Void | tundra, frozen coast | **banned** | Spirit | Icecutters | .3 |
| Wayfarer Crossroads | — | grasslands, coasts | **banned** in markets | forbidden tags | Merchants' League | .9 |

**How a settlement is generated:**
- The two most suitable sites become **cities**, the next four **towns**, and the rest **villages**.
- **Relations** between settlements come from three things: how similar their cultures' values are, distance, and a seeded grudge or friendship.

**How settlements change:**
- `Settlements.judgeCast` applies a settlement's laws to casts inside it. Forbidden magic costs −25 reputation, a banned domain −12, and unlicensed harmful casting −6. Peaceful use of a revered domain earns +0.5, scaled by the culture's openness.
- Reputation is stored per player in their own data.
- Settlement prosperity, relation drift and structural damage are stored as **additive deltas**, so every server's contributions merge cleanly.

---

## 8. Persistent world changes (delta saves)

**Each terrain edit is a small, idempotent op:**
```lua
{ i = "jobid:42", k = "ball" | "block" | "replace", m = "Air", x, y, z, r?, sx?, sy?, sz?, f? (replace source), t = unix }
```

**Where edits are stored:** one DataStore key per chunk, `WorldDeltas/d_<cx>_<cz>`. The `ops` field is compressed with Codec. An op that touches several chunks is stored in each of them. Replaying an op twice gives the same result, so duplicates are harmless.

**When edits are written:**
- `WorldStateService:edit` applies ops immediately and queues them per chunk.
- Every 45 s, and on shutdown, each dirty chunk is written with `UpdateAsync` as a *union by op id*. Concurrent servers never overwrite each other.

**How other servers find out:** a MessagingService message on `WorldDeltas` lists the changed chunks. Other servers that have built those chunks re-read the log and replay ops they haven't applied yet.

**On chunk build:** base terrain is generated, then the chunk's log is replayed.

**Log size cap:** 600 ops per chunk. When a log is full, the oldest *small* ops (radius ≤ 6) go first, then the oldest overall.

**Next step (not built yet): compaction.** For heavily edited chunks, replace old ops with a run-length-encoded voxel diff against the generated base.

**Other saved world state:**
- **Region state:** stress, vegetation and ore, saved sparsely; the newer timestamp wins.
- **Settlement deltas:** additive.
- **Chronicle:** a capped list in the World store.

---

## 9. Worked example: a Grandmaster earthquake

Code: `World/Effects/Earthquake.luau`. To try it, open the console (F2) and run `quake 10` while standing on a fault zone (run `pois fault` to find one).

| Step | What happens | Numbers for a P10 Cataclysm at a mountain fault zone (fault 0.85) |
|---|---|---|
| 1. Measure | `world:castContext(pos, 150)` | stress = 0.1 + 0.75·0.85² + 0.15 = **0.79**; groundMass ≈ 0.9; density ≈ 1.3; earth resonance 1.25 |
| 2. Validate | `MagicCore.computeStats` with that context. Rules `fault_stress` (needs 0.12·1.25⁵ = **0.37**) and `ground_mass` (needs 0.3·1.08⁷ = **0.51**) | ratios 2.1 and 1.75 → best surplus bonus ×1.06; resonance √1.25 = ×1.12 → power ≈ **620** |
| 3. Release | magnitude = `log10(power+1)·2·(0.5+stress)` | log10(621)·2·1.29 ≈ **7.2**. Released stress 0.79·0.9 = 0.71, leaving the region at **0.08**; each neighbour gains +0.027 (aftershock risk). Refills in ~9 days |
| 4. Deform | along the fault direction (perpendicular to the fault field's gradient) | ~338-stud-long fissure (balls of radius 8.8), an uplift ridge on one side, a sunken trough on the other, and ~28 cracks. Capped at 150 ops, applied in a Scheduler job, then `world:edit` saves them |
| 5. Damage | structures within radius ~376, characters within ~225 | up to 180 integrity damage at the centre (collapse within ~45% of the radius at robustness 1); up to 43 HP. Others are only hurt with `pvp_enabled` |
| 6. Record | cosmetic shake for clients; Earth pressure (which raises volcanic unrest odds); chronicle entry; **if the caster lived 5 s inside the zone: `survived earth:self_collapse`** | which completes one of Earth's Master breakthrough requirements |

**Why it can't be spammed:**
- The same region has no stress left (0.08). A second Cataclysm there is **blocked** (`fault_stress` needs 35% of 0.37).
- The ritual has a ~282 s cooldown.
- It costs about 2,400 mana, mostly drawn from ambient magic.

---

## 10. Worked example: a tsunami

Code: `World/Effects/Tsunami.luau`. To try it, run `tsunami 10` while standing on a coast.

| Step | What happens | Numbers (P10) |
|---|---|---|
| 1. Origin | must be an ocean cell **connected to the world edge** (flood fill). Lakes and lagoons fail with `NOT_OPEN_SEA` / `ENCLOSED_WATER` | |
| 2. Measure | `castContext(origin, 400)`: waterVolume summed from ocean cells | about 50 cells × 68 studs depth × 128² ≈ **55M studs³**, against **112k** required by `great_wave` → surplus bonus ×1.15; ocean resonance √1.4 = ×1.18 |
| 3. Coastline | march toward the target over the coarse grid: open sea must continue until **open coast** (coastDistance 0) within 1,800 studs; otherwise `NO_OPEN_COAST` | |
| 4. Wave | crest = `6 + 34·√(power/520)` → **44** (capped); width = area×1.2 ≈ **470**; run-up ≤ **420** studs inland. Each 16-stud step writes a water slab at the front and clears the last one (`ReplaceMaterial` Water→Air above sea level) | ~41 steps at 70 studs/s, about 9 s |
| 5. Damage | structures (4×height), characters (0.8×height), pushes unanchored assemblies inland | |
| 6. Aftermath | a shallow flood that drains after 25 s (not saved). **Persistent:** the first stretch of coast turns from grass/ground/mud to **sand** (`replace` ops, saved); flooded regions become **salted** (vegetation 0.3, recovering over about a week); chronicle entry | |

---

## 11. Instances and rendering

**Ground is terrain only.** It costs zero Instances, streams automatically, and handles caves and edits. Floating islands are terrain too.

**Points of interest:**
- **Server:** a single invisible marker per POI at most. Gameplay checks are distance math in POIService, not touch events.
- **Buildings:** authored prefab Models (MeshParts with low part counts) cloned from ServerStorage. Use `ModelStreamingMode = Atomic` for whole buildings, and `Persistent` only for the spawn city.

**Client only:**
- **Decorations** (trees, rocks, grass): generated from public per-chunk data (biome and position hashed with a public salt, never the world seed) by a client DecorationController. Pooled and recycled, with no collisions on small decor.
- **Ley lines:** Beam or Trail along the line paths.
- **Weather and VFX:** driven by `RegionInfo` and `WorldEffect`.

**Server Instance budget (target):** under ~20k parts in workspace, excluding terrain. That covers characters, prefab buildings near players, unanchored rubble (cleaned after 2 minutes) and spell VFX anchors.

**Never** create one Part per tree, wave segment or spell particle on the server.

---

## 12. Performance budget

| Item | Budget | How |
|---|---|---|
| Scheduler jobs (terrain, quakes, erosion) | **4 ms per frame** total (flag `world_build_budget_ms`) | coroutines that call `Scheduler.checkpoint()` |
| Chunk build | ~30 ms of work spread over 10–40 frames; ≤ 2 chunks in flight | heights for 66² columns; 16k-cell `WriteVoxels` slabs; one `FillBlock` for deep rock |
| Start-up | index + POIs < 0.5 s (spread); spawn 3×3 chunks ~5–10 s | characters wait (`CharacterAutoLoads` off until ready) |
| `castContext` | ≤ 2–3 ms | bounded `ReadVoxels` (≤ 64×40×64 studs); ocean volume from the coarse index |
| POI proximity | every 2 s; O(players × POIs) ≈ 60 × 70 | distance checks only |
| Event director | every 60 s | weighted pick; modifiers are distance tests |
| Region info to clients | every 2 s per player, only when the region changes | one small table |
| DataStore | deltas every 45 s per dirty chunk; region and settlement state every 45 s when dirty | union merge, compressed |
| Server memory | terrain for the built chunks plus ~1 MB of world tables | chunks stay built (no unloading in v1) |
| Network | terrain streams through StreamingEnabled; world cues are small events | no per-frame remotes |

## 13. Shortcuts and approximations (to keep it playable)

1. **Biome climate is sampled every 4 voxel columns.** Heights are per voxel; climate isn't. Borders are slightly blocky in material only.
2. **The detail band is only 24 studs below the lowest surface point;** everything deeper is one `FillBlock` of rock. Caves only exist inside the band.
3. **Water volume for big spells comes from a 128-stud grid,** not voxels. Only small radii read voxels.
4. **Tsunamis are a moving slab plus run-up attenuation,** not fluid simulation. Clearing a slab also drains any elevated lake inside it.
5. **Quake deformation is ~150 terrain balls** along the fault, not physical rupture. Structure collapse is attribute-based.
6. **Tectonic stress is lazy:** a value and a timestamp, computed on read. No ticking simulation.
7. **Events are per-server**; only global events (eclipse, starfall) and big disasters go to the shared chronicle.
8. **Built chunks are never unloaded on the server.** Fine at 256 chunks; revisit if the world grows.
9. **Settlement NPC populations are numbers** until the NPC system simulates them.
10. **Persistent edits are an op log** (600 per chunk). Compaction into voxel diffs comes later.

## 14. Security notes

- **Secrets:** the world seed, the terrain seed, POI rules, hidden mythic sites and hint mapping never leave the server.
- **What clients get:** only `RegionInfo` (biome, density, resonance), visible POI markers, and cosmetic `WorldEffect` cues.
- **Server-measured inputs:** all environment facts behind a cast are measured on the server.
- **Edit limits:** terrain edits only come from server-resolved effects. They're capped per effect (150 ops) and per chunk log (600).
