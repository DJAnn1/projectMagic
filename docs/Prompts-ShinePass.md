# The Shine Pass (2026-11-10)

One prompt, generated at the owner's request: take the current systems and flesh out everything — less janky, more engaging, more fun — without adding new systems. Written to be given back to Claude as a whole ("Run the Shine Pass") or resumed later ("continue the shine pass"). The pass keeps its own memory in `docs/ShineLedger.md` once phase 1 creates it.

---

# The Shine Pass

Everything in this prompt is about what is **already built**. Do not add new systems. The goal: a player who joins for one evening should find a world that feels *finished* — responsive, alive, coherent, and free of the hundred small things that whisper "unfinished." Work by phases, in order. Each phase ends with a commit batch and a playtest request to me before the next begins. Say the plan before coding, every time. The realism rule holds absolutely: every improvement must make the world feel more real, never more like a game. If a fix would add a meter, card, or announcement, find the in-world version instead.

**Ranking rule for everything:** order work by *how often a player feels it in their first two hours*, not by how interesting it is to fix. A janky walk animation seen every minute outranks a broken edge case seen once.

## Phase 1 — The jank ledger

Audit from the player's seat, not the code's. Produce a ledger (`docs/ShineLedger.md`) of everything broken, ugly, or half-done, ranked by first-two-hours exposure. Seed it with the known list — verify each is still real before fixing:

- **NPCs (the big one):** the pinned pathfinding problem — rooms sealed to the pathfinder, ~25–30 NPCs standing with no path, people teleport-appearing inside buildings instead of walking in, sleepers leaving by doors of homes that aren't theirs, the door fallback opening locked doors. This is the single largest source of "the world is fake." Treat the pin as open for this pass.
- **UI:** the "Gear" filter button truncated to "Gea"; the inventory grid's ninth column cut off; verify the hover-card and toast-overlap fixes actually landed in play.
- **Known breaks:** the Moor's lift not lifting; riding indoors reading a roof as ground; Timestop not freezing tsunamis/quakes already running; later hits from grips, loops, finishers and Meteor Landing (and all of Time's spells) escaping crime judgment; `foundation_failed` on House_12/HouseLarge_07; the spawn rescue from near the world origin.
- **Dead content:** the Guided cards that route to `manifest` and do nothing (`earth contour generate touch`, `geomancy contour generate touch`, `alloycraft purity transmute touch`); `summon` promising a body and giving none; `linked` and `silent` modifiers with no code; DiscoveryLog's "Try something" possibly suggesting dead spells. Dead content is worse than missing content — a player who follows the game's own suggestion into nothing loses trust. Fix the routes or remove the suggestions.
- **Visual:** Neon accents blown to white by Bloom (NPC belts, familiar glow); the permanent name-and-job nameplates (propose the in-world alternative: names learned by meeting people); anything that z-fights, floats, or clips found while auditing.

Fix in ranked batches. One commit per batch.

## Phase 2 — Feel

Casting, moving and fighting should feel physical. Within realism (weight and consequence, not arcade flash): cast anticipation and release weight using the existing poses and conjure visuals; hit confirmation you can *feel* (hit-stop tuning, sound layering, flinches firing reliably); footsteps per surface; movement that never slides or snaps (dash, run, lock-on transitions); camera that never fights you. Audio coverage audit: every action a player repeats hourly should sound like something — list the licensed-library gaps (wind/blizzard is known missing) and bring me the picks to audition. Tune the numbers that were shipped untested: dash charges, stamina, charge timings, `focusLimit`.

## Phase 3 — The world coheres

The systems exist; make them *talk*. Weather should reach barks, activities and NPC moods, not just spell power. NPCs should react to what's in front of them: rain (cover), a mark, a familiar, a titan on the horizon, a feral rumor they heard. Journal lines, rumors, and barks should reference the same events so the world agrees with itself. Activities should flow into each other instead of teleport-switching. Every "built, never seen" feature in CLAUDE.md gets exercised and either confirmed, fixed, or flagged to me: NPC remarks on marks, familiar KO and rename, Rift rooms never entered (Twins, Long Dark, Frostgate), the unseen Rift reactions, wild zone rumors, second-client views of conjuring and familiars.

## Phase 4 — The first two hours

Play the new-player path with fresh eyes (`firsthoursim` plus a real run): awakening, first casts, first NPC conversation, first quest, first creature, first death. Every moment should answer three questions without UI: *what just happened, what can I do, why do I care?* Fix the gaps with in-world teaching — the mentor, the practice yard, overheard talk — never tutorials. Verify the beginner quests actually complete, the innate spells feel distinct from each other, and dying teaches instead of just costing.

## Phase 5 — One layer deeper

For each major shipped system, add exactly one layer of depth that multiplies what's there (no new systems): spells — make the modifiers that exist all *do* something visible; NPCs — one more beat of memory in conversations (they reference the last thing you did together); familiars — one more behavior in idle and combat; Rifts — make the unused answers discoverable; items — make affixes legible in play, not just stats; towns — one more sign that time passed (wear, repairs, seasonal goods already in data).

**Standing rules for the whole pass:** server-authoritative, deterministic, data-driven, budget for 30–60 players and 100–300 NPCs. Boot specs must pass after every batch; selene + VS Code diagnostics on every edited file; expected spec count stated in every handoff. Keep the ledger current — it is the pass's memory. When the owner says "continue the shine pass," read the ledger and resume at the top unfixed item.
