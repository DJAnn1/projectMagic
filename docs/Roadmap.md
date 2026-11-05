# Roadmap: from "written" to "shipped"

Written 2026-11-03 for a solo developer or a team of two or three. Effort is counted in **focused sessions**: about 2.5 hours of real work in Studio or VS Code, at roughly 5 sessions a week.

## 0. The honest starting point

Most of what a roadmap would normally *build* already exists in this repo:
- the grammar for 12 domains;
- innate profiles, progression, casting, combat and VFX;
- 216 NPCs with LOD;
- a 4,096-stud world with events and disasters;
- settlements, quests, factions and the admin panel.

Almost none of it has been **played for real**. CLAUDE.md tracks what has run, and most entries say "written, not yet run".

That changes the plan:

| The usual risk | This project's risk |
|---|---|
| Building too slowly | **Built breadth before depth**: every system exists, few are proven, and bugs hide where systems meet (each Studio session so far found 2–4 integration bugs) |
| Scope creep in code | Scope creep in **tuning and verification**: 12 domains × ~140 branches × 11 forms is far more than one person can balance by hand |
| Missing features | Features nobody has seen working, so nobody can tell whether they're fun |

**The strategy:** **freeze features, carve a slice, prove it, then switch systems back on one milestone at a time.** Every milestone below is mostly *enable + verify + tune*, with new code only where play shows a gap. That is why the estimates are realistic for one person. Writing all of this from scratch would be 18–30 months of solo work.

Total across 11 milestones: **~150–210 sessions, roughly 7–10 months** at 5 sessions a week. Milestones 1–3 (the first playable game people outside the team can try) are about 7–9 weeks.

## 1. Milestones

Each one ends with a build someone else can play. The acceptance tests are things to do in Studio with the Output window open: **clear the Output first, and run only one `rojo serve`.**

### M1: Vertical slice in a box (carved, not built): 14–20 sessions

**Scope:**
- One region of the island: the spawn settlement plus about 600 studs around it.
- Energy and Earth only; every other domain is switched off by a flag.
- About 8 curated spells.
- One NPC type: smiths and miners in the spawn town, about 20 NPCs.
- Save and load.

**Systems on:**
- MagicCore/Registry, filtered to 2 domains;
- CastService + DamageModel + Delivery;
- EffectRunner (no fields);
- the HUD + Composer (Guided mode only);
- ProgressionService for 2 domains;
- NPCService with `npc_population_mult` low, plus a town filter;
- DataService;
- the admin panel.

**Systems off (flags):**
- world events, quests, awakenings, mythic domains, disasters (power cap 7);
- the settlement build in other towns (optional; it costs boot time only).

**New code:**
- a `magic_domains_enabled` flag, enforced in `MagicCore.validateRecipe` and the Composer;
- an NPC town filter;
- a curated spell list.

**Acceptance tests:**
1. Cold boot. Specs pass, and nothing red appears in the Output except Core.spec's deliberate `lock_lost`.
2. A brand-new player can cast their first spell within 3 minutes without help.
3. All 8 spells, cast on `dummy spawn`, show their expected damage within ±20% of the table in Combat.md §3.
4. Cast, rejoin: XP, spellbook, hotbar and settings persist. Kill Studio mid-session, rejoin: the data is no older than one autosave.
5. Hit an NPC: it flinches, then fights or flees; knocking it out costs reputation, and nothing errors.
6. 30 minutes of play with no server errors, and heartbeat time under 8 ms on average.

**Risks:**
- A hidden dependency between systems makes a flag break boot. Fix by making each service check its own flag, not by deleting code.
- VFX look wrong in real lighting.

**Cut if behind:** drop NPCs to 5 and skip the Composer (hotbar presets only).

### M2: Combat feel and the core loop: 12–16 sessions

**Scope:** make the 2 domains *feel* good.
- Hit feedback, VFX tuning and sounds.
- NPC fights; status effects, wards and knockdowns.
- Conduction and explosions, within Energy and Earth.
- The first balance pass on the damage curve.

**Acceptance tests:**
1. A blind tester can tell fire, lightning and stone apart with their eyes closed for one second after each cast (that is, by the sound and lingering marks).
2. A P3 projectile visibly lands where the damage happens (no hit-vs-visual mismatch beyond 0.2 s).
3. A guard NPC wins against a P2 novice about half the time.
4. With 10 casters spamming area spells, the client holds 50+ FPS on mid graphics and the server heartbeat stays under 12 ms.

**Risks:**
- "Feels weak" is subjective. Record before and after clips.
- Projectile flight under server lag.

**Cut if behind:** custom sounds (keep the built-ins) and conduction (keep explosions).

### M3: Progression and the first outside playtest: 14–18 sessions

**Scope:**
- Mastery tiers, breakthroughs and discoveries for the 2 domains;
- the Grimoire;
- specialization oaths (optional);
- the Journal's Log tab;
- onboarding (the awakening moment, first steps).

**Acceptance tests:**
1. JourneySim and a real 2-hour session agree within 25% on the tier reached.
2. 5–10 friends play 45+ minutes. At least 70% reach Adept in one branch, and at least half discover a recipe nobody told them about.
3. Play telemetry (§5) arrives in your dashboard.

**Risks:**
- The XP curve: the decision on record is `xpScale = 2.3`, slower than the design doc. Revisit with real data, not instinct.

**Cut if behind:** oaths, signature spells, and the Composer's Full mode.

> **Gate:** do not start M4 until M3's playtest says the core loop is fun. If it isn't, fix *this* before adding the world.

### M4: The whole island: 14–20 sessions

**Scope:**
- All 15 biomes, ley lines, POIs (no hidden mythic sites yet), chunk streaming for 30 players, roads;
- all 14 settlements built;
- regional world events that aren't disasters (drought, magic storm, ley surge).

**Acceptance tests:**
1. 30 simulated players (Studio's Local Server with 8 clients, plus a bot script) spread over the island: no chunk holes, heartbeat under 10 ms, server memory under 2.5 GB.
2. A new player reaches 3 settlements in their first hour.
3. An event starts, a player relieves it, and it ends.

**Risks:**
- Streaming and memory at 30 players.
- Spawn safety (characters falling or stuck after terrain edits).

**Cut if behind:** roads (paths only), decor density, and the volcanic biome.

### M5: NPC society at scale: 14–18 sessions

**Scope:**
- The full 216 NPCs with T0/T1/T2 LOD, schedules, homes and work;
- grammar-based dialogue, memory and gossip, relationships;
- NPC magic careers (frozen at chapter 0–1);
- the NPC inspector.

**Acceptance tests:**
1. Walk into a city at noon: NPCs are at work, and they go home at night (`npcday` trace).
2. Knock out a merchant: the guards remember, and gossip reaches another town within a game day.
3. With 216 NPCs and 20 players in one city, the server heartbeat stays under 12 ms.

**Risks:**
- LOD thrash at tier borders.
- Pathfinding cost.
- NPC brains are hard to debug.

**Cut if behind:** gossip, NPC careers beyond chapter 0, and the T1 tier (go straight from T0 to T2).

### M6: Common domains complete (Water, Air) and interactions: 12–16 sessions

**Scope:**
- Water and Air branches, waves (spell-scale), fields (currents);
- the InteractionMatrix (steam, conduction, firestorm, freeze);
- fire spread and the heat model;
- the second closed playtest with 20–40 players.

**Acceptance tests:**
1. Each of the 4 common domains has at least 6 recipes rated "fun" by 3 or more testers.
2. All the reactions in the matrix trigger in an arranged test (`testspells`).
3. Branch distribution (§5) shows no common domain below half of its fair share of playtime.

**Risks:** fire spread runaway, and the water and terrain write budgets.

**Cut if behind:** blizzard and firestorm reactions, and spell waves (keep currents).

### M7: Quests v1 and reputation: 14–20 sessions

**Scope:**
- SituationDetector with the 8 most reliable templates (tunnel, reservoir, commission, escort, duel, teaching, lost technique, wildfire);
- Journal, map pins and NPC talk offers;
- settlement and faction standing (visible factions only), infamy and bounties, guards.

**Acceptance tests:**
1. In a 60-minute session, a player gets at least 2 offers that match their focus, and completes one in 2 different ways across 2 playthroughs.
2. A shared crisis is resolved by 2 players together and both are rewarded.
3. Bounties make guards hostile, and atonement clears them.
4. No quest gets stuck (each one completes or expires) across 50 forced quests (`questgen` loop).

**Risks:**
- Objectives that can't be completed (an NPC moved, an optional NPC is missing).
- Pacing feels random.

**Cut if behind:**
- heist, diplomacy, rogue bounty and mythic templates;
- secret factions;
- complications;
- creative recognition (keep matched solutions).

### M8: Uncommon and rare domains, full innate profiles: 14–18 sessions

**Scope:**
- Life, Mind, Spirit, Void and Space;
- the full innate profiles (latents, temperaments, awakening events);
- status-heavy spells (charm, fear, silence), dispel and wards;
- Settling Accounts (the atonement quest) and The Quiet Student.

**Acceptance tests:**
1. Person-rarity shares stay within 2 points of the targets in CLAUDE.md (≈ 49 / 22 / 21 / 6.6 / 1.1).
2. Mind magic on NPCs moves Scholars' League standing.
3. An awakening plays its full-screen moment and the unlocks appear in the Grimoire.
4. Fear and charm change NPC behaviour visibly.

**Risks:**
- Status stacking exploits.
- Mind PvP griefing (silence-lock).

**Cut if behind:** Space (Rare, few players have it), and hybrids.

### M9: Persistent world and disasters: 18–26 sessions (the hardest milestone)

**Scope:**
- Persistent terrain deltas across servers, settlement state deltas;
- MessagingService announcements;
- earthquakes, then tsunamis;
- the world chronicle.

**Acceptance tests:**
1. A quake on server A shows its scar on server B within 60 s, and after a full restart.
2. 100 persisted edits load in under 2 s per chunk.
3. A tsunami at max power runs with heartbeat under 20 ms and never traps a player in the terrain.
4. DataStore request budgets are never exceeded at 30 players (`perf`).

**Risks:** see §4. This is where solo projects die.

**Cut if behind:**
- ship the §4 fallbacks: quake scars local to one server, tsunami as a scripted water wall;
- no cross-server terrain.

### M10: Mythic magic, gated: 12–18 sessions

**Scope:**
- Time, Gravity and Reality with hard constraints;
- hidden mythic sites, lore hints and breadcrumb quests;
- the Quiet Hand (notoriety, hunters) and Seam Keepers.

**Acceptance tests:**
1. The measured mythic rate in the profile sampler holds (~1 in 41k innate). The awakening funnel is visible in telemetry.
2. A mythic player can't crash, freeze or soft-lock a server with any recipe (fuzz `cast` with `overpower`).
3. Hunters appear at notoriety 35 and can be survived 3 different ways.

**Risks:** see §4 (mythic constraints).

**Cut if behind:** Reality (ship Time and Gravity), the Time rewind buffer, and the Seam Keepers.

### M11: Launch readiness: 12–16 sessions

**Scope:**
- Moderation (chat filter paths, reports), anti-exploit sweep (movement checks, Backend.md §8);
- a server browser / regions decision;
- analytics dashboards;
- performance on low-end mobile (`quality()` paths), accessibility pass, store page;
- live config (global feature-flag overrides).

**Acceptance tests:**
1. 48-hour soak on 3 live servers with no data loss (session locks hold through crashes).
2. Exploit checklist passed: speed, teleport, remote spam, aim fabrication.
3. Mobile at 30 FPS.

**Risks:** Roblox platform review and moderation surprises.

**Cut if behind:** a regions system (one world is already the design), and the tutorial polish beyond the first 10 minutes.

### M12 (post-launch): content cadence
- Quest templates
- POI and dungeon content
- Building prefabs
- The deferred list in §6

## 2. Dependency graph

```
DataService ─┬─► PlayerDataService ─► ProgressionService ─┬─► SpecializationService
             │                                             └─► DiscoveryLog
             └─► WorldService (seed, epoch) ─► WorldGen ─► WorldIndex ─► POIPlacer
                                                    │                       │
Registry/MagicCore ─► Reservoir ─► CastService ◄────┘ (castContext)         │
     │                   │            │                                     ▼
     │                   │            ├─► Delivery / Targeting ─► DamageModel ◄─ Resistances
     │                   │            ├─► EffectRunner ─► FieldEffects, FireSim, ThermalSim
     │                   │            │        └─► InteractionMatrix ─► TerrainDeform ─► (persistence: M9)
     │                   │            └─► HitReactions ─► NPCCombat
     │                   ▼
     │              HUD / Composer / Grimoire (client, via MagicStateController)
     ▼
InnateProfile ─► ProfileGenerator ─► (players) awakenings ─► mythic (M10)
                       └─► NPCFactory ─► NPCService (LOD, brain, memory) ─► NPCCombat
                                                   │
SettlementSites ─► SettlementLayout ─► BuildingGenerator ─► SettlementService ─┘ (homes/work)
                                                   │
EventDirector ◄── WorldStateService (stress, density, events)
      │
      └─► SituationDetector ─► QuestDirector ─► JournalService / map pins
                                    ▲
             ReputationService ◄─ FactionService ◄─ (NPC membership, deeds)
```

**Hard ordering rules:**
1. Nothing goes on top of CastService until DamageModel is proven.
2. Quests come after NPCs *and* events, because quests read both.
3. Persistence comes after every system that edits terrain.
4. Mythic magic comes after persistence: Reality edits must be revertible and cross-server-safe.

## 3. Effort summary

| Milestone | Sessions | Weeks at 5/wk | Mostly |
|---|---|---|---|
| M1 slice | 14–20 | 3–4 | enable flags, verify, fix integration bugs |
| M2 feel | 12–16 | 2.5–3 | tuning, VFX, sound |
| M3 progression + playtest | 14–18 | 3–3.5 | onboarding, balance, telemetry |
| M4 island | 14–20 | 3–4 | performance, streaming |
| M5 NPCs | 14–18 | 3–3.5 | LOD and brain debugging |
| M6 common domains | 12–16 | 2.5–3 | content + reactions |
| M7 quests | 14–20 | 3–4 | robustness, pacing |
| M8 rare domains | 14–18 | 3–3.5 | statuses, profiles |
| M9 persistence + disasters | 18–26 | 4–5 | hardest engineering |
| M10 mythic | 12–18 | 2.5–3.5 | constraints, fuzzing |
| M11 launch | 12–16 | 2.5–3 | ops, moderation, mobile |
| **Total** | **150–206** | **~30–41 weeks** | |

Add 20% for life. A **solo** developer ships around month 9–11. **Two people**, with one on art/VFX/audio and tuning, cut that to about 6–7 months, because the code is not the bottleneck.

## 4. The hardest problems: when, and what to ship first

| Problem | Why it's hard | Tackle in | Ship first (fallback) | Upgrade later |
|---|---|---|---|---|
| **Persistent terrain deltas** | Concurrent servers, DataStore budgets (requests and 4 MB values), load time of heavily edited chunks, players stuck in re-filled terrain | M9 | **Per-server only**: edits revert on restart; persist only small deltas ("scars": quake cracks ≤ N ops per chunk); CharacterSafety stays on | Cross-server union merge (already designed), voxel-diff compaction for heavy chunks |
| **Tsunami** (WaveSimulator) | Column height-field + terrain writes at scale; must never trap or fling players; costs a lot of server time | M9, after quakes | A **scripted wall of water**: client visual + server damage/knockback band, no terrain water writes; the existing heavy-effect budget (2 per server) | Real column sim with terrain pour/recede, persisted shoreline damage |
| **Earthquake** | Terrain ops, structure collapse, aftershocks, rescues | M9 (spell-scale quakes are already in M2's slice for Earth) | Camera shake + damage + knockdowns + **cosmetic** crack decals; structures take Integrity damage but don't unanchor | Terrain edits + rubble physics + persistent scars |
| **NPC LOD** | Tier thrash, rig pool, pathfinding cost, 216 brains + 30 players | M5 | **Two tiers**: T0 full rigs (≤ 40) and T2 data only; no T1 anchored hop; pathfinding only in towns | T1, cross-town travel, parallel brain scoring (ParallelPool exists) |
| **Mythic magic constraints** | Time (rewind, slow), Gravity (fields, flight), Reality (rule edits) can break physics, grief players, desync, or crash servers | M10, only after M9 | **Fields only**, with hard caps: radius ≤ 60, ≤ 30 s, ≤ 2 mythic fields per server (already budgeted); no rewind; Reality limited to slick/transmute on props; mythic power capped at 7 until telemetry says otherwise | Time rewind buffer, Reality ledger edits, Paradox meter |
| **Shared crisis state across servers** | Each server sees a different world | M7 (per-server is the design) | Per-server crises (as built) | Global announcements only ("a drought grips Saltmere on another shard") |
| **Balance across 12 domains × 140 branches** | Combinatorial; impossible to hand-tune | Every milestone, with telemetry | Tune **per form and per domain multiplier**, not per branch; JourneySim before and after every change | Per-branch overrides only where data shows outliers |

**Rule:** a fallback ships first *and stays* unless telemetry or players show the real version matters. Most players will never notice a scripted tsunami.

## 5. Playtest plan

| When | Who | Size | Length | Goal |
|---|---|---|---|---|
| Every session | you | 1 | 15 min | regression: specs, the milestone's acceptance list |
| End of M1 | you + 1 friend | 2 | 30 min | can a stranger cast in 3 minutes? |
| End of M3 | friends | 5–10 | 2 × 45 min | is the core loop fun? (the M3 gate) |
| End of M6 | closed group (Discord) | 20–40 | 1 week | balance, branch distribution, performance at 20+ |
| End of M8 | closed group | 40–80 | 2 weeks | economy of time, quest pacing, retention |
| M11 | open beta (private server links) | 100–500 | 2–4 weeks | soak, exploits, mobile |

**Telemetry.** Add an `AnalyticsService` sink behind Logger, plus a daily summary to a DataStore for your own dashboard. Collect:

| Metric | Definition | Healthy target (first guess) |
|---|---|---|
| Session length | median minutes per session | ≥ 25 at M3, ≥ 40 at M8 |
| Time to first spell | seconds from join to the first resolved cast | ≤ 180 |
| Discovery rate | first-time recipes per player-hour | 4–8 early, falling to 1–2 later |
| World firsts | per day across all servers | steady, not front-loaded |
| Branch distribution | share of XP by domain, and by branch inside it | no common domain under 0.5× its fair share |
| Tier funnel | % of players reaching Novice → Adept → Skilled… by hour | matches JourneySim within 25% |
| Mythic frequency | innate mythics / new players; awakenings / week | ≈ 1 in 41k innate; awakenings rare enough to be news |
| Refusal reasons | CastResult `refused` counts by reason | `INVALID_RECIPE` falling (the Composer is working) |
| Quest funnel | offered → accepted → completed / failed / expired / solved by others | ≥ 40% acceptance; ≤ 20% solved by others |
| Server performance | heartbeat ms (p50/p95), Scheduler backlog, part count, remote KB/s per player, memory | p95 heartbeat < 16 ms; memory < 3 GB |
| Errors | `log:error` count per server-hour | 0 at launch, trend down every milestone |

**Balance iteration:**
- Change **one** tuning table per playtest (CastTuning, CombatTuning, ProgressionTuning, QuestTuning are all data).
- Run JourneySim and the spec suite before and after.
- Write the change and the reason into the tuning file's comment, and the result into CLAUDE.md.
- Never tune from a single anecdote. Use at least 5 testers or the telemetry.

## 6. Scope control: wait until after launch

These sound great, and every one of them is a month that doesn't ship the game:

- **A second continent**, or any world bigger than 4,096 studs.
- **Time rewind, Reality's Paradox meter, persistent Reality edits.** Ship fields only.
- **Real tsunami terrain flooding and cross-server terrain persistence.** Ship the fallbacks.
- **Player building and housing, building prefabs, dungeon content, POI interiors.**
- **A player economy:** trading, auction house, crafting, gear drops. Gear exists only as resistance data.
- **Party systems:** shared personal quests, groups, guild UI.
- **PvP arenas, rankings, leaderboards, MemoryStore rumours.**
- **NPCs' full spell repertoires, NPC-vs-NPC wars, NPC politics between factions.**
- **LLM dialogue (`npc_llm_dialogue`).** Grammar dialogue is enough, and safer for moderation.
- **Signature audio timbres, custom VFX textures per domain.** Built-ins until art budget exists.
- **A full map screen.** World pins exist; a minimap is the post-launch candidate.
- **Weather simulation.** Events already change storm charge and moisture.
- **Heist, diplomacy, mythic and hunted quest templates; secret factions.** They exist, but keep them behind `quests_enabled` subsets until M8+.
- **Hybrid branches.** Already designed; enable after balance data exists for their parents.
- **Hand-authored story content of any kind.** The game is non-linear by design, so don't write a campaign.

## 7. First week: concrete tasks (about 5 sessions)

Each task is small and testable. Check them off in CLAUDE.md as you go.

**Session 1: a stable baseline**
1. Run `git init` if needed, then commit everything as "baseline before slice". *(The repo has no commits; every file is untracked. This is the cheapest insurance you can buy.)*
2. Play, clear the Output, and confirm the specs (154/154). Save the clean Output as `docs/baselines/boot-2026-11-03.txt`.
3. Write down the 8 slice spells (4 Energy, 4 Earth: a bolt, a beam, a burst, a ward/buff per domain) as a `SliceSpells` data list, using `SpellExamples` entries where possible.

**Session 2: the domain allowlist**
4. Add a `magic_domains_enabled` flag (default: all 12; replicate = true).
5. Enforce it in `MagicCore.validateRecipe`, with a new refusal code `DOMAIN_DISABLED` and a HUD reason string.
6. Filter the Composer and Grimoire to enabled domains, and add a Quest.spec/Cast.spec check that disabled domains can't be cast.

**Session 3: the slice world**
7. Switch off for the slice: `world_events_enabled`, `quests_enabled`, `awakenings_enabled`. Set `npc_population_mult` to about 0.1, or add a town filter flag that keeps NPCs only in the spawn town.
8. Give new players the 8 slice spells on first join (a slice-only starter-kit flag).
9. Check acceptance tests 1 and 2: boot clean; a fresh player (`profile reroll`) casts within 3 minutes.

**Session 4: combat on the slice**
10. `dummy spawn`, then cast all 8 spells. Compare damage to Combat.md §3 and record a table in CLAUDE.md.
11. Fight 3 NPCs (a smith, a guard, a miner). Paste the Output with `combat_debug_log` on.
12. Fix the first 3 issues found; note the rest as M2 items.

**Session 5: save and load, and the M1 checklist**
13. Cast, change the hotbar and settings, rejoin, and confirm they persist. Stop Studio mid-cast, rejoin, and check the data's age.
14. Run 30 minutes of play with `perf` every 10 minutes and record the heartbeat and memory.
15. Update CLAUDE.md: the M1 status, open bugs, and the next week's tasks.

By the end of the week you'll have a clean, committed baseline, a flag-carved slice, and measured numbers instead of assumptions.
