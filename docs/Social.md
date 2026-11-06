# Multiplayer and social systems

The owner's brief (2026-11-05): make playing with others fun without breaking the sandbox, keep solo play great, and follow Roblox's rules for chat, user content and safety. Built in stages.

| Stage | What | State |
|---|---|---|
| **1** | Audit, parties with shared quest progress, the party UI, one two-player combo, emotes, consent-based duels | built 2026-11-05, not yet run |
| 1b | Party sharing of creature XP and loot, quest XP and loot | built 2026-11-05, not yet run |
| **2a** | Shared world events | built 2026-11-06, not yet run |
| **2b** | **Cross-server news, safe trading, markets (owner asked for these next)** | **designed below, not written** |
| 3 | Guilds | later |
| 4 | Social hubs, PvP modes | later |

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
7. **Corrected 2026-11-05:** this audit first said creature kills reward only the last hit. That was wrong: everyone who dealt `creditShare` of its health was already rewarded (`CreatureService.luau:21`). What was missing was credit for party members who dealt less, such as healers. Fixed in §3.
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

Shared crises: party members within 150 studs of a rewarded member now share at 60% of that member's share.

### Shared creature XP and loot, and quest items (built 2026-11-05, not yet run)

- **Share:** members within 120 studs of a kill each earn `(1 + 0.35 × (n − 1)) / n` of a solo reward: 67% for 2, 57% for 3, 51% for 4, 48% for 5 (`Data/PartyRewards`). Strangers still earn their own reward as before.
- **Loot mode (leader picks, Party screen):** free for all, round robin (coins split evenly), or need or greed (gear only; stackables go round robin). `Services/PartyLootService`, `Social/LootRules`.
- **Quest items are new.** Quests only paid coins before, so a successful quest now also has a seeded item drop by template type (`QuestTuning.loot`). This also applies to solo players. Chores, training, hunted and atonement quests drop nothing.
- **Limit:** a need-or-greed roll is held in memory, so it's lost if the server closes. All-pass or no answer means nobody gets the item.

---

## Shared events (built 2026-11-06, not yet run)

Data: `Shared/Social/Data/SharedEvents`, `Social/Data/EventEnemies`. Rules: `Social/EventRules`. Runtime: `Services/SharedEventService`. Client: `Controllers/SharedEventController`, `Fx/EventFx`. All numbers are first guesses from the damage formula; none has been played.

- **Schedule:** `slot = floor(os.time() / 2400)`, one event every 40 minutes. Type and place come from `Seed.random(worldSeed, "shared_event", "schedule", slot)`, so every server runs the same event at the same time. Phases: 120 s warning, fight, ended (40 s recap). A server booting mid-event joins if at least 25% of the fight remains.
- **Place:** a random town. Siege is on the town itself; the others are on dry ground 150–230 studs out.

| Event | Fight | Win | Danger |
|---|---|---|---|
| Wild Elemental | 300 s | Kill the boss (1200 health; one of 4 elements, each with a weakness) | Slam: 22 damage, 14-stud radius, 2.2 s warning, faster below half health. Also a melee hit |
| Magical Storm | 300 s | Break 3 nodes (350 health each) | Each node strikes a random player in the zone: 14 damage, 9-stud radius, 1.6 s warning |
| Siege | 360 s | Stop 3 waves of raiders (6, 8, 10, plus up to 4 by players; 70 health) | They bite anyone within 22 studs on the way. 6 reaching the plaza loses the siege |
| Fallen Comet | 270 s | Break 8 shards (140 health each) | The landing: 25 damage, 24-stud radius, 3 s warning. Shards then pulse at anyone within 16 studs |

- **Enemies:** built with `CreatureRig`, carrying a `SharedEvent` attribute. They appear once a player is within 320 studs and the chunk is built, so an event nobody visits costs nothing and ends as "passed". At most 24 alive. Hitting one is never a crime.
- **Attacks:** a cue draws the warning, and the server applies the damage after the delay to whoever is still inside. The cue never decides who is hit. Guards work on them.
- **Scaling:** health = base × (1 + 0.85 × (players in the zone − 1)). It only goes up, by the difference, so damage already dealt stands.
- **Contribution:** damage to this event's enemies; healing other players in the zone (`TargetHealed`, at most 40 points a second); 2 points a second in the zone if you acted in the last 30 s. Tiers: gold ≥ 40% of the top score, silver ≥ 10%, bronze above 25 points. Needs 30 s in the zone. Playing alone earns gold.
- **Rewards:** gold 300 XP and 60 coins, silver 180 and 30, bronze 90 and 12, each with a seeded item roll. A failed event pays 35% of the XP and coins and no items. XP goes to your strongest branch through the study channel, so daily caps apply.
- **Server hopping:** `data.sharedEvents.claimed[event id]` in the session-locked save is checked before paying and saved with the reward. Contribution never carries between servers.
- **Screen:** a panel at the top centre (hidden during a duel), a ✦ world marker, your score once a second, and a recap. The **World event alerts** setting hides the panel and marker until you enter the zone.

**Known limits:**
- Leaving before the end pays nothing on that server.
- An item that doesn't fit in your bags is lost, though the XP and coins still arrive.
- Town guards and NPCs ignore raiders, because `NPCCombat` only targets players.
- Raiders walk in straight lines and hop 12 studs forward after 5 s stuck, so they can pass through a wall.
- A boss that falls out of the world counts as defeated, so the event can't hang.
- Two players who can hurt each other could trade damage and heals to score healing points; the per-second cap limits this.

**Admin:** `sharedevent start <type>` (in front of you, 10 s warning), `end` (no rewards), `win` (pays out), `status`, `schedule`. Flag: `shared_events_enabled`.

**Budget:** one 4 Hz loop while a fight runs, a 1 Hz zone and score pass, one unreliable score message per participant per second, state messages only on change.

---

## Still to build (design agreed 2026-11-05, nothing written yet)

The remotes below are already declared in `Net/Remotes` with no handlers: `RequestWorldNews`, `TradeAction`, `MarketAction`, `WorldNews`, `TradeState`, `MarketChanged`. Adjust them freely.

### Cross-server (`WorldNewsService`, `LeaderboardService`)

- **Event wins:** `Topics.SharedEventEnded` is already published for this, with no subscriber yet.
- **Announcements:** subscribe to `WorldEventRecorded`; an allowlist of kinds becomes anonymous text ("Someone has awakened Time magic"). Add a topic in `ProgressionService.syncInnate` to detect mythic awakenings.
- **History:** add `WorldService.recordOnce(id, kind, data)` with a deterministic id (one win per event type per day), so servers don't flood the 200-entry chronicle.
- **Leaderboard:** seasonal OrderedDataStore (in-memory in Studio), writes queued and throttled, an opt-out setting, and removal in `DataService.eraseUser`.

### Direct trade (`TradeService`, pure `Social/TradeModel`)

Request and accept (a `tradeRequests` setting and blocks apply); offers by ref with a fingerprint of every record field; any change clears both confirmations; Ready, then a server-built final summary with total values, then a 3 s wait, then both Confirm. Commit through `InventoryService.transfer`, which needs a new public method to audit and recompute the second player. Refuse if coins would exceed `maxCurrency`, because `addCurrency` truncates. Refuse bound, quest, locked and equipped items. `saveNow` both players afterwards. **Known window:** a crash between the two saves could duplicate or lose a traded item.

### Markets (`MarketService`, pure `Social/MarketBook`, `Schemas.Market`)

- **Storage:** 4 shards per town, `scopedKey("market_<town>_<shard>")`, to stay under the per-key write limit. Each holds `listings`, `mail` and `tx`. Store user ids, never names.
- **Escrow order, which prevents duplication:** (1) remove the items or coins in memory and write `data.market.pending[txId]`; (2) `saveNow`, and refund if it fails; (3) `store:update`, recording `tx[txId]`; (4) clear pending. On a clear refusal, refund. On an ambiguous datastore error, keep pending. Recovery at load and every 60 s: if `tx[txId]` exists it was applied; otherwise write `tx[txId] = "void"` and refund.
- **Items leave only through mail:** sales, cancels, expiry, outbid refunds and proceeds all become `mail` entries. **Collect:** add to the inventory and set `data.market.claimed[mailId]` together, `saveNow`, then delete from the store. The session lock makes this exactly-once: on recovery, a mail entry already in `claimed` is only deleted.
- **Rules:** usable only inside a town (`settlementAt`), M key plus a prompt on the `market_stall` building (add it to the InteractionController `openable` list). Fee 2% (min 1), tax 5%. Caps: 6 stalls, 3 auctions, 3 commissions. Stalls 48 h; auctions 12–24 h, 5% minimum raise, a bid in the last 60 s extends by 60 s. Validate records with `ItemInstance.validate` on listing and on delivery. Refuse a uid you already hold, and log it.
- **Commissions:** the requester escrows materials and pay; a crafter takes it exclusively for 1 h. The crafter finishes at the right station (needs public helpers on CraftingService for nearest station and result roll), and the store then sends the item to the requester and pay to the crafter. Materials never reach the crafter, so they can't be stolen. Exclude hearth recipes.
- **Also needed:** Controls entries (M for markets; K is now Surge, so trade needs another key), a "Trade" button in the Party screen's people list, specs in `Tests/Economy.spec`, and a note that market shards keep numeric user ids until entries expire (handle this for `eraseUser` before launch).

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
- Shared events: is one every 40 minutes right? Are the rewards right against quest pay? Should guards fight raiders (needs `NPCCombat` to target non-players)? Should the event place favour towns with players in them, since it can land across the map?
