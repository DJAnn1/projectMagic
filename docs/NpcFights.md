# NPCs fighting each other

Owner, 2026-11-16: "I do want npcs being able to fight each other." Built the same day, not yet run.

## What was missing

- NPC combat (`NPC/NPCCombat`) could only aim at players (`u:<id>`) and registered external targets (ferals, siege Wildborn).
- When an NPC's bolt hit another NPC, the victim had no subject. It ran or "fought" nobody, and the guards ignored it.
- Wildborn only ever targeted players. Guards shot at a siege band and the band never answered.
- Raids were a fire set at night at the town's edge. In daylight, a live raid resolved at once (log 2026-11-16: `agenda_resolved ... live=false` in the same millisecond as the start).

## The foundation

- **Subjects for any body.** `NPCCombat.subjectOfModel(model)` gives `u:<userId>` for a player, `n:<npcId>` for an NPC rig, and `m:<n>` for anything else with a Humanoid. An `m:` subject is an external target that drops itself once the body is gone. `n:` subjects resolve through `NPCCombat.setNpcResolver`, which NPCService sets: the target must be alive, have a rig and not be knocked out.
- **Who hit an NPC.** NPCService listens on `Damage.listenAttacked`, which fires just before the `MagicDamage` for the same hit, and remembers the attacker for 1 s.
  - For an NPC attacker: an `attacked_me` memory and a soured relationship (rivalry +0.1), and guards within `witnessRadius` come over. Brawls are the exception: the service handles those.
  - For a Wildborn or creature attacker, the guards come.
  - Log line: `npc_knocked_out_by`.
- **`NPCCombat.challenge(npc, subject, { maxPower, reason })`.** `maxPower` holds a brawler's bolts back. `reason` is `brawl`, `raid` or `admin`. There are also two new helpers, `fighting(npc)` and `reason(npc)`.
- **Wildborn fight NPCs.** Moves split who sees a cue (players only) from who a move can hurt (players plus T0 NPC bodies, through `Moves.setTargets`).
  - A `View` now carries `model`, and its `player` is optional. Pushing an NPC sets its velocity on the server.
  - A Wildborn hurt by a non-player turns on it for 12 s (`actor.foe`).
  - With no player nearby, it goes for the nearest NPC who is standing to fight.
  - Bystanders caught in an area move get hurt too.

## Brawls (`Services/NpcFightService`)

- **When it can happen:** in the evening (16:00 to 01:00), in a town a player can see.
- **Who:** two free adults within 30 studs whose grudge (`FightRules.grudge`) is 0.45 or more.
  - Grudge = rivalry plus dislike (the worse direction), plus friction: (1 − compatibility) × (1 − the lower agreeableness).
  - Family never brawls with each other.
- **How often:** one seeded roll per pair per game hour, at a 30% chance.
- **How it plays out:**
  1. Four seconds of words. They stop and face each other, and the shorter temper speaks first.
  2. Then spells held to power 2, with a `HealthFloor` of 35% max health. A brawl never kills.
- **It ends when** one of them reaches the floor (`a_won`/`b_won`), a guard walks over (`broken`), one runs 45+ studs (`ran`), 40 s pass (`spent`), or one is gone.
- **Afterwards:**
  - Rivalry +0.15 both ways.
  - The winner and loser get `duel_won`/`duel_lost`, and both get `brawled_with`.
  - Bystanders within 40 studs get `saw_brawl`. These are gossiped, so the town talks about it.
  - The guard who broke it up says a line, and both fighters remember them.
- **Cooldowns:** a game day per pair, half a day per person.

## Live raids

- **Trigger:** `AgendaService` starts a raid with a player within `liveReach`, at any hour.
- **Who comes:** `NpcFightService:raid` takes 3 to 5 real fighters from the raiding town: guards and hunters first, then the bravest, and only NPCs who are out of sight. They appear past the edge on the side facing their own town.
- **The town reacts:** it gets a `raid` danger (people go indoors), and someone shouts `shout_raid_coming`.
- **What the raiders do:** each walks for the outermost building on that side, 20 studs per second-step.
- **Defence:** guards and hunters within 140 studs of a raider turn on them. A raider within 45 studs of a defender who is fighting answers.
- **How it ends:**
  - A raider within 10 studs of the building sets it alight and they all go home: `burned`.
  - All of them beaten or fled: `driven_off`.
  - 180 s pass and they give up: `driven_off`.
- **Afterwards:**
  - Townspeople near the raid remember each raider (`raided_us`, with the raiding town's id in the memory's note).
  - Knocked-out raiders wake at home.
  - The live outcome overrides the seeded one on this server.
- **Fallback:** if nobody could come, a raid at night falls back to the old edge fire.

## Admin and logs

- `fights`: brawls and raids running now.
- `brawlnow [npc]`: that NPC and the nearby person they can least stand come to blows, skipping the hour and the roll.
- `npcvsnpc <a> <b>`: a real fight with no floor.
- `agendanow raid`: raiders from the nearest town.
- Log lines: `npc_brawl_started` (with `grudge`), `npc_brawl_ended how=`, `npc_raid_started raiders=`, `npc_raid_fire`, `npc_raid_ended outcome= left=`, `npc_knocked_out_by`.
- Flag: `npc_fights_enabled` (it covers Wildborn targeting NPCs as well).

## Test

Clear the Output first. The expected boot line is **`specs 1152/1153`** (5 new specs in `Tests/Fights.spec`; the 1 failure is the known Standing room spec).

1. Go to Glenhold. Run `brawlnow`, watch the words, then the spells. Run `fights`. Watch for a guard walking over.
2. Run `npcvsnpc nearest <another name>`. One should be knocked out (`npc_knocked_out_by`).
3. Run `agendanow raid` in daylight. You should see `npc_raid_started`, raiders arriving at the edge, guards fighting them, and then `npc_raid_ended`.
4. Run `agendanow siege`. The Wildborn should now fight the guards back.
5. Run `time 19` and wait near the tavern or plaza. Watch for a natural `npc_brawl_started`.

## Open questions (defaults in use)

- Can brawls happen out of sight, as news only? Default: no, only with a player near.
- Should a player be able to join a brawl or a raid's side? Default: hitting one is still assault.
- Should raiders steal coin or goods, not only burn? Default: burn only.
- Should brawls happen in the daytime too, at a lower chance? Default: evenings only.
- Should Wildborn hurt civilians caught in their area moves? Default: yes.
