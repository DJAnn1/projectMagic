# Prompt pack: the owner's ideas (2026-11-05)

Eleven prompts, ordered from simplest to most advanced. Paste one per session. Every prompt
follows the project bible in CLAUDE.md (restate + assumptions, Explorer hierarchy, complete
`--!strict` code, risks, and test / next / open questions), and the non-negotiables: server
authority, data-driven content, seeded determinism, the 30–60 player / 100–300 NPC budget.

**Order and why**

| # | Idea | Kind | Why it sits here |
|---|---|---|---|
| 1 | Suggest improvements for the current game | design only | An audit; no code. **Done: docs/Improvements.md** |
| 2 | Ideas to make the magic system more fun | design only | A ranked idea list grounded in the grammar |
| 3 | Make the game more engaging (not linear) | design only | Ideas on top of quests / factions / the Director |
| 4 | Controls panel | UI | One screen + one data module. **Built 2026-11-05** (UI.md §7 Controls) |
| 5 | Spell-creation explanations | UI + data | Composer text and live previews; no new mechanics. **Built 2026-11-05** (UI.md §4.4) |
| 6 | Run toggle, walk default, Alt toggle, dash | input + server | Input changes are small; the dash needs server validation. **Built 2026-11-05** (Combat.md §15; dash = R) |
| 7 | Spell sounds and music | audio system | Needs your soundpack first; a new audio layer + music director |
| 8 | NPCs look better and more unique | world / visuals | Appearance data exists but isn't drawn; asset choices needed |
| 9 | Make the early game more fun | design + several systems | Re-plans and continues Prompts-EarlyGame.md (2–8) |
| 10 | Gravity feels powerful (flight, crush, more) | new mechanics | New resolvers, movement allowance, client physics |
| 11 | Time is powerful (timestop, timelines, recall) | new mechanics | State snapshots, freezing everything, PvP fairness: the hardest |

Notes:
- **Roadmap conflict:** docs/Roadmap.md says freeze features and verify a vertical slice first.
  1–5 don't fight that; 6–11 add systems. Decide per prompt.
- Dependencies: 4 should list the bindings that 6 adds (6 updates the controls data). 2 and 3
  may feed 9–11. 7 needs audio from you before code.
- Parked VFX questions live in CLAUDE.md › Open design questions.

---

## 1. Suggest improvements for the current game

```
Design only, no code. Audit projectMagic as it stands and suggest improvements.

Read CLAUDE.md, docs/Roadmap.md and the system docs first. Then give me a ranked list
(impact vs effort) in five groups:
- Broken or risky: things likely to fail in a live server (data loss, exploits, perf at
  60 players / 300 NPCs, unverified systems the roadmap depends on).
- Feel: what makes a minute of play feel worse than it should (feedback, pacing,
  readability, UI friction).
- Content gaps: places a player runs out of things to do or understand.
- Tech debt: duplicated logic, modules that grew too big, missing specs, luau-lsp noise.
- Quick wins: under one session each.
For each: what, why it matters, where in the code (file paths), rough size (S/M/L), and
whether it fits the roadmap's current milestone. End with your top 5 to do next.
Save it as docs/Improvements.md and summarise it in chat.
```

## 2. Ideas to make the magic system more fun

```
Design only, no code. Generate ideas to make the magic system more fun and interesting.

Ground every idea in what exists: the grammar (12 domains, branches, properties, verbs,
forms, modifiers in docs/MagicSystem.md), InteractionMatrix reactions, statuses, fields,
charge/channel, guards and parries, spellblade, mutations (Prompts-MagicCombat #8),
weaving (#9), discoveries and signature spells (Progression.md).
Give 20–30 ideas across: combos between players, environment interplay, risk/reward
(overdraw, overcharge), expression (signatures, named spells), mastery moments (what a
Grandmaster can do that feels earned), counterplay, utility outside combat, rare/mythic.
For each: the player fantasy in one line, how it fits the grammar (new data vs new
resolver), how it scales with mastery, server cost, exploit risk.
Rules: no paid features, deterministic where generated, no new class system.
End with a top 5 ranked by fun-per-effort. Save as docs/MagicIdeas.md.
```

## 3. Make the game more engaging without making it linear

```
Design only, no code. Ideas to make projectMagic more engaging and fun in general. No
linear story: find the middle ground between pure sandbox and guided play.

Build on what exists: SituationDetector + Narrative Director (Quests.md), factions and
reputation, the Journal, NPC memory/gossip/relationships, careers, world events, POIs and
the mythic breadcrumb, housing, items and crafting.
Organise ideas by time scale: the next 5 minutes, one session (~1 hour), weeks.
Cover: personal threads that grow from a player's own innate profile and choices (not a
script), rivals and mentors who remember you, rumours that point at real places, world
changes players cause and others notice (one world, many servers), reasons to return,
social play (co-op, teaching, duels), and goals players set themselves.
For each: the hook, which systems it reuses, what's new, size (S/M/L), and how it stays
optional. Flag anything that would feel like a forced story. Top 5 at the end.
Save as docs/EngagementIdeas.md.
```

## 4. Controls panel

```
Build a Controls panel that shows every control in the game.

- Single source of truth: a new data module Shared/UI/Controls listing every binding:
  action id, label, keyboard/mouse, gamepad, touch, the context it applies in (always,
  equip mode, quick mode, while attuned, building placement, admin), and the screen or
  controller that owns it. Where practical, controllers read their KeyCodes from this
  module, so the panel can't drift from the code. Today's bindings include: 1–9/hotbar,
  LMB cast, RMB/L1 guard, F/B slash, Q stow, wheel/D-pad slot swap, L2/R2, Left Alt/MMB
  lock-on, R3, C Composer, G Grimoire, I Inventory, J Journal, Z X V B quickbar,
  F2 admin, housing R/Q/Esc, Shift modifier in interactions. Audit every controller for
  the rest (grep KeyCode / UserInputType).
- A "Controls" screen registered with InterfaceController (proposed key: H; check it's
  free), also opened from the HUD menu and Settings. Grouped (Movement, Casting, Combat,
  Items, Menus), shows the current input type (keyboard, gamepad or touch) with a switch,
  greys out actions whose system is off by flag, and hides admin rows from non-admins.
- First join: a small toast "Press H for controls" (once, saved in preferences).
- A spec that every action id is unique and every binding names a real KeyCode.
Follow the UI conventions (Kit, Theme, no colour-only cues).
```

## 5. Explanations while creating spells

```
Make the Spell Composer explain exactly what the player is doing, so nobody has to guess.

Today: Guided and Full modes, a one-line hint per step ("What shape does it take?"), live
≈ previews. Add:
- Every option (domain, branch, property, verb, form, modifier) shows a plain-language
  explanation and a concrete example ("Generate + Temperature = make heat: light a candle,
  burn an enemy"). Text lives in data (extend the existing description fields), not in the
  UI code.
- A live sentence that describes the whole spell as built so far, from the real route
  (EffectLibrary) and stats: "Hurls a bolt of fire that bursts on impact: ~24 damage,
  costs 18 reservoir, 3 s cooldown, range 40." Updates as choices change.
- Locked options stay visible with the reason ("needs Adept in Pyromancy", "this verb
  can't take a Projectile form") taken from MagicCore's validation errors, so players
  learn the rules.
- A first-time walkthrough in Guided mode (3–5 steps, skippable, remembered).
- A "What does this mean?" glossary for terms (reservoir, overdraw, instability,
  mastery tier).
Never reveal hidden information (ProfileTuning, hidden latents, mythic locations).
Respect the UI conventions (TextBoxes outside Kit.dynamic regions, glyph + word cues).
```

## 6. Run toggle, default walk, Alt as a toggle, and dash

```
Movement and input changes:

- Running: Left Control TOGGLES running (press on, press off). While running: the Run
  clip, sprint speed from data, and (ask me) whether it drains stamina via StaminaService.
  Not running: the default Roblox walk clip, so change CombatAnimations.locomotion to map
  only `run` (walk back to the default). Running stops when casting, blocking or attuned
  aiming, per the action-state rules. Gamepad: click the left stick (L3). Touch: a button.
- Lock-on: Left Alt TOGGLES lock-on instead of holding it (middle mouse too). Add a
  setting `lockOnMode` = toggle (default) | hold, in Shared/UI/Settings.
- Dash: build Prompts-MagicCombat.md #7 (domain-flavoured dash, charges, brief damage
  reduction, cancels charging, server-validated distance, blink raycast, a displacement
  allowance in the movement check). Key: ASK ME first. Shift clashes with shift-lock,
  E with ProximityPrompts, Q with stow; R is free outside housing placement.
- Update Shared/UI/Controls (prompt 4) with every new binding.
Server-authoritative: the client sends a dash intent only; the server checks charges,
cooldown, state and distance. Specs for the dash rules.
```

## 7. Spell sounds and music

```
Add sound to spells and music to the world. BEFORE writing code, ask me for the soundpack
(or approve a list of Creator Store audio you propose). Audio must be owned by the place's
creator or be Roblox-licensed, or it won't play.

- An audio data layer like DomainFx.UPLOADED: role → asset id with built-in fallbacks.
  Per domain: cast, charge loop, launch, travel loop, impact, and a few per-form variants
  (beam hum, chain zap, zone drone). Plus UI (click, open, error), combat feedback (hit,
  crit, kill, block, parry), and melee swings.
- SoundGroups: Master, Music, Spells, Combat, UI, Ambience, each with a volume slider in
  Settings (validated server-side, reconcile fills old saves).
- A client MusicDirector: picks tracks by state (exploring per biome, settlement, night,
  combat when you've hit or been hit recently, a world event nearby), crossfades, never
  restarts a track on small state flickers, plus short stingers for awakening,
  breakthrough, new tier and discovery.
- Ambient beds per biome and time of day.
- Keep the existing caps (12 live spell sounds); add a per-category cap; signature pitch
  from the caster's Signature (Runtime.md §9 "signature audio").
```

## 8. Make NPCs look better and more unique

```
Make NPCs look better and more distinct. Today they are R6 rigs recoloured per NPC (skin,
shirt, trousers); NPCFactory already generates hair, build and feature strings that are
never drawn.

- Draw the generated appearance: hair (accessories), a face, clothing by culture and
  occupation (palette, layers, aprons, robes, armour for guards), build (scaled R6
  proportions), and the feature (scar, freckles, glasses, beard...). Deterministic from
  Seed.random(worldSeed, npcId, "appearance").
- Ask me which route for assets: free catalog accessories by id applied through
  HumanoidDescription (list them in data), simple part-built hair/hats from the code, or
  my own uploaded meshes/clothing. Mixed is fine.
- Status shows on the body: a mage's signature colours as a faint accent at higher tiers,
  rich vs poor clothing by household wealth, tools of the trade (Items' GearVisuals).
- Optional overhead name + title on hover/near (name, occupation, faction badge).
- Budget: the rig pool recolours on acquire; keep that cheap. Accessories loaded once and
  cloned; no per-frame work; T1/T2 LOD keep the cheap look. Measure parts per NPC.
```

## 9. Make the early game more fun

```
Make the first hour more fun. Start from docs/Prompts-EarlyGame.md: prompt 1 (domain
strikes) is built; 2–8 aren't. The VFX, lightning, slashes and fxpreview now exist.

Step 1 (this session): play-design the first 30 minutes as it would run TODAY, minute by
minute (spawn, awakening moment, first spell, first target, first discovery, first goal),
from the code, and mark every dead spot, confusing moment and missing reward. Then
re-order and revise EarlyGame prompts 2–8 into a plan (merge, split or drop as needed),
taking prompts 5 (Composer explanations) and 6 (movement) of THIS pack into account, and
docs/MagicIdeas.md / docs/EngagementIdeas.md if prompts 2 and 3 have been run.
Step 2: build the first item of that plan.
Keep it non-linear: suggestions and situations, never a mandatory tutorial chain.
Measure: what the "first hour" metrics (EarlyGame #8) should log.
```

## 10. Gravity that feels powerful

```
Make Gravity (Mythic) feel powerful, scaling with mastery. Existing: gravity fields (heavy,
light, invert), crushing heavy fields that spare the caster (Combat.md), the Levitation
branch, the Gravity strike, Orbitcraft / Attraction / Collapse in the journey sim.

Build, each as data + EffectLibrary route + Effects resolver + SpellExamples entries
(project conventions), gated and scaled by tier:
- Flight (Levitation): hold to hover, steer to fly; reservoir per second; speed, ceiling
  and duration rise with tier; landing slam at Master+. Players' characters are
  client-owned, so the server grants a movement allowance and the client applies the
  force (like knockback); the server validates speed/height.
- Crush: a targeted crush that pins one enemy and ramps damage; can kill (respect the
  60%-per-hit PvP cap and Damage.apply); telegraphed; ends on line-of-sight loss.
  Check first what the crushing field already covers and don't duplicate it.
- More (propose and pick with me): gravity well (pull everything in), lift and slam
  (throw a target), orbiting debris shield that blocks projectiles, deflect projectiles'
  paths, ground pound, weightless jump for allies.
- VFX for each through SpellFx/FxLayers (space-warp rings, debris), budgets respected.
Exploits: flight speed, crush on admins/safe zones, network ownership of NPC rigs.
```

## 11. Time that feels powerful (timestop, timelines, recall)

```
Make Time (Mythic) powerful, scaling with mastery. Existing: time fields (slow, haste),
the Hastening and Rewind branches, the Time strike; the "Time rewind buffer" is still on
the roadmap (Runtime.md §9).

Core mechanics (server-authoritative):
- A state buffer: the server records each character's position, health, reservoir and
  key statuses a few times per second for the last N seconds (ring buffer, bounded
  memory for 60 players + nearby NPCs).
- Self timeline: mark yourself (saves health, reservoir, position); recall within the
  window reverts you to that state. Cost, cooldown, a visible afterimage while the mark
  lives, and rules for death (can't recall from dead? recall on lethal at Grandmaster?).
- Timelines of others: mark a target; recall snaps them back to the marked spot (into
  your traps and other attacks) and stuns them. PvP limits: stun cap, immunity window.
- Timestop (Grandmaster): a short zone where everyone but the caster freezes:
  players' input and physics held by the server, NPC brains paused, projectiles and
  fields in Delivery paused. Very short, huge cost, long cooldown, big telegraph.
- Propose more and pick with me: time loop (target repeats its last 2 s), delayed
  damage (hits stack and land at once), future sight (see enemies' next cast telegraph),
  rewind-dodge, haste chains, aging/decay of structures.
Each: data + route + resolver + SpellExamples entry; specs for the buffer and the PvP caps.
Exploits: recall out of a crime or death, recall across chunk rebuilds or teleports,
desync with client-owned characters, timestop vs the admin panel and safe zones.
```
