# Save files, main menu and reset

Owner (2026-11-13): "add a file select, main menu, and a reset character option". Choices: **3 files** per player; **each file is its own character with its own seeded innate magic**; **Reset wipes a file's progress but keeps its magic.** Built 2026-11-13, not yet run.

## How it works

- **Nothing loads on join.** The client runs `Client/Menu/MainMenu` before booting any controller (`init.client.luau`). The camera drifts round the spawn town under the title and a Play button. Play shows three file cards.
- **A file card** shows the best branch and its mastery, spells known, time played and when it was last played, with Continue and Reset. An empty card says "a new character" and offers Begin. Reset asks you to type RESET.
- **Choosing a file** (`FileChoose`) loads it (`PlayerDataService:loadFile`). The server sets the Player attribute `SaveFile`, the menu closes and the client boots. The character spawns only now (`WorldStateService.spawnIfReady`). `CharacterAutoLoads` stays false for good, so respawn after a death is done by hand after `Players.RespawnTime`.
- **Return to main menu:** at the bottom of the **Settings** screen (owner, 2026-11-13: "there should be an option to return to main menu in settings while playing") and on the **File** screen (tab bar, after Settings), both the same two-click block (`Client/UI/ReturnToMenu`). On live servers you rejoin the same place (`TeleportAsync`) and the menu runs again; in Studio the session ends (no teleports).
- **Join a friend** (owner, 2026-11-13): a second button on the title. It lists Roblox friends online in Project Magic (`GetFriendsOnline`, filtered to this place), each with Join. The server checks again before sending you (`FileJoinFriend`): you must be friends (`IsFriendsWith`), and they must really be on another server of this place (`GetPlayerPlaceInstanceAsync`). Then it teleports you to their server (`TeleportOptions.ServerInstanceId`), where the menu runs again and you pick a file. Menu only (no file open). Not in Studio (no teleports). The game's own privacy settings can't be read for a player on another server, so Roblox friendship is the permission; unfriending or blocking ends it. A full server fails the teleport, and the menu says so.
- **Reset** (`FileReset`), from the menu only with no file open: the file's save becomes a fresh template under a session lock. Its next load regenerates the same innate magic from the file's seed. If that file bought a house, the claim is released (`HousingService:releaseClaim`).

## Keys and seeds

| File | Save key | Profile seed |
|---|---|---|
| 1 | `player_<id>` (the original key) | `player:<id>` (the original seed) |
| 2 | `player_<id>_f2` | `player:<id>#f2` |
| 3 | `player_<id>_f3` | `player:<id>#f3` |

So **everyone's existing character is their File 1**, untouched. All keys go through `WorldService:progressKey`, so a progress reset covers every file. `DataService.eraseUser` erases all three files and the account record.

The **account record** (`Schemas.Account`, `account_<id>`) keeps a summary of each file, so the menu never opens or locks the files. It is written when a file loads and when its player leaves. A player from before save files has no account record yet: the menu reads their File 1 save read-only and shows it.

## Known limits

- **Houses belong to the account**, not the file (claims are keyed by user). Each file has its own house storage, and resetting the file that bought a house releases it. Making houses fully per-file would touch every door and access check.
- Other things seeded or stored by account stay shared: the spell hand's look, cast rolls, Titan fall names, world-firsts.
- `restoreprogress` restores File 1's key only.
- In Studio the mock DataStore doesn't keep files between Play sessions.
- `FirstHourService` times now include time spent in the menu.

## Code

Server: `Services/SaveFileService` (new), `PlayerDataService` (`loadFile`, `fileKey`, `entityFor`, `sessionStore`, `slot` on the state), `WorldStateService` (spawn gate, respawn), `HousingService.releaseClaim`, `DataService.eraseUser`, `Persistence/Schemas.Account`. Remotes `FileList`, `FileChoose`, `FileReset`, `FileReturn`. Client: `Menu/MainMenu` (new), `Controllers/FileController` (new), `init.client.luau`. Spec `Tests/SaveFiles.spec` (3). Log: `file_listed`, `file_chosen`, `file_reset`, `file_return`, `player_ready file=`.
