# Improvements audit (2026-11-05)

**Done 2026-11-05 (not yet run in Studio):** git baseline commit; quiet boot (Tech debt #1); crime-while-learning, smallest version (Feel #1: harm judged after the spell lands, practice dummies exempt); Future lighting + post-processing (Quick win #1); FxRecipes on DomainFx textures (Tech debt #5).

Design only: what to improve in projectMagic as it stands, ranked by impact versus effort.
Sizes: **S** = under one session, **M** = 1–3 sessions, **L** = a milestone's worth.
"Roadmap" says where it fits in docs/Roadmap.md (M1 = the vertical slice).

Sources: CLAUDE.md, Roadmap.md, Backend.md's launch checklist, the code (286 Luau files,
~80k lines), and the three Studio runs on 2026-11-05.

---

## Top 5 to do next

1. **Commit the project to git.** (S, Roadmap week-1 task 1.) Still no commits: 80k lines and 18
   design docs exist only on one disk. One `git commit` makes every later change reversible.
2. **Stop new players committing crimes while learning.** (S–M, M1.) Every harmful cast inside
   a "licensed" town costs −6 reputation and 3.6 infamy, with or without a target or a witness.
   A new player spawns on the plaza; ~7 practice casts post a bounty, ~12 make guards attack
   on sight. See Feel #1.
3. **Make the boot Output short and quiet.** (S, M1.) Every Play prints ~250 lines (unit specs,
   magic examples, profile statistics, the journey sim, a 14-line settlement table) plus a
   deliberate red `lock_lost` ERROR from Core.spec. Real problems hide in it, and it's the
   reason a stale log got pasted three times. See Tech debt #1.
4. **Verify what's built before building more.** (M, M1.) Most systems since 2026-11-02 have
   passed `rojo build` but never been played (list under Broken #3). The roadmap's slice
   carving (flags for domains, quests, events, NPC count) is the cheapest way to do it.
5. **Turn on modern lighting.** (S, M2 feel.) `default.project.json` pins
   `Lighting.Technology = "Voxel"` and there is no Bloom, ColorCorrection or Atmosphere. The
   new VFX, Neon cores, lamp PointLights and dark Void effects all look flatter than they
   should. See Quick wins #1.

---

## 1. Broken or risky (live servers)

| # | What | Why it matters | Where | Size | Roadmap |
|---|---|---|---|---|---|
| 1 | **No git history** | A bad edit, a disk failure or a wrong Rojo sync can't be undone. Everything is untracked. | repo root | S | week 1, task 1 |
| 2 | **Real DataStores never exercised** | Studio runs `mock=true`. The place is published ("projectMagicTest", v143) and playtesters can join. Session locks, retries, compression and the v1→v4 migrations have only run against the mock. | `Services/DataService`, `Persistence/*`; Backend.md checklist lines "Session locking tested on two live servers", "migration path tested" | M | M3 (outside playtest) |
| 3 | **Most systems unplayed** | Written but never run in play: Grimoire, Composer, Journal and quest pins, Inventory screens, equip and quickbar, housing, buildings part 2 (stations, furniture, lamps), charge, aim reticles, guards and parries, spellblade, dash (not built), NPC talk, the inspector, LOD at a city, the NPC day traces. Bugs compound when they're found late. | CLAUDE.md "not yet run" notes | M | M1 |
| 4 | **No movement validation** | Backend.md §8 anti-teleport and speed checks don't exist. Speed and teleport exploits work today, and future flight and dash (Ideas #6, #10) need an allowance system to build on. | none yet; Backend.md §8 | M | M2 (with dash) |
| 5 | **Unmeasured performance** | No `perf` run under load yet. 216 NPCs, 154 lamps against a 160-light budget, ~3,300 parts around spawn after 20 s, and 34 per-frame connections across the codebase. The 30–60 player target is unproven. | `perf` admin command; Roadmap week 1, task 14 | S to measure, M to fix | M1 |
| 6 | **Admin panel enabled live** | `EnableInLiveServers = true` on a published place. It is allowlisted (UserId 17476255; negative ids only in Studio), but no live test is recorded. | `Config/AdminConfig.luau` | S | M11 |
| 7 | **Spell-name filtering unverified** | Only filterable on a published place; never checked there. A compliance item, not a nicety. | `Services/SpellbookService` | S | M3 |
| 8 | **Asset ownership** | Block (111952812431898) still fails: not owned by the place's creator. Every future upload (animations, audio for Ideas #7) has the same trap. | `Data/CombatAnimations` | S (owner action) | now |

## 2. Feel (what makes a minute worse than it should be)

| # | What | Why it matters | Where | Size |
|---|---|---|---|---|
| 1 | **Casting is a crime where you learn** | See Top 5 #2. Options (pick one or mix): (a) only judge casts that hit a person or property, or that a witness sees; (b) a first-offence warning from a guard instead of a crime; (c) exempt Novice-tier and training-dummy casts; (d) give the spawn town a practice yard where casting is licensed; (e) scale `crimeScale` down for the first hour. Keep crime meaningful for real attacks. | `World/Settlements.judgeCast`, `WorldStateService.judgeCast`, `Quests/Data/QuestTuning.infamy` | S–M |
| 2 | **No map** | A 4,096-stud island with 14 settlements, 64 POIs and ley lines, and no map or compass. Quest pins help for one target only. (`PoiMarkers` is on the backlog.) | new client controller; WorldStateService already has public settlement data | M |
| 3 | **Silence** | Spells use ~6 built-in sounds; there's no music and no ambience. Sound is half of hit feel. | Ideas #7 | M |
| 4 | **Movement is plain** | No run toggle, no dash, and lock-on must be held. | Ideas #6 | M |
| 5 | **The Composer assumes knowledge** | One-line hints per step; players must already know the grammar. | Ideas #5 | M |
| 6 | **Spawn lands in water sometimes** | `character_rescued … reason="spawned in water"` appears in boot logs. The safety net works, but the first second of the game is a jump. | `WorldStateService` spawn placement | S |
| 7 | **Your own slash arc lags** | It follows the server's state, so it lands 50–150 ms after your swing starts. | `Controllers/SlashFxController` | S |

## 3. Content gaps (where players run out of things)

| # | What | Why it matters | Size | Roadmap |
|---|---|---|---|---|
| 1 | **Nothing wild to fight** | No creatures. Early targets are dummies and townsfolk, and hitting townsfolk is a crime. (EarlyGame #5.) | L | M2–M4 |
| 2 | **No economy or trade** | Coins exist (quests pay); there's nothing to buy from or sell to NPCs and no player trading. (Items stage 5.) | L | after M7 |
| 3 | **No sky for world events** | Events like the magic storm and eclipse run without world-event visuals. | M | M9 |
| 4 | **NPCs look alike** | Plain recoloured rigs; generated hair, build and features are never drawn. | M | Ideas #8 |
| 5 | **Mythic magic is unreachable for most** | By design (about 1 in 40,000), but there's nothing to *see* of it (no mythic NPC moments, no rumours that pay off soon). | M | M10; Ideas #3 |
| 6 | **Designed-only screens** | Path, Self, and NPC dialogue screens (UI.md §4.5–4.8) are still unbuilt. | M | M3 |

## 4. Tech debt

| # | What | Why it matters | Where | Size |
|---|---|---|---|---|
| 1 | **Noisy boot** | Specs, examples, ProfileStats and JourneySim all run and print on every Play. Proposal: one-line summaries ("specs 297/299 · examples 33/33 · profiles 14/14"), details only on failure; keep ProfileStats and JourneySim behind flags that default off; Core.spec captures its deliberate `lock_lost` instead of logging it as ERROR; the settlement table prints only on request (it also says "0 buildings built", which is just the moment it's printed, before chunks build). | `Server/init`, `Tests/TestRunner`, `Tests/Core.spec`, `SettlementService:788`, `Config/Flags` | S |
| 2 | **Two permanently failing specs** | "SettlementGround never paints roads…" (settlement_6) and "BuildingGenerator builds every type…" have failed every run since they were added. Failing specs that everyone ignores stop protecting anything. Fix them or mark them pending with a reason. | `Tests/Settlement.spec:298`, `:485` | S–M |
| 3 | **Giant modules** | NPCService (2,160 lines), QuestDirector (1,869), SpellFx (1,396), CastService (1,377), WorldStateService (1,374, with pre-existing luau-lsp type errors), BuildingGenerator (1,295), HudController, ComposerController, AdminPanel (each ~1,200). Hard to review, and slow to load into context. Split along existing seams (e.g. NPCService: tick loops / talk / admin API; CastService: validate / pay / resolve). | listed files | M each |
| 4 | **CLAUDE.md is 351 lines** | It's loaded into every session. Much of it is history (what was fixed after which run). Proposal: keep a short status (what exists, what's unverified, decisions, conventions) and move run-by-run history into `docs/History.md`. | CLAUDE.md | S |
| 5 | **Duplicate texture constants** | `Fx/FxRecipes` keeps its own built-in texture paths, so it can't pick up the uploaded Kenney textures. | `Fx/FxRecipes.luau:47-49` | S |
| 6 | **Lint noise** | The known `pcall` solver quirk, admin `args` literal inference, and selene's stale "not defined" warnings make new errors easy to miss. A `selene.toml`/luau-lsp config pass to silence the known false positives. | `selene.toml`, `.vscode` | S |

## 5. Quick wins (under one session each)

1. **Lighting:** `Technology = "Future"` (or ShadowMap on a budget), plus Bloom (subtle), ColorCorrection (a touch of contrast) and Atmosphere in `default.project.json`. Low-end devices fall back automatically. Check FPS on a phone emulator afterwards.
2. **Commit to git** (Top 5 #1).
3. **Quiet boot** (Tech debt #1).
4. **Crime-while-learning fix**, the smallest version: no crime for casts that hit nobody and nothing.
5. **Re-upload Block** under the place's creator (owner action), then confirm `animation_unavailable` is gone.
6. **FxRecipes onto DomainFx textures** (Tech debt #5).
7. **Trim CLAUDE.md** (Tech debt #4).
8. **Spawn-in-water:** log the chosen spawn's height versus sea level on boot and fix the placement check.

---

## How these line up with the ideas pack

- Movement (Feel #4) = Ideas #6. Composer (Feel #5) = Ideas #5. Silence (Feel #3) = Ideas #7.
  NPC looks (Content #4) = Ideas #8. Creatures (Content #1) belong to Ideas #9 (early game).
- Movement validation (Broken #4) should land **with** the dash in Ideas #6, and before
  gravity flight (Ideas #10).
- The crime fix (Feel #1) and the map (Feel #2) aren't in the ideas pack; they're the two
  biggest new finds here.
