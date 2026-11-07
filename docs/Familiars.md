# Familiars

A small creature generated from your innate magic, which grows and fights beside you. Stage 1 built 2026-11-07 on the owner's "build the familiars", not yet run. Every number is a first guess.

Specs: `Tests/Familiars.spec`.

## Where it lives

| What | Where |
|---|---|
| Content and numbers | `Shared/Familiars/Data/Familiars` |
| Decisions (pure) | `Shared/Familiars/FamiliarRules` |
| Running it | `Services/FamiliarService` |
| The body | `Familiars/FamiliarRig` |
| The screen (O) | `Controllers/FamiliarController` |
| Effects | `Fx/FamiliarFx`, from the `familiar` WorldEffect cue |
| Save | `PlayerData.familiar` |

Flags: `familiars_enabled`, `familiars_max_alive` (60). Remotes: `FamiliarAction`, `FamiliarState`.

## How it works

**Bonding.** Your first 5 spells, or reaching Novice. Nothing has to be unlocked, in keeping with "I don't want to restrict anything for the player". Its domain is your strongest awakened one, saved at that moment so a later awakening can't change who it is.

**Generation.** `Seed.random(worldSeed, "player:<id>", "familiar")` picks the shape, default name, size and which side of you it keeps to. Colours come from your magical signature, tinted by the domain. Personality comes from your temperaments. It's the same on every server. There are no rerolls, and there never will be paid ones.

The client only gets the personality's word and line, never the temperament, so a familiar can hint at a temperament you don't know you have yet.

**The body has no Humanoid (a deliberate choice).** Every part has CanCollide, CanQuery and CanTouch off, and `AlignPosition` moves it.

- Spells, aim, projectiles and lock-on can't see it, so your own bolts pass through it and nobody can grief you by killing it.
- Walls don't stop it, so it needs no pathfinding and can't get stuck.
- 60 of them cost 60 small floating assemblies rather than 60 Humanoids.

**Orders.**

| Order | What it does |
|---|---|
| Follow | Stays with you and never fights |
| Guard (default) | Fights what you hit and what hits you |
| Hunt | Guard, plus wild creatures near you, only while you're playing |
| Stay | Holds its spot and bites only what's in reach. Comes running once you're 400 studs away |

It sits out your duels. Hunt only ever starts on creatures, never on people.

**Damage.** Everything goes through `Cast/Damage` with you as the source, so PvP rules, parties, wards and quest wards all apply, and creature kills credit you. No bite takes more than 6% of another player's health. Damage kinds start with `familiar`, and `SurgeService` ignores those, so it can't fill your meter. An Ascendant's bite is under half of one of your full hits.

**Its health.** Only what it attacks hurts it: 5% of its health per attack it lands, 10% against anything with 2,000+ health. At zero it's knocked out for 45 s and comes back by itself. It can't die.

**Growth.** XP comes from your effective casts (2, at most one per 4 s) and kills it helped with (10–50), only while you've moved or cast in the last 90 s, up to 600 a day.

| Stage | XP | Gets |
|---|---|---|
| Hatchling | 0 | Bite |
| Young | 120 | Its own domain's ability |
| Grown | 500 | |
| Elder | 1,500 | A second ability, from the domain you cast most other than its own. If you've cast no other, from the first domain that pairs with its own (`synergies`) |
| Ascendant | 4,000 | |

At the daily limit, Ascendant takes about a week of hard play. Time, Gravity and Reality familiars bite 25% harder. Abilities fail where magic does (the Hushed Hollow, through `densityAt`). Bites don't.

**Name.** The raw name stays on the server, and everyone sees the TextService-filtered one (`SpellbookService:filterName`). If filtering fails on a live server, its default name shows. Default names are a hand-picked list, because combining syllables could spell something bad.

**Saves.** It's a field in the player record, so `resetallprogress`, `restoreprogress` and `DataService.eraseUser` already cover it. Nothing is stored anywhere else.

## Admin

`familiar bond | status | xp <n> | stage <1-5> | mode <1-4> | ko | forget`, with an optional player after the number. `forget` wipes it, and it bonds again from their next spells.

## Log lines

`familiars_ready`, `familiar_bonded`, `familiar_grew`, `familiar_ko`, `familiar_renamed`, `familiar_budget_full`, `familiar_step_failed`.

## Reasoned, not yet seen in play

- Whether `AlignPosition` replication looks smooth to other clients at 5 updates a second, and whether the bob reads as alive.
- Whether it looks wrong passing through walls and floors. It hovers over the ground found from about your height, so indoor floors should work.
- Whether the bodies look like anything. They're built from the same kind of parts as creatures, and have no animation.

## Known limits

- Fetch from the first pitch was dropped: loot goes straight to your bag, so there's nothing to fetch.
- Other players' spells can't hurt it. That stops griefing, but it also means a player can't deal with an opponent's familiar except by beating them.
- Only its attacks expose it to harm, so a familiar that isn't attacking is never in danger.
- NPCs don't have familiars. That's a budget question, not a technical one.
- If you hit an NPC directly, Guard joins in, and its hits count as yours. Damage over time doesn't set a target, so a spreading fire won't send it after a bystander.

## Ideas for stage 2 (nothing chosen)

Idle animations and a look per stage, its own sounds, an order key that doesn't need the screen, familiars taking real hits, combos between you and it, showing it on the map, and NPC mages with familiars.
