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

## Stage 1: built (2026-11-16, on the owner's "go stage 1"; not yet run)

The open questions took their defaults: strong but limited, anyone can use a gate, player seals capped at 2.5 s.

| Power | Recipe that reaches it | What it does |
|---|---|---|
| **Gate** (`space_gate`) | Gatecraft · boundary or position · amplify or transfer · zone, wall or ritual | Opens a ring 5 studs ahead and one at the aim point. Bodies (players, NPCs, creatures, Wildborn) within 2.8 studs come out of the other 4 studs along its face. Bolts and arrows come out with the same speed (Delivery's new `"warp"` action). It lasts 20 + 5/tier s (max 60). You get 2 pairs at once and the server 24. |
| **Swap** (`space_swap`) | Translocation · position · transmute or bind · touch, beam or projectile | You and the target change places, up to 140 studs. Other players only with PvP. |
| **Seal** (`space_seal`) | Containment/Sealing · boundary or volume · bind, generate or amplify | Status `space_sealed`: no moving, no casting, no damage taken. A bolt reaching the box stops. It lasts 3 + 0.4/tier s (max 6), and 2.5 s at most on a player. Area forms seal up to 8. |
| **Folding Stride** (`space_stride`) | Folding · distance or volume · reduce or amplify · aura | Walk ×1.9 + 0.18/tier (max 3.4) for 12 + 3/tier s. It ends the moment you hurt someone. |
| **Cut** (`space_cut`) | any Space branch · distance, position, volume or boundary · release or transmute · beam or touch | 1.35× a hit on everyone along the aim (6 at most), `pierce` so guards can't turn it. |
| **Dislocation** | any Space backfire, and the Dislocation risk | Thrown 10 + 2.5 × power studs (max 34), tries 6 directions, 25% dropped from 14 studs above (a roof, a ledge). |

- Old routes stay: Blink and Displace (redirect/transfer position), Fold (volume reduce, not aura), push and pull.
- **Code:**
  - Server: `Shared/Magic/Data/SpaceTuning`, `Cast/SpaceRuntime`, `Cast/Effects/SpacePower`, `Services/SpaceService` (10 Hz step; wraps `Delivery.interceptor` after Gravity's and Reality's), BacklashService and Blink both call `SpaceRuntime.dislocate`.
  - Client: `Fx/SpaceFx` (cue `space`).
  - Statuses: `space_sealed`, `space_stride`.
- **Flag and tools:** flag `space_powers_enabled`. Admin `space`, `spaceclear`, `dislocate [player] [studs]`. Log `space_gate_opened`, `space_gate_closed`.
- **Specs:** expected boot line `specs 1159/1160` (3 new in `Tests/Space.spec`, 4 new examples). The Seal example now routes to `space_seal`.
- **Not verified in Roblox:**
  - whether moving a player through a gate with server `PivotTo` feels smooth (Blink already moves players this way);
  - how the rings look (a cylinder turned onto the gate's face);
  - whether `damageTaken = 0` covers every way of being hurt (statuses that tick go through Damage.apply too).

## After stage 1's run (2026-11-16)

The owner: "the gate looks good but the range is too small. at a high enough skill level you should be able to gate anywhere around the map."

- **Long gates:**
  - Set a waypoint on the map (M, click), then cast a gate. Its far end opens at the waypoint instead of where you aim.
  - How far it can reach depends on your tier (`SpaceTuning.gate.waypointReach`):

    | Tier | Reach |
    |---|---|
    | Below Expert | none |
    | Expert | 700 studs |
    | Master | 1,600 studs |
    | Grandmaster and up | 8,000 studs (the whole island) |

  - The waypoint must be on ground you've uncovered on your map (`MapService:hasSeen`).
  - A far end on ground nobody has built yet asks for it (`requestArea`). A small ring flickers in front of you (`gate_forming`), and the gate opens when the ground is ready, or gives up after 12 s.
  - Clear the waypoint to gate where you aim again.
  - The client sends its waypoint on remote `MapWaypoint` (Net.send, nil to clear).
  - Gate cues now go out at both ends, so people at the far end see the gate too.
- **Spec fixes:** that run had `specs 1157/1160`. Transmute needs a tier 2 branch and release a tier 1, so Swap's example is now on Blinking and Cut's on Translocation.
- **The deer** got a rounded neck (it read as a plank).

## Stage 2: built (2026-11-16, on the owner's "begin stage 2"; not yet run)

| Power | Recipe | What it does |
|---|---|---|
| **Anchor** (`space_anchor`) | Blinking · position · bind | Space remembers where you stand: one anchor each, kept for the session. |
| **Recall** (`space_recall`) | Blinking · position · release · aura, burst, zone or ritual | Back to your anchor. Reach by tier: 250 → 1,800 studs, the whole island from Grandmaster. From Grandmaster, party mates within 14 studs come too. A far anchor waits up to 10 s for its ground. |
| **Stretch** (`space_stretch`) | Folding · distance or volume · amplify · zone, burst, wall or ritual | For 8–16 s, everyone inside but you is `space_stretched` (walk ×0.4). Anyone else's bolts crossing it slow to ×0.45, once each. You get 2 at once and the server 16. |
| **Pocket** (`space_pocket`) | Pocketcraft · volume · amplify, store or transfer · aura or touch | Opens your saved pocket (`data.spacePocket`, 6 → 22 slots by tier; it never shrinks) as a container window, usable anywhere for 30–120 s. It's in your own save, so it can't be duplicated across servers. |
| **Clairsentience** | Spatial Sense · orientation · sense | Sense sight's new `space` kind: every body, door (tag `Door`) and container, through walls. The radius is ×2.2 the usual, up to 200 studs. Bodies and doors are outlined in pale blue, containers in gold. |

- Swap is now transmute only, because bind on position is the Anchor.
- **Code:**
  - Server: `SpaceRuntime` (anchors, recall, stretches and their interceptor `"bend"`, matesHook, pocketHook), `ContainerService.openPocket` (a container whose "part" is your root, reachable only by you while it's open), `Cast/SenseSight` `gatherSpace`.
  - Client: `SenseController` draws the `space` kind; `Fx/SpaceFx` draws `anchor`, `stretch` and `stretch_end`.
  - Save: `Schemas` `spacePocket`.
- **Specs:** expected boot line **`specs 1160/1161`** (one new spec in Space.spec; the one failure is the known Standing room spec).

## 5. Open questions for the owner

1. Is Space meant to be overpowered like Time and Gravity (it's Rare, not Mythic)? Default: strong but limited: costs stay `costMult` 1.3, and seals are capped against players.
2. Gates: may enemies use your gate? Default: yes, anyone can, because it's a real hole in space.
3. Worldgate: per server for an hour (default), or saved for every server like Wild Zones?
4. Pocket storage: should items in the pocket be lost if you die or go down? Default: no, they're safe.
5. Mindlink: allowed to reach players outside your party? Default: party only, for safety.
6. Start with stage 1?
