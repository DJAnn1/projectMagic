# Admin / Developer Panel

An in-game panel for testing every system without grinding: teleports, mastery and profile editing, spell cheats, world and time control, debug overlays, terrain tools and NPC tools.
It replaces the old F2 debug console. Every old command was moved into the panel's registry with typed arguments.

Status (2026-11-02): code complete; it passes `rojo build` and luau-lsp. **Not yet run in Studio.**

---

## 1. Security model

| Rule | How |
|---|---|
| Only listed accounts | `Config/AdminConfig.AdminUserIds`. In Studio, "Start Server + Players" test players (negative UserIds) also count (`StudioTestPlayers`). |
| Studio only unless enabled | `AdminConfig.EnableInLiveServers = false`: a live server creates no panel for anyone. |
| Non-admins get nothing | The client code lives in `ServerStorage/AdminClient`. It is cloned only into an admin's PlayerGui, next to an `AdminLink` folder holding two RemoteEvents (`Command`, `Reply`). PlayerGui replicates only to its owner, so other clients never see the code or the remotes. |
| Server-authoritative | The client sends `(requestId, name, { string tokens })`. The server checks, in order: sender = link owner → still an admin → payload shape (≤ 16 tokens, ≤ 200 bytes each) → rate limit (10 burst, 4/s) → owner-only / Studio-only → the command's argument schema (types, ranges, options). Only then does the handler run. |
| Audit | Every non-hidden call is logged to the Output (`admin_command`, with who, command, args, ok and ms) and pushed to every connected admin's Log tab. `auditlog` lists them. |
| Owner-only | `reseed` and `regenworld` require `AdminConfig.OwnerUserId` (17476255) **and** a typed `RESEED`. They work on live servers once the panel is enabled there. |

This is the one exception to "every remote is declared in `Remotes.luau`": a shared remote would be visible to every client.

## 2. The registry

```lua
admin:Register({
	name = "tp", aliases = { "teleport" }, category = "Teleport",
	description = "Teleport anywhere",
	args = {
		{ name = "where", type = "enum", options = { "settlement", "poi" } },
		{ name = "target", type = "text", optional = true, hint = "name, index or id" },
	},
	handler = function(ctx, a) return "went to " .. a.target end,  -- string or { text, data }
	ownerOnly = false, studioOnly = false, unavailable = nil, hidden = false,
})
```

Adding a command takes one `Register` call; the panel builds its card, inputs and autocomplete from the schema.

**Argument types:**

- **Built in:** `string`, `text` (the rest of the line), `number` / `integer` (`min`, `max`, `slider`), `boolean`, `enum` (`options`), `vector3` (`x,y,z`; the panel turns `@cursor` into the world point under the mouse).
- **Registered with `RegisterType(name, { parse, options })`:**
  - from `AdminService`: `player`, `flag`;
  - from `WorldStateService`: `settlement`, `poi`, `biome`;
  - from `EventDirector`: `activeevent`;
  - from `AdminToolsService`: `domain`, `branch`, `property`, `verb`, `form`, `modifier`, `temperament`, `growth`, `awakening`, `specialization`, `occupation`, `quirk`, `trait`, `need`, `npcaction`, `ambition`, `mythic`, `tier`, `masterytarget`, `npc` (`nearest`, a name, an id, or `@selected`), `bookmark` (per admin).

**Handler data** (`{ kind = ... }`) drives the panel:

| kind | Panel action |
|---|---|
| `catalog` | builds the panel |
| `options` | fills dropdowns |
| `movement` | fly / noclip |
| `overlay` | draws a layer |
| `npclist` | rows with tp / inspect buttons |
| `npcinspect` | opens the inspector |
| `select` | sets `@selected` |

## 3. Panel

- **Opening:** F2 (`AdminConfig.ToggleKey`), or the ADMIN button on touch devices.
- **Window:** drag by the title bar; resize from the corner (minimum 520 × 340).
- **Tabs:**
  - **Log:** replies, plus other admins' audit entries in grey.
  - **Inspector:** click an NPC. It refreshes every second and has action buttons plus need and trait sliders.
  - **History:** click an entry to put it back in the console.
  - **One tab per category.**
- **Search** filters every command by name, alias, description and category.
- **Cards:** dropdowns with a filter box for options and ids, sliders for ranged numbers, a toggle for booleans (tri-state when optional), and "◎ pick in world" / `@cursor` for positions.
- **Console** (the bottom bar):
  - Type `/tp village 3` (the leading `/` is optional).
  - Tab completes command names, then each argument's options.
  - Up/Down walk the history.
  - The hint line shows the usage with the current argument marked (▸), plus its range or hint.
  - Local commands (never sent to the server): `clear`, `cperf`, `book`, `learn`, `rename`, `forget`.
- **Input blocking:** while the panel is open, `InterfaceController.isInputBlocked()` is true (the `AdminPanelOpen` attribute on the local player).

## 4. Commands

| Category | Commands |
|---|---|
| **Teleport** | `tp <where> [target]`, where is one of: settlement, village, town, city, poi, shrine, school, awakening, ruin, mythic, biome, spawn, nexus, ley, coords, player, npc, random, up, down, cursor, bookmark. Also `tpsettlement`, `tppoi`, `tpbiome`, `tpnpc`, `tpplayer [bring]`, `tpcursor`, `bookmark save/go/delete/list` (saved per admin) |
| **Movement** | `fly [on/off] [speed]`, `noclip`, `walkspeed`, `jumppower`, `resetmovement` |
| **Magic** | `setmastery <all/domain/branch/Domain/Branch> <tier>`, `setxp`, `addxp`, `xp` (normal multipliers), `resetbranch`, `resetprogression RESET`, `unlock <branch/all/hybrids>`, `lock`, `unlockbranch` (normal rules), `breakthrough`, `commit`, `renounce`, `mythic <time/gravity/reality> on/off`, `unlockall [tier]`, `prog`, `grant`, `testmage` (Studio) |
| **Profile** | `profile [player] [0-3/truth]`, `affinity`, `capacity`, `regen`, `temperament add/remove/clear/list`, `growth`, `signature`, `reroll [seed]`, `forcerarity <tier> [mythic]`, `awaken <event> [domain]`, `revealall` |
| **Spells** | `cheat infinite/nocooldown/nobacklash/all/none`, `overpower`, `refill`, `resists [player]`, `gear <player> <slot> <item/none>`, `resist <player> <key> <value>`, `knockdown [player]`, `density [value] [radius] [minutes]`, `cast <recipe> [at] [modifiers]`, `spellstats <recipe>`, `dummy spawn/heal/clear`, `castinfo`, `route`, `effects`, `budget`, `clearfx`, `fxpreview <domain> [power] [property] [tier]` (a domain's whole visual set in front of you, only you see it; `charge` = lightning), `testspells` (Studio) |
| **World** | `seed`, `reseed` (owner), `regenworld` (owner), `regenchunk [radius]`, `regensettlements`, `time <hour>`, `daylength`, `timescale <0/1/5/20/100>`, `startevent <type> [here/global/point]`, `stopevent <id/all>`, `events`, `spawnpoi <type>`, `spawnsettlement`, `where`, `chunks`, `pois`, `stress`, `quake`, `tsunami` |
| **Terrain** | `terrain carve/raise/flood/smooth [radius] [at] [material]`, `deltas show/clear` |
| **Overlays** | `overlay <density/resonance/ley/stress/water/biomes/chunks/settlements/npclod/clear> [on/off] [radius]` |
| **NPCs** | `npc`, `npcinspect`, `npcday`, `npctalk`, `npcawaken`, `npcspawn [occupation] [seed] [at] [spec]`, `npcdelete`, `npckill`, `npcheal`, `npcfreeze`, `npctier <0/1/2/auto>`, `npcneed`, `npctrait`, `npcmastery`, `npcrel`, `npcbond teacher/apprentice/none`, `npcdo <action/home/flee/duel/teachme>`, `npcgossip`, `npcambition`, `npcresists`, `npcfight [npc] [player]`, `npccourage` |
| **Population** | `npcs`, `npclod`, `npclist [settlement] [occupation] [domain] [minMastery]`, `population <mult>`, `npcrebuild`, `simdays <days>` |
| **Quests & factions** | `quests`, `situations`, `questgen <template>`, `questcomplete <quest> [outcome]`, `questfail`, `questreset`, `queststage <quest> <stage>`, `questsituation <quest>`, `hunters [domain]`, `faction <faction> <value>`, `standings`, `infamy`, `bounty <settlement> <amount>`, `notoriety`, `npcfactions`, `reveal <secret faction>`, `rep <settlement> <value>` (docs/Quests.md) |
| **Social** | `parties`, `testparty`, `partyleave [player]`, `combos`, `combotest <combo> [power]`, `emote <id> [player]`, `duels`, `duelforce <a> <b> [rule]`, `duelend [player]` (docs/Social.md) |
| **Server** | `help [command]`, `perf`, `flags`, `flag`, `log`, `players`, `save`, `auditlog` |

### What a few of them actually do

- **`cast`** goes through the **real** CastService pipeline. For that one cast it ignores knowledge, tier, power caps, aim, range and line of sight. Payment, budgets and effects stay real; turn on `cheat infinite` / `nobacklash` for those.
- **`overpower`** applies those same exemptions to your *next normal* cast.
- **`density`** adds a multiplicative world modifier, sized so the density at your position becomes the value you set.
- **`timescale`, `time`, `simdays`** move only **this server's** NPC clock (`WorldClock`), which then drifts from other servers until a restart. At 100× NPCs change actions faster than they can walk.
- **Terrain tools** are **persistent** edits (`WorldStateService:edit`). `regenchunk` undoes them; it needs `terrain_generate_at_runtime`.
- **`spawnpoi` / `spawnsettlement`** are runtime only (lost on restart). POIService reads `placement.pois` live, so a spawned awakening or mythic site works at once.
- **`npcbond apprentice`** makes the NPC treat you as its mentor: its chapters study ×1.5 in every domain, and it names you in dialogue.
- **`reseed`:**
  - writes a new seed and epoch and bumps `World.generation`;
  - world-keyed stores use `WorldService:scopedKey`, so the new world starts clean;
  - every server closes via the `WorldReseeded` message;
  - player saves are untouched, so reputation and relationships keyed by settlement or NPC ids now point at the new world's places with the same ids.

## 5. Deferred (listed greyed out, with the reason)

`quests`, `questgen`, `questcomplete`, `questfail`, `questreset`, `queststage`, `questsituation` (no QuestDirector) · `faction`, `infamy`, `bounty`, `hunters` (no faction, crime or notoriety layer) · `weather` (no weather system) · `spawnbuilding` (no building prefabs).

Each becomes a real command by replacing its entry in `Admin/Commands/Deferred.luau` with a `Register` call.

## 6. Files

| Where | What |
|---|---|
| `Config/AdminConfig` | Who, where, the toggle key, rate limit, log size |
| `Services/AdminService` | Registry, types, parsing, private remotes, rate limit, audit, built-ins |
| `Services/AdminToolsService` | Shared argument types, bookmarks (`AdminData` store), loads `Admin/Commands/*` |
| `Admin/Util`, `Admin/Commands/{Teleport, Magic, Profile, Spells, World, Terrain, Overlays, Npc, Deferred}` | The tools |
| Service-owned commands | Their own services (`CastService`, `EventDirector`, `EffectRunner`, `ProgressionService`, `WorldStateService`, `TestMageService`) |
| `ServerStorage/AdminClient/{AdminPanel.client, Overlay, Movement}` | The panel, the overlay renderer, fly and noclip |
| Hooks into other systems | `CastService:cheats/castAs/preview`; `NPCService` public API; `WorldClock` scale, offset and day length; `WorldService:reseed/scopedKey`; `WorldStateService:resetChunk/chunkDeltas/clearChunkDeltas/addPOI/clearSettlementState/magicMap`; `EventDirector:startEvent(…, radius)`; `InnateProfile.revealLatent`; `NPCLOD` forced tier and freeze |

## 7. Risks

- **Live saves:** the magic, profile and progression tools write real save data. On a live server that's permanent, so use test accounts.
- **Server cost:** `forcerarity` generates up to 20,000 profiles, yielding every 400. The `regenchunk` radius is capped at 3, and overlay grids at 33 × 33. `npcrebuild` regenerates every NPC.
- **Anti-cheat:** fly and noclip run on the admin's client. When server-side movement checks arrive (Backend.md §8), they must exempt admins.
- **Admin trust:** an admin's own client could still send any registered command; the registry trusts admins by design. Keep `AdminUserIds` short.
