# Prompt pack: magic feel, casting and combat

Paste these one at a time, in order. Each one builds on the one before it. They assume the project bible rules, the current code (CastClient, CastService, EffectLibrary, DamageModel, Delivery, Targeting, HitReactions, NPCCombat, SpellFx, CombatFeedback) and docs/Combat.md.

**Before prompt 1:**
- The animation IDs must be owned by the same account or group that owns the place. If they aren't, `LoadAnimation` fails silently in live servers.
- `run` and `Slash1` share the same ID (138752334774532). Fix one of them or confirm it's on purpose.

---

## 1. Animation foundation

```
Build the animation layer that every combat feature will use.

Animation IDs (data, not hardcoded in logic):
BlockStart 115334865008883, Block 128098131606169, BlockHit 112849868505263,
Equip 89289769245430, Hold 108827586483203, Slash1 138752334774532,
Slash2 113754806600593, Run 138752334774532 (same as Slash1, so flag it and let me
supply a new one), Dash 103931697209739, CastSpell 135616983966337.

Requirements:
- Shared data module Data/CombatAnimations: id, priority (Action/Action2/Movement),
  looped, fade times, speed, named markers we expect (e.g. "Release", "HitFrame",
  "ParryOpen"), and per-domain speed/weight overrides.
- Client AnimationController (Bootstrap controller) that preloads tracks on the
  local Animator, rebuilds them on respawn, and exposes play/stop/marker signals.
  Uses the character's Animator so it replicates to others automatically.
- A server-side state mirror (an "ActionState" attribute on the character: idle,
  equipping, holding, charging, casting, slashing, blocking, dashing, staggered)
  so the server, not animations, decides what is allowed. Animations only follow
  the state.
- NPC rigs (NPCLOD T0/T1) play the same set through a server-side player, but only
  at T0 and within a distance budget.
- An admin command `anim <name>` and `animstate` overlay for testing.
- Fallback when an animation fails to load: keep the state machine working
  without the animation, and log once.
Cover markers that never fire (time-based fallbacks), animation speed scaling with
castTime, and the fact that Run/Slash1 share an id.
```

## 2. Equip a spell (attunement stance)

```
Replace "press a number key to fire" with an equip-and-aim model, and keep
quick-cast as an option in Settings.

Design:
- Pressing a hotbar key attunes that spell (Equip animation, then the Hold loop).
  The hand glows with the caster's signature colour, the form's reticle appears,
  and the character turns to face the mouse (shift-lock style, but only while
  attuned). Pressing the same key again or Q stows it.
- While attuned: LMB casts, RMB blocks/wards (prompt 5), scroll or 1-9 swap spells
  with a short re-equip.
- Movement while attuned: walk speed x0.85; Run plays only when not attuned.
- Server: an `Attune` intent (slot key) validated against the spellbook/hotbar,
  stored per player, and required by CastService for equip-mode casts. Cooldown
  between swaps. Casting a non-attuned spell is refused in equip mode.
- Gamepad: LT attune/aim, RT cast, LB block. Touch: tap slot to attune, on-screen
  cast and block buttons, aim from the screen centre.
- New setting castMode = "equip" | "quick" (default equip).
Update CastClient, MagicStateController, the HUD hotbar (attuned slot highlight)
and Remotes. Keep the existing prediction/correction flow.
```

## 3. Mouse aim and form-aware reticles

```
Make aiming readable and fair for each spell form.

- Reticle per form, client-only, from the spell's previewed stats:
  bolt/projectile: a dotted arc using the same flight maths as Delivery (gravity,
  speed), ending in an impact ring; beam: a thin line to the first hit with a
  max-range fade; area/burst: a ground decal circle sized to the radius that
  conforms to terrain; cone/touch: a wedge in front of the hand; chain: highlight
  the first target and ghost the next hops; aura/self: a ring around the caster.
- Out-of-range and no-line-of-sight states are shown in the reticle (colour plus a
  glyph, since colour can't be the only cue).
- Soft lock-on: a held key (or gamepad LT) sticks to the nearest valid target
  inside a screen cone. The server still re-validates aim plausibility.
- The server's aim check (CastService) must use the same origin as the reticle (the
  hand or "Release" point, not the HumanoidRootPart), or the reticle will lie.
- Performance: one reticle at a time, pooled parts, updated on RenderStepped
  only while attuned, with raycasts throttled to 30 Hz.
```

## 4. Hold to charge, hold to channel

```
Close the "hold-to-channel" gap in Casting.md §5 and add charging.

- Press LMB = begin, release = commit. Short tap = a quick cast at reduced power.
  Holding fills charge stages (e.g. 0 / 1 / 2 / Overcharge) using the CastSpell
  wind-up, then the Hold loop. Release plays CastSpell's release at the
  "Release" marker.
- Charge scales power, area, speed or pierce per form (data in CastTuning, not
  code). Overcharge past the safe stage risks backlash through BacklashService
  and drains extra reservoir; it's visible through hand shake, rising audio pitch
  and a cracking aura.
- Channel forms (beams, streams, auras) sustain while held: a reservoir drain per
  tick through Reservoir, EffectRunner keeps the effect alive, and release or
  running dry ends it. The aim can sweep slowly (turn-rate cap).
- Server-authoritative timing: the server records begin/release on its own clock,
  clamps the charge to what its clock allows (ignores client-claimed durations),
  auto-commits at max hold, and cancels on stagger, silence, knockdown, dash or a
  blocked hit. Charging slows movement.
- NPCs (NPCCombat) can charge too, telegraphed so players can react.
Include the network message shape, rate limits and spam/abuse cases
(begin/cancel loops to skip cooldowns).
```

## 5. Blocking, wards and parries

```
Add defense so fights have back-and-forth.

- Hold RMB while attuned: BlockStart, then a looping Block. It raises a ward
  shaped by the attuned spell's domain (earth: stone plate, water: a rippling
  film, energy: a hex shield), facing the camera direction within a front arc.
- Blocking reduces damage from the front through Damage.apply (a "Guarding" status
  with a resist value), drains reservoir per absorbed point, and plays BlockHit
  plus a hit-stop on impact. A guard meter breaks into a stagger when empty.
- Perfect parry: a short window after BlockStart (data, ~0.18 s, server-timed with
  a latency allowance capped at 120 ms). A parried projectile reflects back along
  the aim (closes Combat.md §10 beam/projectile reflection); a parried melee
  staggers the attacker.
- Some spells are unblockable or pierce the guard (properties in the grammar
  decide it, e.g. piercing or mental), shown on the reticle and in the Grimoire.
- NPCs block and parry based on traits and magic tier (NPCCombat).
Watch out for block-spam and parry-window latency exploits, and for whether
blocking counts as "healing" for Brush with Death (it shouldn't).
```

## 6. Spellblade melee (Slash1 / Slash2)

```
Give close range a magic melee option so it's not just ranged spam.

- With a spell attuned, a melee key (F, or LMB when the target is within 6 studs:
  you decide which) does a Slash1 → Slash2 combo. The hand or focus becomes an
  edge infused with the attuned spell's domain.
- The server owns hit detection: a swept box between the "HitFrame" markers, timed
  on the server from the swing start, not trusting client hits. Damage goes through
  DamageModel with a melee share and a small reservoir cost; the domain's status
  can be applied at low power.
- Combo window and cancel rules: a slash can cancel into a dash or block, and the
  2nd slash into a quick cast ("spell finisher") for a bonus.
- Hit reactions: flinch on NPCs, small knockback, hit-stop, CombatFeedback numbers.
- Give equipped items from the item system (staves, orbs, blades) bonuses to the
  spellblade.
Explain why melee XP feeds the attuned branch (or doesn't).
```

## 7. Dash and magic movement

```
Add a Dash that every domain flavours differently.

- Q (or a double-tap direction), using the Dash animation, in the move direction
  (or backwards when standing still). Costs reservoir or a separate stamina
  charge (2 charges, recharge time in data).
- Domain flavour, data-driven: Energy blinks a short distance with an afterimage;
  Earth slides on a stone ridge; Water rides a wave; Fire jets with a scorch
  trail; Air gets a longer, floatier dash. Mythic domains get their own (Time:
  rewind-dodge to 1 s ago; Gravity: a vertical flip). Mastery tier extends it.
- Brief damage reduction (not full invulnerability) during the dash; it cancels
  charging and casting.
- Server-authoritative: the server validates distance, charges and cooldown, does
  the movement check (this is the start of Backend.md §8 anti-teleport), and
  allows the dash's displacement in that check. Blinks can't go through walls
  (raycast from the server).
- Run animation for sprinting when not attuned.
```

## 8. Make mutations real

```
Mutation rolls are logged (`mutation_rolled`) but do nothing (Casting.md §5).
Make them the fun surprise of the system.

- Data/Mutations: ~25 mutations with weights, gated by domain/property/form
  (e.g. bolt splits into 3, fire leaves a burning trail, water bolt freezes on
  impact, chain jumps one extra time, area pulses twice, beam bends toward the
  nearest target, wild surge: random property swap).
- The chance comes from the existing roll (seeded per cast, deterministic). It goes
  up with overcharge and with the caster's temperament, and goes down with mastery
  (masters can choose to suppress or "invite" mutations).
- A mutated cast plays a distinct VFX/audio sting and a toast naming the mutation.
- A mutation seen N times can be "captured" as a spell variant in the spellbook
  (feeds DiscoveryLog and signature spells).
- Must respect EffectBudget (splits charge extra parts) and go through
  EffectLibrary routes.
Add SpellExamples entries and Cast.spec tests for determinism.
```

## 9. Spell weaving and combos

```
Reward sequencing spells instead of mashing one.

- Primers and detonators: some spells leave a mark (Soaked, Charged, Oiled,
  Brittle, Floating) and others detonate it through InteractionMatrix (Soaked +
  charge = conducted stun; Brittle + kinetic = shatter crit; Floating + heavy
  gravity = slam). Data-driven, in InteractionMatrix plus StatusEffects.
- Weave window: casting a second spell within ~1.2 s of the first, from a
  different branch, adds a "weave" bonus. A three-step weave from three branches
  is an "Opus" with a big visual (this rewards breadth, so explain how it balances
  against the focus-vs-breadth rules).
- First-time combos register as discoveries (DiscoveryLog, journal entry, XP).
- Co-op: weaves count across players, so two players combo each other's marks.
- HUD: a small weave-chain indicator next to the hotbar.
Watch for performance (mark bookkeeping per target) and PvP balance (stun-lock
caps, diminishing returns).
```

## 10. Game-feel pass

```
Do a juice pass on casting and hits using the existing Fx layers.

- Camera: a small FOV push while charging, kick on release scaled by power,
  shake on heavy impacts and nearby quakes. All of it respects a new
  "Screen shake" setting (Off/Low/Full).
- Hand and focus: a charge glow that grows per stage, sparks/embers/droplets per
  domain from DomainFx, and a trail on slashes.
- Audio: charge loops with rising pitch, a release sting, impact layers by
  domain and power, and signature timbre/pitch per caster (a Runtime.md §9
  gap).
- Hit-stop on crits, parries and kills; enemy hit flash; knockback arcs; a slow
  ragdoll-to-knockdown on kills.
- Cast circles under the feet scale with tier; Grandmaster+ casts darken the
  surroundings for a moment.
- Keep every effect inside FxPool/budget caps, with a "Reduced effects" setting
  for low-end devices.
List each effect, where it lives, and its budget cost.
```

## 11. NPCs fight with the same kit

```
Make NPC fights use the new combat kit so they're readable and beatable.

- NPCCombat uses the same action states (attune, charge, cast, slash, block,
  parry, dash) and the same animations, with telegraphs (a charge glow, a wind-up
  before slashes).
- Decisions come from personality: aggressive NPCs press melee, cautious ones
  kite and block, clever ones use primers then detonators, and cowards dash away.
  Mastery sets reaction time and parry chance.
- Real spell repertoire per NPC from their profile and career (Combat.md §10),
  through the same CastService resolvers (no Player assumption).
- Group rules: at most 2-3 NPCs attack one player at once, and the others circle
  or hold, so fights don't feel unfair.
- LOD: full combat only at T0; T1 resolves abstractly.
```

## 12. Combat sandbox and tuning

```
Build a test arena so we can tune feel and numbers fast.

- Admin `arena` teleports to a flat combat yard with dummies that block, parry,
  dash or cast on a timer (configurable per dummy), plus a DPS/TTK readout.
- A `combatlog` overlay shows every hit with charge stage, weave, mutation,
  block/parry results and the final DamageModel breakdown.
- Target numbers for me to approve: time-to-kill for equal-tier duels, the share
  of damage from melee vs spells, charge-vs-tap DPS parity, and a reservoir-empty
  time in a sustained fight.
- Combat.spec additions for charge clamping, parry windows, weave timing and
  mutation determinism.
```
