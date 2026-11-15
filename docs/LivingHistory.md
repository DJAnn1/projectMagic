# Living History

The design for `docs/Prompts-LivingHistory.md`: Dwarf Fortress, Caves of Qud and Kenshi-style engagement, built mostly by connecting systems that already exist. Stage 0 (this audit and design) written 2026-11-14. Nothing is built yet.

**Status:** stage 0 done, waiting for the owner before stage 1.

---

## 1. Audit: what already exists

### 1.1 Things that record events

| Where | What it keeps | Scope and life | Who reads it |
|---|---|---|---|
| `NPC/MemoryService` | Per NPC: `{t, kind, subject, valence, intensity, secondhand, from, note}`. 33 kinds. At most 24 per NPC; they decay (4 days for good things, 6 for bad); gossip passes them on one hop. | Live per server. Memories **about players** are saved per town (`Schemas.NpcTown`, merged across servers), so they're effectively global. | Opinion, greetings, dialogue, barks, gossip |
| `WorldService.recordEvent` → `World.chronicle` | `{id, kind, t, data, origin}`, at most 200. Written by: world-first recipes, signatures declared, world events, NPC awakenings, earthquakes, tsunamis. | **Global**, one record. | **Only** `NPCService` (to apply awakenings from other servers). **Everything else is written and never read.** |
| `TitanService` → `Schemas.TitanFalls` | `{id, kind, x, z, t, by, u, n}`, at most 20. | Global | Map pin, crater, bones |
| `JournalService` | The player's log, at most 200 entries. | Per player save | The Journal screen. **Every `log` call also fires `JournalChanged`, which the HUD shows as a toast.** |
| `Schemas.SettlementState` | Prosperity, relation drift and building damage per settlement. | Global | Settlement reputation and mood |
| `Schemas.Npc` | A named NPC's world-level state, including `alive = true`. | Global | **Nothing ever sets `alive` to false.** |
| `DiscoveryLog` | World-first recipe claims. | Global | Journal, chronicle |
| `FeralService` blame | Memory kinds `lost_control`, `spell_hurt_me`, `ended_it`, `cleaned_up`. | As memory | Gossip, barks |

**What this means:** projectMagic already has a Legends Mode: a global chronicle that six systems write to and nothing reads. That's DF's bloat (history nobody lives) without DF's payoff (history you run into). Stage 1 starts here and builds no parallel store.

### 1.2 Things that surface information to players

- **Rumour hooks** (`NPCService.setRumorHook`): FeralService, OmenService, RumorService, WildbornService and WildZoneService each answer "any news?".
- **Greeting hook** (`AmbientLifeService.setGreetHook`): NoticeService ("Was that you, out north?").
- **Talk hook**: QuestDirector.
- **Overheard pairs**: RumorService has two townspeople talk while you overhear. That's the mechanism tavern talk can reuse.
- **Barks**: `BarkEngine`, with conditions such as `fear`.
- **Journal**: first-person lines (☾ dreams, ☄ omens, ◉ sight, ☁ weather), but each one also toasts.
- **Map**: POIs you've uncovered and Titan fall pins. There are no place names apart from POIs and towns.

### 1.3 Things that could carry a past

- **Items:** the `ItemTypes.Record` of a unique item has `c` (crafter), `cn` (filtered custom name) and `t` (minted). It has **no history field**. One short field (`h`) is all an item needs.
- **Places:** POIs and towns only. Titan craters are the one place a deed has changed.
- **NPC makers:** `NPCMagicLife` careers, the `invention` memory kind, CraftingService recipes with a quality, and Activities with workshop stations. Everything a strange mood needs is there, apart from the mood itself.

### 1.4 What happens when you lose

- **Players** die. The `Humanoid.Died` handler in `WorldStateService` respawns them at the spawn after `RespawnTime`. There's no downed state outside duels, which use `HealthFloor` in `Damage.apply`. Every loss ends the same way.
- **NPCs** are knocked out for 6 game hours (`NPCService.knockout`, `knockedOutUntil = now + 0.25`), and the rig is thrown away and rebuilt. Nobody ever dies.

### 1.5 What acts without the player

- **EventDirector** rolls world events per server (drought, plague, migration...). They start, can be relieved by magic, and end.
- **Titans and shared events** run on seeded schedules, so every server agrees on them.
- **Factions** (`FactionService`, 11 of them) only **react to player deeds**. `Quests/Data/Factions` already defines faction-to-faction `relations` and `Settlements` defines base town relations with seeded grudges. Nothing ever acts on either.
- **Towns** have town repair, `NPCService.setLotDown` (residents move out of a damaged building and back), crises from SituationDetector, and Wildborn haunts (at least 260 studs from towns, at most 14 alive).

### 1.6 Knowledge

- RumorService tells you about places and dens and reveals that patch of the map.
- `JournalService.reveal` handles secret factions you've learned of.
- The scholars' faction already has a `lore_shared` deed (+60).
- There's no trade in knowledge: NPCs give information freely or not at all.

### 1.7 A constraint the prompt didn't name: servers don't last

Roblox servers close when they're empty. Anything kept **only** per server, like a fallen town, resets on the next server, often within hours. A town that falls on an empty server never falls at all. So per-server outcomes need a deterministic baseline every server can compute (see §5).

---

## 2. Overlaps with the queue

| Queue item | Fate |
|---|---|
| #25 Credited inventions | Stage 1 (world-first recipes become chronicle entries people talk about) and stage 2 |
| #46 Clear it or leave it | Stage 4 (retaking a fallen town) |
| #47 While you were away | Stage 4 (NPCs mention what changed since your last visit) |
| #52 Towns that change | Stage 4 |
| #57 The world's mood | Stage 4 (the mood of a region comes from recent outcomes) |
| #59 Living world stage 2 | Stage 4 (growth and history); vignettes and wonder events are not taken |
| #5 Town Mysteries, #55 Secret factions | Fed by stage 5, not built |
| #44 A rival who remembers | Untouched, but it will read the Chronicle when built |
| Feral spells, Titans, Wildborn, Noticing, Rumours | Become **sources** for stage 1, unchanged otherwise |

---

## 3. The rules for every stage

**The filter:** can the player see it, act on it, and tell a friend about it? Any "no" cuts it.

**The cut list (never build):**
- a history browser
- player hunger, thirst or labor management
- per-limb injuries or gore
- squads of followers
- new loot tiers or junk loot
- history the player can't find
- paying players for being beaten
- permadeath or losing a save
- slavery (capture means held, never owned)
- one player wrecking shared things for everyone

**Quiet by default:** history reaches players through people and places. A Journal line written by this work is **quiet**: it's written to the Journal without a toast. That needs a `quiet` option on `JournalService.log`. Today every line toasts, which is a card.

---

## 4. Stage 1: The Chronicle

**Goal:** the world remembers its big moments and people talk about them for days.

**Three levels, by significance:**
1. **Memory** (exists): small things stay in individual NPCs' memories.
2. **Server chronicle** (new, in memory, at most 120 entries): `{id, kind, actors = {"u:<id>" | npc id}, place = {town? | poi? | x, z}, things = {uid}?, t (world time), score}`. It lasts the server's life, and its top entries also seed the town's NPC memories, which are already saved.
3. **Legends** (global): an entry scoring at or above `legendAt` is written through `WorldService.recordEvent("legend", …)`. Legends go into a **separate list, `World.legends`, at most 60**, so world-event noise can't push them out. Writes are batched: at most one per 5 minutes per server. A player's name is stored as `by` plus `u` (UserId), like Titan falls, so `DataService.eraseUser` can take names off.

**Sources:** each one is a topic subscription with a score in `Data/ChronicleKinds`.
- a Titan felled
- a Wildborn boss killed (first or not)
- a feral escaping in a town, or being ended
- a shared crisis or quest outcome
- a world event relieved by someone's magic
- an NPC awakening
- a world-first recipe
- an ultimate or wish cast in or near a town
- a struggle won in front of witnesses
- later: a town falling or being retaken, and an NPC dying (stage 4)

**Anti-farming:** the score drops for each repeat of the same `(kind, actor, place)` within a real day, and nothing scores against dummies, duels or quest-sanctioned targets.

**How it reaches players** (no new screen):
- **Being asked for news:** a new rumour hook. "People in Glenhold still talk about the night the Ashwalker fell at the ford", with a direction.
- **Tavern talk:** RumorService's overheard-pair mechanism, at the tavern in the evening. One NPC tells a chronicle entry or a legend, and others nod or argue. At most one per tavern per in-game evening.
- **Greetings:** NPCs who know you did something greet you for it (a new memory kind `legend_of`, subject `u:<id>`, which gossip spreads one hop as now).
- **Other servers' legends:** read on boot. NPCs in the town where a legend happened know it as a secondhand memory.
- **Your own Journal:** one quiet first-person line when one of your deeds becomes a legend.

**Files:**
- `Server/Chronicle/ChronicleRules` (pure: scoring and decay)
- `Server/Chronicle/Data/ChronicleKinds`
- `Server/Chronicle/Data/ChronicleLines`
- `Services/ChronicleService`
- `WorldService.legends` / `recordLegend`
- a `quiet` option on `JournalService.log`
- the `legend_of` memory kind
- `DataService.eraseUser` gains legend scrubbing

**Flag** `chronicle_enabled`. **Admin:** `chronicle [n]`, `legends`, `chronicleadd <kind>`, `tavernnow`. **Log:** `chronicle_added`, `legend_written`, `chronicle_told`.

**Not taken:** a legends screen, history before the world's epoch, and songs with authored lyrics (tavern talk is a told line, not music).

---

## 5. Stage 4 needs this decided first: how fallen towns and deaths work across servers

This changes how stage 4 is built, so it comes before the stage designs. Recommended:

- **Agendas are deterministic.** Each world day, `Seed.random(worldSeed, "agenda", day)` picks a few faction and town agendas (a raid, a Wildborn siege, a feud, an alliance, a trade boom), each with a start time and a seeded **unattended outcome**. For example: "the Glenhold siege on day 412: the guards hold, 60%". Every server computes the same history, so a new server boots into the same world. This is how Titans already work.
- **Players change it locally.** If players are present when an agenda plays out live, its outcome on that server is what actually happened. A fallen town that players retake stays retaken until the server closes. That keeps your answer (per server).
- **Deaths are global, recorded on first resolution.** That happens either when the event plays out live, or at the window's end if nobody was there. The first resolution sets `Schemas.Npc.alive = false`, like the first server to fell a Titan. Deaths are capped at **1 per in-game week, world-wide**, only in sieges, raids or Titan passes. A **successor** (a new seeded person in the same household or job) arrives a few days later, so towns never empty. The dead get a legend, and their household and friends grieve and remember who was there.

---

## 6. Stage 2: Things with a past

- **Items:** a unique item involved in a legend gets `h` (the legend's id) and a seeded epithet ("Ashbreaker") from `Data/DeedNames`. The tooltip shows one line: "Broke the Ashwalker at Cinder Ford". NPCs who know the legend recognise it when it's equipped ("Is that the staff that…?"). This uses the greeting hook, alongside Noticing. An item that changes hands keeps its past, and stealing a famous item is talked about.
- **Places:** a legend in the wilds (not in a town) names that spot ("Ashfall Ford"). The name shows on the map for everyone who has uncovered the ground, and NPCs use it in rumours. At most 1 per 400 studs, and each world's legends cap keeps the count low.
- **Monuments:** each town's top legend gets a carved stone near the plaza, built by its own builders the way town repair works (a walk, a hammer, scaffolding). At most one per town, replaced when a bigger legend comes along. Reading it gives one line, not a lore wall.
- **Strange moods** (one, narrow): rarely (at most one per server at a time, about one in-game week apart per town), an NPC mage or craftsperson becomes obsessed. For three in-game days they take over a workshop station, readable as an activity ("obsessed"); they won't talk shop and they barely sleep. Then they make a **named unique item** from their own domain and craft (crafter `c`, epithet). It enters the chronicle. They keep it. You can buy it (dear), be given it (if they love you most), or steal it (a crime, and the town remembers). Interrupting the mood leaves them miserable for a while, and that's remembered too.

**Not taken:** DF's failed-mood madness, artifact demands for specific materials, and item biographies longer than a line.

---

## 7. Stage 3: Losing leads somewhere

When a **non-player** source drops you to 0 (creatures, Wildborn, ferals, event enemies, falling), you're **downed**, not dead. The `HealthFloor` path in `Damage.apply` holds you at 1 with a `downed` status: lying down, slowly losing ground. Then one outcome, chosen by context and seed:

| Where and what | Outcome |
|---|---|
| Wilds, nobody near | You come round where you fell after ~20 s at 25% health. Whatever downed you has moved off. |
| An NPC within reach (townspeople, travellers, hunters) | They carry you to the nearest town's healer: a fade, then you wake in the healer's house. They remember it (`owes_me` on their side, which exists), and thanking them matters to them. |
| Any downing with coins on you | 20–40% of your coins drop **as a purse where you fell**. A passer-by may find it: someone who likes you brings it back next time they see you; someone who doesn't keeps it, and you may overhear about it. **No new bandit enemy.** |
| Deep wilds (260+ studs from a town), by a Wildborn | It drags you to its haunt or lair. You wake there, held among the standing stones while it's near. Getting out takes your own magic, stealth or a fight. If you're stuck for 90 s, it wanders off. |
| No outcome applies | You wake at the spawn, as now. |

**Scars:** what downed you can leave a faint scar through Magic Marks (a new `scar` kind) that fades like any mark. It's a story on your arm, never a stat penalty.

**Anti-grief and policy:**
- Downing by **another player** is a normal death; nothing here applies.
- No outcome twice in a row.
- No capture within 15 minutes of the last one.
- Never gear lost.
- Never slavery or anything that reads as it. Capture means "held", and it never lasts.

**Files:**
- `Server/Downed/DownedRules`
- `Data/DownedTuning`
- `Services/DownedService`
- client `DownedController` (lying pose, screen dim, the fade)

**Flag** `downed_enabled`. **Admin:** `downme <outcome>`, `purse`. **Log:** `player_downed`, `downed_outcome`, `purse_returned`, `purse_kept`, `capture_escaped`.

**Not taken:** lasting injuries with stat penalties, limb loss, being robbed of gear, slavery, and Kenshi's long helpless crawl.

---

## 8. Stage 4: The world acts without you

Built on §5.

- **Agendas** (`Agendas/AgendaRules`, pure; `Data/Agendas`) come from faction and town relations, culture and recent outcomes. They use existing actors:
  - a **Wildborn siege** (WildbornService spawns them near the town; guards fight through NPCCombat; residents shelter through `setLotDown`)
  - a **raid** between feuding towns (their guards meet on the road)
  - an **alliance** (envoys travel; prices and greetings warm)
  - a **trade boom or failure** (prosperity shows in decor and goods)
  
  At most 2 live per server.
- **Fallen town:** buildings are scarred (existing collapse and damage), residents flee to neighbouring towns (they live and talk there, and remember), and Wildborn hold the plaza. It stays that way until retaken (#46), then TownRepair rebuilds. The fallen state comes from §5's deterministic outcome unless players on the server changed it.
- **What players notice:** smoke on the horizon (Omens), refugees on the road and in neighbouring taverns, rumours, a changed greeting. Nothing is announced.
- **While you were away (#47):** your save keeps your last world day. NPCs who know you mention agenda outcomes since then: "You missed it. Larkwell fell to the Wildborn three days back."
- **The world's mood (#57):** a region's mood comes from recent outcomes and feeds barks, prices and how guarded strangers are.
- **Deaths:** as in §5.

**Files:**
- `Server/Agendas/AgendaRules`
- `Server/Agendas/Data/Agendas`
- `Services/AgendaService`
- hooks into WildbornService, NPCService (`setLotDown`, relocation, successor), TownRepairService, OmenService, ChronicleService

**Flag** `agendas_enabled`. **Admin:** `agendas [day]`, `agendanow <kind> <town>`, `townfall <town>`, `townretake <town>`. **Log:** `agenda_started`, `agenda_resolved`, `town_fell`, `town_retaken`, `npc_died`, `npc_succeeded`.

**Not taken:** faction territory maps, war with front lines, player-led armies, and economic simulation beyond what prosperity already does.

---

## 9. Stage 5: Secrets as currency

- **Secrets** (`Secrets/SecretRules`, `Data/Secrets`) are server-authored ids, never text from players. Kinds:
  - the location of a lair or den you don't know
  - a spell recipe an NPC mage knows (from their career)
  - a hidden faction member
  - a feud's real cause
  - a mythic breadcrumb
  - who took a famous item (from stage 2)
  
  Each NPC holds 0–3, seeded from `Seed.random(worldSeed, npcId, "secrets")` plus what they've lived.
- **Trading** happens in existing NPC dialogue (a "trade news" topic, no new screen). An NPC tells you a secret if their trust is high enough, or **in exchange for one you know and they don't**: the water ritual, without the name.
- **Consequences:** spilling a faction's secret to its rival is a faction deed (`secret_spilled`), discovered through gossip like everything else. Scholars value `lore_shared`, which already exists.
- **What you keep:** the player save gets `secrets.known` (at most 60), shown as quiet Journal lines in the first person. Lair secrets uncover that patch of the map, as rumours already do.

**Files:**
- `Server/Secrets/SecretRules`
- `Server/Secrets/Data/Secrets`
- `Services/SecretService`
- an NPCService talk topic
- a FactionService deed

**Flag** `secrets_enabled`. **Admin:** `secrets [npc]`, `secretgive`. **Log:** `secret_told`, `secret_traded`, `secret_spilled`.

**Not taken:** a secrets inventory screen, Qud-style long gospel texts, and #5 or #55 themselves (this only feeds them).

---

## 10. Risks

**Performance:**
- The chronicle is in memory and capped, with O(1) scoring per event.
- Tavern talk reuses RumorService's tick.
- Agendas are at most 2 live and reuse the Wildborn cap of 14.
- Legend writes are batched (1 per 5 min per server) against the shared World record, which every server updates optimistically. If contention shows up, legends move to their own key.

**Exploits:**
- Chronicle farming: diminishing scores, and nothing counts against dummies or duels.
- Purse farming: a dropped purse can only be picked up by NPCs, not players.
- Escaping capture: never forced, 90 s at most.
- Secret trading uses server ids only.

**Privacy:**
- Player names in global legends are erasable (`u` field, `eraseUser`).

**Consistency:**
- §5's split is the riskiest part. It needs a spec proving two servers compute the same day.

**Feel:**
- The quiet Journal option changes how existing Journal lines can be written. Old callers keep toasting unless they opt in.

---

## 11. Open questions

**Need an answer before the stage they affect:**
1. **(Stage 4)** Is §5 right: deterministic agenda outcomes every server shares, live play changes them locally, and NPC deaths are global on first resolution with a successor arriving? Recommended yes.
2. **(Stage 3)** Coins drop as a purse NPCs may return or keep, instead of a new bandit enemy. Recommended yes; bandits can come later if the roads feel empty.
3. **(Stage 1)** Should **all** first-person Journal lines (dreams, omens, weather, sight) go quiet like this work's lines? Recommended yes, since toasts are cards.

**Defaults that will be used unless you say otherwise:**
4. **(Stage 2)** A monument per town for its top legend: yes.
5. **(Stage 3)** The healer carry costs nothing, but the carrier remembers.

---

## 12. Order

Stage 1 (the Chronicle) is the foundation the others read. Then 3 (losing), since it's self-contained and felt early. Then 2 (things with a past, which needs legends to exist). Then 4 (agendas, the largest, which needs §5 answered). Then 5 (secrets). This differs from the prompt's 1-2-3-4-5 only in moving losing forward, because a new player meets losing in their first hour and meets legends much later.
