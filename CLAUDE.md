# projectMagic: status and handoff

An open-world Roblox magic sandbox. There's no linear story: everyone (players and NPCs) has innate magic that is procedurally generated, trained and mastered over time. It's written in Luau and synced to Studio with Rojo (`default.project.json`). Last updated **2026-11-02**.

## How the owner works with Claude

- **Every feature response follows this structure** (their standing "project bible" rules):
  1. Restate the request and list assumptions.
  2. Show where each script lives in Explorer.
  3. Write complete, commented `--!strict` code.
  4. Call out performance risks, exploit risks and edge cases.
  5. End with **(1) what to test, (2) what to build next, (3) open design questions**.
- **Non-negotiable constraints:**
  - Server-authoritative: clients send intents only.
  - Data-driven: content lives in data modules.
  - Deterministic: everything generated derives from `Seed.random(worldSeed, entityId, system)`.
  - Budget for 30–60 players and 100–300 NPCs.
- **Testing loop:** the owner presses Play in Studio and pastes the Output window.
  - Remind them to **clear the Output first**; they once re-pasted an old log three times.
  - Remind them to run **only one `rojo serve`**; a duplicate instance once caused a duplicate spec module.
  - No Luau runtime exists locally (only `rojo`), so code can't be executed outside Studio. Verify with `rojo build` and the VS Code diagnostics.

## Decisions already made (don't re-ask)

- **One world, many servers.** Every server runs the same seed and the same world. Live state is per server; a thin global layer holds the World store, MessagingService announcements and saved terrain edits.
- **No paid features at all.** Never design paid rerolls of innate profiles.
- **Players name their spells.** The raw name is stored server-side only; clients only ever see the TextService-filtered version, via `SpellbookService:displayName()`.
- **Admin:** UserId **17476255** (`src/server/Config/AdminConfig.luau`), also the owner (only the owner may `reseed` / `regenworld`, and that is allowed on live servers). In Studio, negative-id test players are admins too. The panel is Studio-only until `EnableInLiveServers = true`.
- **Admin panel decisions:** it replaced the old F2 console; commands for systems that don't exist yet (now only weather and building prefabs) are listed greyed out, not faked.
- **XP curve stays at `xpScale = 2.3`** for now. The journey sim showed it's slower than the doc's "Expert in ~26 h"; the owner chose to leave it.
- **R6 rigs everywhere (2026-11-03).** The owner's combat animations are R6, so players (Game Settings › Avatar › Avatar Type = R6), NPC rigs and test dummies are R6. `CombatAnimations.rigType` is the one switch; code that touches body parts handles both rigs.
- **PvP is on for all players (2026-11-03):** `pvp_enabled` defaults to true (`Config/Flags.luau`). The per-hit cap (`pvpMaxShare`, 60% of MaxHealth) still applies.
- **Life is Uncommon.** Mythic domains are Time, Gravity and Reality.
- **"Brush with Death" has a hard trigger:** health ≤ 5%, an enemy ≥ 1.5× stronger, and 10 s survived without healing. It's enforced through `requires`/`facts`.
- **Person-rarity rules were tuned:** a Gifted gift needs top affinity ≥ 0.55; Uncommon and Rare domains need ≥ 0.35. Measured shares: about 49 / 22 / 21 / 6.6 / 1.1, Common to Legendary.

## What exists (each system has a design doc)

| System | Doc | Key code |
|---|---|---|
| **Spell grammar**: 12 domains, ~130 branches + 10 hybrids, 58 properties, 10 verbs, 11 forms, 10 modifiers; recipes → stats; reservoir and overdraw | `docs/MagicSystem.md` | `src/shared/Magic/` (MagicCore, Registry, Reservoir, Seed, Data/*) |
| **Innate profiles**: gift tiers, affinities, temperaments, latent potentials, 30 awakening events, rarity, what people know about themselves, signatures | `docs/InnateProfiles.md` | `src/server/Magic/` (ProfileGenerator, InnateProfile, Data/ProfileTuning, Data/AwakeningEvents) |
| **Backend**: Bootstrap service locator, Net (validated, rate-limited remotes), DataService (session locks, retry, compression, migrations, mock store in Studio), Logger, SignalBus, FeatureFlags, ParallelPool template | `docs/Backend.md` | `src/shared/Core/`, `src/shared/Net/`, `src/server/Services/`, `src/server/Persistence/` |
| **Spellbook** with filtered spell names | Backend.md §9 | `Services/SpellbookService.luau` |
| **Progression**: XP per branch → mastery; 9 tiers gate verbs, forms and power; breakthroughs; 6 XP channels; focus vs breadth; unlock rules; specialization oaths; discoveries and signature spells; anti-grind | `docs/Progression.md` | `src/server/Progression/`, `Services/ProgressionService`, `SpecializationService`, `DiscoveryLog`, shared `Data/MasteryTiers`, `Specializations`, `Techniques`, `EnvironmentRules` |
| **Casting**: CastService validates intents (knowledge, tier, range, line of sight, aim plausibility, cooldowns, requirements, budgets), pays from the reservoir with seeded rolls, routes through EffectLibrary to effect resolvers, and awards XP, discoveries and survival facts. CastClient handles input, aim and prediction | `docs/Casting.md` | `Services/CastService`, `Magic/Data/EffectLibrary`, `Magic/Data/CastTuning`, client `Controllers/CastClient` |
| **Magic runtime**: ~40 data-driven routes and 19 resolvers; statuses; heat model and wind-driven fire; time, gravity, current and reality fields; InteractionMatrix reactions; BacklashService; EffectBudget (slots, token buckets, LOD); TerrainDeform (temporary Granite, water and ice, plus persistent ruptures and landslides); WaveSimulator (column height field) driving the tsunami; aftershocks; signature-tinted, tier-refined, pooled VFX | `docs/Runtime.md` | `Services/EffectRunner`, `BacklashService`, `src/server/Magic/Cast/` (Effects/*, StatusEffects, Damage, ThermalSim, FireSim, FieldEffects, InteractionMatrix, EffectBudget), `World/TerrainDeform`, `World/WaveSimulator`, shared `Data/SpellExamples`, client `src/client/Fx/`, `WorldEffectController` |
| **Player UI**: HUD (reservoir, region, hotbar casting, feedback, toasts, awakening moment), Grimoire, Spell Composer (Guided + Full, live `≈` previews), Settings; plain Luau + `Kit` helper (no framework); hotbar and settings saved; `ReservoirService` streams the reservoir | `docs/UI.md` | `src/client/Controllers/` (MagicState, Interface, Hud, Grimoire, Composer), `src/client/UI/`, `src/shared/UI/Settings`, `Services/ReservoirService`, `PreferencesService` |
| **NPCs**: deterministic people (Big Five + 8 traits, 58 quirks, households, 3 authored), utility AI with schedules, memory and gossip, relationships, chapter-based magical careers, grammar dialogue, T0/T1/T2 LOD with rig pool, town persistence | `docs/NPC.md` | `src/server/NPC/`, `Services/NPCService`, client `NpcDialogueController`; NPC tools in the Admin Panel |
| **Settlements** (in progress): fine site refinement, seeded layouts (plaza, contour-following roads, side streets, lots), terrain levelling applied with chunk builds, BuildingGenerator (all 11 building types) | `docs/Settlements.md` | `World/SettlementSites`, `SettlementLayout`, `SettlementStyles`, `BuildingGenerator`, `SettlementDecor`, `Services/SettlementService` |
| **Admin/Developer Panel** (F2): allowlisted, per-admin private remotes, typed command registry (`Register`), ~120 commands (teleport, movement, mastery/profile editing, spell cheats, world/time/terrain control, overlays, NPC tools, population), console with autocomplete, audit log, owner-only reseed | `docs/AdminPanel.md` | `Services/AdminService`, `Services/AdminToolsService`, `src/server/Admin/`, `src/serverstorage/AdminClient/`, `Config/AdminConfig` |
| **World**: 4,096-stud island; 15 biomes; ley lines; on-demand chunked terrain; POIs incl. 3 hidden mythic sites + lore hints; 8 cultures; 10 world events; tectonic stress, water volume and other environment facts; saved terrain edits; earthquake and tsunami resolvers | `docs/World.md` | `src/server/World/`, `Services/WorldStateService`, `EventDirector`, `POIService`, `Core/Scheduler` |
| **Quests, factions, reputation** (written 2026-11-03, not yet run): SituationDetector reads quest-worthy situations off world, NPC and player state; 18 templates with slots, staged approach options, creative-solution recognition by interaction tags, outcomes, escalation, NPC solving; Narrative Director pacing (tension, focus, novelty, power); shared crisis quests vs saved personal quests; 11 factions (3 secret), infamy, bounties, guards, mythic notoriety + Quiet Hand hunters; Journal (J) | `docs/Quests.md` | `src/server/Quests/`, `Services/QuestDirector`, `FactionService`, `ReputationService`, `JournalService`, client `JournalController` |
| **Items, inventory, equipment** (stage 1 of 5, written 2026-11-03, not yet run): 60 items in 16 categories, 65 affixes + 3 sets, 6 rarities with roll bands, seeded generator, compact instance records (uids), pure Inventory model with atomic transactions + rollback, 15 equipment slots with R15 gear models, bags, quickslots, StatCalc (ordered breakdown), focus tradeoff at power 6+, durability, consumables (heal, reservoir, buff, study, scroll spell, repair, cleanse), Inventory screen (I) + quickbar (Z X V B) | `docs/Items.md` | `src/shared/Items/`, `src/server/Items/`, `Services/InventoryService`, client `ItemStateController`, `InventoryController`, `UI/ItemWidgets` |
| **Functional buildings** (world-expansion stage 1 of 6, written 2026-11-03, not yet run): floors fixed (interiors cleared of terrain after every chunk build), working locked/unlocked doors (key, metal magic, lockpick, crime), registry-driven interactables with server ProximityPrompts (beds, chests/barrels/crates, the forge), containers through atomic two-inventory transactions, forge recipes with quality, access/theft rules, `buildingcheck`/`buildingaudit`/`door` | `docs/Buildings.md` | `src/server/Interact/`, `Services/InteractionService`, `ContainerService`, `CraftingService`, `World/BuildingGenerator`, shared `World/Interactables`, `Items/Data/Recipes`, client `InteractionController` |

The player save schema is **v4** (`Persistence/Schemas.luau`), with migrations v1→v2 (spellbook array → map), v2→v3 (mastery → XP) and v3→v4 (placeholder inventory → real inventory).

## Test status

- **Last confirmed full pass** (2026-11-02, after the world tuning): unit specs **79/79** (including the World spec), magic examples **33/33**, profile stats **14/14**, and the journey sim ran.
- **World for seed 1337:** all 14 surface biomes; ocean 39%; volcanic is rare (2 cells); 23 nexuses and 36 ley lines; 64 POIs and 14 settlements. Generation takes ~1.3 s; the spawn area is ready in ~4.3 s.
- **Player UI, CastService and the magic runtime (2026-11-02) are not yet verified in play:** all pass `rojo build` and luau-lsp (no new errors beyond the solver's known `pcall`/`xpcall` quirk, which `Bootstrap` and `Signal` also hit).
- **First NPC boot (2026-11-02):** specs 111/113. `Npc.spec` passed; both failures were in `Cast.spec` (its first run): an eagerly built `assert` message calling `MagicCore.describe` on a raw recipe, and a test caster with no mastery. Both are fixed and need a re-run. `NPCService` booted 216 NPCs in 14 towns in 3.2 s with no errors. Talk, the inspector, LOD and `npcday` aren't verified yet.
- **`Cast.spec`:** It covers routing, ~55 spell examples (grammar validity + expected route), statuses, interactions, budgets, and the Granite-is-unused invariant. The examples' recipes were composed by hand against the grammar tables, so the first run may flag one or two.
- **Admin panel, first run (2026-11-02):** specs **113/113** (both Cast.spec fixes held), magic examples 33/33, profile stats 14/14. Confirmed working: panel link, audit log, `testmage`, `npc`, `npcawaken`, `events`, `quake` at a picked point, `regenchunk`, `regensettlements` (216 NPCs rebuilt in 439 ms), `reseed` (closes the server). A double-clicked `reseed` ran twice (generation 1 then 2); now guarded to one per server. Fixed after play: the panel died on respawn (its remotes and script were in plain folders, which respawn deletes; now inside a `ResetOnSpawn = false` ScreenGui), and terrain edits could drop players through the map (new `World/CharacterSafety`: lift after edits, hold during chunk rebuilds, 0.5 s stuck/void safety net). Both still need a Studio check. Not yet exercised: fly/noclip, overlays, cast/spellstats/dummy, terrain tools, bookmarks, NPC inspector sliders, timescale.
- **Settlements step 1-2 + small house, first run (2026-11-02):** specs 119/121; layouts for 14 settlements in 1.4 s (176 lots, 18 failed, 3,124 terrain ops). Fixed after the run: a site with no dry ground fell back to its wet coarse pick (Coldfall in the sea, 0 roads; now retried at radius 56, else the candidate is skipped), 11 of 14 settlements were tidecall (chooseCulture now penalises repeats), dead lot spots were retried by every later building. Buildings in play not yet confirmed. Then (same day): the other 10 building types (shared `shell`: walls with openings, optional second storey with stairs, culture roof), a PointLight budget (160), and spawn fixes (findDryLand never returns water; spawn checked on built terrain with a 6x6 pad and moved onto the spawn city's plaza; respawn guard moves anyone who spawns in water). Not yet run. Then Step 4 decoration (`World/SettlementDecor`): NPCSpawn anchor, lamp posts (light budget), fences, goods, trees and rocks, culture flavour (forges, crystal spires, docks with boats, planters, banners, braziers, carts). **First run with buildings + decor:** specs 124/125 (the well had no anchor: fixed), 194/203 lots placed, 8 cultures in use; 20 s after boot 44 buildings, 107 decor, 26 lights, 2,659 parts around spawn. The plaza spawn move was refused because layouts finished before the spawn existed (fixed: setSpawn waits). NPC panel tools (npckill, npcdo teachme/duel/home/flee, npcgossip, npcheal, npcbond, trait/need sliders) ran without errors. Then: **NPCs moved into buildings** (docs/NPC.md §6b): households get houses (OwnerNPCId, NPCHome beds), professions work at NPCWork anchors, everyone spawns at the plaza NPCSpawn points; `Topics.BuildingBuilt` re-routes to real anchors. Not yet run. Check that roofs are peaked, not V-shaped (WedgePart orientation assumed: full height at +Z).
- **Not yet verified in play:** the console commands `pois vent` (at least one vent must exist for Energy's Master breakthrough), `quake 10`, `tsunami 10`, `startevent <type>` and `events`. Terrain changes and events have only been checked by code review.
- **What runs on Studio boot** (flags in `Config/Flags.luau`): the unit specs (`Tests/*.spec`) and `MagicExamples` (`debug_run_tests`), printed as ONE summary line ("Boot checks: specs N/M · magic examples N/M"; failures still print in full). `debug_verbose_boot` brings back every detail line and the settlement table; `ProfileStats` and `JourneySim` are off by default (`debug_profile_stats`, `debug_journey_sim`). Specs log details through `t.log`; a spec that provokes an error on purpose wraps it in `Logger.expecting(event, fn)`.
- **Quick-wins pass (2026-11-05, not yet run; from docs/Improvements.md):** git baseline commit (`baseline` branch), the quiet boot above, the crime-while-learning fix (World.md §settlement law: harm judged after landing; `PracticeTarget` dummies), Future lighting + Atmosphere/Bloom/ColorCorrection/SunRays in `default.project.json`, FxRecipes on DomainFx textures.

- **First boot with combat + quests (2026-11-03):** after renaming the admin command `reputation` → `standings` (it clashed with `rep`'s alias), 25 server modules booted; specs **154/154** (incl. Combat.spec and Quest.spec), magic examples 33/33, profile stats 14/14, 216 NPCs in 14 towns. The `lock_lost k1_…` error in that log is Core.spec's deliberate lock-steal test. Not yet exercised in play: casting with the new VFX/damage, NPC fights, conduction, explosions, the status bar, any quest command or the Journal.
- **First play session with quests (2026-11-03).** Fixed after it:
  - every director check crashed (`math.max` got `getMasteryTier`'s second return value);
  - knocking out an NPC errored in the T0 loop (rig already gone);
  - console commands failed with a leading `\r` (Enter re-typed after refocus; now split on any whitespace + trimmed server-side);
  - shared crises ended as "locals" every scan and re-spawned (the situation cap trimmed live world situations; NPC situations never aged out). Now: `lastSeen`, NPC situations expire after a full NPC cycle, the cap never drops a live situation, cap 400, and a re-offer cooldown for ended shared quests.
  - Second session: every faction deed crashed (`string.gsub`'s count leaked into `addStanding`'s opts; parenthesised). `hunters` now starts the hunt directly. Locals can't solve a quest in its first quarter (the 4%/game-hour roll was ending crises within 2 minutes). Offers and starts are logged (`quest_offered`, `quest_started`).
  - Seen working: `testmage`, quakes with terrain edits and structure collapse, scorch marks, `knockdown`, casting crimes (`cast_judged`), NPC knockouts, drought and monster-migration events.
- **Crushing gravity fields (2026-11-03, not yet run):** heavy gravity fields cast with generate or amplify now damage everyone inside but the caster (15% of a hit per second, falloff, knockdowns). Heavy and light fields spare their caster. See Combat.md.
- **Quest map pins (2026-11-03, not yet run):** `QuestDirector.pinsFor`/`pushPins` (the `QuestPins` remote, owner only, on change) + client `Controllers/QuestPinsController` (world markers + an edge arrow for the tracked quest), the `questMarkers` setting, and auto-tracking of a new quest.
- **Quests, factions, reputation (written 2026-11-03):** `rojo build` clean, no diagnostics in the new files.
  - New spec: `Tests/Quest.spec` (template consistency, factions, objective rules).
  - Touches existing code:
    - CastService publishes `SpellResolved`;
    - EffectRunner damage topics carry `npcId`;
    - `judgeCast` publishes `CrimeCommitted`;
    - NPCService gained `get`, `setLeash`, `setTalkHook`, `questBond`, the "quest" talk topic and `opts.faction` on spawn;
    - `Damage.apply` honours `QuestWard`;
    - ProgressionService gained `awardQuest`;
    - new save fields (quests, journal, factions, infamy, bounties, notoriety) arrive by reconcile, with no schema bump;
    - the `quests_enabled` flag.
  - Pre-existing luau-lsp type errors in WorldStateService (not from this change) showed up when it was edited.

- **Items stage 1 (2026-11-03), first boot:** specs **187/187** (Items.spec's 33 new tests included), magic examples 33/33, profile stats 14/14, 26 server modules, no item errors. Not yet exercised in play: starter kit, the Inventory screen, equip/visuals, quickbar, consumables, admin item commands. Before that boot: `rojo build` clean; luau-lsp clean apart from admin `args` table-literal inference (same as the existing Combat.luau). New spec `Tests/Items.spec`.
  - Touches existing code:
    - CastService (`StatCache.applyToCast` after step 7, `applyToConsequences` after payment, `bonusModifierSlots`/`bonusFormTier` before validation, new `castFromItem`);
    - MagicCore.validateRecipe honours those two bonuses;
    - ReservoirService applies gear capacity and regen;
    - Resistances gained an `items` source (`setItemProvider`);
    - Data/Gear is now built from the ItemDatabase (`npc_gear` tag);
    - QuestDirector pays and receives coins through `InventoryService:addCurrency`;
    - admin category "Items";
    - HUD menu button;
    - flags `items_enabled` and `items_debug_log`;
    - topics `ItemsGained` and `ItemUsed`.
  - **Next item stages, in the owner's order:** loot/containers/harvesting → crafting/alchemy/enchanting → economy/trade → survival and movement.
- **Items Step 2 finished (2026-11-03, not yet run; Items.md §10–11):**
  - Weapons fight when no spell is readied: melee combos per kind, bows (draw), crossbows (reload), knife bandolier. Shared `Items/Data/WeaponTuning` + `Items/WeaponRules`; `Services/WeaponService` (remotes `WeaponIntent`/`WeaponResult`); client `Controllers/WeaponClient` (hooks into `CastClient.weapon`) and `Fx/WeaponFx` (`weapon` WorldEffect cue).
  - `Services/StaminaService` (Player attributes `Stamina`/`StaminaMax`, HUD bar, admin `stamina`/`infstamina`).
  - Weapon blocks: GuardService accepts a blocking weapon with no spell readied (look `steel`), paid in stamina.
  - Repair: `Shared/Items/Repair`, `ItemRules.repair`/`mend`; forge/workbench/loom `RepairAction` (CraftingService) with a Repair card on the Crafting screen; Earth/Metallurgy magic mending (`InventoryAction "mend"`, Inventory "✦ Mend" button).
  - New items: `light_crossbow`, `knife_bandolier`, `wooden_arrow`, `iron_bolt`, `throwing_knife`; `Delivery.newId()`; GearVisuals `crossbow` shape; six stats now wired. New spec `Tests/Weapons.spec`.
  - Still open from Step 2: trading (Step 5) and world drops (Step 3). Weapon animations beyond Slash1/Slash2 are listed in `WeaponTuning.animations`.
  - `rojo build` clean; no diagnostics in the new files (selene's stale "Repair/ItemTypes not defined" in CraftingService/InventoryService predates the require lines, which are there).

- **Functional buildings (2026-11-03, not yet run):** `rojo build` clean; luau-lsp clean in the new files apart from admin `args` literal inference (as before). New spec `Tests/Buildings.spec`; Settlement.spec's door test now expects a closed, solid door.
  - Root cause of the missing floors: lot levelling ops are bucketed per overlapped chunk, but street and neighbour-lot ops reaching into a lot from another chunk refill terrain over the floor when that chunk builds later. Fixed by clearing each building's interior box at build and after every later nearby chunk build.
  - Touches existing code: BuildingGenerator (floor slab, door leaf, interact() tagging, interior attributes, Access), SettlementService (`clearInterior`), Inventory (`cap`, `removeMatching`, `transactMany` with a cross-inventory uid check), InventoryService (`transact`, `transfer`, `ownerKey`), InterfaceController (`hidden` screens), Items (`skeleton_key`), Remotes, Topics (`ItemCrafted`), Flags (`interact_enabled`, `buildings_lock_doors`).
- **Functional buildings, part 2 (2026-11-03, not yet run; part 1 not yet run either):**
  - What's new:
    - stations: workbench, loom, cooking hearth (needs a lit fire), alchemy table, enchanting desk, with recipes and 8 new materials;
    - furniture and rooms: wardrobes, bookshelves (seeded books → study/lore), lamps and fireplaces (Interact/Lamps: lit at dusk when occupied, cap 60, Warm attribute), a notice board (opens the Journal), wells, a training dummy, meditation mats (new Meditating reservoir activity), ward stones, the focus-crystal pedestal (insight);
    - NPCSeat anchors and a LotCFrame attribute;
    - player housing (HousingService: world-store claims, deed signs, personal storage in the player save, furniture placement with a ghost).
  - Admin: `lights`, `lamps`, `house`.
  - Save: `housing` field (reconcile) and a new `Housing` world store.
  - `rojo build` clean; luau-lsp clean apart from the known `pcall` quirk and the admin `args` literals.
  - **Next world stages, in the owner's order:** caves → creatures → lairs → secrets → wilderness details.
- **Combat animations + action states, prompt 1 of `docs/Prompts-MagicCombat.md` (2026-11-03, not yet run; Combat.md §11):**
  - New: shared `Data/CombatAnimations` + `Magic/ActionRules`, server `Cast/ActionState`, client `Controllers/AnimationController`, `Tests/Animation.spec`.
  - Touches: CastService (state gate + `casting` state), HitReactions (`staggered`), NPCCombat (`casting`), NPCLOD (combat clips in the rig pool, `followState`), CastClient (predict/cancel), HUD reason text, CastTuning `minCastAnimation`, flag `combat_anim_debug`, admin `anim`/`npcanim`/`actionstate`/`npcstate`/`animstate`.
  - **VFX textures (2026-11-05, not yet run):** the whole Kenney Particle Pack is uploaded (`Fx/KenneyTextures`, name → id); `DomainFx.UPLOADED` maps each texture role to a Kenney name. Spell colours are now the domain palette tinted by the signature (`SpellFx` `SIGNATURE_TINT`). Also fixed: `FoundationBuilder.verify` crashed iterating `ReadVoxels`' `Size` field (most buildings weren't built).
  - **Verified in play (2026-11-05):** the owner reports all the new VFX work (`fxpreview` across domains and tiers). After the FoundationBuilder fix, 44 buildings were built (was 3), but **every checked foundation failed** (27/27, every ray hit): terrain ends ~0.5–2 studs above the planned fill top (lot level − 0.25), often just above the floor top, though nothing but the layout/foundation ops writes terrain there. The owner looked: floors are clean (no grass or dirt through them); the red bumps were the Studio failure markers. So the check was too strict: it now fails only terrain more than 0.6 studs above the floor TOP (`FoundationBuilder` `SHOW_THROUGH`). **Re-run confirmed:** `built=44 foundationsChecked=27 foundationsFailed=0`, no markers, no foundation errors; specs 297/299 (only the 2 known Settlement failures).
  - **More VFX (2026-11-05; Combat.md §8):** lightning for `charge` beams/chains and conduction (`SpellFx.lightning`; Conduction's chain cue now carries `property = "charge"`), projectile muzzle flashes and streak trails, slash arcs (`Fx/SlashFx` + `Controllers/SlashFxController`), and the admin command `fxpreview` (`Admin/Commands/Fx`). FxPool now resets beam/trail texture and brightness on reuse.
  - Run's real id is 136370984503271 (2026-11-05); it replaces the walk/run sets of the default Animate script through `CombatAnimations.locomotion` (players only; NPC rigs not yet). Not yet run.
  - `rojo build` clean; no diagnostics in the new files.
  - **Verified in play (2026-11-03):** after switching to R6, CastSpell and Dash play on players and NPCs. `Block` (old id 128098131606169) failed to load (ownership); re-uploaded by the owner as 111952812431898.
- **Equip mode, prompt 2 (2026-11-03, not yet run; Casting.md §6):**
  - New: `Services/AttunementService`, client `Controllers/AttuneGlowController`, remote `AttuneSpell`, setting `castMode` (equip default / quick), `Tests/Attunement.spec`.
  - Touches:
    - CastService (`NOT_ATTUNED`, client casts only);
    - CastClient (pressSlot/attune/stow/castAttuned, facing the aim, crosshair, wheel swap, gamepad L2/R2);
    - HudController (attuned outline + ✋, touch Cast/Stow buttons);
    - MagicStateController `attune`;
    - SpellbookService `hotbarKey`/`recipeOf`;
    - StatusEffects `setWalkMultiplier`;
    - CastTuning `attuneSwapCooldown`, `attunedWalkMult`.
  - **Verified in play (2026-11-03):** specs 242/244 (only the 2 known Settlement failures), and equip-mode casting works.
- **Aim + reticles, prompt 3 (2026-11-03, not yet run; Casting.md §7):**
  - New: shared `Magic/Aim` (the single source for range, sight, flight, beam, cone and chain-hop maths and their tuning), client `Controllers/AimController` (aim sampling + soft lock-on) and `Controllers/ReticleController` (a guide per form), setting `aimGuide`, `Tests/Aim.spec`.
  - Server now reads its aim tuning from `Aim.tuning` (CombatTuning, CastTuning): Delivery.plan, Targeting.lineOfSight/chainJump, CastService range (now from the muzzle) and eye.
  - CastClient.aim delegates to AimController.
- **Hold to charge / channel, prompt 4 (2026-11-03, not yet run; Casting.md §8):**
  - New: shared `Magic/Charge` + `Data/ChargeTuning` (Quick/Charged/Full/Overcharged; Charged = today's cast), remotes `CastHold` (begin/cancel/release) and `ChannelAim`, action state `channeling`, `holdAt` freeze/resume in AnimationController and NPCLOD, `Tests/Charge.spec`.
  - Touches:
    - CastService (holds timed on the server clock, charge applied after StatCache, channel release + capped aim sweep);
    - CastClient (pressCast/releaseCast/cancelCharge);
    - HudController (charge meter; touch Cast is press-and-hold);
    - AttuneGlowController (stage glow, hum, overcharge shake);
    - ReticleController (grows with the stage);
    - NPCCombat (telegraphed seeded charge);
    - Delivery (`ctx.speedMult`);
    - AttunementService `equipMode`/`attunedRecipe`;
    - CombatTuning aggro charge shares.
  - Quick mode is unchanged.
- **Guards, prompt 5 (2026-11-03, not yet run; Combat.md §12):**
  - New: shared `Magic/GuardRules`, server `Cast/Guard` + `Services/GuardService`, remote `GuardIntent`, client `Controllers/GuardFxController`, `Tests/Guard.spec`, admin `npcguard`/`guard`.
  - Touches:
    - Damage.apply (guard before wards; Info gained property/pierce/form/attacker);
    - DamageModel.hit (fills them);
    - Delivery (projectile parry → reflect home, `onReflect`, `reflectedBy`);
    - CastService.strike (reflect cues, a returned bolt lands on its caster as a backfire; a guard cancels a charge);
    - NPCCombat (reactive guards, reflected bolts can hit the NPC);
    - AttunementService (stow lowers the guard);
    - CastClient (right mouse / L1);
    - HudController (guard meter, touch Block, refusal texts);
    - ReticleController and Composer (guard tags);
    - AnimationController and NPCLOD (hold the entry pose when a loop clip is unusable);
    - CombatTuning aggro guard numbers.
- **Spellblade, prompt 6 (2026-11-03, not yet run; Combat.md §13):**
  - New: shared `Magic/Melee` + `Data/MeleeTuning`, server `Services/MeleeService`, remotes `MeleeIntent`/`MeleeResult`, `Tests/Melee.spec`.
  - Touches:
    - CastService (finisher via `consumeFinisher`);
    - CombatAnimations (slashing can cancel into block/dash/cast/slash);
    - AnimationController (`predict` variant, `hitStop`; failed clips retried on every respawn);
    - CastClient (F / gamepad B, buffered combo);
    - HudController (touch Slash);
    - AttuneGlowController (blade trail);
    - MagicStateController (`slash`, melee events).
  - Melee XP: 20% of a cast to the attuned branch.
- **Foundations + town ground (2026-11-03, not yet run; docs/Settlements.md §5b–5d):**
  - What's new:
    - `World/FoundationBuilder`: voxel-snapped stone foundation, yard apron and downhill steps under every lot, plus a raycast/voxel verification after each build (`foundation_failed` / `foundation_fixed`, red markers in Studio, flag `foundation_markers`, shown in `buildingcheck` / `buildingaudit`);
    - `World/SettlementGround`: the town ground mask (core / inner / outer), shoulders, desire paths, deliberate grass patches; painted per chunk after the generated ops, before saved edits.
  - Touches existing code:
    - generated ops carry `c = true` and are clipped to the chunk being built (`TerrainBuilder.applyOp(op, clip)`, `applyChunkOps`), and WorldStateService gained `setGroundPass` and `wetnessAt`;
    - the floor is 1.2 thick, top at +1.55 (FLOOR_Y 1.5), with walkable door steps (≤ 0.6), a plinth that reaches down on slopes, and flagstones (`spec.path`);
    - Decor: trees obey the mask, plus street trees, gardens, orchards, a green, curbs, hay, puddles and cart tracks.
  - The owner asked for Step 2 without reporting a Studio run of Step 1, so neither is verified in play. Steps 4 (admin/debug tools: settlement teleport, mask overlay, per-building report, regen one settlement/building, Decoration toggle, grass check) and 5 (test plan) are still to do.

## Admin panel (F2)

Full reference: `docs/AdminPanel.md`. `help` lists everything and `help <command>` explains one. In the console, Tab completes, `@cursor` is the world point under the mouse and `@selected` is the inspected NPC.

- **Buildings:** `house claim` (free nearest vacant house), `lamps on`, `lights`, `buildingcheck` (teleports into the nearest house + checklist), `buildingcheck smithy`, `buildingaudit`, `door unlock`, `flag buildings_lock_doors false`.
- **Items:** `kit me caster`, `give me oak_staff 1 legendary`, `give me ember_orb 1 epic ember_touched,of_haste`, `itemstats`, `itemroll ember_orb 5000`, `wear me chest 200`, `repairall`, `invlog`.
- **Fast test setup:** `unlockall 8` or `setmastery earth/metallurgy Grandmaster`, `cheat all`, `testspells`, `tp shrine`, `timescale 20`, `overlay ley`, `npclist`.
- **Studio only:** `testmage`, `testspells`. **Owner only:** `reseed`, `regenworld` (typed `RESEED`).
- **Spellbook** (local to the panel): `book`, `learn …`, `rename <n>`, `forget <n>`.

## NPC simulation system (written 2026-11-02, not yet run in Studio)

Design doc: `docs/NPC.md`. Code: `src/server/NPC/` (NPCFactory, NPCBrain + UtilityScore, ScheduleService, MemoryService, RelationshipGraph, NPCMagicLife, DialogueEngine, NPCLOD, WorldClock, Data/*), orchestrated by `Services/NPCService`.

- **NPCService** boots after the world (a Scheduler job), runs Heartbeat LOD/brain loops and hourly T2/social/relief/chapter work, reacts to `MagicWitnessed`, `MagicDamage`, world events and cross-server awakenings, handles `NpcTalk` (≤ 14 studs; `learn` → `ProgressionService:awardStudy(…, "mentor", npcId, {mentorTier})`) and exposes a public API for the Admin Panel's NPC tools (inspect, spawn, edit, force actions, rebuild, simulate days), and saves dirty towns every 120 s with a merging `Store.update`.
- **Client:** `Controllers/NpcDialogueController` (Talk prompt → panel layer; `NpcSpeech` → chat bubbles) and `SpellFx.styleFor(userId, domain, signature?)` so NPC work casts are signature-tinted.
- **NPC work casts are cosmetic cues**, not CastService casts.
- **Fixed on the way:** NPCFactory lerped the signature's hex *string* (now `InnateProfile.signatureColors`); every `for … in x or {} :: T` site in the NPC modules is now parenthesized.
- **Not yet done:** the three day traces in NPC.md §9 (paste from `npcday`).

## IN PROGRESS: combat and VFX rebuild (requested 2026-11-02)

**The owner's report:** spells cast and consume resources, but most don't deal damage or apply their effect, and visuals are weak. Design doc and audit: **`docs/Combat.md`**.

**Done and written (2026-11-02), `rojo build` clean, NOT yet run in Studio:**
- **Step 1, the audit** (Combat.md §1). The root causes:
  - damage was ~5 at P3 (`4·power^0.7`, fire ×0.5);
  - instant hits against a stale aim point;
  - chains with a 0 jump radius;
  - 0-width rays;
  - no hit feedback;
  - dim, tiny, 3-texture VFX.
- **Step 2, the core:**
  - `Data/CombatTuning`; `Cast/DamageModel`, the one formula (base `9·power^0.6`, share, area falloff, `Resist_<domain|property>` attributes, seeded variance and crits, caps incl. 60% max per PvP hit);
  - `Cast/Delivery`: server-stepped projectiles with gravity, homing, pierce, bounce and splash;
  - `Targeting`: a touch cone, thick beam sweeps, real chain hops with sight, area occlusion;
  - CastService: re-aims at moving targets, `strike()` per cast/echo/pulse, `launch`/`chain` cues, a per-cast `cast_hits` log (`combat_debug_log` flag), and `damage` in CastResult;
  - `Damage`: info (domain, crit, kill), per-thread recording, an `onHeal` hook;
  - `StatusEffects.onApplied`;
  - Topics `SpellCast`, `SpellHit`, `TargetDamaged`, `TargetKilled`, `StatusApplied`;
  - EffectRunner sends `hit`/`heal`/`statusTag` cues (DoT summed every 0.75 s);
  - every damaging resolver (Impact, Thermal, Force, Status, Siphon, Terrain) goes through DamageModel; heals are raised to `8·power^0.6`.
- **Step 3, the VFX:**
  - `Fx/DomainFx` (per-domain material data; built-in assets verified on disk);
  - `Fx/FxLayers` (animation scheduler, flat-particle shockwaves, runes and ground marks, pooled lights, budgeted sounds, cast circle);
  - SpellFx rebuilt: cast circle + charge, projectiles mirroring the server flight, two-layer beams, chain arcs, a full impact recipe, area-form shapes;
  - `Fx/CombatFeedback`: damage numbers, hit markers, hurt flash, hit-stop, status words;
  - a new **Damage numbers** setting;
  - FxPool caps raised, lights pooled, anchors fully reset.
- **New spec:** `Tests/Combat.spec` (formula, crit rate, resistance, falloff, caps, chain jump, flight planning).

**Then (same day; also `rojo build` clean, NOT yet run; Combat.md §9):**
- `Cast/HitReactions`: a knockdown status (30% hit, or kinetic P4+ at 12%; 4 s immunity; NPCs PlatformStand, players fall on their client) and NPC flinch (Waist tilt + pause).
- `NPC/NPCCombat`: a threat table; fight or flee from courage (traits, magic tier, health, guard bonus); fighters cast real bolts via Delivery + DamageModel (no reservoir; ~2.2 s interval); fleers jog away; guards and hunters join. NPCService skips brain routing while engaged.
- `Cast/Conduction`: `charge` spreads through metal (flood fill) and water (incl. the caster).
- `Cast/Explosion`: P3+ blasting area harm throws loose parts; P5+ rips anchored Decor/Breakable/Rubble loose (cleaned up after 20 s).
- `Cast/Resistances`: four sources:
  - NPC innate (affinities + traits);
  - wards (`resist` on statuses: Ward resists all by `0.06 + 0.025·P`);
  - gear (`Data/Gear`, `Gear_<slot>` attributes; NPCs wear their occupation's set; players via the `gear` admin command);
  - manual `Resist_*`.
- HUD status bar (`Shared/Magic/Data/StatusInfo`, `MagicStateController.statuses`).
- Admin commands: `resists`, `npcresists`, `gear`, `resist`, `knockdown`, `npcfight`, `npccourage`.
- Combat.spec extended.

**Still to do (Combat.md §10):**
- slippery ice;
- beam reflection;
- status stacks;
- target body overlays;
- a full NPC spell repertoire and NPC-vs-NPC aggro;
- a gear/inventory UI;
- commissioning custom assets.

**The owner's Step 3 brief was cut off at "shockwave ring (expanding"; ask for the rest and reconcile it with Combat.md §8.**

## What's next (priority order)

**Roadmap (2026-11-03): `docs/Roadmap.md`.**
- The strategy: freeze features; carve a vertical slice (Energy + Earth, the spawn town) out of the existing code with flags; verify it; then re-enable systems one milestone at a time (M1–M11, about 150–210 sessions).
- Week-1 tasks are in its §7. The first one is `git init` + a baseline commit: the repo has no commits yet.
- The list below is the older backlog; where they conflict, follow the roadmap's order.
- **Owner's ideas prompt pack (2026-11-05): `docs/Prompts-Ideas.md`** (11 prompts, simplest first: improvements audit, magic ideas, engagement ideas, controls panel, Composer explanations, run/Alt toggles + dash, sounds + music, NPC looks, early game, gravity powers, time powers). Prompt 4 built (2026-11-05, not yet run): the Controls screen (H) from `Shared/UI/Controls` + `Tests/Controls.spec`, with two input clashes fixed on the way (docs/UI.md §7 Controls). Prompt 1 done: **`docs/Improvements.md`** (audit, 2026-11-05). Its biggest new finds: harmful casts in a licensed town are crimes even with no target (a new player gets a bounty in ~7 practice casts), there's no map, the repo still has no commits, real DataStores are untested on the published place, and `Lighting.Technology` is pinned to Voxel.
- **Early-game prompt pack (2026-11-03): `docs/Prompts-EarlyGame.md`** (8 prompts). Audit finding: Earth, Mind, Void, Space, Time and Reality had no `harmful` property in their root branch; Life could only attack from Novice; Space and Time couldn't `generate` at all.
  - **Prompt 1, domain strikes (written 2026-11-03, not yet run; Combat.md §14):** shared `Data/Strikes` + `Magic/Strike`, server route `strike` + `Cast/Effects/Strike`, statuses `dazed`/`jinxed` (+ `critTaken`, `stripBeneficial`), `Compatibility.propertyVerb` (generate tempo/distance) read through the new `Registry.verbPropertyEff`, Composer "Strike" line, 7 SpellExamples, `Tests/EarlyGame.spec`. MagicExamples' "generate distance" rejection became "generate position". `generate probability`/`growth` on point forms changed route (fortune/restore → strike). `rojo build` clean; no diagnostics in the new files. No RECIPE_VERSION bump: the recipe shape didn't change, and routes are resolved at cast time.


1. **Verify the runtime in play** (docs/Runtime.md §6 walkthroughs, §7 stress checklist), then close the gaps in Runtime.md §9:
   - a mutation system (rolls are only logged);
   - hold-to-channel input;
   - NPC casting through the same resolvers;
   - signature audio (timbre/pitch);
   - a proper wave mesh.
2. **Client presentation (rest):**
   - done: HUD, Grimoire, Composer, CastClient, and spell/field/wave/quake/reaction/status VFX;
   - still to build: world-event visuals (sky), a DecorationController (client-only trees and rocks from public per-chunk data), map markers (`PoiMarkers`), and the designed-only screens in docs/UI.md §4.5–4.8 (Path, Self, Journal, NPC dialogue).
3. **NPC system:** verify in play (talk, the panel's Inspector tab, LOD at a city, a knockout, a drought with farmers relieving it, `npcawaken`), paste the day traces into NPC.md §9, then real NPC casting through the same resolvers (CastService assumes a Player today) and building prefabs for districts.
4. **Server-side movement checks** (anti-teleport/speed), as described in Backend.md §8.
5. **Mythic runtime systems:** Reality's Convergence and Paradox, the edit ledger for reality edits, the Time rewind buffer, gravity zones (InnateProfiles.md §6).
6. **Later:**
   - building prefabs for POIs, and dungeon content;
   - compacting heavily edited chunks into voxel diffs;
   - global feature-flag overrides;
   - MemoryStore rumours and leaderboards;
   - golden-snapshot tests for the generators;
   - hybrid branches' overdraw should report both domains' risk ids (currently only the first).

## Open design questions (still unanswered)

- Should disaster scars (quakes, erosion) heal over time unless anchored, or stay permanent (current behaviour)?
- What happens to a player after repeated crimes in a settlement? **Built (proposal):** infamy, Concord bounties at infamy 25, guards attack at 40, atonement quests. Banishment is still open.
- World size: keep the single 4,096-stud island, or add a second continent later?
- Where does mythic `fragment:` knowledge come from? **Proposed and built:** the mythic breadcrumb quest (Something Older) fed by POI hints, plus the secret Seam Keepers. Loot and mythic mentors are still open.
- Is the Rite of Unbinding repeatable from a temple, or a rare item (currently a 10% hermit-tower drop)?
- Should breakthrough requirements be visible up front, or revealed as hints?
- Can players share or teach named spells? In cast announcements, should others see the custom name or the generated description?
- What happens after a player knocks out an NPC? **Built (proposal):** settlement −15, faction standing for its factions, a crime (infamy, maybe a bounty), and the NPC fights back or flees.
- **VFX (parked 2026-11-05, the owner wants these built someday):**
  - Should non-`charge` Energy spells (plain fire) get some lightning too, or keep lightning strictly electric?
  - Should weapon slash arcs differ by weapon: wide sword arcs, a thin streak for spear thrusts, a heavy chop for axes?
  - Should `fxpreview` also demo guards and parries?
  - Is the signature tint right (primary 25%, secondary 40%, accent 100%)? Should Mythic domains ignore the signature so they're unmistakable?
  - One rune circle for everyone (`magic_02`), or one per domain (`magic_01`/`magic_02`/…)?
  - Does walking need its own slower clip, or is Run fine at walking speed?
  - Smaller follow-ups: slash arcs for NPC swings; draw your own arc at the button press, not after the server's state arrives.
- Should players keep the Modest gift-tier floor? Should WorldGen deliberately seed one hidden mythic NPC per world? Should Reality's Paradox show as a visible meter?

## Conventions

- **Bootstrap modules** (`Services/*`, `Controllers/*`) declare `dependencies`. `ctx.get` only works for declared ones. `init` must not yield; anything that yields goes in `start`.
- **Remotes:** every remote is declared in `src/shared/Net/Remotes.luau` and used only through `Net`. The one exception is the Admin Panel's per-admin pair in PlayerGui (a shared remote would be visible to every client).
- **Admin commands:** one `admin:Register({ name, category, description, args = {typed schema}, handler })` per command; services register their own, cross-system tools live in `Server/Admin/Commands/*`. Never parse raw strings in a handler: add an argument type (`RegisterType`) instead.
- **Bus topics** are declared in `Core/Topics.luau`.
- **Heavy work** goes through `Scheduler.spawn` + `Scheduler.checkpoint()`. Jobs must never yield any other way.
- **Ids are permanent.** Renames go through `Data/Aliases`. Bump the version constants (`RECIPE_VERSION`, `PROFILE_VERSION`, `GENERATOR_VERSION`, schema `version`) when behaviour changes for existing data.
- **UI:**
  - screens register with `InterfaceController` in `init`;
  - data comes only from `MagicStateController` Values;
  - re-render regions with `Kit.dynamic`, and keep TextBoxes outside dynamic regions;
  - colour is never the only cue (glyph or word, plus monogram or shape);
  - add settings in `Shared/UI/Settings` (validated server-side, and filled into old saves by reconcile).
- **Magic runtime:**
  - every magic hit goes through `Cast/Damage` (wards, hexes, NPC hooks);
  - every part an effect touches is charged to `EffectBudget.takeParts` (terrain writes to `takeTerrainOps`);
  - durational effects belong to `EffectRunner`;
  - a new spell effect is a route in `EffectLibrary` + an `Effects/<Name>` resolver + a `SpellExamples` entry;
  - budget refusals go in a resolver's `precheck`, so they happen before payment;
  - temporary terrain uses only Granite / pour / freeze (all revertible); persistent edits are carving or natural materials, through `TerrainDeform.commit`.
  - terrain that can fill where people stand must call `CharacterSafety.checkArea` (WorldStateService.edit and raiseStone already do); ice is exempt on purpose (freeze traps swimmers).
- **Never send secrets to clients:** the world or terrain seed, ProfileTuning, hidden latents, and mythic site locations.
- **luau-lsp quirk:** `for _, x in t.field or {} do` raises a false error. Write `for _, x in (t.field or {}) :: { T } do`.
