# projectMagic: status and handoff

An open-world Roblox magic sandbox. There's no linear story: everyone (players and NPCs) has innate magic that is procedurally generated, trained and mastered over time. It's written in Luau and synced to Studio with Rojo (`default.project.json`). Last updated **2026-11-06**.

## How the owner works with Claude

- **Every feature response follows this structure** (their standing "project bible" rules):
  1. Restate the request and list assumptions.
  2. Show where each script lives in Explorer.
  3. Write complete, commented `--!strict` code.
  4. Call out performance risks, exploit risks and edge cases.
  5. End with **(1) what to test, (2) what to build next, (3) open design questions**.
- **Design rule (2026-11-07):** a feature must feel like part of a realistic simulated world, not a game system laid over it. Tournaments were dropped for being "too streamlined". Prefer causes inside the world, and tell players through NPCs, journals and what they can see before cards, pins and announcements. Flag anything that still feels like a game.
- **Non-negotiable constraints:**
  - Server-authoritative: clients send intents only.
  - Data-driven: content lives in data modules.
  - Deterministic: everything generated derives from `Seed.random(worldSeed, entityId, system)`.
  - Budget for 30–60 players and 100–300 NPCs.
- **Testing loop:** the owner presses Play in Studio and pastes the Output window.
  - Remind them to **clear the Output first**; they once re-pasted an old log three times.
  - Remind them to run **only one `rojo serve`**; a duplicate instance once caused a duplicate spec module.
  - No Luau runtime exists locally (only `rojo`), so code can't be executed outside Studio. Verify with `rojo build` and the VS Code diagnostics.
  - `rojo build` does NOT check Luau syntax (a broken string once passed it); always read the VS Code diagnostics for every edited file. Diagnostics with no `linesInFile` may mean the file wasn't analysed.
- **Git:** the repo now has history on branch **`baseline`** (no `main` yet). Commit each finished piece separately with a descriptive message; the owner has been fine with that ("build next" includes committing).
- **How the owner drives work:** "Build next" / "Build prompt N" means continue the current plan. They reply to the open questions selectively; unanswered questions get a sensible default, said out loud, and stay in the open-questions list below.
- **Before coding, say the plan** (asked 2026-11-05: "Tell me what you're doing before you code"): a short plan in the reply, then build.
- **Syntax check:** selene parses every file: `~/AppData/Roaming/Code/User/globalStorage/kampfkarren.selene-vscode/selene.exe --display-style quiet <files>` (0 parse errors = syntax OK). Use it after edits, since VS Code diagnostics may be empty for unanalysed files.
- **Client → server intents use `Net.send`** (`Net.fire` is server → client only; using it on the client broke running and dashing once).

## Build queue (saved 2026-11-06, the owner's "to make later" list)

**Start here.** This list decides what comes next; where the session notes below name a different next step, this list wins. Work top-down unless the owner picks something else. Only Rifts follows the recommended order the owner has been approving; the rest are pitched or designed, not yet chosen. Design details are in the linked docs. Say the plan before coding, and commit each piece.

**Newest: Your hand in the spell + conjuring while charging (`docs/SpellHand.md`), built 2026-11-07 on the owner's "Implement Your hand in the spell ... Have a spell be visually conjured while charging". Boot confirmed 2026-11-07: `specs 974/974`, `spell_hand_matured tier=8` after `testmage 8 all`, casts with no client errors. Owner confirmed in play: the spell forms while charging, grows and shakes when overcharged, and flashes into the cast or falls apart on cancel. Not yet seen: a second client watching.** The 63-idea list is in the session transcript `003f9b69…` (assistant message at line 807); re-show it from there. Each player has a seeded hand (`Seed.random(worldSeed, "player:<id>", "hand")`, temperaments lean the shape): a rune pattern (their cast circle and conjured runes), a shape (orb, shards, halo, helix), a spin and a voice (cast sound pitch), more elaborate with mastery tier (motes, a second rune at Expert, a crown at Grandmaster). No menu: it's innate. While charging in equip mode the spell forms (`Fx/Conjure`, from `AttuneGlowController`): in the palm, overhead or at the feet by form, looking like its domain and property (new attribute `AttunedProperty`), growing per stage, unstable when overcharged, flashing into the cast or falling apart. Expected boot line `specs 974/974` (16 new in `Tests/SpellHand.spec`, if 958 holds). Test with `spellhand`, then equip a projectile spell and hold to charge (watch it form, overcharge it, release, and cancel), a burst and a zone spell, `spellhandtier 8` for full detail, and a second client to see someone else conjure. Unverified: how each domain's core reads in game, the rune Decal discs (Kenney ids as Decal textures), the ActionState "casting" check that tells release from cancel (0.08 s after the charge clears), and frame cost with many casters. The Owner's ideas list (2026-11-07, 63 items in this chat) is waiting on which to discard and which to implement; only #23 (this) was picked so far.

**Magic Marks ("Magic Changes You", `docs/MagicMarks.md`), built 2026-11-07 on the owner's "Begin with magic changes you". Boot confirmed: `specs 958/958`, `marks_ready`; `markset energy 1`, `markset energy 3`, `markclear` and `markset void 3` all logged `marks_changed` correctly. Not yet seen: NPC remarks (now logged as `npc_remarked_mark`, throttled), `npcmarks`, `greetstate` with marks, and how the marks look (no comment from the owner yet).** The domain you use most marks your body in 3 stages (arms darken or change from the hand up, particles off the hands, footprints from stage 2). NPC mages carry marks from their own mastery tier. Small perk: 4% resistance to your own domain per stage. Quirk: strange marks (Void, Reality, Time, Spirit) make nervous NPCs warier. NPCs remark once per mark and stage, and whisper from further off. You hear about it through a first-person Journal line, with no popup. Expected boot line `specs 958/958` (27 new in `Tests/Marks.spec`) and `marks_ready`. Test with `markset energy 1`, then `markset energy 3` (look at your arms, walk to see prints, read the Journal), then walk up to Glenhold NPCs (one should remark), `greetstate` near a nervous NPC after `markset void 3`, `npcmarks` (how many NPC mages are marked, by stage), `marks`, `markclear`. Log: `marks_changed`. Unverified: welded client-side overlay parts on other players' characters and on NPC rigs (they should follow the arm), how each domain's colour and material read in game, and whether the prints sit on town ground. The owner decided (2026-11-07) that marks fade over time: 2% of points a day without use (stage 3 to 2 in about 9 days, to 1 in about 68, gone in about 146; a fresh stage 1 in about 9). Asked whether that pace is right; no answer yet. Defaults Claude chose (still open): no backfill from earlier mastery, nothing hides a mark, two marks at most.

**Readable NPC activities (`docs/Activities.md`): stage 2 confirmed, set aside 2026-11-07.** The owner said "Everything looks fine for now, let's move on to other ideas", so the poses, props and labels count as accepted. Don't resume it unprompted. Still open when it comes back: the two door fixes (sleepers leaving by the door, locked doors), then audio, icons and barks, join and assist, and the LOD pass.

- **Where it stands.** Stage 1 is built (commits `ac6cc28`, `b10bb3a`, `cc2b3c8`, `2a3ed63`) with 15 activities. Confirmed in logs: `specs 926/926`, stations 107 with 3 invalid (`activity_stations`), `actreport` pass 0 · warn 13 (sound only) · fail 9 (the fails are actions with no activity yet), and `actforce forging` working.
- **Confirmed 2026-11-07 (fourth run):** the door-fallback loop fix (`standingOnIt`) and the 15 s re-route (`retryAt`) work: `actphases Glenhold` about 3 minutes after `time 22` showed Performing 28, Travelling 8 (6 standing), no activity 4, against 36 of 40 Travelling before. In that run about 30 `npc_went_indoors how=door` against 6 `how=walked`, and 7 `npc_left_by_door` (3 for `sleep`: #5 from L17, #7 from L18 although L18 is #7's home, #12 from L20). Suspected cause, not measured: a bed in `RecentlyFailed` that they aren't within 4 studs of falls back to `spotFor` (an outdoor spot) instead of the door fallback. Also seen: `npc_building_path_failed reason="path crosses a locked door"` (#11, practice, L19); the door fallback opens doors without checking locks, so someone may be put inside a locked building that isn't theirs.
- **First thing to do:** play, `time 22`, then run `actphases Glenhold` twice about a minute apart. Before the fix it showed 36 of 40 Travelling. If Performing climbs, look inside houses for blankets and at the smithy after `actforce forging`. Watch the log for `npc_left_by_door action=sleep`.
- **What will still hold it back:** about 25 to 30 NPCs standing with no path even outdoors. That's the other pin below, and the two are tied together. Ask the owner whether to resume pathfinding once this run is read.
- **Stage 2 confirmed 2026-11-07 (log + `actreport Glenhold` screenshots):** `specs 931/931`, `actreport` pass 0 · warn 36 · fail 0, and every warn is sound only (no "no activity" rows left). `actpreview practice_gravity` and `actlabels on` ran with no errors, but the owner hasn't said how the poses, props and labels look, so the unverified items below are still open. `activity_stations` still has 3 invalid (bed 48/49, seat 8/9, table 26/27). That log ran in the daytime, so no `npc_left_by_door action=sleep` showed up, and the path failures are unchanged (the pin below). The paragraph that follows is the original build note.
- **Stage 2 built 2026-11-07 on the owner's "Do stage 2"** (`docs/Activities.md` "Stage 2"): 54 activities (39 new) covering every brain action, every trade, every hobby quirk and practice in all 12 domains. Expected boot line `specs 931/931` (5 new). Test with `actreport` (expect no "no activity in the library yet" rows), `actpreview <id>` for the new ones (e.g. `practice_gravity`, `selling`, `hobby_whittling`, `lessons`), and `actlabels on` around Glenhold in the day. Unverified: whether ground-sitting poses (lower 1 stud) sit on the ground or float or sink, the bow's orientation in the aim pose, and the lantern pole held forward. Two small fixes from the fourth run are still open and NOT in stage 2: the sleep exits through the door (#7 left their own home L18) and the door fallback opening locked doors. After that come audio, icons and barks, join and assist, and the LOD pass.
- **Open owner questions:** should talking to a sleeper wake them (the Talk prompt is off while they sleep, by default)? Did the Observe label appear on hover (never confirmed)? Should the permanent name-and-job nameplate go? Should the glowing Neon belts be dimmed? Do the Observe skill, Activity Director and Growth system from the brief exist, or are they new? Should we pick licensed activity sounds now or in the audio stage?

**📌 PINNED by the owner (2026-11-07): NPC pathfinding and getting indoors. Paused, not finished.** Don't pick this up unprompted. When the owner says to resume, start here.

- **Where it stands.** In daytime, NPCs walk around town. At night or at meals they walk to a building's door, the door opens, and they appear at their spot inside (the "door fallback", `NPCService` `stepEnterHome`, `leaveBy`, `npc.enterHome`, `npc.insideLot`). They leave the same way. It covers any built lot (`SettlementService.lotAt`), both ways. The latest version (any building, both ways) hasn't been run.
- **Fixed on the way, each confirmed in a log unless marked:**
  - NPCs falling through the world: T1 bodies drawn at generator height, inside levelled town ground (`NPCLOD` `standOnRealGround`). Confirmed: no `npc_fall_seen` in 5+ minutes.
  - Building anchors (`NPCHome`, `NPCWork`, `NPCSeat`, `Entrance`) applied twice and landing far from their buildings (`BuildingGenerator.anchor`). Confirmed by `specs 899/899` and the deed sign.
  - The path queue jamming itself (`Navigation.enqueue`, `nextJob`). Confirmed: `queued` 0.
  - NPCs owned by the player's client (`npc_owner_taken_back`). Confirmed: `network owner server`.
  - `PathfindingLink`s through every front door and up every staircase. Confirmed: `doors` went from 0 to 11, `how=walked` appeared.
  - Not yet confirmed: `PathfindingModifier` on NPC bodies, a narrow check for walks under 6 studs, 3 path attempts instead of 6.
- **The open problem: rooms are sealed to the pathfinder.** `nav_no_path` reports `goalOk=false` for spots inside buildings and `startOk=false` for NPCs already inside. Suspects, not measured: furniture crowding the anchors NPCs aim for (`NPCHome` is 2.6 studs from a bed, which is a Seat), the inside end of each door link sitting off the walkable floor, and `AgentRadius` 1.25 to 1.5 in small rooms. `no path` was still about 2:1 against paths. Some failures are outdoors too, including a 3-stud plaza walk, possibly town ground steps or slopes.
- **To resume:** play at night in Glenhold with the Output open. Read `nav_no_path` (`startOk`, `goalOk`, from and to), `npc_building_path_failed`, `npc_went_indoors how=walked` against `how=door`, and `npc_left_by_door`. Run `npcmove settlement_1#<n>` for `paths`, `no path`, `doors`. Good first steps: test one empty house with `overlay npcnav`, move `NPCHome` anchors clear of furniture, or snap link and anchor points to the real floor with a raycast at build time.
- **Temporary, remove once resolved:** the `nav_no_path` probes (`canLeave`, two extra path computations at most every 5 s) and `npc_fall_seen` / `npc_fall_loop`.
- **Unanswered owner questions from this thread:** should NPC accent Neon (belts, bands; the "cyan line") be dimmed, since Bloom blows it out to white? Is people appearing inside at their spot, instead of walking across the room, acceptable for now? Workplaces and the tavern may get crowded inside, which hasn't been seen.
- **Expected boot line `specs 906/906`.** Commits: `5d48f14` through `0033e44` on `baseline` (not pushed: the branch is 43 commits ahead of `origin/baseline` as of this pin).

**1. Check first (built, not yet confirmed in a log)**
- **Readable activities, third run 2026-11-07: `actphases` at 22:00 showed 36 of 40 Travelling (26 to 32 standing), even though about 20 had `npc_went_indoors`.** The cause was a loop in `NPCService.route`. The door fallback leaves someone on the use point with no destination. The next think re-routed them, `RecentlyFailed` dropped the target they were standing on, and they were sent to the outdoor district spot through `leaveBy`. Fixed: a target within 4 studs is kept (`standingOnIt`). ActivityService also re-routes anyone stalled short of their use point every 15 s (`retryAt`). Not yet run. `actforce forging` without arguments works now (the npc default fix held). Expect Performing to rise at night in `actphases`.
- **Readable activities, second run 2026-11-07: `specs 926/926`, `activity_stations` 107 stations, 3 invalid.** `actphases` at 22:00: 32 of 40 Travelling, 28 of them standing with no path. So the pinned pathfinding problem is what blocks most activities from showing. The owner asked "Do NPCs still talk in their sleep?": they did (barks never checked sleep). They also lay down in the street wherever a failed path left them. Fixed, not yet run: no barks while asleep; the Talk prompt is off while someone sleeps (default; asked the owner whether talking should wake them); someone with a station counts as arrived only at its use point; a station lights up only when its user is there (`presentUser`). Also: npc-type admin defaults (`"nearest"`) reached handlers as the word (`actforce forging` crashed); now parsed like `"me"`. That affects the 5 commands defaulting to `nearest`.
- **Readable activities, first run 2026-11-07: `specs 926/926`, no errors from the new code.** `stationcheck` showed 89 of 91 seats and 22 of 27 tables without a use point. The causes: seat anchors hang off the foundation, so they were measured from the wrong part and shared one station part; the clear-space box started at the ankles instead of the torso (an R6 body only collides from 2 studs up); large houses use `Stool`s; and house stools counted as tavern seats. All four are fixed, and reading falls back to the home table when the town has no desk (`altStation`). Not yet run. The debug labels showed nearly everyone "Travelling 0%": probably the pinned pathfinding problem (`nav_no_path` throughout), not measured. New `actphases` and the `actnpc` travel note say walking, standing or heading for a door: read those first. Three `npc_fall_seen` at Tavern_01, each within 2 s of `npc_went_indoors how=door lot=…L03`: the door fallback put bodies at a seat anchor at bench height. `NPCService` `landingFor` now lands them on the nearest use point or on the floor (a small change inside the pinned code, flagged to the owner). Expected boot line still `specs 926/926`. `activity_stations` now logs 90 s after boot with usable/total per kind.
- **Readable NPC activities, stage 1 (`docs/Activities.md`), built 2026-11-07.** The owner's brief: every activity readable at a glance. `Services/ActivityService` replicates one `NpcActivity` attribute per rig. `Life/StationRegistry` gives anvils, hearths, desks, beds, altars, tavern seats and home tables use points at runtime, and `NPCService.route` sends people there (`setActivityHook`). The client draws props, procedural poses, set pieces and station looks (`ActivityController`, `Fx/ActivityPoser`, `ActivityProps`, `SetPieces`, `StationFx`). `ObserveController` adds a look-at label behind the **Reading people** setting. 15 activities so far. Expected boot line `specs 926/926` (20 new in `Tests/Activity.spec`), plus `activity_stations` (watch `invalid=`). Test with `actlabels on`, `actreport`, `stationcheck`, `actforce forging`, `actpreview practice_earth`, and `timescale` across a day. Unverified Roblox behaviour: a client playing an activity clip on a server-owned NPC (it falls back to the procedural pose after 3 s if the clip doesn't load), and posing through `Motor6D.Transform` in PreSimulation. Kill switch: flag `activities_enabled`. Overlaps the pinned pathfinding work: sealed rooms still mean the door fallback, not a walk, puts people at stations.
- **Rooms are closed to the pathfinder: the door fallback now covers any building, both ways (2026-11-07, not yet run).** With `startOk`/`goalOk`: `goalOk=false` for spots inside buildings, `startOk=false` for NPCs already inside. The owner saw a crowd "eating outside": sociable NPCs eat at the tavern (`ScheduleService.districtFor`), and a failed path to it sent them to an outdoor district spot. Now a failed path into any built lot (`SettlementService.lotAt`) walks them to its door and in, and a failed path out of one sends them out through its door. Log: `npc_building_path_failed` (replaces `npc_home_path_failed`), `npc_left_by_door`, `npc_went_indoors`. Still open: why rooms are sealed (furniture near anchors, or the link endpoints), which would let them walk inside too. Boot line stays `specs 906/906`.

- **After the links (2026-11-07, `specs 906/906`; the 907 below was a miscount):** the links work: `doors` 7 to 11 and `npc_went_indoors how=walked` appear. The owner: "they seem to kinda go in their house but sometimes not". `no path` still about 2:1, including a 3-stud walk across the plaza. Built, not yet run: `PathfindingModifier` on NPC rigs (anchored T1 bodies may carve the navmesh, a guess), a narrow check for walks under 6 studs, 3 path attempts instead of 6, and `nav_no_path` now reports `startOk` and `goalOk`: read those first, they say which end is sealed. The cyan line asked about earlier is NPC signature accents (`NpcLooks` Neon belts and bands), which Bloom also blows out to white; not dimmed yet, the owner hasn't said. Boot line stays `specs 906/906`.

- **Links through doors and up stairs, built 2026-11-07.** After the queue fix: `queued` 0, owner `server`, but 498 no path against 160 paths and 0 doors ever. Failures ran both ways, into a house and out of one, so interiors look sealed to the pathfinder: a guess that a 3.5-stud doorway is too narrow for its grid, not measured. `BuildingGenerator` now adds a `PathfindingLink` at each `frontDoor` and each staircase, unproven until `doors` climbs above 0 and `npc_went_indoors how=walked` appears (that line used to fire right after `how=door` as well; fixed). If a link's endpoints sit off the navmesh it will do nothing, and those positions are the first thing to check. People who came in by the door go out the same way. Some no-paths look outdoors or between close points (`help` at -627,146 to -631,144), so expect a second cause. Expected boot line `specs 907/907`.

- **The NPC path queue jammed itself, fixed and confirmed 2026-11-07 (`specs 905/905`, `queued` 0).** `npcmove` in the owner's log: `queued`, 77 to 79 waiting, 63 finished paths in 2 minutes against a nominal 6 a second, 0 doors, 0 failed, 35 no path. A full queue takes about 13 s to clear and people re-ask after about 10, adding a new job at the back, so jobs went stale before their turn and stale jobs still took turns. `Navigation.enqueue` keeps one place per person, and `Navigation.nextJob` skips stale jobs free. Expected boot line `specs 905/905`. Then see: `nav_no_path` (over half of paths had no route, reason unknown), `npc_owner_taken_back` (NPCs reported a client as network owner), `npc_home_path_failed`, `npc_went_indoors`, and whether `npcmove` shows doors above 0.

- **NPCs still didn't go home after the anchor fix (owner's screenshot, 2026-11-07, `specs 899/899`): built, not yet run.** Tamine, on `sleep` with a bed in HouseLarge_01, stood in the street at 00:34. A failed path to a bed sent them to an outdoor district spot, and `nav_failed` was debug-only, so the reason is still unknown. Now `npc_home_path_failed` logs it once per NPC, and they walk to their own door and go in (`NPCService` `stepEnterHome`, `npc.insideLot`). That's a fallback, not the fix: `npc_went_indoors how=walked` against `how=door` shows how often the real walk works, so read those next. Only homes, not workplaces.

- **Building anchors were all in the wrong place, fixed 2026-11-07, `specs 899/899` confirmed.** `BuildingGenerator.anchor` set `WorldCFrame` before parenting, so the position was applied twice. Found through `town_collapse_strays` (`DeedSign` about 600 studs from its house). It affected every anchor: `Entrance`, `NPCHome`, `NPCWork`, `NPCSeat`, and so the deed sign and the player's house marker. So NPCs may now really walk to their homes and workplaces, possibly for the first time: watch for new door, pathing and crowding problems, and more `npc_recovered reason="moved..."`. Expected boot line `specs 899/899`.

- **Owner said "Everything looks good now" 2026-11-07, with `specs 898/898`:** one builder finished a 133-piece house, residents left and came back, scaffolding is the right size. No `npc_fall_seen` in nearly 5 minutes (the earlier long run had several), which supports the fall fix.

- **NPC falls: cause found 2026-11-07, fix not yet run.** `npc_fall_seen` showed real ground (`hitY`) 4 to 5 studs above the generator's `surface`, in Freefall, in clusters, with the chunk built and terrain solid. T1 rigs are drawn at `groundAt` (generator height, ignoring town levelling), so going to T0 released them inside solid terrain. `NPCLOD.sync` now stands them on real ground as they're unanchored. If `npc_fall_seen` still appears, the fix isn't complete: T1 rigs also still look sunk into town ground. Keep the logging until a clean log confirms.

- **Earlier notes on those falls (log of 2026-11-07):** `npc_recovered reason="below the terrain"`, `settlement_1#1` once a second for 17 s, and others, all around x -700 to -760 in the spawn chunk, starting before the player did anything. The rescue's ground is verified solid and the chunk is built, and the player doesn't fall there, so it looks specific to those rigs. A rig that falls 3 times in 8 s is held for 30 s (`npc_fall_loop`). A log of 2026-11-07 also showed single falls (settlement_1#16 at -611,150 and #17 at -641,163, y about -63) that the loop check missed, so `npc_fall_seen` now logs the rig and the ground at the spot it fell, on each NPC's first fall: read that first. The next log (`specs 852/852`, a feral fought near spawn) had no falls at all, so it's intermittent and still unexplained. It first appeared in the first log with Feral Spells, so `FeralService`'s dependency on `NPCService` changing boot order is worth ruling out, though nothing links them yet.

- **Collapsed buildings rebuild: `specs 885/885` confirmed 2026-11-07, full rebuilds seen.** The same pieces go back, from the ground up, after 2 minutes to settle (`docs/TownRepair.md`). The owner then reported the builder getting walled in, and asked for residents to react and for scaffolding. Built, not yet run: workers stand outside the footprint and move round, `NPCService.setLotDown` sends residents to a friend's house or the tavern and home again, others are sent out of the footprint, `Towns/Scaffold`, and pieces rise into place. Test with `townrepair rush`, then `townrepair collapse`, or a real `quake` or `tsunami` (not yet tried with this). Log: `town_collapse_noted`, `town_residents_moved`, `town_rebuilt`. `specs 894/894` confirmed. The owner's screenshot then showed a scaffold stretched across the sea, and the log showed three workers starting one job: the footprint measured every part in the model, so one stray far-off part stretched it, and the workers' spot was out of reach. It now uses the lot's size from the layout. What the stray part is isn't known: `town_collapse_strays` will name it. Fix not yet run. Expected boot line `specs 898/898`. No `npc_fall_seen` in that log, but it was only 2 minutes, so the fall fix still isn't confirmed.

- **Places recover: owner said "it all looks good", 2026-11-07.** Repairers carry a hammer, and living things (`tree`, hedges) grow back by themselves; `specs 879/879` unconfirmed in a log. In the owner's screenshot of the worker there was a cyan glowing line across them at ground level, unexplained and not asked about yet.

- **Places recover (`docs/TownRepair.md`), built 2026-11-07 on "build next".** Unsaved fires leave grass bare, regrowing by quarters over 10 to 20 minutes. Any fire that chars part of a town gets repaired, by a builder walking over with the hammer clip near a player and more slowly with nobody there, and a repaired part stays slightly paler. Not saved. Test with `townrepair burn`, `townrepair status`, `townrepair scar`, `townrepair heal`; log `town_repair_started`, `town_repaired`. Expected boot line `specs 878/878`, if the unconfirmed 865 holds. Worth watching: this is the first use of a `hold` leash for ordinary work, and of `Navigation.Face` from outside the NPC system.

- **Towns remember loose spells, built 2026-11-07 on "build next", not yet run.** New memory kinds `lost_control`, `spell_hurt_me`, `ended_it`, `cleaned_up`, spread by gossip, driving opinion and five new deed barks. Claude's default on the open question: your loose spell hurting people costs a little standing, and isn't a crime. Log: `feral_blamed`, `feral_remembered`. `feral spawn` now counts as yours, so all this can be tested with it. Expected boot line `specs 865/865`.

- **Ferals in the world, built 2026-11-07 on the owner's "It looks better, do what you said", not yet run.** Domain effects (a fire feral burns what it passes, water quenches, air throws people back, statuses on hit) and towns responding (guards and hunters fight it through `NPCCombat.setExternalTarget`, others run through `NPCCombat.alarm`, some shout; log `feral_town_reacted`). 

- **Feral Spells (`docs/FeralSpells.md`), first seen working 2026-11-07:** `feral_escaped`, `feral_woke`, `feral_fell`, `feral_rumor` all in a log, no errors. Not yet seen: a real escape from a backfire, an NPC accident, `feral_studied`, a guttering out. The owner approved a second look from a screenshot (no shell, seeded pieces per domain, constant motion that gets wilder as energy runs out, no name or health bar) and said "It looks better"; `specs 852/852` confirmed. The only spec failure in that log was a rounding mistake in the spec. No interface, on purpose: see the design rule below. Test with `feral spawn`, `feral list`, `feral goto`, asking townspeople for rumours, and an NPC accident's clue. Look for `feral_escaped`, `feral_woke`, `feral_fell`, `feral_studied`, `feral_guttered`, `feral_rumor`. The doc lists the parts that still feel like a game, for the owner to judge.

- The progress reset's specs and the map's specs passed (they're inside the confirmed `specs 673/673`); neither feature's in-play behaviour has been seen.
- The map: check where a click lands, whether a fully explored map hitches on opening (`maprevealall`), and whether uncovered ground survives a rejoin (`docs/Map.md`).
- A shared event played to the end: payout, tiers, and the guaranteed first relic (`sharedevent start elemental`, 30+ s in the zone).
- Not reported yet: whether the relic panel hides after 60 s, plain `borrowed time` without `me`, how Surge looks, Timestop freezing flames and animations on a second client, craters, flight feel.

- **Rifts stage 1 (`docs/Rifts.md`): `specs 673/673` and one full run confirmed 2026-11-06** (rooms, Warden, gold payout with epic gear, the schedule opening a Rift by itself). The owner sent the log without comment, so looks and feel are unreported. Fixed after it, not yet re-run: the pocket moved from y = 120 to y = 60, because Travel read it as flying too high and ended every ride (`travel_violation height=76`). Expected boot line `specs 674/674` and no `travel_violation` inside a Rift. To check: the Gallery at low level (the run sat there about 90 s at tier 1, solved 32 s after `testmage`; `rift_eye_gone` now logs each eye), a Rift run at one level throughout, and the panel's position. One `dash_overshoot` (blink, allowed 5, moved 21) is log-only; watch for more. Also new: `foundation_failed` on House_09 and HouseLarge_07 fixed itself later (`foundation_fixed`), so those are at least sometimes a timing issue; House_12 didn't in this log.

- **Rifts stage 2 (`docs/Rifts.md`): `specs 690/690` confirmed 2026-11-06.** 7 rooms, 8 twists, 3 bosses, reactions as answers, first-time answers pay XP and a journal line (`data.rifts.found`). Seen in that log: the Vigil, Engine and Gallery, the Stormheart, Overflow, `rift_answer_found`, a gold payout. **Not yet in any log:** the Twins, the Long Dark, the Frostgate, Echo, Gloom, Short Fuse, any `rift_reaction`, Travel inside a Rift since the y = 60 fix.
- **Rifts tuning pass and the NPCCombat fix, built 2026-11-06, not yet run.** Expected boot line `specs 699/699` (9 new). Flatter power curve, repeated answers wear out within a room, eyes and lamps take 2 clever casts, enemies scale to the strongest spell cast inside (table in `docs/Rifts.md`), hints once per room (`rift_hint`), and `rift_ended` now logs `seconds` and `power`. The NPCCombat crash (`nil with 'casts'`) was an NPC disengaging during a bolt's wind-up; the charge now drops. Tuned from high-level runs only, one with `cheat all`, so its times don't count.

- **Wild Zones stage 1 (`docs/WildZones.md`): `specs 731/731` confirmed 2026-11-06, which also confirms the Rift tuning specs.** Owner on Vale, Hollow, Moor, Shore: "everything else seems good" apart from the Moor. Riot and Slow Wood not entered in that log.
- **The Moor fix and Wild Zones stage 2, built 2026-11-06, not yet run.** Expected boot line `specs 748/748` (17 new), plus `wild_zone_terrain` for each zone. The Moor's cause is reasoned, not measured: a standing Humanoid pins itself against a gentle lift, so the client now pushes you into freefall (`WildZoneController.letGo`). If it still doesn't lift, look there first. Stage 2: real terrain through `WorldStateService.addGeneratedOps`, creatures and loose objects obey the rules, rumours through `NPCService.setRumorHook` (`wild_zone_rumor` in the log) and `MapService.revealArea`, and a full bag no longer spends a harvest. Test with `wildzone goto <zone>`, and ask townspeople for rumours.

- **Titans (`docs/Titans.md`), built 2026-11-06 on "Build that next", not yet run, and the Moor fix and Wild Zones stage 2 above still unreported.** Expected boot line `specs 780/780` (32 new in `Tests/Titans.spec`), if the unconfirmed 748 holds, plus `titans_ready`. Test with `titan start`, `titan goto`, `titan status`, then break a weak point and `titan win`. Look for `titan_built`, `titan_weak_broken`, `titan_fell`. A fall's name is in a world store, so erasure needs `titan forget any <userId>` as well (Backend.md).

- **Event cards moved (2026-11-06, owner: the popout in the middle of the screen "gets hard to read or see"), not yet run.** Shared event, Titan, wild zone and Rift cards now stack in one right-hand column (`UI/SideCards`, 120 down) with a more solid background. Claude assumed the Titan or shared event panel was the one meant; the duel card stays top centre on purpose. New cards of this kind belong in this column, not the middle. No spec change: still expect `specs 780/780`.

- **Log of 2026-11-07: `specs 780/780` confirmed, which also confirms the Wild Zones stage 2, Titans and event card specs.** One full Titan fight ran: `titan start`, two weak points broken, `titan_fell` with `first=true`, gold payout, crater. `wildzone goto vale` worked. The owner sent no comment on looks or feel, and the Moor's lift isn't in this log. Not bugs: the double `cantrips_granted` (two awakened domains), `towns=` empty on a forced Titan, `power=1` at build (it rises as spells land).

- **Owner, 2026-11-07, after the build below: "Everything is good" apart from the inventory's hover card**, so **,** and **.** work and the third familiar look is accepted (no log sent, so `specs 825/825` is unconfirmed). The hover card's cause: its ScreenGui used Global layering with the panel at ZIndex 10, so the card drew over its own text. Now Sibling layering and a solid raised panel, not yet run. Seen in that screenshot and not raised by the owner: the "Gear" filter button reads "Gea", and the item grid's ninth column is cut off.

- **Keys and the familiar's third look, built 2026-11-07.** I and O never opened a screen in Studio, through two fixes: `ContextActionService` above the camera, then destroying `CameraZoomAction`'s `KeyboardBinding`. The real cause was never found. The owner said to use non-letter keys, so Inventory is now **,** and Familiar is **.**; both fixes are gone, and I and O zoom again. A spec keeps screens off them. From the owner's screenshots, a serpent read as a chain of balls with googly eyes, a duck-bill snout and Neon flaring white under Bloom. Now: one colour with overlapping segments, smaller eyes that are mostly pupil, dimmed Neon (`F.glowDim`), and secondary colours that stop going grey. Only the serpent's body was reworked; the other five got the shared fixes. Expected boot line `specs 825/825` (2 new).

- **Log of 2026-11-07 (second): `specs 816/816` confirmed, `familiar_bonded` seen, and `commission_delivery` is now offered, so that fix held.** The owner reported that O doesn't open the Familiar screen. Roblox's camera binds I and O for zoom and is the likely cause (reasoned, not measured), so `InterfaceController` now binds both above the camera with `ContextActionService`; they no longer zoom, and the mouse wheel still does. If O still fails, suspect a Studio plugin or shortcut, and the tab bar (G, then the Familiar tab) still opens it. `settlement_dispute` failed with `why="slot envoyA unresolved"` (a town with no guards) and now falls back the same way. `specs 817/817` confirmed in the next log (the dispute spec's first failure was the spec's own fake data), with `familiar_grew` through stage 5 and no errors. **Whether O and I now work is still unreported: the log can't show it, so ask.** That log also showed `learned=` empty at stages 4 and 5: a familiar only learned at the moment it reached Elder, and only from another domain. It now also checks on load, and falls back to its domain's `synergies`. **Confirmed in the next log: `specs 819/819`, `familiar_grew learned=energy stage=4`, no errors.** No log yet shows `familiar_ko` or a rename, and the owner has sent four logs without comment, so O, I, and how familiars look and move are all still unreported. `foundation_failed` on House_12, HouseLarge_07 and House_09 recurred, and House_12 fixed itself within seconds, more evidence of a timing issue.

- **Familiars stage 1 (`docs/Familiars.md`), and the Titan fire fix, built 2026-11-07, in-play behaviour not yet reported.** A Titan's fires no longer save scorch or vegetation (`FireSim.igniteGround`'s `unsaved`), so a walking Ashwalker should add no `terrain_edit cause=scorch` of its own. Familiars: O opens the screen. Test with `familiar bond`, `familiar stage 4`, the four orders, `creature spawn`, rename, and a second client to see whether it moves smoothly. Look for `familiar_bonded`, `familiar_grew`, `familiar_ko`.

**2. Next up**
- **Rift tuning is paused by the owner (2026-11-06: "we'll go back to tuning rifts another time"):** don't raise it unprompted. When it resumes, the missing log is a low-level run with no `testmage` or `cheat`; `rift_ended seconds=` gives the answer directly. Stage 3 ideas are in `docs/Rifts.md`, nothing chosen.
- **Wild Zones stage 3, once stage 2 has been played:** quests pointing at zones, more zones or a share per world, rules changing with weather or time of day (`docs/WildZones.md`). Nothing there is chosen.

**3. Small follow-ups to what's built**
- **Map:** a minimap on the HUD (recommended), towns visible from the start (one line, owner to decide), rumours and quests marking the map, drag to pan, drawing roads.
- **Surge:** a stronger look per domain (flame wings, a stone shell, hair and eye glow), and its own sound.
- **Domain Travel** (owner: "passable"): a riding pose per style, boards for the 8 styles without one, sound, and a fix for riding indoors, where a roof reads as ground. Decide whether Earth and Life should stop at water (it may clash with "don't restrict the player") and whether riding should cost reservoir, since low levels run dry in about 33 s.
- **Time:** sounds, which need a library pick. Timestop doesn't stop tsunamis or quakes already running.
- **Gravity:** Inversion's wall-walking, and the "vector an area" ritual (`docs/Gravity.md`).
- **Town crimes:** later hits from grips, loops, finishers and Meteor Landing aren't judged as cast crimes, and neither are Time's spells.
- **Fixes if they show up in play:** `foundation_failed` on `House_12` and `HouseLarge_07` in settlement_2, and the spawn rescue from near the world origin.

**4. Pitched and not yet picked (the 2026-11-06 and 2026-11-07 ideas rounds)**
- ~~**Magic Changes You**~~: built 2026-11-07 as Magic Marks (see the top of this list).
- **Pacts:** seeded otherworldly beings offer a real power for a real cost. M.
- **Town Mysteries:** a seeded crime in a town, solved with NPC memories and your own magic. M–L.
- **Ley Claims:** claim a ley nexus for a server session; it boosts your domain nearby, and others can take it. M–L.
- **The Apex:** a mythic player opts in to be hunted by the whole server. M. Must stay opt-in.
- **Echoes:** faint ghosts replay legendary moments where they happened, on every server. M. Needs the same limits as Titans.

**5. Paused: multiplayer (design in `docs/Social.md`, "Still to build")**
- Cross-server news and leaderboard, then direct trade, then markets (stalls, auctions, commissions). The remotes are declared with no handlers. M is now the map and K is Surge, so markets and trade need other keys. Should relics be tradable? (Recommended yes.)
- Later stages: guilds, social hubs, PvP modes, and party extras (mute and report tools, the fake-player load test, more combos).

**6. Waiting from older briefs**
- **Living world stage 2** (`docs/LivingWorld.md`): settlement growth, rumours, vignettes, world history, wonder events.
- **NPC movement stage 2** (`docs/NPCMovement.md`): LOD transition rework, network ownership and physics, anchor validation, soak test.
- **Earlier top-5 lists, not picked:** `docs/EngagementIdeas.md` (people noticed that, overheard rumours, goals you set yourself, a rival who remembers) and `docs/MagicIdeas.md`.

**Decisions waiting on the owner**
- **Familiars:** should other players be able to hurt a familiar (it's untouchable now, to stop griefing)? Should Hunt loot count in full?
- **Titans:** is 20 falls the right limit (at least 40 hours before the oldest fades, craters stay)? Should bones ever be permanent for the first-ever kill of each kind?
- **Craters:** holes in towns (they're scorch marks there now, by Claude's call)? Should craters outside towns ever heal?
- **Self Timeline:** is a 6 s recall cooldown at Transcendent right?
- **Timestop and duels:** fighters in someone else's duel stay exempt, by Claude's call.
- **Relics:** is one guaranteed by your first gold finish too generous?

## Where we left off (session 2026-11-05)

**Newest work (2026-11-06, owner: "If nothing is wrong build the next step"):** the map built, NOT yet run (`docs/Map.md`, `Services/MapService`, `Shared/World/MapData`, `Controllers/MapController`, `Tests/Map.spec`, 24 new specs, expected `specs 623/623`). M opens it, so markets need another key. Next by my recommended order: Rifts, not approved yet.

**Domain Travel (2026-11-06):** `specs 599/599` confirmed; the owner calls it "passable" (`docs/Travel.md`). Y toggles it and shares the key with landing. Open: poses and boards for each style, whether Earth and Life should stop at water, whether it should cost reservoir. In that log, `rbxassetid://81504106` failing isn't in the project, and one `npc_recovered` was the safety net returning an NPC to its remembered spot.

**Boot confirmed 2026-11-06: `specs 577/577`, magic examples 33/33, no errors.** **Newest work (2026-11-06, owner: "go" on the ideas round):** Borrowed Power and Surge built (`docs/Moments.md`, `Tests/Moments.spec`). Seen in the log: a relic's Timestop and recalls, its minute passing with no error, Surge starting and the Solar Flare finisher hitting a target, a creature kill during Surge, and a shared event starting by itself on the clock (`storm` at Larkwell; the session ended before it finished, so no payout or first-relic guarantee has been seen). How Surge looks and whether the relic panel now hides are unreported; plain `borrowed time` (no `me`) wasn't retried. `foundation_failed` recurs in settlement_2: House_12 and HouseLarge_07, terrain about 1.1–1.3 above the floor against a 0.6 tolerance, not caused by this work. The relic panel bug's root was an old AdminService bug: a left-out `default = "me"` reached 76 player arguments as the word "me", so most `[player]` commands failed unless you typed `me` (a player default is now parsed; other string defaults stay words). That left a bad entry that crashed the relic's expiry loop for good; the relic, Surge and shared-event loops now survive an error, and the panel hides itself on time. The owner said Timestop "runs fine", with no log. Next from that round, my recommended order, not yet approved: Domain Travel, a map, Rifts. Still pitched and unpicked: Wild Zones, Titans, The Apex, Tournaments, Echoes, Familiars. Defaults used: relics are rare (first gold guarantees one), Surge is a full transformation. The social queue (news, trade, markets) stays paused; K is now Surge, so trade needs another key.

**Boot confirmed 2026-11-06: `specs 540/541`, magic examples 33/33, 50 server and 30 client modules, 216 NPCs.** That's the first log since `dc61694`, so the specs for multiplayer stage 1, party loot, shared events, Gravity and Time all pass. The one failure was the Stored Moment example (Bind needs a tier 2 branch; causality is tier 1), fixed by moving it to `rewind`: expected `specs 549/549` with Timestop's 7 new specs. **Then the owner asked "Timestop should freeze everything in the radius" (not yet run):** everyone but the caster, allies and warded NPCs too, loose objects, fire, heat, fields, gravity powers, statuses, event attacks, particles, and hits on the frozen wait and land together (`Cast/TimeZones`, docs/Time.md). Fighters in someone else's duel stay exempt (Claude's call, flagged). In play at tier 8: `time_recall` and `timestop` ran with no errors (cooldowns respected), and an NPC was knocked out. **Not yet in any log:** Last Moment, Target Timeline, Stored Moment (it couldn't be cast), Borrowed Wound, Future Sight, Time Loop, all Gravity powers, craters, shared events. The owner sent the log without comment, so looks and feel are unreported. Still seen: the spawn rescue from near the origin, and one `foundation_failed` (House_12, terrain 1.13 above the floor, past the 0.6 tolerance); neither is new.

**Newest work (2026-11-06, Ideas prompt 11, owner: "Make time next, have self timeline restore everything, and let it save you from death at grandmaster. Have meteor landing and singularity leave craters."):** Time powers built: Self Timeline (N), Last Moment, Target Timeline, Stored Moment (L releases both), Timestop, Borrowed Wound and Deferred Pain, Future Sight, Time Loop (`docs/Time.md`, `Cast/TimeRuntime`, `Effects/TimePower`, `Data/TimeTuning`, `Magic/TimeRules`, `Services/TimeService`, client `TimeClient`, `Fx/TimeFx`). Craters: `GravityRuntime.crater`, permanent outside towns, a scorch mark inside (Claude's call, flagged to the owner). Held creatures and NPCs no longer bite or cast. Expected `specs 541/541` (31 new in `Tests/Time.spec`). **Next:** the paused social queue (cross-server news and leaderboard, direct trade, markets) unless the owner says otherwise. Fixes to Gravity and Time are also likely once played.

**Previous (2026-11-06, Ideas prompt 10, owner: "Time is supposed to be overpowered so don't hold back on the abilities. Same with gravity. Build gravity"):** Gravity powers built, NOT yet run: Flight, Meteor Landing, Crushing Grip (can kill), Lift and Slam, Gravity Well, Singularity, Orbit Shield, Bend Path, Mass Shift, stronger fields (`docs/Gravity.md`, `Cast/GravityRuntime`, `Effects/GravityPower`, `Data/GravityTuning`, `Magic/GravityRules`, `Services/GravityService`, client `GravityClient`, `Fx/GravityFx`). Expected `specs 510/510` (38 new in `Tests/Gravity.spec`, if the unconfirmed 472 holds). `cheat infinite` is now real (`ReservoirState.infinite`: nothing spends, nothing drains) and naming a cheat turns it on instead of toggling; the owner reported limited reservoir after the old toggle, fix not yet run. Also fixed: a status change unanchored static enemies and dummies. The social queue below (cross-server news, trade, markets) is paused, not cancelled.

**RESUME HERE (2026-11-06):** the owner asked for "shared events, markets, shared creature kill XP and loot and quest xp and loot sharing". **Done, not yet run by Claude's knowledge:** party sharing of creature XP and loot and quest XP and loot (`PartyLootService`, `Social/LootRules`, `Data/PartyRewards`, `QuestTuning.loot`; quests had no item drops before, so these are new and also apply solo), and shared events (`SharedEventService`, `Social/EventRules`, `Data/SharedEvents`, `Social/Data/EventEnemies`, `SharedEventController`, `Fx/EventFx`; docs/Social.md "Shared events"). 41 new specs: `Tests/SharedEvents.spec` (30) and `Tests/Economy.spec` (11), so expect `specs 472/472` if the unconfirmed 431 holds. Test with `sharedevent start elemental` (also `storm`, `siege`, `comet`), then `sharedevent status`. **Not started; build next, in this order:** cross-server news and leaderboard, direct trade, markets (stalls, auctions, commissions). The agreed design is in `docs/Social.md` under "Still to build": read it first. The remotes for these are declared with no handlers. **On 2026-11-06 the owner said "everything is already tested" and to build on, but sent no Output,** so stage 1 is treated as tested on their word; no log since the `dc61694` boot fix has been seen.

**Newest work (2026-11-05, owner's multiplayer brief, built in stages, `docs/Social.md`):** stage 1 is built, NOT yet run: audit, `Cast/PvpRules` (one rule for who can hurt whom, checked in `Targeting.canHarm` AND `Damage.apply`), parties with shared quest progress and a Party screen (P) + HUD bars (`PartyService`, `Social/PartyModel`, `PartyController`), one two-player combo (Earthflare, Earth + Energy: `ComboService`, `Social/ComboMatcher`, `Data/Combos`), emotes (hold T, chat commands: `EmoteService`, `EmoteController`), consent-based non-lethal duels (`DuelService`, `Social/DuelModel`, `Data/DuelRules`, `HealthFloor` in `Damage.apply`), blocks and privacy settings (`SocialSafetyService`). Expected: 43 new specs in `Tests/Social.spec` (`specs 431/431` if the unconfirmed 388 still holds). Testing needs Test > Clients and Servers with 2 players. Client-created `TextChatCommand`s and stopping a replicated clip on a hiding viewer are unverified Roblox behaviour. **Open, needs the owner:** `pvp_enabled` stays on (their 2026-11-03 decision), but this brief calls PvP opt-in; recommended turning it off. **Wait for the owner to confirm before stage 2** (order: guilds, shared events, markets, then hubs and PvP modes). Audit items not fixed are listed in Social.md §1.

**Newest work (2026-11-05, owner's NPC movement brief, built in stages, `docs/NPCMovement.md`):** stage 1 is built, NOT yet run: audit with ranked root causes, `NPC/NavigationService` (owns all T0 movement), `NPC/NPCAnimator` (walk from real velocity), `NPC/NPCConversation` (pause, face, talk, resume), door `PathfindingModifier`s, `overlay npcnav`, `npcmove`. First Play confirmed `specs 387/387`, a scene with stepping in, creature kills and `first_hour` lines; the owner reported janky walking and looping `point`/`hold`, fixed the same day, not yet re-run (expected `specs 388/388`). The spawn rescue is confirmed as a character loading at the world origin before the spawn exists (not fixed). **Wait for the owner to confirm before stage 2:** LOD transition rework (T1 hops still teleport), network ownership and physics, anchor validation, soak test. Rule from the brief: nothing outside Navigation may call MoveTo or Move or write WalkSpeed or Jump on an NPC (only `NPCLOD`'s T1 and spawn `PivotTo`s remain, for stage 2).

**Previous work (2026-11-05, owner's "living world" brief, built in stages, `docs/LivingWorld.md`):** stage 1 is built, NOT yet run: audit, daily life in the spawn town (`AmbientLifeService`, `NPC/DailyLife`, `Data/Activities`; flag `ambient_all_towns`), 122 barks + 40 greetings (`Data/Barks`, `BarkEngine`, `GreetingRules`), 10 scenes (`SceneDirector`, `Scenes/`). Expected boot line `specs 377/377`, plus `daily_life_town` and later `scene_started`. **Wait for the owner to confirm before stage 2** (settlement growth, rumours, vignettes, world history, wonder events). The full brief asks for 300 lines, 40 scenes, 50 vignettes and a 30-day simulation in the later stages. Known limit: hitting a scene's thief still counts as ordinary assault.

**Earlier step:** all 8 early-game items are built and `specs 357/357` is confirmed. The first `firsthoursim` table is in EarlyGamePlan §10: speed targets met, and the beginner lesson now pays a fixed 200 XP (owner's decision; it used to reach Novice alone at about 3 minutes). Time's and Reality's two power 1 attacks now cost like Gravity's (owner's decision; `Data/Strikes` `innateCost`), and Mythic domains are exempt from the 25% check. Neither change has been run. Expected boot line `specs 359/359`. `xpScale` stays unless the owner changes it. Items 6 and 7 and live `first_hour` lines still aren't seen in a log: that run landed no hit. `character_rescued` logs x, z and ground height, and since 2026-11-05 the position BEFORE the move (older logs reported the destination), to explain the spawn-water rescue (3 of the last 4 runs). Unproven guess: the character loads before the spawn exists and lands somewhere else. The Journal "Path" hints are still open, and prompts 10 and 11 of the Ideas pack haven't started. The owner hasn't picked from the top-5 lists in `docs/MagicIdeas.md` and `docs/EngagementIdeas.md` yet. Items 7 and 8 (EarlyGamePlan §9–10) are built, not yet run; expected boot line `specs 357/357`, `first_damage` and `first_hour` in the log, 81 sounds. If FirstHour.spec fails, the sim's player model may be at fault as well as the rules: read `BEHAVIOUR` first. To check: one mentor lesson pays `650 x tier gap` XP, about 835 reaches Novice. Item 5 (six creatures in seeded dens around every town) is verified in play. Item 6 (novelty XP, first-reaction toasts, Guided "Try something") is built (EarlyGamePlan §8), not yet run. Item 3 (first ranged spell) is built: the owner said **"I don't want to restrict anything for the player"**, so Projectile opens at Sensing and the thrown Strike (Ember Dart...) is a third innate spell (EarlyGamePlan §5). Item 4 (six beginner quests + a town mentor) is built (EarlyGamePlan §6, Quests.md).

**Ideas prompt pack (`docs/Prompts-Ideas.md`, 11 prompts) progress:**
| # | Prompt | State |
|---|---|---|
| 1 | Improvements audit | done: `docs/Improvements.md` (quick wins also built: git, quiet boot, crime fix, lighting, FxRecipes) |
| 2 | Magic-system fun ideas (design only) | done: `docs/MagicIdeas.md` (28 ideas, top 5; none approved or built) |
| 3 | Engagement ideas (design only) | done: `docs/EngagementIdeas.md` (23 ideas, top 5; none approved or built) |
| 4 | Controls panel (H) | built |
| 5 | Composer explanations | built |
| 6 | Run toggle, Alt toggle, dash (R) | built; the first test failed (client used `Net.fire`), fixed, not yet re-run |
| 7 | Sounds + music | built (80 licensed picks, not auditioned) |
| 8 | NPC looks | built (catalog hair/hats/beards, part-built clothing, signature accents) |
| 9 | Early game | step 1 plan done; items 1 (innate spells), 2 (practice yards), 3 (ranged at Sensing), 4 (beginner quests + mentor), 5 (first creatures), 6 (experimentation pays), 7 (first-time flourishes) and 8 (first-hour measurement) built; **all 8 done, tune from `firsthoursim`** |
| 10 | Gravity powers | built 2026-11-06, not yet run (`docs/Gravity.md`) |
| 11 | Time powers | built 2026-11-06, not yet run (`docs/Time.md`) |

**Built 2026-11-05 and NOT yet run in Studio** (ask for an Output after the next Play; expected boot line `specs 326/328 · magic examples 33/33`, the 2 failures being the known Settlement ones):
- Controls screen + `Tests/Controls.spec`; gamepad L1/L2 and furniture-placement input clashes fixed.
- Finding your house: ⌂ marker, Journal "Show the way", `house goto`.
- Composer explanations (`Shared/UI/SpellHelp`, About card, walkthrough + glossary).
- Movement: the run/dash remote fix (`Net.send`), dash flavours, lock-on toggle. The Deepwatch floor fix (`clearInterior` from the slab bottom).
- **Boot confirmed 2026-11-05: `specs 350/350`, magic examples 33/33.** There are no known spec failures any more: treat any failure as new. In that run no sound failed to load (whether they sound right is unreported), and `mentor_lesson` was offered, started and completed. `rbxassetid://203785492` still fails but isn't in `src`.
- **Foundations (not yet run):** the 1 s re-check delay didn't help: 16 of the same settlement_2 buildings failed again. `clearInterior` now clears one voxel below the slab. If `foundation_failed` persists, look inside one with `buildingcheck`. Also watch: `character_rescued reason="spawned in water"` at the spawn town appeared in one run and not the next, unexplained; `quest_build_failed template=commission_delivery` (another quest was offered instead), cause not looked at.
- Experimentation pays (`Progression/Experiment`, `DiscoveryLog`, `SuggestSpell`, `MagicReaction`; `reaction_discovered` in the log): boots cleanly, but novelty, reactions and "Try something new" aren't confirmed in play. First creatures are verified in play; the look of their bodies hasn't been reported yet.
- Sound system (`Client/Audio/Audio`, `AudioController`, volumes, `sound <role>`); watch for an `[Audio] N of M sounds failed to load` line.
- NPC looks, clothing and accents (`npclook`); watch for `[NpcLooks] N accessories failed to load`.
- Innate spells (`cantrips_granted` in the log; slots 1–3: strike, utility, thrown strike), the "Your magic answers" card, practice yards, Projectile at Sensing. Beginner quests: watch for `quest_offered` with `first_practice` / `mentor_lesson` / `show_me_magic` / `lost_pet` / `light_the_lamps` / `spar_master` in the first minutes. Expected boot line now `specs 331/333` (one new Cantrips test, four new Quest.spec tests).

**Verified in play 2026-11-05:** the VFX work (Kenney textures, lightning, slashes, muzzle flashes, `fxpreview`), the domain-tinted colours, the FoundationBuilder crash fix (44 buildings built), the relaxed foundation check (0 failures in the spawn town), the quick wins (one-line boot summary, no red `lock_lost`).

**Owner actions still pending:** audition the audio picks in `docs/Audio.md`. Block (97111944327100) still reports length 0, but the public asset API shows all 3 uploads owned by the owner's account, the same as clips that load, so ownership probably isn't the cause. Likely a single keyframe (Length 0); asked the owner to check it in the Animation Editor. The game holds BlockStart's last pose meanwhile.

**Open questions from this session (unanswered; defaults in use):**
- Running stamina drain: free for now (`MovementTuning.run.staminaPerSecond = 0`). Dash numbers (2 charges, 16 studs, 2.5 s refill) not yet judged.
- Combat music holds 12 s after the last hit; quest-complete fanfare has no client signal yet.
- Wind/blizzard ambience: no licensed pick; search third-party uploads or leave silent?
- Paid Roblox-made catalog items on NPCs: used (they cost nothing); owner hasn't objected.
- Faces for NPCs (classic faces)? Culture clothing palettes OK (`NPC/Data/NpcLooks` `palette`)?
- Cantrip utility by temperament instead of a seeded "Sense <property>"?
- Practice yard on markers / in the Journal? A first-hit reward on a dummy (plan item 7)?
- Lighting haze (Atmosphere density 0.28) OK? Should fire that spreads after a spell count as a crime?
- Should more forms open at Sensing (Burst, Beam)? It's a data change in `Data/MasteryTiers`. Thrown Strike in slot 2 instead of 3?
- Beginner quests: permanent map pins for the practice yard and the mentor? Should finishing "Lamps at Dusk" actually light the lamps (today it's flavour)? Beginner rewards: add coins or a starter item (only the lost pet pays 10)?
- Creatures: should some wander into town so guards fight them and farmers pay for it (needs NPCCombat to target non-players)? Should fighting one drop loot on the ground instead of straight to the bag? Sprites and rats attack on sight: too rough for minute one near the spawn town? Should the spawn town's dens be guaranteed gentle types?
- Parked VFX questions are listed under "Open design questions" below.

## Decisions already made (don't re-ask)

- **Tournaments are dropped (2026-11-07):** the owner doesn't want them. Don't pitch them again.
- **Magic Marks fade over time (2026-11-07):** a mark you stop feeding fades and eventually goes. Marks are never permanent (`Data/Marks` `decayPerDay`).

- **One world, many servers.** Every server runs the same seed and the same world. Live state is per server; a thin global layer holds the World store, MessagingService announcements and saved terrain edits.
- **No paid features at all.** Never design paid rerolls of innate profiles.
- **Players name their spells.** The raw name is stored server-side only; clients only ever see the TextService-filtered version, via `SpellbookService:displayName()`.
- **Admin:** UserId **17476255** (`src/server/Config/AdminConfig.luau`), also the owner (only the owner may `reseed` / `regenworld`, and that is allowed on live servers). In Studio, negative-id test players are admins too. The panel is Studio-only until `EnableInLiveServers = true`.
- **Admin panel decisions:** it replaced the old F2 console; commands for systems that don't exist yet (now only weather and building prefabs) are listed greyed out, not faked.
- **XP curve stays at `xpScale = 2.3`** for now. The journey sim showed it's slower than the doc's "Expert in ~26 h"; the owner chose to leave it.
- **R6 rigs everywhere (2026-11-03).** The owner's combat animations are R6, so players (Game Settings › Avatar › Avatar Type = R6), NPC rigs and test dummies are R6. `CombatAnimations.rigType` is the one switch; code that touches body parts handles both rigs.
- **PvP is on for all players (2026-11-03):** `pvp_enabled` defaults to true (`Config/Flags.luau`). The per-hit cap (`pvpMaxShare`, 60% of MaxHealth) still applies. **No safe zones anywhere (2026-11-06):** not the spawn plaza, not inside Rifts. Don't re-ask.
- **Resetting everyone's progress (built 2026-11-06, not yet run):** `resetallprogress RESET`, owner only, from a live server after publishing and restarting servers. Nothing is deleted, and `restoreprogress <n> RESTORE` undoes it (docs/Backend.md, "Resetting progress"). Anything new stored per player must use `WorldService:progressKey()` and be added to `DataService.eraseUser`, and the same goes for markets, trade and leaderboards when they're built.
- **Life is Uncommon.** Mythic domains are Time, Gravity and Reality.
- **Time and Gravity are meant to be overpowered (2026-11-06):** "don't hold back on the abilities." Limits only where they keep the server honest or stop someone being frozen forever.
- **"Brush with Death" has a hard trigger:** health ≤ 5%, an enemy ≥ 1.5× stronger, and 10 s survived without healing. It's enforced through `requires`/`facts`.
- **Asset sources (2026-11-05):** textures are the Kenney Particle Pack (CC0), uploaded by the owner (`Fx/KenneyTextures`, `DomainFx.UPLOADED` maps roles to names). Audio comes only from the licensed Creator Store libraries **ProSoundEffects** (SFX) and **APMOfficial** (music, stingers) (`Shared/Audio/AudioLibrary`, `docs/Audio.md`). NPC accessories are **Roblox-made catalog items** only (InsertService can load them at any price; they stay on the catalog). Third-party uploads are avoided: they can be deleted.
- **Nothing is gated behind tasks for the player (2026-11-05):** "I don't want to restrict anything for the player." Projectile opens at Sensing; tiers still gate the other verbs/forms and the power ceiling. If more should open early, it's a data change in `Data/MasteryTiers`.
- **Dash key is R** (gamepad L3); Left Ctrl toggles running; lock-on toggles by default.
- **Settlement law judges harm by what a spell did**: harmful casts that hurt nobody (practice dummies don't count) and changed no land aren't crimes (World.md).
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
| **Multiplayer and social** (stage 1, written 2026-11-05, owner says tested, no log seen; shared events written 2026-11-06, not yet run): PvP rules, parties, shared quest progress, one combo, emotes, duels, block and privacy settings, scheduled server-wide events | `docs/Social.md` | `Magic/Cast/PvpRules`, `src/server/Social/`, `Services/PartyService`, `ComboService`, `EmoteService`, `DuelService`, `SocialSafetyService`, `SharedEventService`, shared `Social/Data/*`, client `PartyController`, `EmoteController`, `DuelController`, `SharedEventController`, `Fx/ComboFx`, `EmoteFx`, `EmotePoses`, `EventFx` |
| **Titans** (not yet run): a huge boss crosses the island every 2 hours on a seeded road, with weak points that make it stumble; the first server to kill it writes a crater, bones and a named map pin that every server shows, 20 kept at most | `docs/Titans.md` | `Services/TitanService`, `src/server/Titans/`, shared `Titans/Data/Titans`, client `TitanController` |
| **Rifts** (stages 1 and 2 confirmed, tuning pass not yet run): seeded dungeons in a sealed pocket off the island; 7 rooms, 8 twists, 3 bosses; every room accepts all 12 domains; clever answers and magic reactions solve rooms; first-time answers pay once | `docs/Rifts.md` | `Services/RiftService`, `src/server/Rifts/`, shared `Rifts/Data/RiftData`, client `RiftController` |
| **Wild Zones** (stage 1 confirmed, stage 2 not yet run): 6 permanent seeded regions with broken rules (gravity, slow time, burning water, a tide, no magic, constant healing), each with a heart that pays once and harvests daily; magic effects are permanent `WorldStateService` modifiers; generated terrain per zone; rumours mark them on the map | `docs/WildZones.md` | `Services/WildZoneService`, `World/WildZoneRules`, `World/WildZoneBuilder`, shared `World/WildZones`, client `WildZoneController` |
| **Town repair** (not yet run): unsaved fires leave grass bare and it regrows; towns repair charred buildings, near a player by someone walking over and working on it; not saved | `docs/TownRepair.md` | `Services/TownRepairService`, `src/server/Towns/` |
| **Feral Spells** (not yet run): strong spells that lose control may tear loose and roam, casting what they were, running out of energy, drawn to ley lines and to magic; NPC mages have accidents too; no interface of any kind; a Journal clue to a recipe you didn't know | `docs/FeralSpells.md` | `Services/FeralService`, `src/server/Ferals/` |
| **Readable activities** (stage 1, not yet run): one replicated activity record per NPC, stations with use points, client-drawn props, poses, set pieces and station looks, the Observe label, a Readability Report | `docs/Activities.md` | `Services/ActivityService`, `src/server/Life/`, shared `Life/`, client `ActivityController`, `ObserveController`, `Fx/ActivityPoser`, `ActivityProps`, `SetPieces`, `StationFx` |
| **Magic Marks** (stage 1, not yet run): the domain you use most marks your body in 3 stages; NPC mages are marked from their tier; a small own-domain resistance; nervous NPCs warier of strange marks; NPC remarks and whispers; Journal lines, no UI | `docs/MagicMarks.md` | `Services/MarkService`, shared `Magic/MarkRules`, `Magic/Data/Marks`, `NPC/Data/MarkLines`, client `MarkController`, `Fx/MarkFx` |
| **Familiars** (stage 1, not yet run): a creature seeded from your innate profile, bonded after your first spells; no Humanoid, so spells can't touch it and walls don't stop it; 5 stages, 2 abilities, 4 orders, a filtered name | `docs/Familiars.md` | `Services/FamiliarService`, `src/server/Familiars/`, shared `Familiars/`, client `FamiliarController`, `Fx/FamiliarFx` |
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
- **Studio only:** `testmage`, `testspells`. **Owner only:** `reseed`, `regenworld` (typed `RESEED`), `resetallprogress` (typed `RESET`), `restoreprogress` (typed `RESTORE`).
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
- Week-1 tasks are in its §7. The first one (`git init` + a baseline commit) is done: branch `baseline`, 2026-11-05.
- The list below is the older backlog; where they conflict, follow the roadmap's order.
- **Owner's ideas prompt pack (2026-11-05): `docs/Prompts-Ideas.md`** (11 prompts). Progress, what's built and the next step are in **"Where we left off"** at the top of this file. The early game continues in `docs/EarlyGamePlan.md` (8 items; 1–4 built).
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
- **Admin commands:** one `admin:Register({ name, category, description, args = {typed schema}, handler })` per command (a new category must be added to `CATEGORY_ORDER` in AdminService, or the service fails at boot); services register their own, cross-system tools live in `Server/Admin/Commands/*`. Never parse raw strings in a handler: add an argument type (`RegisterType`) instead.
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
