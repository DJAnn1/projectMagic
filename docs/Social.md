# Multiplayer and social systems

The owner's brief (2026-11-05): make playing with others fun without breaking the sandbox, keep solo play great, and follow Roblox's rules for chat, user content and safety. Built in stages.

| Stage | What | State |
|---|---|---|
| **1** | Audit, parties with shared quest progress, the party UI, one two-player combo, emotes, consent-based duels | built 2026-11-05, not yet run |
| 2 | Guilds | waiting for the owner to confirm stage 1 |
| 3 | Shared world events | later |
| 4 | Player markets, safe trading | later |
| 5 | Social hubs, PvP modes | later |

Left out of stage 1 on purpose, to arrive with those stages: party loot options, shared discoveries, more combos and supportive roles, group scaling, mentorship, titles and banners, wagers, duel arenas and replays, mute and report tools, and the fake-player load test.

---

## 1. Audit

Line numbers are from the code before this work (commit `ed9e03e`).

### What existed

| Area | State |
|---|---|
| **Shared quest state** | Two kinds. Personal quests belong to one owner (`QuestDirector.luau:176-190`, saved in their data), and nobody else could advance them. Shared crises are open to anyone in range, with rewards by contribution (`:601-612`). No concept of a group. |
| **PvP rules** | One global flag, `pvp_enabled`, default on (`Flags.luau:31`), read by `Targeting.canHarm` (`Targeting.luau:66-74`). Everyone can hurt everyone, everywhere. |
| **Friendly fire** | No such thing as an ally. Every player was an enemy, or with the flag off, nobody was. |
| **Trading** | None. `Inventory.transactMany` and `InventoryService.transfer` are atomic across two inventories, so stage 4 has a sound base. Items already carry a `bound` flag. |
| **Duels** | Against NPCs only (quest `duel` type, `QuestSanction`). |
| **Seeing other players** | The Roblox player list. Nobody could see another player's health or reservoir. |
| **Chat and custom text** | Default TextChatService. Spell names are correctly filtered (`SpellbookService.luau:65`). |
| **Blocks** | Nothing read the Roblox block list. |

### What broke with several players

Ranked by how much it would hurt. **Fixed** means in this stage.

1. **Fixed: damage skipped the PvP check.** `canHarm` guards what spells target, but `Damage.apply` had no check. Status ticks (`StatusEffects.luau:394`), reactions and field damage go straight to it, so with PvP off, your burn could still hurt another player. There is now one rule, checked in both places (§2).
2. **Fixed: a duel in town would have been a crime.** `CastService.luau:408-415` counts any non-practice hit as harm. Hitting a duel opponent in a settlement would have built infamy.
3. **Fixed: helpers would have paid other people's fines.** Once quests could be shared, talking to a `pay` objective's NPC would have taken coins from whoever talked (`QuestDirector.luau:1098`). Only the owner's coins can pay now.
4. **Fixed: hitting a party member's sanctioned rival was a crime.** `FactionService.luau:251` only excused the quest's owner.
5. **Not fixed: griefing with open PvP.** With `pvp_enabled` on, anyone can attack anyone, including at spawn and new players. This was the owner's call on 2026-11-03, so it stays until they decide (see Open questions). Parties and duels work either way.
6. **Not fixed: quest wards can clash.** Two players with quests on the same NPC overwrite each other's `QuestWard` (`QuestDirector.luau:1182`), and the loser's hits do nothing. Rare, and would need per-quest wards.
7. **Not fixed: creature kills reward the last hit only** (`CreatureService.luau:22`). Fighting one together pays only whoever finishes it. Needs a design decision on assists; belongs with group scaling.
8. **Not fixed: effects with no source hurt allies.** Fire that has spread with no recorded caster (`FireSim.luau:251`) and the steam reaction's burn (`InteractionMatrix.luau:184`) carry no source, so party protection can't apply to them. A non-damaging push (`Force.luau:80`) still moves anyone, which allows some griefing.
9. **Not fixed: watching teaches for free.** `CastService.luau:479` gives observation XP to anyone nearby. Its anti-grind caps apply, but two friends can use it deliberately.

**Could not check without running it:** behaviour at 30–60 real players. That needs the load tool planned for the safety stage.

---

## 2. Who can hurt whom

`Cast/PvpRules` is the one answer. First match wins:

1. Yourself: always (backfires).
2. Either person is in a duel: only the two fighters, and only once the fight starts.
3. A duel between these two just ended: no, for 6 seconds (late projectiles).
4. Same party: no.
5. Everyone else: the `pvp_enabled` flag.

It's asked by `Targeting.canHarm` and again inside `Damage.apply`, so damage that skips targeting obeys it too. `PvpRules.canHelp` is the same idea for heals and buffs: nobody can help across a duel.

**Solo play is untouched:** with no party or duel, these rules give the same answers as before, except the leak in audit item 1.

---

## 3. Parties

- **Size:** 2–5. A party forms when the first invite is accepted and disbands at one member.
- **Invites:** from a leader, or from anyone not in a party. They last 45 s. A "no" stops the same person for 30 s, and you can have 5 open at once.
- **Lifetime:** per server, not saved. Leaving the server leaves the party.
- **Screen:** Party (P) has requests, your party, the people here and emotes.
- **HUD:** each member's health and reservoir, as bars and as numbers, plus distance. A ◆ and name mark them in the world.

### Shared quest progress

Each quest still has one owner and is saved in their data. Party members can advance it:

- `activeFor` now includes party members' personal quests, so casts, talks, kills, pins and polling all count for them. The Journal lists these under "Your party's quests".
- **Not shared:** first-hour quests (a veteran doing your tutorial teaches you nothing) and quests that start themselves (being hunted).
- **Only the owner can:** accept, abandon, pay coins, and pick up an escort.
- **Helper rewards**, when the quest succeeds, for anyone who advanced it or stood within 150 studs of the owner at the end: 60% of the XP (in their own best branch), coins and standing gained. Never fines, infamy, bounties, lore, lessons or awakenings; a failed quest costs helpers nothing.

**Known limit:** shared crises still pay by personal contribution, so a healer standing by earns little.

---

## 4. Combos

Data: `Shared/Social/Data/Combos`. Rules: `Social/ComboMatcher`. Runtime: `Services/ComboService`.

**Earthflare (Earth + Energy).** Two party members land any Earth spell and any Energy spell within 3.5 s and 18 studs. The ground erupts at the midpoint.

| | |
|---|---|
| Power | average of the two recipe powers, +1, at most 10 |
| Damage | `9·power^0.6 × 1.6` at the centre, half at the rim, ±variance, resistance applies, usual caps |
| Radius | 12 + power |
| Also | burning for 3 s |
| Cooldown | 12 s per party |
| Reward | 120 experimentation XP, once ever per player |

There's no combo button, and neither spell costs extra. Your partner sees a ring and a line of text when your spell could be finished, but only if they have the other domain. When it fires, everyone nearby sees the eruption and a banner with both names. Hurts nothing that either caster couldn't hurt.

---

## 5. Emotes

Data: `Shared/Social/Data/Emotes`. Wave, Bow, Cheer, Laugh, Dance, Meditate, Light show, Halo.

- **Use:** hold T and point (wheel), type `/bow` and so on in chat, or use the Party screen's buttons. Touch has an Emotes button.
- **Look:** clips are Roblox's default R6 emotes. Bow and Meditate are procedural poses, since no animation asset exists. Light show, Halo and Meditate's motes use your Signature's colours.
- **Rules:** cosmetic only. Moving, casting, being hit or dying ends one. Server-side cooldowns.

---

## 6. Duels

Rules: `Shared/Social/Data/DuelRules`, `Social/DuelModel`. Runtime: `Services/DuelService`.

| Rule | Ends when | Health floor |
|---|---|---|
| First blood | someone has dealt 5% of the other's max health | 20% |
| No lethal (default) | someone reaches the floor | 15% |
| To yield | someone yields, or stays at the floor for 8 s | 8% |

All of them also end on Yield, leaving the ring for 3 s, the 3-minute limit (healthier fighter wins), or either fighter leaving the server.

- **Consent:** nothing happens until the other player accepts. Challenges last 30 s, and a "no" stops the same challenger for 15 s.
- **Can't kill:** `Damage.apply` holds fighters at the floor. Afterwards, each gets back at least the health they started with, and harmful statuses are cleared.
- **Isolated:** nobody else can hurt or heal a fighter, and fighters can't hurt anyone else. Spectators are safe.
- **No escape hatch:** you can't start within 10 s of being hit. Something else bringing a fighter to the floor calls the duel off, with no heal.
- **Legal:** hits between fighters aren't crimes. A town that bans a domain outright still judges the cast.
- **Ring:** a 45-stud circle drawn on the ground, with names over the middle.
- **Recap:** the result and why, each fighter's damage, hits, crits and biggest hit.

**Known limits:** damage that doesn't go through `Damage.apply` ignores the floor: your own overdraw (`CastService.luau:1038`) and backlash (`BacklashService.luau:134`). Those deaths are your own doing and count as a loss. A burn applied by the winning hit can outlast the duel by a tick or two after the grace period.

---

## 7. Safety and policy

- **No free text in this stage.** Only Roblox display names appear, and Roblox moderates those. Chat commands are read by the client and never shown to anyone. Guild names, house names and books in later stages must go through `TextService`, as spell names do.
- **Blocks:** each client reports its Roblox block list. A block stops invites, challenges and emotes in both directions. A false report could only hide things from the sender.
- **Settings:** Party invites and Duel challenges (Anyone, Friends only, Nobody), Emotes from others (Everyone, My party, Nobody).
- **Refusals don't reveal why:** a block reads the same as a setting, so nobody can use invites to find out they've been blocked.
- **People list:** names only, the same as the Roblox player list.

---

## 8. Admin

`parties`, `testparty`, `partyleave`, `combos`, `combotest <id> [power]`, `emote <id> [player]`, `duels`, `duelforce <a> <b> [rule]`, `duelend [player]`. Flags: `party_enabled`, `combos_enabled`, `emotes_enabled`, `duels_enabled`.

**Testing with two players:** in Studio, open Test › Clients and Servers, choose 2 players and press Start. One-person checks: `combotest earthflare`, `emote light_show`.

---

## 9. Budgets

| System | Cost |
|---|---|
| Party vitals | one 2 Hz loop, one unreliable message per member only on change; positions rounded to 16 studs |
| Quests | `activeFor` also scans party members' quests: at most 5 members × 5 quests per player, per poll |
| Combos | at most 8 recent casts per party; a combo does one area query and at most 24 occlusion rays, with a 12 s cooldown; no parts on the server |
| Emotes | cues only on start and stop; a 4 Hz check over players currently emoting; flourishes use the pooled effects |
| Duels | at most 8 at once; one 5 Hz loop; one invisible anchor part each, and 48 ring segments per client nearby |

---

## 10. Open questions

- **Should open PvP stay on?** `pvp_enabled` is on for everyone (decided 2026-11-03), but this brief calls PvP opt-in. Recommendation: turn it off, so that duels and later PvP zones are the only way to fight another player.
- Should a party's members split creature kill XP and loot?
- Should there be a way to invite someone from across the map, or is the list enough?
- Should the combo's ring also show for partners who can't finish it, as a hint to bring a friend who can?
