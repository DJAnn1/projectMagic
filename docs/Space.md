# Space powers: plan

Owner, 2026-11-16: "I want the space domain to be expanded and better." This is a plan only; nothing is built. It follows what Gravity, Time and Reality got (`docs/Gravity.md`, `docs/Time.md`, `docs/Reality.md`): real powers on the domain's own branches, as ordinary casts with no new keys, each one narrow (its own branch, property, verb and form) so no other spell changes.

## 1. What Space has today (audit)

| Branch (tier) | It promises | What exists |
|---|---|---|
| Raw Space | "a nudge of reach" | the plain-damage `harm` route; `distance_pull` and `distance_push` (Force) |
| Translocation | moving things without crossing the space between | `blink` (redirect: step to the aim point; transfer: pull a target in front of you) |
| Blinking | short line-of-sight teleports | the same blink, nothing more |
| Gatecraft | portals | **nothing** |
| Worldgates | permanent gates across the world | **nothing** |
| Folding | shortening or lengthening space | `fold`, a Force pull (volume / reduce) |
| Pocketcraft | bags bigger inside; hidden rooms | **nothing** |
| Containment / Sealing | prisons with no doors | **nothing** (fallback statuses only) |
| Spatial Sense / Clairsentience | aware of everything in a region | **nothing**. Sense sight (#11) has heat, metal, ley and tracks, but no Space kind |
| Mindlink (Space + Mind) | telepathy at any distance | **nothing** |

Elsewhere, Space has the ultimate *Fold of Worlds*, the elemental "a fold walker", and the Composer's fallback statuses. In short, Space is "blink, plus push and pull". Six branches promise things the code doesn't do.

## 2. Proposed powers (one per branch, more at high tiers)

Each power is a route in `EffectLibrary` → `Effects/SpacePower` → `Cast/SpaceRuntime`, with numbers in `Data/SpaceTuning`, rules in `Magic/SpaceRules`, a client `SpaceClient` and `Fx/SpaceFx`, and the flag `space_powers_enabled`.

1. **Gates** (Gatecraft; boundary; generate; zone): two linked rifts, one where you stand and one at the aim point (line of sight, range grows with power). Anyone walks through: you, allies, enemies, NPCs, creatures. **Bolts fired into one come out of the other**, through `Delivery.interceptor`, the same way Gravity's Bend Path works. They last 20 to 60 s, with at most 2 pairs per caster.
2. **Worldgate** (Worldgates; power 9+; ritual): a gate from where you stand to any place you've been: a town, a marked spot, or a pin on your map. It stays a real hour on this server and others can use it. It never opens into a Rift, and never into a house that isn't yours.
3. **Swap** (Translocation; position; transfer; touch or beam): you and the target change places. On an ally it's a rescue; on an enemy you take their spot and they take your trouble. A projectile caught mid-flight swaps too.
4. **Anchor and Recall** (Blinking; position; bind, then release): mark a spot, then cast release to return to it from anywhere within range (range grows with tier). Grandmaster recalls your party too.
5. **Fold Stride** (Folding; distance; reduce; aura): each step covers 2 to 3.5 times the ground, as space folds under you. It's movement, not speed: walls still stop you, and it ends when you attack.
6. **Stretch** (Folding; distance; amplify; zone): space around a point lengthens. Anyone walking toward its centre crawls, and bolts crossing it slow and drift. It's a defensive bubble that no wall can match.
7. **Pocket** (Pocketcraft; volume; amplify; aura): opens a pocket you can reach into. It holds extra quickslot and bag slots while the aura holds (`bonusBagSlots`); what's inside is saved with you. At Master, **a hidden room**: step into a small sealed pocket of space, off the island like a Rift. It's safe for 30 to 60 s, then you're put back where you left.
8. **Seal** (Sealing; boundary; bind; touch, beam or zone): a prison with no doors. A clear-edged box closes round the target for 3 to 6 s (2.5 s against players). Nothing crosses it either way: not them, not spells, not you. Zone form seals an area, which can hold a crowd or keep a doorway shut.
9. **Cut** (Raw Space or Translocation; distance or position; release or transmute; beam): a rend in space itself. It ignores guards, wards and armour (`pierce`), but costs heavily. At Grandmaster, the cut stays open for a moment and anything crossing it is hurt again.
10. **Clairsentience** (Spatial Sense; orientation; sense): a new Sense sight kind called "space". It draws the outline of every body, hollow and door within 80 to 200 studs, through walls, for 8 to 20 s: hidden rooms, people indoors, a lair's mouth, a buried chest. It also gets a Journal line the first time.
11. **Mindlink** (the hybrid; thought and distance; transfer): talk to a party member or a known NPC anywhere on the island. An NPC answers as if you were there: news, rumours, the quest-talk hook.
12. **Recast the ultimate:** Fold of Worlds stays. Add **Starfall Gate** (ritual, power 8+): gates open overhead and rain whatever the caster fired into them in the last 10 s back down on the warned spots.

## 3. Better, not only more

- **Dislocation (Space's risk):** a backfire currently "throws the caster a short distance". It should do what the risk says: a real slip, sometimes into a bad place (shallow water, a rooftop, up to 30 studs). It's never into a wall; `standAt` already guarantees that.
- **Looks:** Space's tears, outlines and starfields (`Fx/SpaceFx`). Gates are a real hole showing the other side, rendered by a client `ViewportFrame`. That needs testing for cost.
- **Mastery:** each power grows with the tier: gate range and lifetime, seal time, stride factor and pocket size.
- **NPC mages:** Space NPCs blink out of melee and seal a player for a moment (NPCCombat). Guards with Space seal brawlers instead of fighting them, which fits the world-first rule.
- **World:** a Worldgate leaves a faint scar people talk about (a rumour line). Sealed rooms are a known thing among scholars (a book in the bookshelves).

## 4. Order (suggested)

Build in three stages, each with a commit and a playtest:
- **Stage 1:** Gates, Swap, Seal, Fold Stride, Cut, Dislocation.
- **Stage 2:** Anchor and Recall, Stretch, Clairsentience, Pocket storage.
- **Stage 3:** Worldgate, hidden-room Pocket, Mindlink, Starfall Gate, NPC Space mages.

## 5. Open questions for the owner

1. Is Space meant to be overpowered like Time and Gravity (it's Rare, not Mythic)? Default: strong but limited: costs stay `costMult` 1.3, and seals are capped against players.
2. Gates: may enemies use your gate? Default: yes, anyone can, because it's a real hole in space.
3. Worldgate: per server for an hour (default), or saved for every server like Wild Zones?
4. Pocket storage: should items in the pocket be lost if you die or go down? Default: no, they're safe.
5. Mindlink: allowed to reach players outside your party? Default: party only, for safety.
6. Start with stage 1?
