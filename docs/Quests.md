# Quests, factions and the Narrative Director

**Status:** written 2026-11-03. Everything builds (`rojo build`, clean diagnostics) but **nothing has run in Studio yet**. There is no main story. Every quest is read off the simulation: world state, NPC lives, events and the player's own standing.

```
WorldStateService ─┐   NPCService ─┐   EventDirector ─┐   ReputationService ─┐
 (stress, density,  │   (goals,      │   (drought, fire,  │   (bounties,          │
  ore, relations)   │    secrets,    │    plague, tempest)│    notoriety)         │
                    └──────────► Quests/SituationDetector ◄────────────────────────┘
                                         │ situations (deterministic ids)
                                         ▼
          Quests/Data/QuestTemplates ─► Services/QuestDirector ◄─ pacing: tension, focus, novelty
                                         │  offers / shared crises / quests in progress
           SpellResolved · NpcTalked · TargetDamaged · positions │
                                         ▼
               outcomes ─► rewards (XP, lore, currency, awakening rolls)
                        ─► world (relief, prosperity, stress, relations, NPC mastery, events)
                        ─► FactionService / ReputationService ─► JournalService ─► Journal (J)
```

| File | Role |
|---|---|
| `server/Quests/QuestTypes` | the schema (types only) |
| `server/Quests/Data/QuestTemplates` | 18 templates |
| `server/Quests/Data/Factions` | 11 factions, ranks |
| `server/Quests/Data/QuestTuning` | every number |
| `server/Quests/SituationDetector` | world, NPC and player scans |
| `server/Quests/QuestFactory` | template + situation → quest (slots, text) |
| `server/Quests/Objectives` | pure objective rules, creative recognition |
| `server/Services/QuestDirector` | pacing, offers, progress, outcomes, persistence |
| `server/Services/FactionService` | membership, witnesses, deeds, guards |
| `server/Services/ReputationService` | standings, infamy, bounties, notoriety |
| `server/Services/JournalService` | the player's log, journal tabs |
| `client/Controllers/JournalController` | the Journal screen (J) |
| `server/Admin/Commands/…` + service registrations | quest and faction admin tools |
| `server/Tests/Quest.spec` | template consistency, factions, objectives |

## 1. Situations: where quests come from

A **situation** is a true fact about the simulation that a story could grow from. Its id is `"<kind>:<subject>"`, so the same condition is the same situation on every scan, and nobody can be offered the same story twice for it.

| Kind | Read from | Typical template |
|---|---|---|
| `tunnel_collapse` | mine POI tectonic stress ≥ 0.55 + a miner in the nearest town | The Shut Seam |
| `drought` / `ley_shift` | drought event over a town / the town's ambient density < 0.55 | Low Water |
| `tremors` | stress under a town ≥ 0.65 | The Ground Is Restless |
| `flood` | tempest over a coastal-culture town | Rising Water |
| `wildfire`, `plague` | those events over a town | Firefront, The Coughing Sickness |
| `dispute` | settlement relation < −0.35 | Bad Blood |
| `forbidden_experiment` | NPC aged 14–35 with secret `forbidden_dabble` or the `forbidden` ambition | The Quiet Student |
| `npc_goal_commission` / `npc_goal_journey` | NPC goals and ambitions | Supplies for a Commission / The Road to … |
| `proud_rival` | pride > 0.7, mastery tier ≥ 2 | A Matter of Pride |
| `debt_trouble` | NPC secret `debt` / `thief` | The Other Ledger |
| `rogue_mage` | `npc.magic.rogue` | Contract: … |
| `wants_teacher` *(player)* | an NPC within 120 studs whose focus branch you're 2+ tiers ahead in | A Student of … |
| `lore_gap` *(player)* | a sub-branch whose **only** unmet unlock condition is its treatise | The Missing Treatise |
| `mythic_trail` *(player)* | you hold a `hint:<mythic>:*` but no fragment for that domain | Something Older |
| `wanted` *(player)* | a bounty on you | Settling Accounts |
| `mythic_notoriety` *(player)* | mythic notoriety ≥ 35 | Quiet Footsteps |

**Cost:**
- Settlement and mine checks are a few dozen lookups.
- NPCs are scanned round-robin, 60 per pass, so 300 NPCs cost no more than 60.
- The pass runs inside a Scheduler job with checkpoints.

**Secrets:**
- Nothing reads a player's hidden latents.
- Hidden POIs (mythic sites) are never quest targets.
- Mythic trails start only from hints the player already found.

## 2. The template schema (`QuestTypes`)

```lua
Template = {
  id, type,                 -- delivery rescue investigation escort duel teaching research crisis
                            -- diplomacy heist mythic hunt atonement hunted
  title, summary,           -- text with {slot} placeholders
  giver?, scope,            -- "personal" (saved with the player) | "shared" (server crisis, anyone helps)
  situations = { kinds },   -- what it can grow from
  weight, domains,          -- base weight; focus affinity (metal mage → earth/energy work)
  intensity, difficulty,    -- 0..1 pacing; {minTier, maxTier} it suits
  requires?,                -- { domains, minTier, lore, currency, reputation } to be offered at all
  slots = { name = { kind, from? | pick?, optional? } },
  stages = { { id, text, hours?, failOnDeath?, options = {
      { id, label, approach,           -- talk force magic stealth creative wait trade
        requires?,                     -- only HIDES the option; doing it anyway still counts
        objectives = { ObjectiveSpec }, ordered?,
        outcome? | next? } } } },
  outcomes = { id = { text, success, rewards?, world?, memory?, followUp? } },
  failOutcome, expireHours,            -- game hours (WorldClock; 1 game hour = 60 s by default)
  escalation?  = { afterHours, event?, text, outcome? },  -- unattended, it grows
  npcSolve?    = { chancePerHour, outcome },             -- NPCs get there first
  complications? = { { id, text, afterStage?, chance, effect } },
  protect?, protectOutcome?,           -- NPCs that must survive (quest-warded)
  spawns?, autoStart?, holds?,         -- NPCs made for it; not optional; NPCs pinned to a place
  cooldownHours,
}
```

**Objectives** (`kind`):

| Kind | Completes when |
|---|---|
| `talk` | you talk to the target NPC. `args.gives` hands you a quest item |
| `reach` | you spend `seconds` within `radius` of `at` |
| `cast` | spells within `radius` reach `amount` total recipe power (or `count` casts). See below |
| `subdue` | the target drops to `share` health or is knocked out. Duellists **yield**; they never die |
| `escort` | the NPC follows you (leash) to `at` |
| `collect` | you dwell at `at` and pick up `item` (quest-only: never enters the economy) |
| `deliver` | you talk to the target while carrying `item` |
| `demonstrate` | you cast the student's branch near them `count` times, `spacingHours` apart |
| `wait` | `hours` of game time pass |
| `witness` | world event `event` is active at `at` while you're there |
| `pay` | you hand the target `amount` currency (or the `args.amountSlot` slot's value) |
| `state` | a world predicate holds (`night`, `eventEnded`) |

**Casts** are matched in two ways:
- **Matched solutions** (`match`): domains, properties, verbs, forms, routes, branches (with ancestors), harmful, min and max power. These earn full progress.
- **Creative solutions** (`needs`): a cast whose **interaction tags** (`InteractionMatrix.tagsFor`: water, ice, cold, stone, fire, wind, light, null, life…) meet the problem's needs earns 75% and is logged as *a creative solution*.
  - Freezing a flood, stone firebreaks and dousing fire with a cold front all count, and nobody had to list them.

Casts that hit nothing and changed nothing never count, so spamming at the air does nothing.

**Unseen** (heists): an awake NPC within 14 studs for 1.5 s notices you, and the option ends at its `onNoticed` outcome. Night halves the radius, and the Veil status quarters it.

**Rewards:**
- `xp`: `best:<domain>`, a branch slot, or a branch id; study channel, so daily caps and focus apply.
- `lore`: e.g. `treatise:{branch}`, `fragment:{fragment}`.
- `currency`.
- `awakening`: a mythic awakening roll seeded per quest, so it can't be rerolled.
- `relationship` with the giver, plus a `memory` they gossip about.
- `reputation`: faction ids or `"settlement"`.
- `infamy`, `bounty`.

**World consequences:** relief or ending of the situation's event, startEvent, prosperity (ore folds in), tectonic stress ±, a day of density, relation drift between two towns, NPC mastery, NPC awakening, revealing a secret faction, clearing a bounty, mythic notoriety.

### The 18 templates

| # | Template | Type | Scope | Ways through |
|---|---|---|---|---|
| 1 | The Shut Seam | crisis/fetch | personal | shape rock · shore with pillars · hire a crew · blast (caves it in) |
| 2 | Low Water | crisis | shared | call water · mend the ley · escort the priest's rite · drought-hardy crops |
| 3 | The Quiet Student | rescue + investigation | personal | ask/search or sense traces → unmake · talk down · subdue · *join the choir* |
| 4 | Supplies for a Commission | delivery | personal | fetch · League standing · forge it yourself (creative) |
| 5 | The Road to … | escort | personal | escort (ambush complication) · buy caravan fare |
| 6 | A Matter of Pride | duel | personal | accept or walk away → win · win by misdirection |
| 7 | A Student of … | teaching | personal | 3 spaced lessons → watch them · let them find it alone |
| 8 | The Missing Treatise | research | personal | search + sense the archive · buy a copy · derive it by experimenting |
| 9 | The Ground Is Restless | crisis | shared | ease stress gently (≤ P4) · brace the town · evacuate · trigger it (bad) |
| 10 | Rising Water | crisis | shared | sea wall · freeze · turn the tide (+ creative tags) |
| 11 | Bad Blood | diplomacy | personal | broker · calm with Mind (Scholars object) · deliver an ultimatum |
| 12 | The Other Ledger | heist | personal | unseen · bribe · report the client |
| 13 | Something Older | mythic | personal | keeper → tower → witness the sky / night vigil (Quiet Hand complication) |
| 14 | Contract: … | hunt | personal | subdue · persuade to surrender · warn them |
| 15 | Firefront | crisis | shared | douse · firebreak · turn the wind · wait it out |
| 16 | The Coughing Sickness | crisis | shared | heal · purify water · fetch the remedy |
| 17 | Settling Accounts | atonement | personal | pay the fine · work it off |
| 18 | Quiet Footsteps | hunted (auto) | personal | fight · reach sanctuary · parley |

## 3. Three quests, start to finish

### A. "The Shut Seam": earth, from a quake nobody meant

**World state.**
- Two hours earlier, a player cast `seismic generate burst P6` near Ironhollow (forgehold), which raised tectonic stress at the nearby mine to 0.61.
- The scan finds `tunnel_collapse:mine_3`: stress ≥ 0.55, and Bram Coalby, a miner, lives in Ironhollow.
- Severity is 0.61.

**The Director (player Ada, alloycraft tier 4, ~70% of recent XP in earth):**

| Factor | Value |
|---|---|
| focus | 0.6 + 1.6 × 0.7 = 1.72 |
| novelty | 1 (never done) |
| tension | 0.3 → "rising"; wants intensity 0.6, the template is 0.4 → pacing 0.75 |
| power | tier 4 is inside 1–6 → 1 |
| distance | 400 studs → 0.71 |

The score is about 1.0, the highest candidate. Ada sees: *"A tunnel collapse at the mine has trapped Ironhollow's ore shipment. (talk to Bram Coalby)"*.

**Stage "hear":** she talks to Bram ("About the trouble") and moves to **"clear"**, which has four options.

**How the solution depends on her magic:**
- **Ada (earth):** `geomancy contour reduce burst P4` × 4 casts = 16 ≥ 14 → **cleared**.
  - She gets 400 XP to her best earth branch, 60 currency, Bram's affinity +0.15 and the memory *helped_me*.
  - The Smiths' Guild gives +60. That spreads to the Wayfarer League (+9), the Concord (+12) and the Scholars (+3), and costs −11 with the Hollow Choir, their enemy.
  - Ironhollow's prosperity rises by 2.75.
- **Ada's friend Bo (air):** air `momentum generate`. It doesn't match the listed shaping properties, but its tag `force` meets `needs = { stone, force }`. It counts at 75%, and the log reads *"A creative solution…"*.
- **Cy (fire):** has no earth.
  - The **crew** option is visible to anyone: talk to Pell the builder, pay 40, wait 2 game hours.
  - The **blast** option is visible too. A P5 harmful cast completes it, but the outcome is **caved**: stress +0.2, ore −0.3, Smiths −40, and Bram remembers *harmed_town*.
- **Nobody:** after 30 game hours the escalation fires (*"the forges are going cold"*), prosperity −1.5. Each hour there's a 3% chance the miners dig themselves out first (*locals*).

### B. "Low Water": a shared crisis anyone can join

**World state.**
- A Void mage has spent an evening draining aether at Saltmere's nexus, and the density modifier there sits at 0.42.
- The scan finds `ley_shift:saltmere` (severity 0.58). The template is **shared**, so the Director starts it at once.
- Everyone within 1,400 studs sees *"Saltmere's reservoir is drying out since the ley line shifted"* under **Trouble nearby**.

**Four players arrive:**

| Player | Does | Counts as |
|---|---|---|
| Dee (water) | `hydromancy humidity generate burst P5` × 3 at the wells | 15 toward the 25 needed (matched) |
| Eli (space) | `distance amplify zone P4` × 2 | the **ley** option (8 / 18) |
| Fay (ice) | `phase reduce` | tags `ice`, not `water` → nothing (the reservoir needs water, not ice) |
| Gus (no magic) | talks to Maris the tide-priest, then escorts her to the wells | the **rite** option |

Dee finishes "call" first (25), so the outcome is **refilled**:
- The relief ends the drought if there's one.
- Prosperity +2, settlement +30, Tide Temple +40, Verdant +20.

**Rewards** use contribution:
- Dee contributed 25 and Eli 8 (8/25 = 0.32 ≥ 0.15), so both are rewarded. Eli's share is clamped to 0.4.
- Gus's escort was unfinished, but still added a little contribution. He gets 0.4 of the rewards if his contribution is ≥ 15% of the top, else nothing.
- Fay gets nothing. Contributions come only from progress.

**If nobody comes:**
- At 12 game hours, the escalation starts a **wildfire** event at Saltmere.
- The next scan finds `wildfire:<event>:saltmere`, so **Firefront** begins: the crisis has spiralled without the players.
- Each game hour there's a 4% chance Saltmere's farmers and tide-priests relieve the drought themselves (*locals*). The quest closes as "solved by others" with no rewards, and the world still mends.

### C. "The Quiet Student": Void, an NPC secret becoming a story

**World state.**
- Ilsa Thornwick, 17, in Quillhaven (loreseat), carries the generated secret `forbidden_dabble` and void tier 1.
- The NPC scan produces `forbidden_experiment:<ilsa>`.
- `worriedOne` resolves to her father Aldric (same household). `nearPoi:dungeon,ruined_library` resolves to the Drowned Stacks, 600 studs out.
- On acceptance, `holds = { apprentice = "ruin" }` leashes Ilsa there (for T2 she simply *is* there).

**Stage "trail":**
- **Ask:** talk to Aldric, then search her room (5 s at `npcHome:apprentice`).
- **Or sense:** any `sense` verb at her room.
- Either leads to **"ruin"** (24 game hours).

**Stage "ruin"**, by player magic:
- **Hal (Void, spirit):** reach the ruin, then `aether reduce` (or anything with the `null` / `light` tag), total power 10 → **rescued**.
  - Void XP, Ilsa +0.25 and *saved_me*, Scholars +40.
- **Ivy (Mind):** reach the ruin, then talk to Ilsa → **talked_down**.
- **Jon (Kinetic):** the **subdue** option.
  - Within 40 studs the Director sets `QuestSanction` on Ilsa (Jon's hits aren't crimes) and `NPCCombat.challenge`.
  - Ilsa *fights back* with a bolt of her own magic (her best branch's domain → the first property that validates for her, e.g. Void `essence generate projectile`).
  - At 30% health she yields → **dragged_home**.
- **Kay (Void, curious):** casts Void beside her twice → **joined**.
  - The Hollow Choir is **revealed** in Kay's journal, Choir +120, Scholars −60.
  - The *follow-up* is a `rogue_bounty` contract, which the Director may offer later. The story turns.

**If nobody comes:**
- At 24 game hours a **magic storm** starts at the ruin.
- On expiry the outcome is **lost**: Ilsa's void mastery +15.
- A stronger Ilsa can later turn rogue (NPCMagicLife) and become a `rogue_mage` situation, so the next player meets her as **Contract: Ilsa Thornwick**.

## 4. The Narrative Director (pacing)

- **Tension** (per player, 0..1, saved):
  - Rises with damage, failed quests and crises nearby.
  - A completed quest releases 0.2.
  - Decays 0.02 per minute.
  - **calm** (< 0.25) wants quiet quests (0.3), **rising** wants 0.6, **peak** wants set pieces (0.9).
  - Complications fire 0.3× when calm and 1.6× at peak.
- **Focus:** the share of your recent XP (`progression.focus`) in a template's domains gives ×0.6 … ×2.2. It is never zero, so a metal mage mostly sees forge work but still meets the duel, the student and the dispute.
- **Novelty:** ×0.45 per repeat of the same template among your last 10, and ×0.75 per recent quest of the same *type*. Cooldowns per template stop farming.
- **Power:** inside the tier band ×1; below it ×0.5 per tier short; above it ×0.6 per tier over.
- **Distance:** for world situations, linear to 0 at 1,400 studs. Player situations ignore distance.
- **One offer** per check at most:
  - Each player is checked once per 45 s (staggered across the server).
  - Up to 3 open offers and 5 active quests.
  - The draw is weighted, from `Seed.random(worldSeed, "player:<id>", "director", n)`.
- **Set pieces:**
  - Escalations start real EventDirector events.
  - Complications spawn hostiles (with QuestSanction) or start events.
  - Mythic chains wait for real eclipses and starfalls.

## 5. Factions and reputation

| Faction | Kind | Members | Watches | Notably |
|---|---|---|---|---|
| Smiths' Guild | guild | smiths, miners, builders | forgehold, emberclan | likes earth; theft −120 |
| Scholars' League | academy | scholars | loreseat | **Mind magic on people −60**; forbidden −50 |
| Tide Temple | cult | tide-priests, fishers | tidecall, frostfolk | water + relief |
| Verdant Circle | order | herbalists, healers, farmers | verdant | healing +, burning land −60 |
| Skywardens | order | weathercallers | skywarden | air |
| Wayfarer League | league | merchants, innkeepers | wayfarer | deliveries, diplomacy; theft −150 |
| Hunters' Lodge | hunters | hunters | anywhere a member sees | bounties claimed |
| Island Concord | government | guards | every town | crimes, **bounties**, knockouts −300 |
| Hollow Choir | cult, **secret** | forbidden dabblers (50%) | where members see | likes Void |
| The Quiet Hand | **secret** | 6% of guards, hunters, scholars | — | hunts Mythic users |
| Seam Keepers | **secret** | 8% of retired, scholars, tide-priests | — | keep mythic breadcrumbs |

- **Membership** is deterministic per NPC (`Seed.random(worldSeed, npcId, "faction:<id>")`).
- **A deed counts** in the faction's territory, near a living member (60 studs), or when it's "always known" (quest outcomes, knockouts of members).
- **Gains** spread to allies (+50% × relation) and **losses** to enemies (−30% × |relation|).
- **Esteem** (what a faction thinks of your domain's magic) is rate-limited to ±30 per faction per 10 minutes, so it can't be farmed.
- **Ranks:** Hated −600 · Hostile −300 · Unfriendly −100 · Neutral · Friendly 100 · Honored 300 · Revered 600.

**Crime, infamy, bounty, guards:**
- A crime is unlawful magic judged by the town (`judgeCast`) or harm to an NPC.
- It adds infamy (×0.6 of the reputation lost, decaying 1.5 per real hour) and costs Concord standing.
- At infamy ≥ 25 the Concord posts a bounty in that town (12 per point of severity).
- At infamy ≥ 40, the town's guards within 45 studs **fight you on sight**.
- **Settling Accounts** (pay, or work it off) clears the bounty.
- **This answers the open question "guards, bounties, banishment?"** with guards and bounties. Banishment is not built.

**Mythic notoriety:**
- Every Time, Gravity or Reality cast that anyone (player or NPC) sees within 60 studs adds +2 to that domain's notoriety (decaying 0.5 per real hour).
- At 35, **Quiet Footsteps** starts on its own: a Quiet Hand hunter is spawned on you.
- Fighting reveals the Hand. Parley earns their tolerance (+60, notoriety −25). Sanctuary loses them.
- **Proposed answer to "where does `fragment:` knowledge come from?":** the mythic breadcrumb chain (*Something Older*), fed by the hints POIs already grant, plus the Seam Keepers.

## 6. Persistence and how quests touch the simulation

| Data | Lives in | Survives |
|---|---|---|
| personal quests (active, offers), finished (30), history, recent, tension, follow-ups | `PlayerData.quests` | sessions and servers (NPCs and places are deterministic, so the same NPC exists everywhere) |
| journal log (200), revealed secret factions | `PlayerData.journal` | the same |
| faction standings, infamy, bounties, notoriety | `PlayerData.factions/infamy/bounties/notoriety` | the same |
| shared crisis quests, contributions, situations | QuestDirector memory | this server only: a crisis is per-server live state, like world events |
| consequences | settlement deltas (prosperity, relations), terrain/stress, NPC mastery and memories | global (additive deltas merge across servers) |

New save fields arrive through `reconcile`. No schema bump was needed, because no existing data changes shape.

**How quests touch the simulation:**
- **Read:** stress, density, ore, relations, events, NPC goals, secrets, ambitions, rogue status, households, homes, workplaces.
- **Written** through public APIs only:
  - EventDirector start/stop (relief, escalation);
  - WorldStateService settlement deltas, stress and modifiers;
  - NPCService (`setLeash` follow/hold, `questBond` relationship + gossip memory, `setMastery`, `awaken`, `spawn`/`remove`, `setTalkHook`);
  - NPCCombat `challenge`/`disengage`;
  - ProgressionService `awardQuest`;
  - InnateProfile `applyAwakening`.
- **NPCs act on their own:**
  - `npcSolve` lets locals finish what players ignore.
  - The existing relief system (farmers in a drought) ends events, and the shared quest closes as *solved by others*.
  - Failed rescues make stronger, sometimes rogue NPCs, which become new situations.
- **Talking:** quest givers show **"About the trouble"** in NPC dialogue. Talking accepts their offer, and later shows the current step.

### Map pins (`client/Controllers/QuestPinsController`)

There is no map screen yet, so pins are drawn in the world.

- **What gets a pin:** every objective you can act on *now*. An ordered option pins only its next step, hidden options never get a pin, and people are pinned where they currently stand.
- **Markers:** ◆ marks the tracked quest, ◇ the others, and ▼ a person. Each shows its distance, and the objective text appears for the tracked quest or within 80 studs.
- **Arrow:** an edge-of-screen arrow (with distance) points to the tracked quest's nearest pin whenever it's off-screen.
- **Tracking:** a newly started quest is tracked when nothing else is. The Journal's Track button changes it.
- **Data:** `QuestPins` pushes go only to their owner. The server checks every 2 s and sends only changes, at most 10 pins.
- **Setting:** *Quest markers* (On/Off).

## 7. Multiplayer: anti-grief and anti-exploit

- **Personal vs shared state:**
  - A personal quest's progress is yours alone; the world it touches is shared.
  - Crises are shared on purpose, so everyone helps and the contributors are rewarded.
  - There is no instancing of places.
- **Griefing someone else's quest:**
  - Escorted and protected NPCs carry `QuestWard = owner`: other players' damage does nothing (`Damage.apply`).
  - A knocked-out protected NPC still fails the quest, but only NPC enemies can do it.
- **Duels and quest hostiles** carry `QuestSanction = owner`. The owner's hits on them aren't crimes and don't cost faction standing. Anyone else's hits still are.
- **Leeching shared rewards:** you're rewarded only with ≥ 15% of the top contributor's progress. Shares run from 0.4 to 1. Ineffective casts give no progress.
- **Farming:**
  - Per-template cooldowns, the novelty penalty, and situation ids mean one situation is one quest per player.
  - Abandoning counts as failure (history + tension).
  - Awakening rolls are seeded per quest id, so retrying can't reroll them.
  - Esteem gains are rate-limited.
  - Quest items (`crate`, `ledger`, `herb`) live only in quest state and never enter the inventory or economy.
  - Currency rewards can't go below zero.
- **Client trust:**
  - The client sends only `RequestJournal(tab, page)` and `QuestAction(id, accept|decline|abandon|track)`, rate-limited and validated.
  - Every progress event comes from server topics (casts the server resolved, talks it checked for distance, damage it dealt).
- **Secrets:**
  - Hidden POIs are never quest targets.
  - Latents are never read; awakening rolls only reveal what's there.
  - Secret factions stay hidden in the journal until revealed.
  - The world seed never leaves the server.
- **Budgets:**
  - At most 6 shared quests per server and 120 situations.
  - The NPC scan does 60 NPCs per pass.
  - Polling runs at 1 Hz per player over their own quests.
  - Spawned NPCs are removed when the quest ends or the owner leaves.

## 8. Not built yet / open

- A guards-and-banishment layer beyond bounties.
- Bounty contracts for *other players* (NPC hunters only, since PvP is off by default).
- **Party sharing of personal quests.**
- **NPC-vs-NPC aggro:** NPC bolts have no source.
- **Combining Journal tabs with the designed People and Discoveries tabs** (UI.md §4.7).
- **Real inventory items as rewards.**
