# Wildborn

Built 2026-11-12 from the owner's reference enemy scripts (Ember Wraith, Pyre King, and the rest). The owner chose: **Wildborn** as who they are, **seeded lairs** for bosses, and **all seven themes** at once. The owner's rule: every enemy is a **humanoid model** (R6 rig), never a custom welded body.

## Who they are

People whose innate magic matched a harsh place, and who stayed too long. The land took them in. Ordinary Wildborn haunt their biome. The oldest, the bosses, each keep one lair. Towns tell old stories about them.

| Theme | Biomes (weight) | Wildborn | Boss | Domain | Weak to |
|---|---|---|---|---|---|
| Fire (Ember Wastes) | volcanic highlands 1.4, badlands 1, desert dunes 0.7 | Ember Wraith | Pyre King | energy | water |
| Water (Drowned Shore) | tidal flats 1.4, swamp 0.6 | Tidal Sage | Drowned Lord | water | energy |
| Nature (Overgrown Wilds) | deep forest 1.4, grasslands 0.8 | Meadow Sentinel | Grove Sovereign | life | energy |
| Stone (Iron Crags) | mountains 1.3, crystal caverns 1 | Stone Brute | Iron Tyrant | earth | air |
| Shadow (Shadow Mire) | swamp 1.2, ruinlands 0.8 | Mire Stalker | Penumbra Lich | void | spirit |
| Storm (Frost Peaks) | frostpeaks 1.4, tundra 0.8, skyreach 0.8, frozen coast 0.7 | Storm Caller | Tempest Monarch | energy | earth |
| Void (Void Rift) | ruinlands 1.2, crystal caverns 0.6, skyreach 0.6 | Chrono Phantom | Void Warden | time | space |

## Where they are

- **Haunts:** the island is cut into 256-stud cells. A dry, gentle cell at least 260 studs from any town, in a theme's biome, gets a haunt with chance 0.22 × the biome's weight (at most 40), with one or two Wildborn. Seeded per cell, so every server has the same haunts.
- **Lairs:** one per theme, the best cell of its biomes at least 420 studs from any town, marked by a ring of seven standing stones with dim glowing glyphs. A theme whose biomes the world lacks has no lair.
- Both wake when a player comes within 240 studs and sleep past 320; nobody near = no rigs, no cost. At most 14 ordinary Wildborn alive; bosses don't count.
- Ordinary Wildborn return 4–7 minutes after dying. A beaten boss returns after a real day **on that server** (not saved).

## How they fight

Every 0.2 s an awake Wildborn picks a target (whoever hurt it lately, else the nearest within aggro; forgotten past deaggro), then uses the first of its moves that's ready and in range, else walks in for its plain blow. It stands still while casting. Past its leash it walks home and heals (and forgets who hurt it), so it can't be kited to death. Knocked down or held: nothing.

**Move library** (`Wildborn/WildbornMoves`, numbers per enemy in `Wildborn/Data/Wildborn`):

| Kind | What it does | Used by |
|---|---|---|
| bolt | projectiles (volleys, splash, statuses); `chain` jumps target to target | Ember Wraith, Pyre King, Tidal Sage, Drowned Lord, Tempest Monarch (chain) |
| lob | arcing boulders, landing spot warned | Meadow Sentinel, Grove Sovereign |
| dash | burning trail, then a strike | Ember Wraith, Pyre King |
| blink | to the flank or behind, after-image; clones that fire | Mire Stalker, Penumbra Lich, Chrono Phantom, Void Warden |
| echo | a strike, then again 0.7–0.8 s later | Chrono Phantom, Void Warden |
| burst | warned blast around itself (status, knockback, heal) | most |
| eruption | spikes, vines, a wave: line, cone, wave, at the target, under everyone | Stone Brute, Iron Tyrant, Meadow Sentinel, Grove Sovereign, Tidal Sage, Drowned Lord |
| zone | lingering area that ticks and pulls | Tidal Sage, Drowned Lord (whirlpool, maelstrom), Storm Caller (static), Tempest Monarch (blizzard), Grove Sovereign (petals), Void Warden (tear) |
| tether | drains and heals itself | Mire Stalker, Penumbra Lich (everyone in range) |
| rain | meteors, lightning, an anvil on warned spots | Pyre King, Storm Caller, Tempest Monarch, Iron Tyrant |
| pull | drags everyone in, then slams | Iron Tyrant |
| stasis | stops time on the target; `pull` snaps them in after | Chrono Phantom, Void Warden (Causal Collapse) |
| rally | once, low: heals, may hasten, may blast | Pyre King (Phoenix Rebirth), Grove Sovereign (Awakening) |

**Fair play:** every big move is warned on the ground before it lands. Bosses can hurt one player at most every 0.5–0.6 s (`hitGap`, the Grove Sovereign's rule for all). Every hit goes through `Damage.apply` (wards, guards, parries, resistances, PvP rules). Slows, roots, stasis and burning are real statuses. Knockback goes to the player's own client.

## Bodies

`Wildborn/WildbornRig`: `Players:CreateHumanoidModelFromDescription` with R6, as NPC rigs. The land in the skin colour, dark old clothes, a dim glowing band and glowing eyes in the theme's colour, a catalog hood for ordinary Wildborn, a crown of glowing points for bosses, a particle aura, bosses scaled 1.6–1.7×. Marked `Creature` (hitting one is never a crime) and `Wildborn`. Idle, walk, CastSpell and Slash1 clips.

## Rewards and telling

- Kills pay through `CreatureService:rewardFor` like any creature: XP to the branch you hit it with, seeded loot, coins, the hourly anti-grind factor, party shares.
- Your **first ever kill of each boss** pays 2.5× its XP and writes a Journal line (✠) (`data.wildborn.slain`).
- Ask townspeople for news: with chance 0.6 they tell the old story of the nearest boss you haven't heard of, with its direction; it goes in your Journal and its lair on your map (`data.wildborn.heard`).

## Testing

Expected boot line: `specs 1054/1055` if Omens' 1048 holds (6 new in `Tests/Wildborn.spec`; the one failure is the known Shine Pass item). Log `wildborn_planned haunts=N lairs=M` shortly after boot.

- `wildborn spawn ember_wraith` (any id: `ember_wraith`, `pyre_king`, `tidal_sage`, `drowned_lord`, `meadow_sentinel`, `grove_sovereign`, `stone_brute`, `iron_tyrant`, `mire_stalker`, `penumbra_lich`, `storm_caller`, `tempest_monarch`, `chrono_phantom`, `void_warden`) spawns one 22 studs ahead, no respawn.
- `wildborn lairs`, then `wildborn goto fire` to walk into the Pyre King's lair. `wildborn revive` brings beaten bosses back.
- `wildborn list` shows the nearest haunts, what's alive, and projectiles and zones in flight.
- Ask a townsperson "Any news?" for a boss story; check the map and the Journal.
- Log: `wildborn_killed`, `wildborn_boss_slain`, `wildborn_story`; `wildborn_move_failed` and `wildborn_step_failed` should never appear.
- Kill switch: `flag wildborn_enabled false`.

## Unverified

- How the rigs look (colours, hood, crown, scale) and whether the walk and cast clips play on them.
- Move feel: speeds, ranges, the warnings' timing, knockback strength. All numbers are first guesses from the reference scripts.
- `Model:ScaleTo` on a rig with welded glow parts; the boss standing at the right height after scaling.

## Open questions

- Should Wildborn fight NPCs and creatures too (guards defending a road), or only players?
- Should a boss's return be saved world-wide (the same on every server) instead of per server?
- Should towns near a haunt feel it (NPCs warning travellers, fewer people on that road)?
