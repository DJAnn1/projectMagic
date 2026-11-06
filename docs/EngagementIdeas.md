# Engagement ideas (design only, 2026-11-05)

Ideas prompt 3: how to make the game more engaging without a linear story. Nothing here is built or approved.

**The middle ground I'm aiming for:** the world keeps offering, nothing insists. Every idea below is something the game can *notice about you* and respond to, which you can ignore without losing anything. A thread only grows if you pull on it.

**Test for each idea:** if a player ignores it for a month, does anything bad happen to them? If yes, it doesn't belong here.

**Size:** S under a session, M a few sessions, L many. These are my estimates.

**What's already there to build on:** `SituationDetector` and the Narrative Director (pacing), 24 quest templates, 11 factions (3 secret), infamy and bounties, the Journal, NPC memory, gossip and relationships, magical careers in 7-day chapters, 10 world events, POIs and the mythic breadcrumb, housing, items and crafting, the world chronicle shared across servers.

**Known limits these ideas run into:**
- Personal quests can't be shared with a party yet.
- There's no map yet (Improvements.md).
- POIs have no building prefabs.
- There's no economy to spend coins in.
- Most of this has had little play testing, so check that a system works before stacking on it.

---

## The next 5 minutes

### 1. Overheard rumours
- **Hook:** two villagers mutter that something's been glowing in the old delve, and it really is there.
- **Reuses:** NPC gossip, `DialogueEngine`, POIs and their lore hints, `NpcSpeech` bubbles.
- **New:** rumour lines built from real nearby POIs, situations and dens, said as ambient speech.
- **Size:** S–M.
- **Optional:** it's only overheard. Asking the NPC adds a Journal entry; nothing else does.

### 2. People noticed that
- **Hook:** you scorch a dummy, and a kid says "Do that again!" You blast a hill, and the baker asks if that was you.
- **Reuses:** `MagicWitnessed`, NPC memory and quirks, grammar dialogue.
- **New:** a small table of reactions by domain, power and personality, with a cooldown.
- **Size:** S.
- **Optional:** just flavour. Cheapest way to make the world feel like it's watching.

### 3. Trouble at the den
- **Hook:** something's been at the chickens, and the den is 80 studs east.
- **Reuses:** creature dens, `SituationDetector`, beginner quests, quest pins, the `monster_migration` event.
- **New:** a `den_nearby` situation and 2–3 templates. Also gives creatures a reason to be hunted.
- **Size:** S.
- **Optional:** an ordinary offer.

### 4. The notice board tells the truth
- **Hook:** read the board and see what's actually wrong in town right now.
- **Reuses:** the notice board interactable, situations, the Journal.
- **New:** a screen listing this town's live situations and who's asking, with an accept button.
- **Size:** S–M.
- **Optional:** you have to walk up to it. Replaces some pushed offers.

### 5. Your Path
- **Hook:** the Journal suggests three things that suit you: "Your Water runs deep. Have you tried it on fire?"
- **Reuses:** innate profile (visible parts only), `Experiment.suggest`, tier rules, Journal. This is the leftover from early-game item 4.
- **New:** a small picker of three soft goals, refreshed as you do them.
- **Size:** S–M.
- **Optional:** never required, gives no reward lock, and can be hidden.

### 6. A map
- **Hook:** you can see where you are and where the den, yard and mentor are.
- **Reuses:** `WorldIndex`, POI discovery records, quest pins, `PoiMarkers` (planned, see the backlog in `CLAUDE.md`).
- **New:** a map screen showing only what you've discovered.
- **Size:** M.
- **Optional:** it's a tool. **Most of the ideas below get much better once this exists.** Hidden mythic sites must never be sent to it.

---

## One session (about an hour)

### 7. Dreams about your own magic
- **Hook:** after you rest, a vague dream: "Water, and something under it that isn't water."
- **Reuses:** latent potentials, the 30 awakening events, self-knowledge levels, beds, Journal.
- **New:** dream lines keyed to your profile, with vagueness set by your knowledge level.
- **Size:** M.
- **Optional:** it's a hint, not a task.
- **⚠ Forced-story risk: low, but a secrets risk.** Hidden latents must not reach the client. The server sends only finished, vague text, and a line must not be precise enough to confirm a mythic latent.

### 8. A rival who remembers
- **Hook:** the mage you beat last week has been practising, and tells you so.
- **Reuses:** `proud_rival` situation, NPC careers and chapters, memory, `NPCCombat` duels, relationships.
- **New:** one NPC tagged as your rival after a duel, with lines that use your shared history, and a rematch offer each chapter.
- **Size:** M.
- **Optional:** decline a few rematches and they lose interest.
- **⚠ Forced-story risk: medium.** Must never ambush you or block anything. They ask; you answer.

### 9. A mentor who follows your growth
- **Hook:** the mentor who taught you to Scorch sees you at Adept and says "I never showed you that."
- **Reuses:** town mentors, `awardStudy`, `taught_me` memory, relationships, teaching hints.
- **New:** lines and small gifts on your tier-ups, and a referral to a better mentor once you pass them.
- **Size:** S–M.
- **Optional:** you visit when you like.
- **Note:** tune mentor XP first. It looks oversized (EarlyGamePlan §10).

### 10. Clear it or leave it
- **Hook:** clear the rat den and the road is safe and the town thanks you. Leave it and it grows.
- **Reuses:** creature dens, reputation, faction deeds, the population budget.
- **New:** den health per server, and a small growth rule with a cap.
- **Size:** M.
- **Optional:** dens never leave their leash, so ignoring one costs you nothing personally. Others can clear it.

### 11. While you were away
- **Hook:** you ignored the drought, and now the well is dry and the farmer has left. It didn't need you, but it mattered.
- **Reuses:** situation escalation, NPC solving, quest outcomes, `settlement` deltas.
- **New:** a short Journal digest when you return: what ended without you and how. No guilt, just news.
- **Size:** S–M.
- **Optional:** it's a report only, never a penalty.

### 12. Sparring circles
- **Hook:** a ring on the plaza where a fight is friendly, and people stop to watch.
- **Reuses:** `QuestSanction`, the `pvpMaxShare` cap, spellblade, guards, practice yards.
- **New:** a marked zone where hits don't count as crimes, knock-outs instead of deaths, and a simple tally.
- **Size:** M. Also answers the open question about whether the spawn plaza should be no-PvP, by giving fighting its own place.
- **Optional:** walk in to take part.

### 13. Crisis roll call
- **Hook:** when the wildfire ends, the Journal says who helped and how, and the town remembers each of you.
- **Reuses:** shared crisis quests, `QuestEnded`, faction deeds, relationships.
- **New:** contribution tracking with a short shared summary, and approach credit (the healer counts as much as the water mage).
- **Size:** M.
- **Optional:** you join by turning up.

### 14. Bring a friend on your quest
- **Hook:** you're on a personal quest and your friend can walk it with you.
- **Reuses:** personal quests, objectives, rewards. `docs/Quests.md` already lists this as unbuilt.
- **New:** party sharing with split credit.
- **Size:** M–L.
- **Optional:** yes. Probably the biggest gap for co-op.

---

## Weeks

### 15. You're on the map now
- **Hook:** that canyon you made has a name, on every server, and strangers ask about it.
- **Reuses:** persistent ruptures, the chronicle, `MessagingService`, filtered names, NPC gossip. Pairs with MagicIdeas #18.
- **New:** named places in the chronicle and on the map, plus NPCs who mention them.
- **Size:** M.
- **Optional:** it comes from your own actions. Also the strongest proof of "one world, many servers".

### 16. Towns that change
- **Hook:** the village you helped has a new market stall and your name on a plaque. The one you burned has guards and a grudge.
- **Reuses:** settlement deltas, reputation, `SettlementDecor`, NPC town saves.
- **New:** a small set of visible decor changes driven by saved town state.
- **Size:** M–L.
- **Optional:** the world responds whether or not you care.

### 17. Apprentices
- **Hook:** a newcomer asks you for a lesson. You teach, they grow, and you get credit forever.
- **Reuses:** `awardTeaching`, the mentor channel, `taught` records, "teach" breakthrough requirements (already in the data).
- **New:** a player-to-player lesson flow, and a Journal line for each student you've taught.
- **Size:** M.
- **Optional:** either side can decline. Reduces the loneliness of a new player's first hour, and gives veterans a reason to stay near spawn.

### 18. Goals you set yourself
- **Hook:** pin "Reach Adept in Water" or "Find the old delve" or "Get on good terms with the Tide Temple."
- **Reuses:** progression, POI discoveries, factions, Journal, quest pins.
- **New:** a goal list with a data-driven set of trackable things, and a small flourish on finishing.
- **Size:** S–M.
- **Optional:** entirely yours, with no reward needed beyond the flourish. The most direct answer to "goals players set themselves".

### 19. A home that tells your story
- **Hook:** visitors see your wisp mote on the shelf, a dented dummy, and your signature burning in the hearth.
- **Reuses:** housing, furniture placement, the new creature materials, signature colours.
- **New:** trophy items from milestones, and a way to invite or visit.
- **Size:** M.
- **Optional:** housing already is. Gives the new creature materials a use.

### 20. Secret factions find you
- **Hook:** after your third old inscription, a stranger says, "You read them too." Now you know the Seam Keepers exist.
- **Reuses:** the 3 secret factions, mythic hints, `journal.revealed`, deterministic membership.
- **New:** contact conditions read from your own actions, one conversation, and an invitation.
- **Size:** M.
- **Optional:** you can turn them down, and most players never meet them.
- **⚠ Forced-story risk: medium.** The Quiet Hand already hunts mythic users automatically (*Quiet Footsteps*). That's the one existing system closest to a forced story, so check it feels fair in play.

### 21. Mythic sightings
- **Hook:** you'll probably never have Time magic. But one day you see someone who does.
- **Reuses:** NPC mythic awakenings, chronicle entries, Omens (MagicIdeas #26), gossip.
- **New:** a rare, visible NPC moment and rumours that follow it.
- **Size:** M.
- **Optional:** you just witness it. Answers Improvements' finding that mythic magic has "nothing to see".

### 22. The world's mood
- **Hook:** this week, the whole island has been unusually stormy, and Air mages are thriving.
- **Reuses:** global events, the World store, `EnvironmentRules`, Weather as fuel (MagicIdeas #6).
- **New:** a slow seeded world state shared by every server, shown in the Journal.
- **Size:** M.
- **Optional:** it changes odds, never access. **Nothing may be available only this week**, or it becomes pressure to log in.

### 23. A letter on your return
- **Hook:** back after a month, and there's a letter from your mentor, who's a Master now. Your rival moved to Coldfall.
- **Reuses:** NPC chapters, relationships, the digest from #11, mail through the Journal.
- **New:** a return letter built from what really changed for people you knew.
- **Size:** S–M.
- **Optional:** a nice surprise on return. **No login bonus or streak attached.**

---

## Left out on purpose

| Idea | Why not |
|---|---|
| Daily login rewards and streaks | They create obligation rather than interest. |
| Limited-time content | Fear of missing out. It clashes with a world you return to on your own terms. |
| A main quest, even a soft one | You asked for no linear story. |
| Required tutorials or chains | Against "I don't want to restrict anything for the player." |
| Leaderboards as a main goal | They'd push people toward grinding, the thing anti-grind rules fight. Might suit duels later. |
| Anything paid | A standing decision. |

---

## Top 5

| # | Idea | Why | Size |
|---|---|---|---|
| 1 | **People noticed that (#2)** | Almost nothing to build, and it changes how every minute feels: your magic has an audience. | S |
| 2 | **A map (#6)** | Not exciting alone, but rumours, dens, mentors and pins all depend on being able to find things. | M |
| 3 | **Overheard rumours (#1)** | Directly turns "what do I do now?" into curiosity, and leans on existing systems. Best after the map. | S–M |
| 4 | **Goals you set yourself (#18)** | The clearest middle ground between sandbox and guidance: direction with no story at all. | S–M |
| 5 | **A rival who remembers (#8)** | The first NPC relationship that really feels personal, and the idea most likely to make people talk about the game. | M |

**Just outside:** Apprentices (#17) is the best social idea and worth doing once there are real players to pair up. Bring a friend (#14) matters as soon as people play together.

**Suggested order:** #2 now, since it's cheap. Then #6, #1, #18, #8. Roadmap note: `docs/Roadmap.md` says to freeze features until a vertical slice is verified, and these are your call against that.

**Magic and engagement together:** Sense (MagicIdeas #22) and rumours both point at the same hidden things, so a shared "what's nearby and interesting" source would serve both. Landmarks (MagicIdeas #18) and *You're on the map now* (#15) are the same feature seen from two sides.
