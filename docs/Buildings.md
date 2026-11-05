# Functional buildings

Stage 1 of the world-expansion brief, written 2026-11-03. It hasn't been run in Studio yet.

Later stages, in the owner's order:
1. caves;
2. creatures;
3. lairs;
4. secrets;
5. wilderness details.

## 0. Audit

### How POIs are placed (`World/POIPlacer` + `World/POIRules`)
1. **Candidates:** every 128-stud `WorldIndex` cell is a jittered candidate.
2. **Rules:** each `POIRules` rule runs in order (rarest first). It filters by biome and `filter(cell)`, scores with `score(cell)`, and accepts the best cells greedily. Acceptance respects the rule's `spacing`, the global `clearance`, and the rule's `count`.
3. **Settlements:** sites are refined by `SettlementSites`, then culture, name and size are assigned.
4. **Roads:** an MST over settlements, plus a few extra links.
5. **Lore hints:** scattered for the mythic sites.

`POIService` streams the visible POIs as markers and grants catalysts, insights and awakenings on visits.

### Why floors looked missing
The generator *does* create a Floor part (a 0.2-stud slab on the foundation, collidable). The cause is the terrain levelling:

- A lot's levelling op (air above, ground below at the lot level) is bucketed only into the chunks the op overlaps.
- A street op, or a neighbouring lot's op, can still reach into the lot from a chunk the lot doesn't touch.
- That chunk may be built *later*, when a player approaches from that side. It then replays its ops, which refills road or neighbour terrain over the floor, and the lot's own op isn't in that chunk to undo it.
- Natural terrain and its 4-stud voxel smoothing make it worse at the edges.

The floor was there, under terrain.

### The fix
- **Clearing:** every building now records its room volume (`InteriorCFrame` / `InteriorSize`). `SettlementService` clears it to air when the building is built **and** after every later chunk build within reach.
- **Floor:** a 0.4-stud slab over the *whole* footprint (no seams under walls), its top flush with the foundation, tagged `BuildingFloor`.
- **Checking:** `buildingcheck` samples terrain inside the rooms and reports anything still there.

### Hooks for new feature types
- **POIs:** `POIRules` entries (data) and `POIPlacer` hint chains.
- **Terrain:** `WorldStateService:setGeneratedOps` (per-chunk, regenerated terrain ops, used by settlements).
- **Chunks:** `Topics.ChunkBuilt` (build Instances when their chunk exists) and `Scheduler.spawn` / `checkpoint` (frame-budgeted jobs).
- **Settlements:** `SettlementDecor.plan` / `build` (seeded props).
- **Interaction:** the new `Interactable` tag and registry.

## 1. Buildings

- **Floor and foundation:** see above. Upper floors keep their 0.6-stud slab and stairwell.
- **Multi-room:** the existing medium-house partition and the two-storey houses and tavern.
- **Windows:** real openings, as before.
- **Doors:**
  - The front door is a real leaf: closed and solid.
  - It carries `ClosedCFrame`, `OpenCFrame`, `Locked`, `OwnerLocks`, `LockTier` and `KeyId` (= lot id).
  - Half of small and medium homes, and 60% of large ones, start locked (seeded).
  - Taverns, schools and shrines are unlocked.
  - Open-fronted buildings (smithy, barn) have no leaf.

## 2. Doors (`Interact/Doors`, `Services/InteractionService`)

- **Swing:** server-side 0.4 s tween. Collision turns off while open and back on once shut.
- **Auto-close:** after 7 s, waiting while anyone stands in the doorway. Owner-locked doors relock on closing.
- **From inside:** a locked door is just a bolt; nobody gets shut in.
- **From outside, in order:**
  1. a key (an item with `data.opens` equal to the door's `KeyId`, or the Skeleton Key on tier 1–2 locks);
  2. metal magic (Metallurgy Adept or Ferromancy Novice) for 8 × tier reservoir;
  3. a lockpick: 55% on tier 1, 40% on tier 2; a failure breaks the pick half the time.
- **Crime:** forcing a lock you aren't allowed past is a crime (severity 2). The first press warns; a second press within 6 s commits.
- **NPCs:** loaded rigs open doors within 5 studs. NPCs carry their town's keys.

## 3. Interactables

`Shared/World/Interactables` is the registry: kind → prompt text, hold time, distance, handler, and container or station data.

Generators call `interact(b, part, kind)`. That tags the part `Interactable` and sets `InteractId = "<lotId>:<kind><n>"`, so ids are deterministic and stable across servers.

`InteractionService` creates server-side ProximityPrompts. Triggers are validated: rate (0.25 s), alive, and within the prompt distance + 6.

### 3.1 Beds
An invisible Seat on each mattress. It has `CanTouch` off, so it never auto-seats.

"Rest" sits you down. While resting, the reservoir regenerates at the Resting rate and you heal 1.5% of max health per second. Jump to get up.

### 3.2 Containers (`Services/ContainerService`)
- **What they are:**
  - chest: 16 slots, household loot;
  - barrel: 8 slots, provisions;
  - crate: 8 slots, workshop.
- **Contents:** seeded (`Interact/ContainerLoot`: world seed + id + restock round), rolled on first open. Restocked into free slots after 3 game days.
- **Moves:** take, put, take all and coins are each one `Inventory.transactMany` over the player and the container. Both change or neither does, and a uid can never exist in both.
- **Theft:**
  - taking items you didn't deposit, from a building you aren't permitted in, is theft;
  - severity = 1 + value / 25, capped at 10;
  - it's reported as `Topics.CrimeCommitted` (infamy, Concord standing, bounties).
- **Persistence:** settlement containers are per server (NPC property, regenerated). Player-owned containers (housing) will use the same interface backed by the owner's session-locked save, which avoids cross-server duplication.

### 3.3 Crafting station: the forge (`Services/CraftingService`, `Shared/Items/Data/Recipes`)
- **Recipes:** smelting (2 iron ore → ingot) and smithing (lockpicks, hatchet, sword, pickaxe, repair kits, miner's helm gated at Metallurgy Novice, chain mail at a tier-2 forge).
- **Tiers:** forgehold smithies are tier 2.
- **Ingredients:** specific items or tags (`metal_ingot`).
- **Atomic:** inputs out and outputs in happen in one transaction, or nothing happens (`NO_ROOM`).
- **Quality:** 40 + 6 × Metallurgy tier + 8 × (station tier − 1) ± 6, seeded by the item's uid. The item carries the crafter's display name.
- **XP:** study XP to Metallurgy when unlocked. Topic `ItemCrafted`.

## 4. Ownership and access (`Interact/Access`)

- **Building attributes:**
  - `Access`: houses are `private`, everything else `public`;
  - `OwnerNPCId` (set by SettlementService);
  - `OwnerUserId` (player housing);
  - `GuildId`;
  - `SettlementId` (where crimes are reported).
- **Rule:** one question everywhere: `Access.permits(player, building)`.

## 5. Admin

- **`buildingcheck [house|smithy|tavern|any] [teleport]`** (alias `househere`): teleports you inside the nearest built building. It checks, in order:
  - floor: collidable, covers the interior, flush;
  - terrain inside (re-cleared if found);
  - what's underfoot;
  - headroom;
  - door prompt, lock state, and a live open/close test;
  - interactables per kind, each with a prompt;
  - beds vs NPC home anchors;
  - container contents;
  - part and light count.
- **`buildingaudit`:** the same checks (no door swings) over every built building.
- **`door open|close|lock|unlock`:** acts on the nearest door.
- **Flags:** `interact_enabled`, and `buildings_lock_doors` (off = every door opens).

## 6. Client

`Controllers/InteractionController` adds two hidden screens; `InterfaceController` gained `hidden` screens, which never show as tabs.

- **Container:** the container grid and your bags side by side. Click moves a stack, Shift-click moves one, plus Take all and coins. A theft banner shows on others' property, and hovering shows the tooltip.
- **Crafting:** recipes with ✓/✗ ingredients (have / need), tier and mastery requirements in words, and Craft ×1 / ×5.

## 7. The rest of Step 1 (written 2026-11-03, not yet run)

### 7.1 Interactables by building

| Building | Interactables |
|---|---|
| Every house | door, bed(s), chest, bookshelf, hanging lamp(s); a hearth and fireplace when it has a chimney |
| Medium house | + a wardrobe |
| Large house | + a wardrobe and a loom |
| Tavern | lamps, cooking hearth and fireplace, barrels, an upstairs chest, a notice board by the door |
| Smithy | forge (tier 2 in forgehold towns), crate |
| Barn | workbench, loom, crate |
| Magic school | alchemy table, enchanting desk, a training dummy, two meditation mats, two bookcases, the focus-crystal pedestal (a seeded domain) |
| Shrine | ward stone (the altar), meditation mat |
| Well | drink |

Stools and benches carry `NPCSeat` attachments: leisure points for NPC schedules. NPCService doesn't route to them yet.

### 7.2 Stations and recipes (`Shared/Items/Data/Recipes`)
- **Forge:** smelting and smithing.
- **Workbench:** stool, table, bookcase, torches, fishing rod, pouch, vellum.
- **Loom:** cloth, trousers, cloak, robe, rug.
- **Hearth:** bread, smoked fish, stew. Cooking needs the fire lit: the building's `Warm` attribute must be true.
- **Alchemy table:** healing draught, antidote, reservoir tonic, and ironbark elixir (Earth Novice).
- **Enchanting desk:** Ember Dart scrolls (Energy Novice), and focus rings (Novice in any branch). Real affix enchanting arrives with the crafting stage.
- **New materials:** wood plank, raw wool, cloth, blank vellum, raw fish, raw meat, flour, root vegetables. They're found in barrels, crates and the new wardrobes.

### 7.3 Lights (`Interact/Lamps`)
- **Default:** every lamp and fireplace starts off.
- **Automatic:** at night (19:00 to 06:30, `WorldClock`), a building's lights come on when someone is inside it (a player or an NPC rig) and a player is within 320 studs.
- **Cap:** at most 60 are lit at once, nearest to players first.
- **By hand:** a toggle holds until the next dusk or dawn.
- **Warmth:** a lit fireplace marks its building `Warm`, which the survival stage will read.
- **Admin:** `lights` and `lamps on|off|auto`.

### 7.4 Knowledge and magic rooms
- **Bookshelves:** each shows one seeded book (`Interact/Data/Books`: 20 titles; homes only have the 7 common primers). Reading it goes through `ProgressionService:awardStudy(…, "book", shelfId)`, once per shelf. You get study XP, or lore if the branch is still locked. Each book also records its lore id.
- **Pedestal:** `studyInsight("<domain>:crystal_<id>")`, once.
- **Ward stone:** a Ward (power-3 resist) for 5 minutes, with a 10-minute cooldown per player per stone.
- **Meditation mats:** the new Meditating reservoir activity (×4; Resting is ×2.5).
- **Training dummy:** takes real spell damage through the normal pipeline. It shows last hit, total, hits and damage per second, never dies, and heals 4 s after the last hit. "Reset" clears the readout.
- **Wells:** +10% max health, and they put out burning (20 s per player).
- **Notice board:** opens the Journal's quests (offers and local crises), through a new server→client `OpenScreen` event, whitelisted on the client.

## 8. Player housing (`Services/HousingService`, client `HousingController`)

- **What's for sale:** any house no NPC household lives in. It gets a sign by the door: "For sale · price". Small houses cost 400, medium 900, large 1800.
- **Buying:** press the sign twice. Coins are paid first. Then the claim goes to the world store (`housing`, world-scoped) with an UpdateAsync that cancels if the house is taken or you already own one, and a lost race is refunded. Every server re-reads the claims every 90 s.
- **Giving up:** half the price comes back, but only once your storage and furniture are empty.
- **Door:** owners have their key.
- **Storage:** every chest and wardrobe in your house opens your personal storage. It's 24 slots in your session-locked save, so it can't be duplicated across servers, and others are refused.
- **Furniture:**
  - **Items:** stool, table, rug, bookcase, potted fern, standing lantern (`Shared/World/FurnitureModels`, the same models on server and client).
  - **Placing:** use "Place" in the Inventory while you stand at home. A ghost appears, snapped to half-stud steps, with 15-degree turns and a ✓/✗ fit check.
  - **Server check:** `PlaceDecor` re-checks ownership, that you're inside the house, that it's furniture, that the spot is inside the rooms, and the budget (30 pieces, 120 parts, 3 lanterns).
  - **Saving:** the item's whole record moves into `data.housing.decor`, so picking it up gives back the exact same item.
  - **Visibility:** pieces are built while their owner is on the server.
- **Admin:** `house info|claim|release|forcerelease`.

## 9. Not yet
- the shop counter (the economy stage: merchants);
- NPCs using `NPCSeat`;
- witnesses for crimes;
- furniture visible while its owner is on another server (it lives in the owner's save);
- building plots.
