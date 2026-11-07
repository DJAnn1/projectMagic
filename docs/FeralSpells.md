# Feral Spells

A strong spell that gets out of control can tear loose and go on existing in the world for a while. Built 2026-11-07 on the owner's "build feral spells", not yet run. Every number is a first guess.

Specs: `Tests/FeralSpells.spec`.

## The rule behind this design

The owner turned down Tournaments as "too streamlined": "too much like a game attribute instead of a realistic world attribute". So Feral Spells is built to be something that happens in the world.

**There's no interface at all:** no card, map pin, announcement, remote, name or health bar. You watch one get loose, you run into one, or someone tells you about it. The only client code is cosmetic: `Fx/FamiliarAnimator` moves its pieces, because doing that from the server would flood the network.

## Where it lives

| What | Where |
|---|---|
| Numbers, bodies and words | `Ferals/Data/FeralData` |
| Decisions (pure) | `Ferals/FeralRules` |
| Running it | `Services/FeralService` |
| Cause | `Topics.ControlLost`, from `BacklashService.controlLoss` |
| Rumours | `NPCService.setRumorHook`, which now takes several, and these go first |
| Save | `PlayerData.feral.studied` |

Flags: `feral_spells_enabled`, `feral_spells_max` (6).

## How it works

**Getting loose.** A backfire at power 6+ is already a loss of control. On top of that, there's a seeded chance it gets away: 25% at severity 1, up to 70%. Limits: 6 on a server, one per caster, and 4 minutes between escapes per caster. In a Rift, it stays put and nothing escapes.

**NPC accidents.** Every 25 minutes, the same on every server, there's a 60% chance a seeded NPC mage of Novice or above loses hold of their attack spell. So this happens with nobody around.

**Energy.** A loose spell runs out from the moment it escapes: 10 minutes plus 2.5 per power, before drain. It drains 0.4× as fast where ley energy is thick and 1.6× where it's thin. It leans towards that energy as it wanders, so loose spells tend to end up along ley lines. When it runs out, it gutters away and nobody is told.

**Body.** It only has one with a player within 180 studs, like a creature den. With nobody near, it's a position and a number, and it still moves. It's a real Humanoid, so every spell, status and weapon works on it. Its own domain barely hurts it, and opposed domains hurt it more (water on fire).

**Its magic.** It casts the actual spell at half strength, through `Delivery` and `DamageModel`, with no source player, so nobody is blamed for what it does. It discharges at players and NPCs alike. It isn't a hunter: it goes for whoever hit it, or whatever comes within 22 studs. It turns towards magic cast within 90 studs, so going quiet is a real way to avoid one.

**The world.** Its domain carries over (`FeralData.effects`). A fire spell sets what it passes alight and burns who it hits, water puts fires out, air throws people back, and the rest land a status: earth slows, mind dazes, gravity pins, and so on. Fires it starts are never saved to the island, though burned grass stays bare for a while (`docs/TownRepair.md`).

**Towns.** Guards and hunters within 70 studs come for it through the same `NPCCombat` as any fight, and can bring it down without you. Everyone else runs when it's within 30, and some shout. Once hurt, it lashes out at anything within 34 studs, since it can't tell who did it. This only happens for NPCs with a full body, near a player: with nobody around, the fight doesn't happen. If guards kill it, nobody learns anything from it unless a player also hurt it.

**Memory.** People remember, through `MemoryService`:

| Memory | Who has it | About | Effect on opinion |
|---|---|---|---|
| `lost_control` | Anyone within 70 studs when it got loose | Whoever lost it, player or NPC | Mildly negative |
| `spell_hurt_me` | Whoever it hurt | Whoever lost it | Negative |
| `ended_it` | Anyone within 70 when it fell | Who dealt the most | Positive |
| `cleaned_up` | The same, when that was its own caster | Its caster | Mildly positive |

All of them spread through ordinary gossip, weaker second-hand. Opinion follows, so people greet you warily or warmly and may bring it up. Being hurt by your spell also costs 2 standing in that person's town, for up to 3 hits per spell. It isn't a crime, because it was an accident. Bringing one down in front of people earns 3 standing, or 1 if it was yours. Asked for rumours with nothing loose nearby, someone may tell you what they remember, once per session, in different words if it's about you or if they only heard it. Saved memories hold an id, never a player's name, so erasure stays clean.

**What it leaves.** Everyone who dealt 20% of its health gets a Journal clue naming the recipe's branch, property, verb and form, plus some XP if they hit it with magic. It's only for a spell you don't know and haven't studied. Your own backfires teach you nothing, so failing on purpose earns nothing.

**Rumours.** Ask a townsperson. They may mention one within 1,100 studs, naming who lost it and in which direction. It goes in your Journal and marks nothing.

**Not saved.** A loose spell lasts as long as its server at most. Only what you've studied is saved, so progress resets and erasure already cover it.

## How it looks

There's no shell or outline, only loose pieces around a small centre, in a way that suits the domain (`FeralData.styles`): a gust is long pale streaks circling, earth is tumbling rock, fire is flecks that wink in and out, a life spell is drifting leaves. Pieces are seeded, so two loose spells of a domain differ, but one keeps its body each time it wakes.

Everything keeps moving, and the model's `Unstable` attribute (0 to 1, in tenths) makes it faster, wider and less steady as its energy runs out. So you can judge how close one is to guttering out just by looking at it. Nothing tells you what it is.

## Admin

`feral list | spawn | goto | clear`. `spawn` looses your first known harmful spell 18 studs ahead of you. Because you know that spell, killing it gives no clue. To test a clue, use a spell you don't know, such as an NPC accident's.

## Log lines

`feral_escaped`, `feral_woke`, `feral_fell`, `feral_guttered`, `feral_studied`, `feral_rumor`, `feral_step_failed`, `feral_accident_failed`.

## Parts that still feel like a game

Flagged for the owner, given the rule above:

- **The clue** is a tidy Journal sentence. Something you have to work out from how it behaved would be more realistic, and harder to make fair.
- **"It got away"** is a floating word over it, the one small notice in the system.
- **Lock-on and damage numbers** still work on it, as on everything else.
- **The 20% credit line** is a game rule, there to stop someone learning from one stray hit.

## Known limits

- Its effects come from its domain, not its actual recipe, so two fire spells that did different things behave alike.
- A burning part can still start a saved scorch through `FireSim`: only ground fires carry `unsaved`. It should be rare, but it isn't ruled out.
- What it burned recovers through `docs/TownRepair.md`, not through anything here.
- A guard who brings one down gets no credit: nobody remembers it as their doing.
- Memories are about people, not the event: someone can't say where it happened.
- With a player offline, people call them "a traveller".
- It moves in straight lines through the air on a Humanoid, so a wall can stop it for a while.
- NPCs don't know the caster's story beyond the rumour line.

## Ideas for later (nothing chosen)

Spells that use their real recipe's effects. Several gathering at a ley line and interacting. A way to bind one rather than destroy it.
