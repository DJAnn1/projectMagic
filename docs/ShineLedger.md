# The Shine Ledger

The Shine Pass's memory (commit `4f4e45a` has the brief). Everything broken, ugly or half-done,
ranked by **how often a player feels it in their first two hours**, not by how interesting it is
to fix. Each item says how it was verified: *in code* means the cause is confirmed present in the
source; *playtest* means only a Studio run can settle it. When the owner says "continue the shine
pass", start at the top unfixed item.

Status key: ☐ open · ◐ fixed in code, not yet run · ☑ confirmed fixed in play · ✎ needs the owner's decision.

## Rank 1 — NPCs look fake (felt every minute in any town)

The single largest source of "the world is fake". The pinned pathfinding problem is open for this
pass. Verified in code 2026-11-10: all causes below are still present (NPCService, BuildingGenerator,
Interact/Doors).

- ◐ **Door link endpoints float on sloped lots.** `BuildingGenerator` places each door's
  PathfindingLink ends at fixed local heights (outside end at local Y=1), but a lot with `drop`
  has outside ground lower than that — the endpoint hangs in the air and the link does nothing,
  so that building stays sealed. Fixed: link endpoints are raycast-snapped to the real surface
  2 s after the building is parented (terrain can arrive late — same timing as the foundation
  re-check). Playtest: `npcmove` `doors` should climb; `npc_went_indoors how=walked` should rise
  against `how=door`.
- ◐ **The door fallback walks through locks.** `Doors.open` never checks `Locked`, and the
  enter-by-door fallback admitted any NPC into any building (`npc_building_path_failed
  reason="path crosses a locked door"`). Fixed: residents, workers and shelter guests may enter
  their own lot (they'd have the key); anyone may enter a public or unlocked building; a locked
  private house that isn't theirs now stays shut and they make do outdoors.
- ◐ **Sleepers walk back out of their own homes.** `route()` dropped a RecentlyFailed bed target
  even when the NPC was already inside the right building, sending them out through the door to
  an outdoor district spot (`npc_left_by_door action=sleep`, #7 from their own home L18). Fixed:
  inside the lot that holds the target, they stay put.
- ☐ **Rooms sealed to the pathfinder** (`nav_no_path` `goalOk=false` inside, `startOk=false` for
  NPCs already in). Suspects, still unmeasured: furniture crowding `NPCHome` anchors (2.6 studs
  from a bed), AgentRadius 1.25–1.5 in small rooms. Next step needs a playtest: `overlay npcnav`
  on one empty house, then move anchors or snap them with a raycast at build time.
- ☐ **~25–30 NPCs standing with no path, some outdoors** (a 3-stud plaza walk failed). Cause
  unknown; read `nav_no_path` `startOk`/`goalOk` in the next night run.
- ☐ **People teleport-appearing inside buildings** instead of walking in. By design until the
  sealed-rooms cause falls; the owner accepted it "for now" (question still open).
- ☐ **Sleepers left by doors of houses that aren't theirs** (#5 from L17, #12 from L20). The
  stay-inside fix may cover it if the fallback had put them in the right lot; watch
  `npc_left_by_door action=sleep` in the next run.
- ✎ **Permanent name-and-job nameplates** read as a game overlay. Proposal (in-world): you learn a
  name by meeting someone — the plate shows only after your first Talk (saved), until then a
  plain "farmer" descriptor on look-at via the existing Observe label. Needs the owner's yes.
- ☐ **Activities switch by teleport** (poses/props snap). Phase 3 work; noted here so it isn't lost.

## Rank 2 — The first minute (felt once, by everyone, first)

- ◐ **Spawned at the world origin, then rescued** (3 of the last 4 runs; `character_rescued`).
  Cause verified in code: `WorldStateService.init` turns `CharacterAutoLoads` off, but in Studio
  the character can load at the origin *before* init runs, and nothing cleaned it up. Fixed: any
  character already loaded when init runs is removed; `start()` reloads everyone at the real
  spawn. Playtest: no `character_rescued` at boot.
- ☐ **`foundation_failed` on House_12 / HouseLarge_07** (settlement_2, recurring; sometimes
  `foundation_fixed` later, so at least partly timing). Playtest with `buildingcheck` if it shows.

## Rank 3 — Casting and moving (felt constantly)

- ◐ **Riding indoors reads the roof as ground.** Verified in code: `TravelClient.groundAt` starts
  its down-ray 25 studs up (so low walls count as ground), which is above a storey's roof. Fixed:
  an up-ray first finds any ceiling and the ground check starts just below it, so indoors the ride
  hugs the floor. Playtest: ride into a tavern.
- ☐ **Numbers shipped untested:** dash (2 charges, 16 studs, 2.5 s refill), stamina, charge
  timings, `focusLimit`. Phase 2; needs play feel, not code.
- ☐ **Timestop doesn't freeze tsunamis/quakes already running.** Real (docs/Time.md known limit).
  Medium work in WaveSimulator/aftershocks; rare in the first two hours — Phase 2/3.
- ☐ **Crime judgment misses later hits** from grips, loops, finishers, Meteor Landing, and all of
  Time's spells (only the cast moment is judged). Phase 1 follow-up batch; medium work in
  `judgeCast`/Damage attribution.
- ☐ **Cast poses & Read the cast**: built, not yet run (`specs 1035/1035` expected). Playtest first.

## Rank 4 — UI jank (felt whenever a screen opens)

- ◐ **"Gear" filter chip truncated to "Gea".** Verified in code: the chips use `AutomaticSize.X`
  with `TextWrapped = true`, so the text wraps at measure time and the second line clips. Fixed:
  chips don't wrap.
- ◐ **Inventory grid's ninth column cut off.** Verified in code: the grid's scroll frame pads 2 px
  while the scrollbar overlays 6 px of the canvas, so the last column sits under the bar. Fixed:
  the right padding reserves the scrollbar's width and the grid wraps a column earlier.
- ☐ **Hover card above its own text** and **toasts overlapping event cards**: both fixed earlier
  (Sibling ZIndex / SideCards column), neither confirmed in play. Playtest: hover an inventory
  item; trigger a toast during an event card.

## Rank 5 — Dead content (felt the moment a player trusts a suggestion)

- ◐ **Guided cards that do nothing.** `pebble_nudge` and `shape_stone` routed to `manifest`
  (glow, cost, no effect). Fixed with a real route: `stonetouch` (Terrain `op=stone`, touch form
  raises a hand-sized stone where you touch; earth-branch `contour` + `generate` only, so
  Amplify-Hardness-as-Touch stays honestly dead). `forge_hand` (alloycraft purity transmute
  touch) had no honest route — refining metal by hand already exists as the ✦ Mend action — so
  the card is removed rather than left lying.
- ◐ **"Try something" could suggest dead spells.** Verified in code: `Experiment.suggest`
  validated grammar but never the route. Fixed: suggestions must pass `SpellOutcome.of(...).useful`.
- ◐ **Expert tier text promised summons** ("Give your magic a body") while the summon form casts
  an area blast. Text now says what really happens. True summons stay an open design idea.
- ☐ **`linked` / `silent` modifiers have no code.** The Composer already warns in both cases
  (verified: `RouteSummaries.deadModifiers`), so they're no longer silent traps. Making them real
  is Phase 5 work ("make the modifiers that exist all do something visible") — silent should touch
  witnesses/crime tracing, linked needs a damage-echo design.

## Rank 6 — Visual jank

- ◐ **NPC Neon accents blown to white by Bloom** (belts, sashes, wrist bands — the "cyan line").
  Familiars already dim Neon toward black by 0.42 (`Familiars.glowDim`); NPC garments now do the
  same. Playtest: a strong mage's belt should read as its signature colour.
- ☐ **Z-fights, floaters, clippers**: to be collected during the Phase 1 playtest — walk Glenhold
  at day and night and note anything that flickers, floats or intersects.
- ☐ **Ground-sitting poses** (sink/float), **bow aim orientation**, **lantern pole** — stage-2
  activity visuals never confirmed. Same playtest.

## Playtest requests outstanding (in one run, if possible)

1. Clear the Output first; one `rojo serve` only. Expected boot line: `specs 1037/1037 · magic examples 34/34`
   (2 new specs: dead-content routes in EarlyGame.spec, useful-only suggestions in Experiment.spec; 1 new magic example: Pebble Rise).
2. First minute: watch for `character_rescued` (should be gone).
3. Night in Glenhold (`time 22`, wait ~3 min): `actphases Glenhold` twice; `npcmove settlement_1#<n>`;
   watch `npc_went_indoors how=walked` vs `how=door`, `npc_left_by_door action=sleep`, locked-door
   path failures.
4. Inventory (, key): the Gear chip label, the grid's right edge, the hover card.
5. Ride (Y) into a building; cast while charging (poses); `markset energy 3` for marks if time allows.
6. A strong mage NPC's belt colour under Bloom.
