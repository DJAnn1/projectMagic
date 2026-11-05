# NPC Simulation

Settlement NPCs: who they are, what they want, how they spend their day, what they remember, who they like, how their magic grows, what they say, and how 300 of them stay cheap.
This builds on [InnateProfiles.md](InnateProfiles.md) (NPCs get the same innate magic as players), [Progression.md](Progression.md) (mentoring), [World.md](World.md) (settlements, cultures, events) and [Runtime.md](Runtime.md) (the damage path NPCs react to).

Status (2026-11-02): code complete, it passes `rojo build`, and `Tests/Npc.spec` covers the pure logic. **Not yet verified in play.** The three day traces in §9 still have to be pasted from Studio (`npcday`).

---

## 1. Module map

| Module | Where | Role |
|---|---|---|
| **NPCService** | `Services/NPCService` | Orchestrator: boot, LOD and brain loops, hourly social life, reactions, remotes, persistence, console |
| **NPCFactory** | `NPC/NPCFactory` | Deterministic people from `(worldSeed, npcId)`, plus households |
| **NPCBrain** + **UtilityScore** | `NPC/NPCBrain`, `NPC/UtilityScore` | Needs, utility scoring, decisions. UtilityScore is pure and also runs on Actors |
| **ScheduleService** | `NPC/ScheduleService` | Districts, personal spots, day plans with shifts |
| **MemoryService** | `NPC/MemoryService` | Episodic memory, decay, opinion, gossip |
| **RelationshipGraph** | `NPC/RelationshipGraph` | Directed edges: affinity, trust, rivalry, bond |
| **NPCMagicLife** | `NPC/NPCMagicLife` | Magical careers by 7-day chapters: study, mentors, schools, rivals, inventions, forbidden study, mythic awakening, work casts |
| **DialogueEngine** | `NPC/DialogueEngine` + `Data/DialogueGrammar` | Context → grammar expansion → personality styling; optional model hook |
| **NPCLOD** | `NPC/NPCLOD` | T0/T1/T2 tiers, rig pool, cached pathfinding, movement |
| **WorldClock** | `NPC/WorldClock` | The shared game calendar |
| Data | `NPC/Data/NpcData`, `Quirks`, `NeedsActions`, `DialogueGrammar` | Traits, names, 17 occupations, values, fears, secrets, goals, ambitions, 3 authored NPCs, 58 quirks, needs, actions, schedules |
| Worker | `ServerStorage/Workers/NpcScoringWorker` | Parallel T2 scoring (requires the same UtilityScore) |
| Client | `Controllers/NpcDialogueController`, `Fx/SpellFx.styleFor(…, signature)` | Talk panel and chat bubbles; NPC-tinted work casts. The inspector and every NPC tool are in the Admin Panel ([AdminPanel.md](AdminPanel.md)) |

```
WorldStateService ready ─► NPCService.boot (Scheduler job)
   town records (DataStore, read first) ─┐
   placement.settlements ─► authored overrides ─► NPCFactory.populate ─► enrich ─► RelationshipGraph.seed
                                         └─► applySaved (awakenings, memories of players)
                                             ─► NPCMagicLife.advance(chapter) ─► NPCBrain.compile/decide ─► route

Heartbeat:  LOD.assign/sync (0.5 s) · stepT0 (10 Hz) · stepT1 (2 s) · T0/T1 brains (1 s / 5 s, 1 ms budget)
Game hour:  T2 brains (ParallelPool ≥ 64) · social pairing + gossip · event relief · knockout recovery · chapters
Bus:        MagicWitnessed · MagicDamage · WorldEventStarted/Ended · PlayerDataLoaded · WorldEventRecorded
```

## 2. Identity and personality

Every NPC is regenerated from the seed on every server. Nothing about who they are is saved. Each aspect has its own random stream (`npc.age`, `npc.traits`, `npc.quirks`, …), so changing quirk tuning never renames anyone.

Traits are 0..1 (0.5 = average). Each is drawn as the mean of three uniform rolls, then shifted by culture and age band, then by quirks.

| Trait | Effect |
|---|---|
| openness | Study and wandering appeal; invents techniques; tolerates strange magic |
| conscientiousness | Keeps to schedule (> 0.75 starts work an hour early, < 0.25 an hour late); steady study habit |
| extraversion | Social need decays faster; seeks taverns; taciturn below 0.3 (one-sentence lines) |
| agreeableness | Warmer first impressions; anger instead of grief when low |
| neuroticism | Safety weighs more; negative memories hit harder and last longer; hedges in speech |
| ambition | Purpose decays faster; studies toward the ambition; backlash risk; forbidden study |
| curiosity | Explores; notices a hidden mythic stirring in themselves |
| pride | Rivalries and duels; proud coworkers grate on each other |
| loyalty | Family bonds stronger; worship appeal |
| greed | Wealth weighs and decays more; trade appeal |
| compassion | Helps; mentors; won't chase cruel magic |
| humor | Jokes in dialogue; warms chats |
| patience | Breakthrough chance; better teacher; long study |

Culture shifts (for example forgehold +0.12 conscientiousness, +0.1 pride) and age-band shifts (children +0.15 curiosity, −0.15 patience) are in `NpcData`.

**Households:** adults found homes, and 45% of them are joined by a second adult. Children and elders then join homes that have room (at most 4 people). The resulting bonds are spouse, parent/child (an age gap of 16 years or more) and sibling.

**Authored NPCs** take the last slots of the first settlement that fits their culture and size. If none fits, the culture requirement is dropped, then the size requirement.

| Key | Who | Note |
|---|---|---|
| `metallurgist` | Hedda Ashhand, 19, smith | Gifted, ambition: master Alloycraft |
| `tidepriest` | Corvel Saltmere, 71, retired tide-priest | Grudge keeper, no magic on Tuesdays |
| `gravitychild` | 9-year-old child | **Hidden Gravity latent**; nobody knows, including the child |

## 3. Quirks (58)

Every quirk has a mechanical effect; none are flavour only. Each NPC draws 2–4, weighted by trait affinity and never two that exclude each other.

| Id | Name | Effects |
|---|---|---|
| `talks_to_plants` | Talks to plants | actionMult { hobby 1.4 }; hobby yes |
| `no_magic_tuesday` | No magic on Tuesdays | noMagicWeekday 2 |
| `collects_broken_tools` | Collects broken tools | actionMult { hobby 1.2, trade 1.2 }; hobby yes |
| `hums_when_casting` | Hums when casting | castFlourish yes |
| `distrusts_void` | Distrusts the Void-touched | distrustDomain void |
| `lucky_coin` | Lucky coin | needDecay { safety 0.85 } |
| `secret_poet` | Secret poet | actionMult { hobby 1.3 }; trait { openness 0.05 }; hobby yes |
| `tests_on_pigeons` | Tests spells on pigeons | actionMult { practice 1.3 }; studyMult 1.05 |
| `night_owl` | Night owl | scheduleShift 3 |
| `early_riser` | Early riser | scheduleShift -2 |
| `grudge_keeper` | Keeps grudges | negativeHalfLife 3 |
| `forgiving` | Forgiving | negativeHalfLife 0.4 |
| `gossip` | Incorrigible gossip | actionMult { socialize 1.3 }; needDecay { social 1.3 }; gossipMult 1.8 |
| `tight_lipped` | Tight-lipped | gossipMult 0.2 |
| `counts_steps` | Counts steps | needDecay { safety 0.9 } |
| `afraid_of_fire` | Afraid of fire | fear fire |
| `sea_shanties` | Sings shanties | actionMult { work 1.1 }; needDecay { social 0.8 } |
| `feeds_strays` | Feeds strays | actionMult { hobby 1.2, help 1.2 }; needDecay { wealth 1.1 }; hobby yes |
| `hoards_candles` | Hoards candles | hobby yes; fear dark |
| `reads_at_meals` | Reads at meals | actionMult { eat 1.0, socialize 0.85 }; studyMult 1.05 |
| `insists_on_titles` | Insists on titles |  |
| `terrible_jokes` | Terrible jokes | actionMult { socialize 1.15 } |
| `nervous_laugh` | Nervous laugh |  |
| `collects_rumors` | Collects rumours | positiveHalfLife 1.5; gossipMult 1.3 |
| `prays_before_casting` | Prays before casting | actionMult { worship 1.3 }; castFlourish yes |
| `stacks_stones` | Stacks stones | actionMult { hobby 1.3 }; hobby yes |
| `afraid_of_heights_but_climbs` | Climbs despite heights | actionMult { wander 1.3 }; fear heights |
| `talks_to_the_sea` | Talks to the sea | actionMult { hobby 1.4, worship 1.2 }; hobby yes; likeDomain water |
| `bakes_for_neighbors` | Bakes for neighbours | actionMult { help 1.3, socialize 1.1 }; needDecay { food 0.9 } |
| `hates_mornings` | Hates mornings | scheduleShift 1 |
| `map_maker` | Draws maps | actionMult { wander 1.2 }; hobby yes; likeDomain space |
| `competitive` | Hyper-competitive | actionMult { practice 1.25 }; studyMult 1.05 |
| `collects_feathers` | Collects feathers | hobby yes; likeDomain air |
| `never_sits` | Never sits down | actionMult { idle 0.6 }; needDecay { rest 1.2 } |
| `sleeps_anywhere` | Sleeps anywhere | actionMult { sleep 1.2 }; needDecay { rest 0.8 } |
| `keeps_ledgers` | Keeps ledgers | actionMult { trade 1.2 }; needDecay { wealth 1.2 } |
| `generous_to_a_fault` | Generous to a fault | actionMult { help 1.3 }; needDecay { wealth 1.3 } |
| `superstitious` | Superstitious | actionMult { worship 1.2 }; needDecay { safety 1.2 } |
| `fascinated_by_mythic` | Mythic-obsessed | likeDomain time; studyMult 1.05 |
| `whittles` | Whittles | hobby yes |
| `smells_magic` | Smells magic |  |
| `hates_crowds` | Hates crowds | actionMult { socialize 0.6, hobby 1.2 }; hobby yes; fear crowds |
| `life_of_the_party` | Life of the party | actionMult { socialize 1.4 }; needDecay { social 1.4 } |
| `keeps_old_letters` | Keeps old letters | hobby yes; positiveHalfLife 2 |
| `overprepared` | Always overprepared | needDecay { safety 0.8 } |
| `tastes_everything` | Tastes everything | needDecay { food 1.1 }; studyMult 1.03 |
| `clean_freak` | Clean freak | hobby yes |
| `debates_everyone` | Debates everyone | actionMult { socialize 1.1 } |
| `afraid_of_mages` | Afraid of strong mages | fear mages |
| `worships_a_hero` | Hero worship | positiveHalfLife 1.5; studyMult 1.05 |
| `sleepwalker` | Sleepwalker | needDecay { rest 1.15 } |
| `pockets_full_of_seeds` | Seeds in every pocket | actionMult { wander 1.1 }; likeDomain life |
| `fixes_things` | Fixes everything | actionMult { help 1.3, work 1.05 } |
| `names_their_spells` | Names their spells | castFlourish yes |
| `distrusts_reality_mages` | Fears reality-benders | distrustDomain reality |
| `hums_lullabies` | Hums lullabies | needDecay { safety 0.9 } |
| `collector_of_tales` | Collects tales | actionMult { socialize 1.15, trade 1.1 }; gossipMult 1.2 |
| `practices_at_dawn` | Practises at dawn | actionMult { practice 1.3 }; scheduleShift -1; studyMult 1.08 |

## 4. Needs and the utility brain

Six needs, each 0..1 (1 = satisfied). Base drain per game hour: rest 0.045, food 0.07, social 0.04, purpose 0.035, wealth 0.02. Safety *recovers* at 0.15 per game hour and is knocked down by threats.

```
utility(a) = needs(a) · fit(a, block) · personality(a) · quirk(a) · momentum(a) + jitter(a)
needs(a)   = Σ_n W_n · U(level_n) · gain(a, n)        U(l) = (1 − l)², ×2 when l < 0.15
```

| Term | Value |
|---|---|
| W (weights) | rest 1.0 · food 1.1 · safety 1.6(0.6+N) · social 0.8(0.4+E) · purpose 0.9(0.5+0.5C+0.5Amb) · wealth 0.7(0.5+Greed) |
| fit | Per action and schedule block (`NeedsActions.actions[a].blocks`); in the `danger` block: shelter 3, help 1.4, worship 1.2, others 0.3 |
| personality | 1 + Σ aff(a, t)·(t − 0.5)·2, clamped 0.25..2.5 |
| quirk | Product of the quirks' `actionMult`; rogues ×1.6 on practice and wander |
| momentum | 1.25 for the current action |
| jitter | ±3%, a hash of (NPC seed, game hour, action): same on every server |

**Rules:** shelter is only possible under a threat. Work requires a job (not a child, retired or a rogue). Study and practice require magic, teaching requires a student, attend/play are for children, and trade/help are for adults.

**16 actions:** sleep, eat, work, study, practice, socialize, worship, wander, hobby, teach, attend, play, trade, help, idle, shelter.
**9 schedules:** day, early, night, evening, shift, priest, scholar, child, retired.

## 5. Memory, gossip and relationships

| Rule | Value |
|---|---|
| Cap | 24 memories per NPC; the weakest are dropped |
| Merge | The same kind about the same subject within a game hour stacks |
| Half-life | 4 game days for positive memories, 6 × (0.7 + neuroticism) for negative ones, then quirk multipliers |
| Opinion | Σ valence × strength, clamped −1..1; blended with the edge (0.6 × affinity + 0.8 × memory + reputation) |
| Gossip | Paired NPCs pass on their strongest gossip-worthy memory about a third party: intensity × 0.6 × trust × gossip multipliers. Each listener hears it only once |

**Social pairing (hourly):** NPCs socialising, playing, eating out, worshipping, trading or helping in the same district are shuffled (seeded by town and hour) and paired. Each pair runs `onChat` (a compatibility-weighted warmth) and gossips both ways.

**Reactions:**

| Event | Effect |
|---|---|
| A player's magic is seen (within max(40, 2 × area) studs, awake NPCs, at most 24 witnesses) | `saw_magic` / `saw_harmful_magic` / `saw_mythic_magic`; a first impression from quirk domain biases; harmful magic close by → safety −0.25 and a re-decision |
| An NPC is hit (`MagicDamage`) | `attacked_me` (−0.15 affinity, −0.1 trust); witnesses within 40 studs get `attacked_someone`; reputation −3 (−15 on a knockout); safety −0.4; an immediate re-decision and a spoken reaction |
| A knockout | The rig is discarded (dead Humanoids can't be revived) and the NPC drops to T2 for 6 game hours, then wakes at home |
| A danger event overlapping a town (wildfire, tempest, volcanic unrest, monster migration, plague, magic storm) | Safety drops by the event's severity, the `danger` block applies, professions with matching `relief` turn out and their work magic counts toward `EventDirector:noteCast` |

## 6. Magic lives

These follow `NPCMagicLife` (see its header for the formulas).

- **Baseline:** years of practice before the epoch build mastery along the path toward the NPC's ambition.
- **Chapters:** one every 7 game days. At boot the last 60 are replayed, so every server agrees on everyone's career without saving it.
- **Each chapter, per settlement:** mentorship, schools, rivalries and duels, invented techniques, backlash injuries, forbidden study and going rogue.
- **Rogues** live in the wilds: every action routes them there.

**Work casts (T0 only, cosmetic):** an NPC working near a player casts their profession's recipe every 12–25 s. This only happens if they actually know the branch, aren't injured and it isn't their no-magic weekday. The cue carries the NPC's Signature JSON, so clients tint it like a player's spell. These casts do **not** go through CastService or the resolvers yet.

**Hidden mythic gifts** wake only in specific circumstances:

| Trigger | Wakes |
|---|---|
| Seeing a player cast that same mythic domain at power ≥ 4 within 50 studs | That domain |
| Being awake during an eclipse | Time |
| Being awake during a starfall | Gravity |
| `npcawaken` (admin) | The NPC's hidden gift |

An awakening is saved in the town record, recorded in the world chronicle and applied on other servers through `WorldEventRecorded`. NPCs within 60 studs remember it and gossip about it.

## 6b. Homes, workplaces and spawning (settlement buildings)

NPCService assigns buildings at boot (`assignBuildings`) from SettlementService layout data. That's deterministic, and it works before any building exists.

- **Homes:**
  - Households go largest first. Each takes the smallest free house with enough beds: small house 1, medium 2, large 3, tavern room 1. If none fits, it takes the roomiest left.
  - The eldest member becomes the house's `OwnerNPCId`. Members sleep at the beds' `NPCHome` anchors in age order, sharing when there are more people than beds.
  - If a town runs out of houses, its last households keep their old district homes.
- **Work:**

  | Profession | Workplace |
  |---|---|
  | Smith | Smithy |
  | Innkeeper | Tavern |
  | Merchant, herbalist | Market stall |
  | Guard | Watchtower |
  | Farmer | Barn |
  | Scholar | Magic school |
  | Tide-priest, healer, weathercaller | Shrine |

  Workers are spread round-robin over the town's buildings of that kind, and co-workers fan out around the `NPCWork` anchor. Other professions keep their outdoor district spots.
- **Routing:**
  - sleep and other home actions go to the bed's anchor;
  - work goes to the work anchor;
  - knocked-out NPCs wake at home.

  Until a building exists, its anchor is a planned point inside the lot. When it's built, `Topics.BuildingBuilt` re-routes everyone who lives or works there to the real attachment.
- **Spawning:**
  - Every NPC starts at one of the plaza's four `NPCSpawn` points.
  - Near players they walk out. Data-only (T2) NPCs reach their destination on the next hourly pass instead of teleporting.
  - Pathfinding uses a 1.5-stud agent radius so rigs fit through doorways.
- **Shown in:** the inspector and `npc`, as "lives: House_03 (bed 2) · works: Smithy_01".

## 7. Level of detail and budgets

| Tier | Enter / leave (studs to the nearest player) | Cap | What exists | Brain |
|---|---|---|---|---|
| T0 | < 110 / 140 | 40 | Rig with a Humanoid, pathfinding, animations, name tag, Talk prompt | Every 1 s, plus barks and work casts |
| T1 | < 350 / 400 | 100 | The same rig, anchored; hops 30 studs every 2 s | Every 5 s |
| T2 | beyond | none | Data only | Once per game hour, batched |

**Throughput limits:**

- T0 and T1 brains run round-robin within **1 ms per frame**.
- At most 6 rig spawns per LOD pass (every 0.5 s).
- The rig pool is pre-warmed to min(NPCs, 48) and grows by 12 when it runs dry (up to 140). Rigs are never destroyed except on a knockout.
- Paths are cached per (settlement, 8-stud start cell, 8-stud end cell) for 300 s; at most 4 path computations per second.
- Settlements with no player within 1,500 studs skip per-NPC distance checks.
- T2 scoring runs on 4 Actors when 64 or more are due, in batches of 50; results for NPCs that have since come near a player are discarded.

## 8. Persistence

| What | Where | Why |
|---|---|---|
| Identity, personality, quirks, profile, family, career, NPC↔NPC relationships | Not saved | Regenerated from the seed and chapter |
| Mythic awakenings, memories of players (top 8 per NPC) | `NpcTowns` store, key `town_<settlementId>` | Player-caused; can't be regenerated |
| An NPC's view of a player (affinity, trust, 3 recent memory kinds), at most 80 NPCs | The player's save, `relationships` | Travels with the player to every server |

Towns are saved every 120 s and on shutdown when dirty, with `Store.update` and a **merge**: memories are combined by (time, kind, subject) and the 8 strongest kept, and the earliest awakening wins. Concurrent servers therefore never erase each other's facts.

## 9. Day traces

Paste these from Studio: `npcday <name>` for the metallurgist (Hedda), the old tide-priest (Corvel) and the gravity child. The trace is deterministic: fresh needs at midnight, no threats, 15-minute steps, one line per change of action.

```
(to be filled from the first Studio run)
```

## 10. Console and tools

| Command | What |
|---|---|
| `npc [id\|name]` | Full description (default: the nearest NPC) |
| `npcs` | Every town: population, tiers, knocked out, rogues, dangers |
| `npcday [id\|name]` | The deterministic 24-hour trace |
| `npclod` | Tier counts and caps, rig pool, path cache, brain cost per tick, T2 batch time |
| `npcgoto <id\|name>` | Teleport to an NPC |
| `npcawaken [id\|name]` | List hidden mythic NPCs, or wake one |
| `npctalk [id\|name] [topic]` | What an NPC would say to you (no distance check) |
| Admin Panel → Inspector tab | Click an NPC; refreshed every second; action buttons and need/trait sliders. More NPC tools in [AdminPanel.md](AdminPanel.md) §4 |

**Flags:** `npc_enabled`, `npc_day_seconds` (changing it live shifts the calendar), `npc_population_mult` (applied at boot only), `npc_parallel`, `npc_day_night`, `npc_llm_dialogue`.

## 11. Risks and known gaps

- **Boot cost:** `NPCFactory.populate` generates a whole town without a checkpoint, which could hitch for a moment on a 40-person city. Profile generation is the heavy part.
- **NPC casting is cosmetic.** Real NPC spells through the CastService resolvers are Runtime.md §9 work (CastService still assumes a Player).
- **There is no building geometry.** Districts are points around the settlement centre, and NPCs stand in the open.
- **`npc_population_mult`** moves the authored NPCs' slots, which changes their ids, so their saved memories are orphaned.
- **Knockouts have no consequences beyond reputation.** Guards and bounties are an open design question.
- **The model dialogue hook is off by default.** Its output is always filtered for the listener and only sees game state.
