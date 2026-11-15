# Living History (2026-11-14)

One prompt, generated at the owner's request: bring the engagement of Dwarf Fortress, Caves of Qud and Kenshi into projectMagic, keeping what makes those games fun and cutting what is bloat. The plan was shown first and the owner accepted all of Claude's defaults (2026-11-14). Give it back to Claude whole ("Run Living History") or resume it ("continue living history"). It replaces queue items #25, #46, #47, #52, #57 and #59, and feeds #5 and #55.

---

# Living History

projectMagic already has most of the parts these games are built from: NPC memory and gossip, rumours (#39), witnesses who notice (#38), ferals, Titans with permanent named craters, Wildborn lairs, omens, dreams, the Journal, settlement law, infamy and bounties, Magic Marks, Wild Zones, town repair. What's missing is the tissue between them. Things happen, but almost nothing **remembers** them at world scale, **passes them on**, or **changes** because of them. This pass builds that tissue. It is mostly wiring, not new content.

## What we are taking, and what we are not

All three games get their stories from systems colliding, not from authored content. The player sees the result, reacts, and tells someone. That loop is the whole target.

**Take:** history that shows up in the world (DF engravings, named artifacts); one person's obsession producing something legendary (DF strange moods); secrets as currency (Qud's water ritual); a world that acts without you and stays changed (Kenshi factions, fallen towns); losing as the start of a new story instead of an ending (Kenshi).

**Never build (the cut list; if a stage drifts toward one of these, stop and tell me):**
- A Legends, encyclopedia or history-browser screen. History reaches players only through the world.
- Hunger, thirst, labor or stockpile micromanagement for players.
- Per-limb injuries, dismemberment, gore.
- Squad or follower management beyond what the queue already plans (apprentices).
- New loot tiers, item-count inflation, junk loot.
- Simulated history the player can never find or act on.
- Training by hurting yourself, or any loop that pays for being beaten.
- Permadeath of players, or losing a save.
- Slavery or anything that reads as it (Roblox rules). Capture means "held in a lair", never owned.
- Anything that lets one player wreck shared things for everyone else.

**The filter, applied to every feature before it's built:** can the player *see* it, can they *act* on it, and does it make a story they'd *tell a friend*? Any "no" cuts it. The project's design rule holds absolutely: the world, not a card or announcement, tells the player.

## Owner's decisions (don't re-ask)

- Named NPCs **can die permanently, rarely**: only in big events (Titans, Wildborn raids, a town falling, a feral rampage, a lethal duel they chose), never from an ordinary fight with a player. The Chronicle remembers them; their household and friends grieve and remember who did it.
- A fallen town stays fallen **per server** until retaken. Only Chronicle legends are shared across servers, capped like Titan falls.
- Losing is mild: robbers take **coins only, never gear**; capture by Wildborn happens **only deep in the wilds** (260+ studs from towns, like haunts).
- This replaces queue items #25, #46, #47, #52, #57, #59 in place, as a new group after group 3.

## Constraints

Project bible format for every stage. Server-authoritative, clients send intents. Data-driven content. Deterministic: anything generated derives from `Seed.random(worldSeed, entityId, system)`. Budget 30–60 players and 100–300 NPCs: nothing scans every tick; slow clocks run through `Scheduler`; every record has a hard cap. New per-player saved data uses `WorldService:progressKey()` and is added to `DataService.eraseUser`. Say the plan before coding. One commit per stage. A playtest from me between stages.

## Stage 0: audit (no code)

Map each pillar below onto what exists: which services already record events (Titans' falls, `JournalService`, `MemoryService`, gossip, `RumorService`, `NoticeService`, `FeralService` blame, faction standing, `ReputationService`, `TownRepairService`, `MarkService`), what they keep, how long, and where it already surfaces. List every overlap with the queue and the built-but-unrun features. Write `docs/LivingHistory.md` with the audit, the design for stages 1–5, the cut list above, and open questions. Stop and show me before stage 1.

## Stage 1: The Chronicle

One server-side record of notable deeds by players, NPCs, ferals, Titans and Wildborn. Each entry: who, what, where, when, a significance score, and the things involved. Significance decides everything downstream: low deeds stay in NPC memory as today; high ones enter the Chronicle; the highest go to a global store shared by all servers (capped, oldest fades, like Titans; erasure covered by `eraseUser`).

It has **no screen**. It reaches players only through what already exists: rumours and greetings, NPC opinions, the player's own Journal (first person, as now), and one new outlet, tavern songs and talk (an NPC at a tavern occasionally tells or sings of a Chronicle deed). Anti-farming: the same deed against the same target, or at the same place, scores less each time.

## Stage 2: Things with a past

Places, items and creatures that took part in a high-significance deed get a seeded name and a one-line history: a ford renamed after a Titan fell there (shown on the map as a place name, not a pin), the staff that killed a Wildborn boss. NPCs who know the deed recognise the thing ("That's the staff that broke the Ashwalker"). Towns gain carvings or a small monument for their biggest deed, built by their own builders like town repair. Then one narrow strange mood: rarely, an NPC mage becomes obsessed, takes over a workshop for a few in-game days (readable as an activity), and makes a named item tied to their magic. It enters the Chronicle; the item can be traded for, earned, or stolen (a crime).

## Stage 3: Losing leads somewhere

Being knocked out by a non-player no longer always means the plaza. By where it happened: wake where you fell after a while; a passer-by carries you to a town healer (they remember it, and you owe them); bandits on roads take some coins; deep in the wilds a Wildborn drags you to its lair and you must get out (with your own magic; the lair holds you, it doesn't torment you). Lasting injuries appear as scars through Magic Marks and fade like marks. A player never gets the same bad outcome twice in a row, and never from another player's knockout (anti-grief). Never permadeath, never gear lost.

## Stage 4: The world acts without you

A slow clock (in-game days) gives each faction and town an agenda from its seeded culture, needs and grudges: raids, feuds, alliances, trade, a town overrun by Wildborn. Agendas use NPCs that already exist and their real movement; outcomes change the world and stay changed per server: a fallen town has damaged buildings, fled residents (who now live and talk elsewhere), and Wildborn inside, until players or guards retake it, after which it rebuilds. Rare permanent NPC deaths happen here. Players learn of it the way NPCs do: rumours, omens, refugees on the road, smoke on the horizon. When a player rejoins, the NPCs who know them mention what changed (#47). This absorbs #52 towns that change, #57 the world's mood, #46 clear it or leave it and #59 living world stage 2.

## Stage 5: Secrets as currency

Knowledge becomes something you trade: lair locations, a latent's trigger hint, a recipe, a town's secret, a mythic breadcrumb. NPCs share secrets only with people they trust (relationship and faction standing), and trade them for secrets you hold or for favours. Telling a secret to the wrong person has consequences (the faction it belongs to remembers). Built on #39 rumours; feeds #5 town mysteries and #55 secret factions without building them.

## Every stage ends with

A feature flag, admin commands to force and inspect it, log lines, specs, an expected boot line, and the test script. Then a review: list anything that still feels like a game system laid over the world, check each feature against the filter and the cut list, and flag what failed.
