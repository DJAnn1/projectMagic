# Readable NPC activities

The owner's brief (2026-11-07): every NPC activity should be readable at a glance, from a distance and up close, without opening a menu. It's built in stages. **Stage 1 is built, not yet run.**

## 0. Audit (before stage 1)

Before this work, NPCBrain picked one of 16 actions and NPCService routed the NPC to a building anchor or a district spot. Then `NPC/DailyLife` played one of 5 clips and welded a prop, all on the server and only in the spawn town. Nothing was replicated except `NpcAnimState`. Nobody reached a station: each building had one `NPCWork` point, and beds had `NPCHome` 2.6 studs to one side.

| Activity | Visible before? | What was missing |
|---|---|---|
| sleep | walked home | lay nowhere: stood beside the bed |
| eat | `sit` clip at a tavern seat only | home meals standing, no food |
| smith | hammer clip and prop | stood near the anvil, the forge never changed, no output |
| farmer | dig clip and hoe | no field and no furrows |
| fisher | rod | no line, bobber or catch |
| guard | spear and patrol | fine |
| other trades | clip and prop at a district spot | no stations |
| study | book prop | desk never used |
| practice | one luminosity spark | same for every domain and mastery |
| worship | hold clip | no kneeling, no altar |
| wander, idle, shelter | nothing | the "standing around" |

## 1. State model

`Services/ActivityService` is the source of truth. Each NPC has a record with an activity, a phase (Travelling, Preparing, Performing, Finishing, Interrupted), a station, a start time, a duration, a reason, a pose variant, an item, a mastery tier and a domain. It's replicated as one string attribute, `NpcActivity` (`Shared/Life/ActivityState`), written only on change. Progress is computed from the start time against the shared clock and loops once per finished piece. An interruption moves the start forward, so progress resumes where it stopped.

- **Data:** `Shared/Life/Data/ActivityLibrary` (15 activities), `HeldProps`, `ActivityPoses` (procedural poses plus the animation slots, which now hold the owner's clips), `StationTypes`.
- **Pure rules:** `Life/ActivityRules` (pick, reason, duration, Observe text).
- **T2 NPCs** have no rig. Their activity is kept as data and counts as Performing, and it still lights their station.
- **Routing:** `NPCService.route` asks ActivityService first (`setActivityHook`) and goes to the use point or the spot. The door fallback lands people on the use point.
- **DailyLife** still roams and patrols. It no longer draws props or clips for activities from the library, and stops entirely for activities done at a station.

## 2. Stations

`Life/StationRegistry` finds anvils, forges (passive, lit by their building's anvil), hearths, desks (enchanting and alchemy), beds, altars (shrine ward stones), tavern seats (`NPCSeat`) and home tables (with `ChairSeat` bodies) in each built lot. It gives each slot a `UsePoint` attachment on clear floor inside the room, facing the work. Sitting and lying are drawn by the client at the use point's `BodyCFrame` (the chair, the mattress), so the server's Humanoid never stands inside furniture. A station with no valid point is logged as `activity_station_invalid` and listed by `stationcheck`. Pathfinding reachability isn't checked (see the pinned NPC pathfinding work).

## 3–4. Rendering (client)

- `Controllers/ActivityController`: client LOD (full within 70 studs, up to 24 NPCs; props within 140, up to 40; halved on phones and with reduced effects). It also handles strikes timed from the shared clock and the debug labels.
- `Fx/ActivityPoser`: procedural R6 poses layered on top of whatever animation is playing (PreAnimation and PreSimulation).
- `Fx/ActivityProps`: pooled props. A Model in `ReplicatedStorage.Assets.Props.<id>` replaces the Part fallback.
- `Fx/SetPieces`: furrows, swept dust, the woodpile, the fishing line and catch, the blanket, and Energy, Earth and Water practice, which scales with mastery and is tinted by the NPC's signature.
- `Fx/StationFx`: anvil blade and sparks, forge embers and smoke, hearth fire, pot and chimney smoke, desk book and candle, altar motes. Chimney smoke shows up to 700 studs away.

## 5. Observe

`Controllers/ObserveController`: rest the pointer (or the screen centre) on someone within 40 studs. The `NpcObserve` remote returns text scaled by how well you know them (`DialogueEngine.band`), your Mind tier (4 or above) and how long you've watched (4 s). The setting is **Reading people**: Off, Minimal, Standard, Detailed.

## 8. Tools

| Command | What it does |
|---|---|
| `actlabels on` | Debug labels over every NPC (you only) |
| `actlist [settlement]` | NPCs grouped by activity |
| `actnpc` | One NPC's activity record |
| `actforce <activity> [npc] [minutes]` | Put an NPC into an activity at the nearest station |
| `actpreview <activity>` | Spawn a test NPC doing an activity |
| `actmissing` | Library check |
| `stationcheck` | Stations, and the ones without a valid use point |
| `actreport [settlement]` | Readability Report: simulates a day, then marks each activity PASS, WARN (sound only) or FAIL (something visual is missing, or the action has no activity yet) |

Fast-forward time with `timescale`.

## Still to build (later stages)

- The other 45+ activities: merchants, healers, scholars at work, teaching, children, trade, socialising, wander, idle.
- Audio: the licensed libraries have no activity sounds yet.
- Icons and speech bubbles.
- The town activity overview and contact cards.
- The Awareness overlay.
- Join and assist, and opportunities.
- The LOD consistency pass.
- Farm plots as real stations.

## Parts that feel like a game (for the owner to judge)

- The Observe label is a floating UI element.
- The always-on nameplate (name and occupation, 60 studs) already tells strangers what the Observe tiers hide.
- The debug labels are admin-only.
