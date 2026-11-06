# NPC movement, animation and conversation

The owner's three reports: NPCs walk into walls and get stuck, they randomly teleport, and they keep playing their walk animation while talking. Built in stages.

| Stage | What | State |
|---|---|---|
| **1** | Audit, `NavigationService` core, `NPCAnimator`, the dialogue flow, overlay and movement report | built 2026-11-05, not yet run |
| 2 | LOD transitions, network ownership and physics, anchor validation, soak test | waiting for the owner to confirm stage 1 |

Line numbers below are from the code as it stood before this work (commit `7e58cb2`, plus the sit fix).

---

## 1. Audit

### How NPCs moved

Three modes by distance, none of them sharing logic:

| Tier | Distance | Movement |
|---|---|---|
| T0 | under 110 studs | `Humanoid:MoveTo` to `PathfindingService` waypoints, re-issued at 10 Hz (`NPCLOD.stepT0`) |
| T1 | 110–350 | Anchored rig `PivotTo`'d 30 studs every 2 s, straight at the goal (`NPCLOD.stepT1`) |
| T2 | beyond | No body. `npc.position` jumps to the destination once a game hour (`NPCService.thinkFar:591`) |

**Agent parameters** (`NPCLOD:466`): `AgentRadius 1.5, AgentHeight 5, AgentCanJump true, WaypointSpacing 6`. Hard-coded, one size for everyone, though children are scaled 0.8 and adults 0.93–1.08. No `AgentCanClimb`, no `Costs`.

### Problem 1: walls and getting stuck, ranked

| # | Root cause | Where |
|---|---|---|
| 1 | **Every building interior was unreachable.** Doors are closed, collidable parts with no `PathfindingModifier` or `PathfindingLink` anywhere in the project, so the pathfinder sees a sealed box. Homes, workplaces and seats are all inside. | `BuildingGenerator:292` (solid leaf); no modifier anywhere |
| 2 | **A failed path became "walk straight at it".** Failure is cached as a one-point route to the goal for 30 s, and the NPC walks that into the wall. Combined with #1, this is what you saw. | `NPCLOD:480` |
| 3 | **While a path was pending, NPCs also walked straight.** At 4 paths a second, shared with up to 40 rigs, that's often. | `NPCLOD:530` |
| 4 | **Routes were shared from a start up to 8 studs away.** The cache key is an 8-stud cell, so an NPC can inherit a route that begins on the other side of a wall. | `NPCLOD:436-437`, `:445` |
| 5 | **Nothing ever invalidated a route.** No `Path.Blocked`, no reaction to doors, spell walls or terrain edits, for 300 s. | `NPCLOD:49`, `:466-480` |
| 6 | **Jump waypoints were thrown away.** Only `wp.Position` was kept. | `NPCLOD:473` |
| 7 | **The stuck check was broken** (see Problem 2, #1). | `NPCLOD:546-553` |
| 8 | **Daily life made this worse** (my stage 1 work). `placeHook` sends more NPCs indoors, and roaming asks for more paths. | `AmbientLifeService.placeFor`, `DailyLife` |

**MoveTo's 8-second timeout:** not an issue. `MoveTo` was re-issued constantly, so it never expired. `MoveToFinished` wasn't used.

**Anchors:** real attachments, about 3 above the floor. Some are placed on or near furniture (`NPCSeat` sits on the stool), and ground spots use the *generated* height, which can be studs off a levelled town (the log shows `ground=63` under a plaza at 65). Full validation is stage 2.

### Problem 2: teleporting, ranked

| # | Root cause | Where |
|---|---|---|
| 1 | **The stuck check fired on NPCs walking normally.** `flat` is the distance to the *current* waypoint. Progress only counts when it drops 0.5 below the best so far, but after the first waypoint that best is about 3, and the NPC moves on to the next waypoint at 3. So progress almost never registers, and every 6 s it `PivotTo`s to the waypoint, with no line-of-sight or view check. | `NPCLOD:533`, `:546-551` |
| 2 | **T1 is visible teleporting by design.** 30-stud hops every 2 s, through walls, at 110–350 studs, inside the 1024-stud streaming radius. The T0/T1 boundary is in plain view. | `NPCLOD:50`, `:557-571` |
| 3 | **Promotion places rigs with no checks.** `groundAt` is the generated height, ignoring floors, levelled ground and edits, then +3. A rig can start embedded, and physics throws it out. | `NPCLOD:399`, `NPCService:171` |
| 4 | **T2 NPCs arrive instantly,** so a T2 NPC promoted later appears at its destination rather than along its route. | `NPCService:591` |
| 5 | **Nothing checks the chunk is built** before unanchoring a rig. | `NPCLOD:409` |
| 6 | **No recovery** for an NPC below the terrain: `CharacterSafety` only watches players. | none |

| Question | Answer |
|---|---|
| Schedule changes teleporting NPCs? | Only T2, as above. T0 walks. |
| Network ownership | `SetNetworkOwner(nil)` at T0 (`NPCLOD:414`), and T1 is anchored. Accessories are welded to the same assembly. **Looks fine, low on the list.** Confirm with `npcmove`. |
| StreamingEnabled | Doesn't affect the server's view of geometry. What matters is this project's on-demand chunks, #5 above. |

### Problem 3: walking while talking, ranked

| # | Root cause | Where |
|---|---|---|
| 1 | **Talking skipped the only code that stops the walk track.** `stepT0` is what stops it, on arrival. While `talkingUntil` holds, the heartbeat calls `Move(0)` instead of `stepT0`, so the body stops and the walk cycle plays on. | `NPCService:1304-1305`, `NPCLOD:517-522` |
| 2 | **Walk animation followed intent, not movement.** The track was started and stopped by "has a destination". Anything else that stopped the body had the same bug: knockdowns, frozen NPCs, and my greetings (`AmbientLifeService:484`). | `NPCLOD:518-541` |
| 3 | **The brain kept deciding.** `think` didn't know about talking, so it could change the destination mid-sentence. | `NPCService:504` |
| 4 | **A talk was an 8-second timer,** with no end. A longer conversation meant they walked off, and nothing told the server the panel had closed. | `NPCService:1434` |
| 5 | **Turning was an instant snap.** | `NPCService:1437` |

The default `Animate` script isn't involved: it's a LocalScript, which doesn't run on server rigs. It's now removed from the rig anyway, and `npcmove` reports whether one is present.

---

## 2. What's built

| Piece | Job |
|---|---|
| `NPC/NavigationService` | All T0 movement. Agent measured from the rig. Direct walk if clear, else validated cached route, else queued path. **Waits rather than walking blind.** Ring search around a failed goal. `Path.Blocked` and terrain invalidation. Per-waypoint deadlines. Stuck: jump, re-path, nearby spot, then recovery only out of sight, else `Failed`. Below-terrain recovery. |
| `NPC/NPCAnimator` | Walk and idle from **real velocity**, with hysteresis, and playback speed follows real speed. Talk and Listen, with a procedural head-turn and bob when there's no clip. State in the attribute `NpcAnimState`. |
| `NPC/NPCConversation` | Talking as a state: pause, face, talk, listen, a beat, resume. Ends on farewell, Close, walking away, 45 s of silence, or a fight. Several players share one conversation. |
| `Interact/Doors` | A `PassThrough` `PathfindingModifier` on every door leaf. |

### Edits to existing systems

| File | Edit |
|---|---|
| `NPCBrain` | **None needed.** It only scores actions and never moves anything. Its execution lives in `NPCService.think` and `route`. |
| `DialogueEngine` | **None needed.** It only writes words. The flow lives in `NPCService.onTalk`, which now calls `NPCConversation`. |
| `NPCService` | `think` returns while paused. `route` won't send an NPC back to a place it just failed to reach: it tries the plain district spot, then stays put. `Failed` makes the brain re-decide. Heartbeat runs `Conversation`, `Navigation` and `NPCAnimator`. New `NpcTalkEnd` remote. |
| `NPCLOD` | Path code, `stepT0` and walk-track handling removed. An NPC in conversation stays T0. |
| `NPCCombat` | Every `MoveTo`, `Move`, `WalkSpeed` and facing write goes through Navigation. |
| `DailyLife`, `AmbientLifeService` | Go through Navigation. A greeting is now a real short pause, with a smooth turn. |
| `InteractionService` | The "open every door within 5 studs" loop is gone: NPCs open only the door on their route, and it respects locks. |

### Doors and locks

An NPC can open an unlocked door, or a locked one if the lot is its home or workplace. A route through a door locked to that NPC is rejected, and it tries elsewhere.

### Budgets

| Thing | Limit |
|---|---|
| Path computations | 6 a second server-wide, one at a time, queue capped at 80 |
| Route cache | 300 routes, 180 s |
| Direct walks | Two sphere sweeps per request, up to 24 studs. Saves most short trips a path |
| Step cost | T0 rigs only (40 at most), 10 Hz |
| Head animation | 5 Hz, only for NPCs in a conversation |

### After the first test (2026-11-05)

| Report | Cause | Fix |
|---|---|---|
| Janky walking | The walk cycle's speed was retimed at 10 Hz from a noisy velocity, and each change replicates. Raw waypoints every 4 studs kept correcting the heading. A jump waypoint set `Jump` on every step, so NPCs hopped. | Retime at most once a second, for a real change. Routes are smoothed once when computed. One jump per waypoint. |
| `point` and `hold` looped | Most likely `AnimationTrack.Looped` set on the server doesn't reach clients, so they use how the clip was published. | One-shots are stopped by hand at their end. `hold` now plays once and freezes, like `sit`. |
| `npc_recovered` to the same spot | `lastGoodPosition` updated while stuck, so "safe" meant "here". | Two remembered spots at least 8 studs apart. A spot closer than 4 studs isn't a recovery: it reports `Failed`. |

**Confirmed by the log:** the spawn-in-water rescue is a character that loads before the spawn exists, at the world origin (`fromX=2 fromY=4 fromZ=0`, ocean floor at -31). An NPC also fell through to `Y=-31` (`settlement_1#36`) and was recovered: unbuilt ground under a rig, for the LOD stage.

---

## 3. Not built yet

- **T1 hopping is still there,** so distant NPCs (110–350 studs) still jump. That's the LOD stage.
- **Spawn placement** in `LOD.sync` is unchanged.
- **Not in this stage's list:** local avoidance, deep water and lava beyond a path cost, look-around pauses, chunk-built checks, anchor validation, personality rules for interruptions (any fight ends a conversation now), and the soak test.
- **Animation runs on the server,** not clients. It's within budget at 40 rigs, and the state attribute leaves the door open.
- **`talk` and `listen` are empty slots** in `Data/Activities.Clips`. The fallback is the head movement.

## 4. Tools

| Command | What |
|---|---|
| `overlay npcnav` | For each full rig: route, goal, a label with name, action, state and animation, last stuck event. Refreshes every 2 s |
| `npcmove [npc]` | State, agent size, speed, network owner, whether an Animate script exists, recent history, and server totals |
| `npclod` | Tiers and path totals, as before |

Logs: `npc_recovered` at Info level, every time, with the reason and both positions. `nav_failed` at Debug.

## 5. If things still go wrong

| Symptom | Likely reason | How to check |
|---|---|---|
| NPCs stand still, yellow in the overlay, then red | The agent doesn't fit the doorway on the navmesh | `npcmove` shows `no path: NoPath`. Lower `agentClearance` |
| They stop at a door | The modifier isn't on the leaf | Look for `PathfindingModifier` under a `Door` part |
| Failed goals inside buildings | The anchor is inside furniture | `npcmove` history shows repeated `no path: FailFinishNotEmpty` |
| Walk still plays on the spot | Something still moves the body slowly, or a clip other than `walk` | `NpcAnimState` in the overlay |
| Teleports up close | The one remaining `PivotTo`, in recovery, is logged. Anything else is T1 at a distance | Search for `npc_recovered` |
