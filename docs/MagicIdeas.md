# Magic ideas (design only, 2026-11-05)

Ideas prompt 2: 28 ways to make the magic more fun, each tied to what exists. Nothing here is built or approved. No paid features, no classes, everything generated stays seeded.

**How to read an entry**
- **Fit** says what it takes: *data* (new table entries), *resolver* (new effect code) or *system* (a new service or remote).
- **Cost** is server cost at 30–60 players.
- **Size:** S under a session, M a few sessions, L many. These are my estimates, and nothing has been prototyped.

**What's already there to build on:** 10 verbs (generate, amplify, reduce, transfer, redirect, transmute, bind, sense, store, release), 11 forms, 10 modifiers, 16 `InteractionMatrix` reactions, 22 statuses, fields, hold to charge, guards and parries, spellblade, discoveries, signature spells.

**Known gaps these ideas lean on:**
- Mutations are only logged (`mutation_rolled`).
- `Prompts-MagicCombat` #8 (mutations) and #9 (weaving) are written but not built.
- The `linked` modifier has a description, but I didn't find it read in `CastService`. Check the resolvers before relying on it.

---

## Combos between players

### 1. Marks and detonators
- **Fantasy:** I soak them, you bring the lightning.
- **Fit:** data + small resolver. New statuses (Soaked, Brittle, Floating) and `InteractionMatrix` entries that read them. This is the core of `Prompts-MagicCombat` #9. Size M.
- **Mastery:** higher tiers leave longer marks and detonate harder.
- **Cost:** a little per target, using the existing status tick.
- **Exploit:** stun-locks in PvP. Give detonations diminishing returns per target.

### 2. Ritual circles
- **Fantasy:** five of us stand in a ring and do something none of us could alone.
- **Fit:** system + resolver. The `ritual` form accepts other casters, whose power adds with falling returns. Size L.
- **Mastery:** the leader's tier sets the ceiling, so a Grandmaster leading novices is a real event.
- **Cost:** low, since it's rare and one effect at the end. Earthquakes and tsunamis still use their budgets.
- **Exploit:** griefing a town with a group quake. Keep settlement law and notoriety in force, and credit the crime to everyone in the circle.

### 3. Linked lifelines
- **Fantasy:** a healer ties themselves to the front-liner and shares the hits.
- **Fit:** resolver. Makes the existing `linked` modifier real: a share of damage or healing crosses over. Size M.
- **Mastery:** a better ratio and longer range.
- **Cost:** one extra lookup in `Damage.apply` for linked targets only.
- **Exploit:** linking to a dummy or creature to shed damage. Only allow linking to players and NPCs, with a cap on the shared share.

### 4. Catch and throw
- **Fantasy:** I bend your fireball around the wall and it lands harder.
- **Fit:** resolver. `redirect` aimed at an ally's projectile takes over its flight in `Delivery`, as parries already do. Size M.
- **Mastery:** a wider catch window, and a bonus from the catcher's tier.
- **Cost:** a nearby-flight check only on a redirect cast.
- **Exploit:** bouncing a bolt between two players to stack bonuses. One catch per bolt.

---

## Environment

### 5. The land keeps the spell
- **Fantasy:** the ice I laid is still slippery when you chase me across it.
- **Fit:** resolver. The `slick` field mode exists, and slippery ice is already on the Combat.md §10 list. Add scorched ground, mud and frost as short-lived terrain states. Size M.
- **Mastery:** larger, longer, and at high tiers you keep your own footing on them.
- **Cost:** budgeted through `EffectBudget`. Avoid terrain writes where a field will do.
- **Exploit:** griefing doorways. These states expire, and repeat casts refresh rather than stack.

### 6. Weather as fuel
- **Fantasy:** I wait for the storm, because in the storm I'm terrifying.
- **Fit:** data. World events already set `stormCharge`, `moisture`, `fuel` and `density`, and `EnvironmentRules` reads the world. Extend the rules and show the bonus in the Composer's preview. Size S.
- **Mastery:** higher tiers draw more from the same weather.
- **Cost:** none new.
- **Exploit:** events are per server, so people could hop servers for storms. Bonuses stay modest.

### 7. Lightning rods
- **Fantasy:** I raised an iron spire, and now your lightning goes where I say.
- **Fit:** small resolver. `Conduction` already floods through metal and water. Let a player-made metal construct attract `charge` spells nearby. Size S–M.
- **Mastery:** rods last longer, and masters can turn the catch back at the caster.
- **Cost:** a check only on `charge` spells.
- **Exploit:** a town-wide rod to deny lightning mages. They expire, and each caster gets one.

### 8. Overworked ground
- **Fantasy:** cast too much in one place and the air starts to hum. Then the storm comes.
- **Fit:** data + small system. `noteMagic` and `pressureAt` already track magic by place. Past a threshold, raise event odds and show a visible sign. Size M.
- **Mastery:** masters can sense the pressure and release it safely for a burst.
- **Cost:** low. The numbers exist.
- **Exploit:** griefers calling storms on a town. Cap it per area and let locals' relief quests answer it.

---

## Risk and reward

### 9. Wild surges
- **Fantasy:** my bolt split into three. I have no idea why, and I want it to happen again.
- **Fit:** data + resolvers. `Prompts-MagicCombat` #8 specifies it: ~25 mutations on the existing seeded roll, capturable as variants. Size L as written, M for the first 8.
- **Mastery:** novices get surprised, masters choose to suppress or invite them.
- **Cost:** splits must pay `EffectBudget`.
- **Exploit:** capturing a mutation to skip tiers. A captured variant still obeys the recipe's power ceiling.

### 10. Last breath
- **Fantasy:** nearly empty and nearly dead, I throw everything left into one spell.
- **Fit:** data + small resolver. `reckless` and overdraw exist. Add a bonus scaled by how far overdrawn you are, paid in burnout. Size S.
- **Mastery:** higher tiers survive the burnout better.
- **Cost:** none new.
- **Exploit:** none serious: a dummy can't feed it, and the burnout is the price.

### 11. Perfect release
- **Fantasy:** I let go exactly at the top of the charge and it rings.
- **Fit:** data. Stages exist in `Data/ChargeTuning`, and the server times the hold. Add a narrow window at Full with a bonus and a sound. Size S.
- **Mastery:** a slightly wider window at higher tiers. Mostly, it rewards the player's own skill.
- **Cost:** none.
- **Exploit:** macros. The window is tuned to survive latency, and the bonus stays small enough not to matter much.

### 12. Blood price
- **Fantasy:** out of magic? I can still pay with myself.
- **Fit:** data + small change. A new `sanguine` modifier pays part of the cost in health. Size S–M.
- **Mastery:** a better health-to-power rate.
- **Cost:** none.
- **Exploit:** combined with a healer for infinite casting. Add a recently-paid penalty on healing received.

---

## Expression

### 13. Your hand in the spell
- **Fantasy:** people recognise my magic before they see me.
- **Fit:** data, client visuals. Signatures already tint spells. Offer three seeded choices per domain (rune pattern, trail shape, cast sound) from `(worldSeed, player, "flourish")`. Size M.
- **Mastery:** a new choice at each tier, and an extra one for a declared signature spell.
- **Cost:** client only, plus one small saved field.
- **Exploit:** a look that hides what a spell does. Keep shape and form readable (see #19).

### 14. Spell pages
- **Fantasy:** I wrote my best spell on vellum and sold it to someone who could never have thought of it.
- **Fit:** system. `blank_vellum`, `CastService.castFromItem` and scroll spells exist. Writing a recipe you know makes a one-use scroll. Size M. It also answers the open question "can players share spells?"
- **Mastery:** the writer's tier limits what can be written and how many uses it holds.
- **Cost:** low.
- **Exploit:** spell names are player text and must stay filtered. Scrolls can't exceed what the writer can cast, and a reader above their ceiling gets a backfire chance.

### 15. Credited inventions
- **Fantasy:** someone across the island casts "Mira's Lance" and doesn't know who Mira is.
- **Fit:** data + small system. World firsts already exist in the Discovery store. Keep a filtered name with the record, and show it in the Composer when anyone else builds that recipe. Size M.
- **Mastery:** naming a recipe needs a real world first, which gets rarer at higher power.
- **Cost:** one store read when a preview is opened, cached.
- **Exploit:** offensive names. Filter them, and let admins clear one.

---

## Mastery moments

### 16. Spell seizure
- **Fantasy:** a Grandmaster doesn't dodge your fireball. They take it.
- **Fit:** resolver, shares #4's code. `redirect` on an enemy's projectile of the same domain, needing a tier well above the caster's. Size M after #4.
- **Mastery:** this is the mastery moment. It only opens at Master and above.
- **Cost:** low.
- **Exploit:** a hard counter to ranged play. Costs a lot of reservoir, and fails against higher tiers.

### 17. Twin casting
- **Fantasy:** two spells at once, one from each hand.
- **Fit:** system. A second attuned slot from Expert, with both released on one input. `AttunementService` assumes one spell, so it needs real changes. Size L.
- **Mastery:** opens at Expert, and costs less at higher tiers.
- **Cost:** low.
- **Exploit:** burst damage in PvP. Both spells' costs and cooldowns apply, and `pvpMaxShare` holds.

### 18. Landmarks
- **Fantasy:** the canyon I made has my name on the map, on every server, forever.
- **Fit:** data + small system. Persistent ruptures and the chronicle exist. A power-10 feat names the place, with filtered text. Size M.
- **Mastery:** only high-tier feats qualify.
- **Cost:** one chronicle entry per feat.
- **Exploit:** griefing for fame. Only unsettled land gets named, and crimes still count.

---

## Counterplay

### 19. Read the cast
- **Fantasy:** I saw the rune and knew to raise my ward.
- **Fit:** client visuals. Each form gets its own charge shape, each domain its colour plus a glyph. One of the parked VFX questions. Size M.
- **Mastery:** masters can hide their tell with `silent`. Those who can sense can still catch it.
- **Cost:** client only.
- **Exploit:** none. It helps fairness.

### 20. Break the charge
- **Fantasy:** I hit them with Void mid-charge and their own spell blew up on them.
- **Fit:** small resolver. Guards can already cancel a charge, and `BacklashService` exists. Void hits on a charging target cause a small backlash. Size S.
- **Mastery:** the charge's size sets the backlash, so greed is punished.
- **Cost:** a check per Void hit.
- **Exploit:** locking someone out. It only works on charges, with a short immunity after.

### 21. Spells that collide
- **Fantasy:** my water bolt met your fire bolt in mid-air and the steam blinded us both.
- **Fit:** resolver. `Delivery` flights checked against each other, then `InteractionMatrix` as normal. Size M.
- **Mastery:** skilled players shoot spells down deliberately.
- **Cost:** the real risk. Keep it to a coarse grid and small flight counts, then measure.
- **Exploit:** none serious. Reactions already have cooldowns per cell.

---

## Utility outside combat

### 22. Sense shows you the world
- **Fantasy:** I close my eyes and see the ore, the lock's weak point, and that this person is lying.
- **Fit:** data + client overlay. `sense` has a route. Each property reveals something: `temperature` shows heat, `magnetism` shows ore and metal, `perception` shows NPC mood. Size M. Probably the biggest gain for how the magic feels.
- **Mastery:** range and detail grow by tier. Experts see through walls.
- **Cost:** a bounded server query per cast, sending only what's in range.
- **Exploit:** seeing players through walls. Hidden mythic locations must never be sent (a standing rule), and `veiled` should block it.

### 23. Make your own road
- **Fantasy:** no bridge? I'll freeze the river, or raise one.
- **Fit:** mostly exists. `stoneshape`, `freeze` and `force` routes are there. Make them easy to use for travel, with Guided cards and short-lived footing. Size S.
- **Mastery:** longer, faster, more durable.
- **Cost:** terrain writes, already budgeted.
- **Exploit:** getting into locked places. Keep building interiors protected, and use `CharacterSafety`.

### 24. Magic as a trade
- **Fantasy:** the town pays me to light its lamps and rain on its farms.
- **Fit:** data. Event relief exists, as do beginner quests, and "Lamps at Dusk" is only flavour today. Make these effects real and pay coins. Size S–M.
- **Mastery:** bigger jobs need bigger magic: moving a boulder, ending a drought.
- **Cost:** low.
- **Exploit:** farming. The job has to actually need doing, and it stays cooled down per town.

### 25. Rune traps
- **Fantasy:** I carve a silent rune on the door and wait.
- **Fit:** data + small resolver. `delayed`, `silent`, `bind` and the `zone` form exist. A bound spell fires when someone steps on it. Size M.
- **Mastery:** more runes at once, harder to sense, smaller triggers.
- **Cost:** a capped number of trigger zones per player.
- **Exploit:** griefing spawn. Runes are crimes in town, can't be placed near spawn or dummies, and clear on logout.

---

## Rare and mythic

### 26. Omens
- **Fantasy:** the sky over every server flickered. Someone, somewhere, bent time.
- **Fit:** small system. Mythic casts are already noted. `MessagingService` and the chronicle exist. Send a rate-limited sky cue with no location. Size S–M, once sky visuals exist.
- **Mastery:** only high-power mythic casts trigger one.
- **Cost:** MessagingService limits. Throttle globally.
- **Exploit:** spamming it. One omen per domain per hour. It must not reveal who or where.

### 27. Small laws
- **Fantasy:** in this circle, for ten seconds, fire falls upward.
- **Fit:** resolver. The `reality` field and `law`/`probability` properties exist. A table of small rule changes in a zone. Size M, and Convergence and Paradox would apply once they exist.
- **Mastery:** more rules, larger, longer.
- **Cost:** the existing field budget.
- **Exploit:** rules that break movement checks. Keep to an allow-list, and nothing that touches movement authority.

### 28. Afterimage
- **Fantasy:** two seconds after I cast, the ghost of me casts it again from where I stood.
- **Fit:** data + small resolver. `echoing` and `delayed` exist. A Time-only flavour replays the cast from the old position. Size S–M. Far cheaper than rewinding, and a good first step toward Ideas prompt 11.
- **Mastery:** more echoes, higher strength.
- **Cost:** one delayed cast.
- **Exploit:** counts as a normal hit, with a damage share below 1 and the usual caps.

---

## Top 5 by fun per effort

| # | Idea | Why | Size |
|---|---|---|---|
| 1 | **Wild surges (#9), first 8 mutations** | The biggest surprise per line of code. The seeded roll already exists and does nothing, and it makes every cast a small gamble. | M |
| 2 | **Sense shows you the world (#22)** | Fixes the weakest verb and changes how the world feels, not just fights. Gives non-combat players a reason to train. | M |
| 3 | **Marks and detonators (#1)** | The first reason to cast two different spells on purpose, and the first real co-op. Builds on the 16 reactions. | M |
| 4 | **Perfect release (#11)** | Tiny, and it turns every charged spell into a moment of skill. Needs only data and a sound. | S |
| 5 | **Weather as fuel (#6)** | Almost free: the numbers exist. World events become chances, not just background. | S |

**Just outside:** Afterimage (#28) and Break the charge (#20) are cheap and could fit in alongside. Spell pages (#14) waits on the economy to be worth much.

**Suggested order:** #11 and #6 first since they're quick, then #9, then #1, then #22. Roadmap note: `docs/Roadmap.md` says to freeze features until a vertical slice is verified, so each of these is your call to make against that.
