# Your hand in the spell, and conjuring while charging

Built 2026-11-07 on the owner's "Implement Your hand in the spell: your style shows in how your spells look. Have a spell be visually conjured while charging". It comes from idea #13 in `docs/MagicIdeas.md`. Stage 1, not yet run.

## The idea

People should recognise your magic before they see you. Signatures already tint every spell. Now each caster also has a **hand**: a rune pattern, a shape their magic gathers into, a way it turns, and a voice. And when you hold a charge, the spell visibly **forms** in front of you, in your hand's style, growing with each stage.

## Your hand

| Part | Options | Where it shows |
|---|---|---|
| Rune | `magic_01` … `magic_05` (Kenney Particle Pack) | your cast circle (every cast), and the rune disc in anything you conjure |
| Shape | orb, shards, halo, helix | what a charge gathers into |
| Spin | sunwise or widdershins, 0.6–1.6 turns a second | how your conjured magic and its runes turn |
| Voice | pitch × 0.88–1.14 | your cast sound |
| Tier | your best mastery tier (0–8) | detail: an orbiting mote every 2 tiers (up to 4), a second counter-turning rune from Expert, a crown of beads from Grandmaster |

- **Seeded:** the hand comes from `Seed.random(worldSeed, "player:<id>", "hand")`, so it's the same on every server, with no rerolls.
- **Temperaments lean the shape:** a matching temperament makes its shape 3 times as likely as each of the others. A swift caster has a helix about half the time. Volatile, brittle and precise lean to shards; resonant and patient to a halo; steadfast, deepwell and radiant to an orb; swift, conduit and subtle to a helix.
- **No menu.** Your hand is who you are, and it matures as you do. This follows the design rule. (The original idea offered three choices to pick from; that's an open question below.)
- **Published:** the Player attribute `SpellHand` (`"rune|shape|spin|speed×100|pitch×100|tier"`). Decoding clamps every field. The world seed never leaves the server. Nothing is saved: the hand is regenerated from the seed.

## Conjuring while charging

Equip mode, holding a chargeable spell (`ChargeStart`/`ChargeStep`, set by CastService), draws the spell forming. Where it forms depends on the form (`AttunedForm`):

| Form | Where |
|---|---|
| touch, projectile, beam, chain | in front of the palm, the rune standing behind it, facing out |
| burst, summon | above the head, the rune lying under it |
| aura, wall, zone, pillar, ritual | a rune circle growing at the feet, with the core rising from its centre |

- **What it looks like:** the domain's look (`Data/SpellHand`: core material and transparency) in your signature colours, swirled by the domain's own spell texture. Properties override it where it matters, using `AttunedProperty`, which is new: lightning (`energy.charge`, `air.charge`), shadow, light, ice (`water.temperature`) and metal (`earth.magnetism`).
- **Growth:** it grows across the safe stages (Quick, Charged, Full) and only 15% more when overcharged.
- **Overcharged:** it shakes, flickers to the accent colour and throws sparks.
- **Release:** a flash, and it's gone; the cast's own visuals take over.
- **Cancel or timeout:** it shrinks and fades in a puff.
- **Other players:** every client draws everyone's conjuring within 150 studs (AttuneGlowController's range, 24 glows at most). No new remotes, and nothing else replicates.
- **Reduced effects:** no light, fewer particles, and none of the tier detail.

## Files

- `ReplicatedStorage/Shared/Magic/Data/SpellHand.luau`: shapes, runes, temperament leaning, form → place, per-domain and per-property looks, sizes.
- `ReplicatedStorage/Shared/Magic/SpellHand.luau`: generate, encode/decode, detail, modeFor, lookFor, progress, sizeAt (pure).
- `ServerScriptService/Server/Services/SpellHandService.luau`: seeds and publishes the hand; it matures on tier changes (checked at most every 20 s after a cast).
- `StarterPlayerScripts/Client/Fx/Conjure.luau`: the conjured spell.
- Changed: `Controllers/AttuneGlowController` (starts, feeds and ends a conjuring), `Fx/SpellFx` (`styleFor` adds `rune` and `pitch`; `handOf`), `Fx/FxLayers` (`Style.rune`, `Style.pitch`; the cast circle uses your rune; `sound` takes a pitch multiplier), `Services/AttunementService` (`AttunedProperty`).
- Spec: `Tests/SpellHand.spec` (16).

## Admin

- `spellhand [player]`: their rune, shape, spin, voice and tier detail.
- `spellhandtier <0-8 | -1> [player]`: preview the hand at another tier until they rejoin (−1 ends the preview). Nothing is saved.

## Not in stage 1

- NPC mages conjuring as they charge. Their charge telegraph doesn't set these attributes, and their hand would come from their own seed.
- Quick-mode casts: no hold means no conjuring. The cast circle still carries your rune.
- Trail shapes for your projectiles (the idea's "trail shape").
- Choosing between seeded options at each tier, as in the original idea.

## What could still feel like a game (for the owner to judge)

Nothing here is a menu, a number or a notice. The detail that arrives with tiers is the closest thing to a visible "level", and it's deliberate: people can read how practised a mage is from their hands.
