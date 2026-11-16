# Hunting and fishing that happen in the world

Owner, 2026-11-16: "npcs are hunting deer or fowl but there is no deer or fowl so create them. they would also fish on the grass instead of near water." Built the same day, not yet run.

## What was wrong

- The hunting activity named "hares", "a deer", "wild fowl", but no such animals existed. The only creatures were the six magical critters near each town.
- Fishers worked at the "harbor" district point: a fixed direction from the town centre. When that point fell in the sea, `spotFor` moved it to the nearest dry land, often inland grass.

## Game animals

- Three ordinary animals in `Creatures/Data/Creatures` with `game = true`: **deer** (2–4), **wild fowl** (3–5, pheasants that run), **hare** (2–4). They have no bite, flee from players (30/16/20 studs), show no name or health bar (`silent`), and wag their tails and bob their heads on the client (`Fx/FamiliarAnimator` now also drives `workspace.Creatures`).
- Loot: `raw_meat` (cooks into stew at a hearth), and the new `deer_hide`, `feather` and `hare_pelt`. They pay little XP (3–5).
- **Herds:** three per town (`CreatureRules.planHerds`), 70–230 studs past the town's edge. Herd ids are `<town>:herd<n>` and the seed system is "herds", so no existing critter den moved. They have no mound: a herd just grazes there. Rumours don't name them.

## Hunters (`Services/HuntService`)

- A hunter's work spot is a stand about 26 studs off one of their town's herds, on the town's side, picked by seed per person and game day (`NPCService.setWorkSpotHook`).
- At the stand, with an animal within 60 studs, they turn to it and shoot every 18–35 s. The arrow is the same one a player's bow draws (the `weapon` cue).
- A hit drops the nearest animal (`CreatureService:shoot`; no player is paid), and a miss startles the herd. Either way the herd runs from the hunter for 6 s. After a kill the hunter moves 50° round to a new stand.
- Herds only exist near a player, so all this happens in sight. Out of sight, hunters keep their old district spot.

## Fishers

- **Shore:** `Life/Shore.find` walks rings out from the town and keeps low, dry ground with open water 7 studs away. NPCService's `harbor` spot is one of those, picked by seed. The fisher faces the water there (HuntService), so the bobber lands on it.
- **No water within reach** (the town's radius + 260 studs): `npc.noShore`. Those fishers do the new `mending_nets` activity instead, because `fishing` has `shore = true` and `mending_nets` has `shore = false` (ActivityRules).

## Admin and logs

- `hunts`: lists hunters, their herd, their distance from the stand and their shot count.
- `huntnow`: the nearest hunter shoots now, always a hit.
- `creature spawn deer|wild_fowl|hare`
- `creaturedens`: herds are listed too.
- Log lines: `creature_dens herds=`, `hunt_shot hit= kind=`.
- Flag: `hunting_enabled`.

## Open questions (defaults in use)

- Should animals also flee from NPCs walking past, not only from players and hunters' shots? Default: no.
- Should a hunter carry the kill home (a carcass on the shoulder, meat at the market)? Default: no, it fades where it fell.
- Should players' hunting of the same herd leave less for the town's hunters (shared numbers)? Default: they already share the same animals; respawn is 3–8 minutes.
