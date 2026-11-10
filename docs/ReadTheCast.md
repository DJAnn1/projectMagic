# Read the cast

Idea #29 from the 2026-11-07 ideas list, picked by the owner 2026-11-09. Built 2026-11-10, not yet run.

## What it does

A spell forming in someone's hand (the conjure from `docs/SpellHand.md`) already showed its domain, its property, its form (palm, overhead or at the feet) and its charge stage. Now it also gives away **what it will do** and **how strong it is**, so the person it's meant for can read it and dodge, guard or close in:

| It will... | It forms |
|---|---|
| attack | fast, restless, shaking a little, sparks thrown off it, bright |
| heal | slow, breathing gently, drifting upward, drawing magic softly in |
| protect | almost still, no breath, a steady glow |
| boost | lifting, bright |
| control | a quick hard pulse, pulling in fast |
| move | spinning fastest, throwing its motion off |
| shape the land | slow and heavy, sinking toward the ground |
| sense | a slow deep breath, dim |
| nothing (a dead spell) | hollow: dim and listless |

Stronger spells form bigger (+7% per power level above 1, up to +60%), and the charge hum is deeper. Nothing is labelled, so people learn to read it. The caster's own spin, rune and shape (their hand) stay theirs; the tell only changes speed, breath, drift and light.

**NPC mages now conjure too.** Their telegraphed wind-up forms the spell in their hand, in their signature colours, moving by what it will do. A bolt that breaks on their focus falls apart; one that's cast flashes into the cast.

## Code

- `Shared/Magic/Data/CastTells`: how each kind moves, plus the power scale and pitch.
- `Shared/Magic/CastTells`: `kindOf(recipe)` (the kind from `SpellOutcome`, the same one the Composer tags), `tellFor`, `scaleFor`, `pitchFor`.
- `AttunementService`: sets `AttunedKind` and `AttunedPower` beside the existing attunement attributes, and clears them with the rest.
- `NPC/NPCCombat`: `beginConjure` and `endConjure` around the wind-up. The rig gets the tag `NpcConjuring` plus attributes (`Attuned*`, `ConjureSignature`, `ChargeStart`, `ChargeStep`), and `ConjureEnd` (`release` or `cancel`) when it ends.
- `Fx/Conjure`: `opts.kind` and `opts.power`.
- `AttuneGlowController`: passes them on, deepens the hum, and draws NPC conjures (at most 12, within 150 studs).
- Flag: `cast_tells_enabled` (off: every conjure looks neutral and NPCs show none).
- Spec: `Tests/CastTells.spec` (5).

## Test

1. Ready an attack (a Fire bolt) and hold to charge: it should spin fast and spit sparks. Then ready a heal (Life) and charge: slow, breathing, drifting up. Then a ward: nearly still.
2. Compare the same spell at power 1 and power 6: the second should form clearly bigger, with a deeper hum.
3. `npcfight` with an NPC mage, then watch its hands before each bolt: a spell should form and flash away as the bolt flies. Hit it hard mid-wind-up (Break the charge): it should fall apart.
4. With a second client, the other player's charge should read the same way.
5. `flag cast_tells_enabled false`: neutral conjures, and no NPC conjures.

## Unverified

- How readable the differences are in play, especially at a distance and for small low-power spells.
- NPC conjures on T0 rigs that move, and that they clear when a rig is pooled mid-wind-up.
- Frame cost with many NPC mages fighting at once (capped at 12 conjures).

## Not decided

- Should skill change what you can read: someone who knows a domain, or has a high Sense mastery, reading its tells more clearly?
- An area spell's landing spot isn't shown (it would need the aim sent while charging, which a cheater could fake).
