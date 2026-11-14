# Spell collisions and spell struggles (plan)

Written 2026-11-14 on the owner's "I do want spells colliding with other people's spells in a spell struggle. Make a plan for that." This revives idea #31 (Spells that collide, discarded 2026-11-09) with the struggle as its heart. **Stages 1 and 2 built 2026-11-14 on the owner's "build it now"; stage 3 waits for the playtest.**

## Built (stages 1 and 2), not yet run

The open questions took their defaults: hold to feed and tap to surge; bolts and beams; allies' spells pass through each other; players and NPC mages; both spells land on the loser; no meter.

- **Collisions** (`Cast/Delivery`): after every step, flights within reach of each other from people who could hurt each other (`StruggleService:canCollide`: `Targeting.canHarm` for players, anyone for NPCs and ferals) meet. They cut through, shatter, glance or are held for a struggle (`StruggleRules.outcome`). Every meeting leaves both spells' presences at the point, so `InteractionMatrix` reactions fire. A beam sweeps lighter bolts away (`Delivery.sweep`), and a beam meets a beam cast in the last 0.6 s from the other side (`Struggle.beam`, `Struggle.rememberBeam`).
- **Weight:** the charge stage is already inside the cast's power by the time it strikes, so there is no separate charge term (`StruggleRules.weight(power, form, tier)` × matchup).
- **The struggle** (`Cast/Struggle`, 10 Hz):
  - Both casters get the `struggling` status (no moving, no casting) and the `Struggling` attribute.
  - The cast button sends `StruggleIntent` "down" (a surge, and feeding) and "up" (stop feeding); routed in `CastClient.pressCast`, `releaseCast` and `pressSlot`. Jumping sends "break" (let go).
  - Endings: overwhelmed, let go (dodge by moving 5+ studs in 0.35 s), broken, or burst at 8 s.
  - NPC mages push by courage (`flight.side.courage` from `NPCCombat.courage`).
- **Look** (`Controllers/StruggleController`):
  - A flash at every clash.
  - In a struggle, two beams to a pulsing knot that takes the winner's colour; the loser's beam thins; the camera shakes nearby.
  - Your screen edges darken as the knot comes for you.
- **Flags:** `spell_collisions_enabled`, `struggles_enabled`. **Admin:** `struggles`, `struggleend`, `struggletest on|off` (a 3x band, so a strong mage can struggle a weak NPC). **Log:** `spell_clash` (at most 1/s), `struggle_started`, `struggle_ended` { how, loser, seconds, wa, wb }.
- **Spec:** `Tests/Struggle.spec` (5).
- **Not done yet:**
  - Ferals and Wildborn don't struggle: ferals shatter instead, and Wildborn bolts don't collide at all.
  - Arrows have no drawn re-cue when destroyed.
  - No sound yet.
  - Struggles grant no XP yet.

### Test
1. Expect `specs 1116/1117` (the failure being the known Standing room).
2. `testmage 8 all`, put a projectile spell on the hotbar, and walk up to a town guard or NPC mage. `npcfight` makes it fight you.
3. `struggletest on`, then fire bolts straight at it as it fires at you. Head-on meetings should lock into a struggle: you can't move, and a knot sits between you.
4. Click repeatedly to surge (the knot should move toward the NPC), stop clicking (it should drift back), and jump to let go. Dash sideways right after letting go to see if you dodge.
5. `struggles` while one runs; `struggleend` to burst it.
6. Without `struggletest`, cast a strong bolt into a weak NPC bolt: it should cut through (flash, the NPC's bolt gone).
7. Two players (Test > Clients and Servers, 2 players, PvP on): beams at each other at the same moment, and bolts head-on.

Look for in the log: `spell_clash`, `struggle_started`, `struggle_ended`, and any `[Delivery] collisions failed` or `[Struggle]` warnings.


## 1. The idea in one paragraph

Two mages' spells can meet in the air. Most meetings are quick: the stronger bolt cuts through, equal ones burst together, and opposed elements react where they meet (fire into water is a burst of steam). But when two spells meet **head-on and close in strength**, neither gives way: they lock into a **spell struggle**. The two casters are held where they stand, each pouring magic into a knot of light grinding between them. The knot creeps toward whoever is weaker or runs dry first, and when it reaches them, both spells land on them at once. There is no meter: the knot's position, its colour and the caster's straining body *are* the meter. Everyone nearby can see it, and people talk about it afterwards.

## 2. What exists today (audit)

| Piece | Today | What it means for this |
|---|---|---|
| Projectiles (`Cast/Delivery`) | Server-stepped flights, one Heartbeat stepper, one Spherecast per step; `interceptor` and `hanger` hooks; parry turns a flight back (`reflect`); clients mirror the flight from the `launch` cue and re-cue through `onReflect`/`onBend` | Flights can see each other cheaply: they're all in one `live` list. Re-cueing a changed flight already works. |
| Who flies through Delivery | player casts (CastService), NPC mages (NPCCombat), ferals (FeralService), arrows and knives (WeaponService) | All four collide for free. Wildborn bolts fly in their own system (`WildbornMoves`), so they don't, until stage 3. |
| Beams (`Targeting`, form `beam`) | An instant thick sweep from chest to point. With the **Channeled** modifier, a held beam pulses every `channelInterval` and follows `ChannelAim` | An ordinary beam exists for one moment, so beam-meets-beam needs a short memory of recent beams (§4.2). |
| Charge (`Magic/Charge`) | Quick, Charged, Full and Overcharged stages | A Full or Overcharged spell weighs more in a collision. |
| Reactions (`InteractionMatrix`) | Elemental tags per recipe (heat, fire, water, lightning...) and a reactions table | Opposed elements in a collision use the same tags and the same table. |
| Rules on who can hurt whom (`PvpRules`, `Targeting.canHarm`) | One rule for PvP, duels, blocks and parties | Spells collide only between people who could hurt each other. |
| Break the charge, Guard, Timestop, Bend Path, Severance | Each has its own hook into Delivery or the hold | A struggle must respect all of them (§7). |

## 3. Weight: how strong a spell is when it meets another

One number per spell, computed on the server at launch and stored on the flight:

```
weight = power^0.8 x form x charge x (1 + 0.04 x tier) x matchup
```

- `power`: the cast's final power, after gear, weather and Surge.
- `form`: projectile 1.0, beam 1.3, chain 0.8; Touch, aura and area forms never collide.
- `charge`: Quick 0.8, Charged 1.0, Full 1.25, Overcharged 1.5.
- `tier`: the caster's mastery tier in that branch.
- `matchup`: 1.2 when this spell's tags counter the other's (water against fire, earth against lightning...), 0.85 the other way round, otherwise 1. It comes from a small `counters` table beside the reactions, not hard-coded per pair.

The numbers live in a new `Data/Struggle` table so they can be tuned.

## 4. Stage 1: collisions

### 4.1 Projectile meets projectile

In `Delivery.step`, after a flight moves it checks the other live flights. Only a few dozen fly at once, and a 16-stud grid keeps the check cheap if that grows. Two flights collide when they come within `r1 + r2 + 0.5` studs **and** their owners could hurt each other (your own and your allies' spells pass through each other). What happens depends on the weight ratio `w = heavier / lighter`:

| Ratio | Outcome |
|---|---|
| Opposed tags in the reactions table | **React** first: the reaction fires at the meeting point (steam, sparks, a flash of ash), then apply the rows below |
| `w >= 1.6` | **Cut through**: the lighter spell is destroyed; the heavier flies on with its weight and damage cut by the lighter's share (`1 - 1/w`) |
| `1.15 <= w < 1.6` | **Shatter**: both end in a small burst at the meeting point (both splashes, half damage), the heavier one's burst biased forward |
| `w < 1.15` and head-on (directions' dot < -0.7) | **Struggle** (stage 2). Until stage 2 is built: a big shared burst |
| `w < 1.15`, not head-on | **Glance**: both bend away from each other by up to 25° and fly on |

Arrows and thrown knives weigh a fixed 0.6, so most spells burn them out of the air. Spells can't be shot down by arrows.

### 4.2 Beams

- **Beam through a flight:** a beam's sweep that crosses a live flight treats it as a collision, using the beam's weight. A strong beam can sweep bolts out of the air.
- **Beam meets beam:** CastService remembers each beam for `beamMemory` (0.6 s), and a held channel for as long as it's held. A new beam whose line passes within 2 studs of a remembered one, from someone it could hurt and facing it (dot < -0.5), collides with it at the crossing point. Head-on and close in weight → struggle; otherwise the heavier one cuts through or both shatter, as above.

### 4.3 What people see and hear

The existing `launch` cue and `onReflect`/`onBend` re-cues already let clients redraw a flight that changed. Stage 1 adds a `clash` cue (point, both domains, outcome) drawn by `Fx/ClashFx`: a burst in both palettes, sparks, and a short shockwave. The reaction's own cue draws on top.

## 5. Stage 2: the spell struggle

### 5.1 Starting

A struggle starts from a head-on meeting of close weights (above), between two bolts or two beams, and only when:
- both casters are standing within `maxGap` (80 studs) of each other;
- neither is already struggling, staggered or frozen;
- `struggles_enabled` is on, and the server has fewer than `maxStruggles` (6) running.

Both spells stop being flights. They become one `Struggle` owned by `Cast/Struggle` (a new module, server-stepped at 10 Hz):

```
{ id, a = side, b = side, point (0..1 along a→b), started, lastPushA, lastPushB, tags }
side = { model, player?, npc?, domain, property, weight, recipe, pushes, fed }
```

Both casters get a new action state, `struggling`. They can't move or cast anything else and they turn to face each other. Their cast poses hold the release pose with a shake (`CastPoseController`, already per kind).

### 5.2 Pushing

**Hold** the cast button to keep feeding the spell. It costs reservoir every second (the spell's channel cost, or its base cost per second if it wasn't channelled). **Tap** cast to pour in a surge: a push that costs a chunk of reservoir. Every second, each side's push is:

```
push = weight x (feeding ? 1 : 0.3) x (1 + surges this second x surgeBoost, surges capped at 4/s) x hurt
```

- `hurt` drops while you take damage from others, using the same rule as Break the charge, so a friend hitting your opponent helps.
- The point moves by `(pushA - pushB) / (pushA + pushB) x drift` per second (drift about 0.12, so a lopsided struggle lasts about 4 s and an even one up to the cap).
- When reservoir runs out you can **overdraw** with the existing overdraw rules and their backlash risk. That's the desperate last push.

The client only sends intents: `StruggleIntent { "feed" | "stop" | "surge" | "break" }`. That goes to a new remote, rate-limited to 8 per second, and the server ignores surges beyond the cap. It never sends the point or the outcome.

### 5.3 Ending

| How | Result |
|---|---|
| The point reaches within 3 studs of a caster | They're **overwhelmed**: both spells land on them (the winner's at full weight, the loser's own at half), plus knockdown. The winner earns XP like a hard-won hit. |
| A caster lets go (`stop` or `break`) | Their spell dies. The winner's spell flies on, from the knot, at whoever let go. A **dash sideways** in the same moment (the existing dash) can get out of its path: a real skill escape, decided by the server's flight. |
| `maxSeconds` (8 s) passes | The knot **bursts**: an explosion (the existing `Cast/Explosion`) at the point, hurting both casters by distance, throwing loose objects, scorching the ground |
| Either caster is knocked down, frozen, staggered, killed, leaves or teleports | The other wins at once (as if the loser let go). |

Duels keep their health floor, since everything goes through `Damage.apply`.

### 5.4 What people see and hear (no meter)

- Both beams, or both bolts stretched into beams, run from each caster to the **knot**, which sits at `point` along the line.
- The knot grows with the two weights, spits sparks in both palettes and shifts toward the colour of whoever is winning. The losing side's beam thins and flickers.
- The ground under the knot scorches (temporary), loose objects nearby get thrown, and the camera shakes more the closer you stand.
- A low hum rises in pitch with the struggle's length. A sound is needed from the licensed libraries (later, with per-property sounds).
- If you're the one losing, the edge of your screen darkens a little as the knot comes closer. It's the only thing drawn for you alone.
- Clients get one `struggle` cue at the start, then the point and the two shares at 10 Hz, and lerp between updates.

### 5.5 NPC mages

NPC fighters (NPCCombat) already cast bolts at players. When one of their bolts meets a player's head-on, they struggle too. Their feed and surges come from courage (traits, tier, health): a cowardly mage lets go early, a proud one overdraws. Guards and hunters nearby can join their side (stage 3).

## 6. Stage 3: the world around a struggle

- **Joining a side:** a third caster's beam or bolt that hits the knot from behind one caster adds its weight to that side for as long as it's held. Two weak mages can beat one strong one. This is the same rule as idea #15 Ritual circles, in miniature.
- **Hitting a struggler:** anyone can hit a struggling caster, and that caster's push drops by the Break the charge rule. The struggle is a moment of exposure.
- **Reactions at the knot:** when the two spells' tags react, the reaction fires again every 2 s at the knot (fire against water fills the street with steam).
- **The world remembers:**
  - NPCs who saw it keep a `spell_struggle` memory, gossip spreads it ("two mages locked spells in the square, the stranger won"), and it changes opinion like the other deed memories.
  - Your first struggle won and your first lost each get a first-person Journal line.
  - A struggle in a town with an explosion ending is judged by settlement law like any other harm.
- **Wildborn bosses:** their bolts move to Delivery, or `WildbornMoves` learns the same check, so you can struggle a boss's bolt.
- **Later, if wanted:** winning by a huge margin seizes the loser's spell, which is where #26 Spell seizure would grow from.

## 7. Interactions with what's built (rules)

- **Timestop:** a struggle inside the zone freezes (the point doesn't move, feeding costs nothing) and resumes after.
- **Gravity Bend Path or Orbit Shield, and Reality's Severance:** these act on flights before collisions, so a bolt they erase never collides. A struggle's knot is not a flight and they don't touch it.
- **Guard parry:** a parried bolt turns back and can collide on the way. A struggling caster can't guard.
- **Surge, Weather as fuel, Marks:** they all already feed into power, so they feed weight.
- **Elementals, ferals and ultimates:**
  - Elemental and feral bolts collide.
  - A feral can struggle, using its energy as its reservoir.
  - Ultimates' warned strikes and rains are not flights and never collide.
- **Break the charge:** a struggle is not a charge. Its own `hurt` rule applies instead.
- **Blocked players and PvP off:** their spells pass through each other, as if the other weren't there.

## 8. Code plan

| Piece | Where | Stage |
|---|---|---|
| Weights, counters, outcome bands, struggle numbers | `Shared/Magic/Data/Struggle` | 1 |
| Pure rules: weight, outcome, push, point step, ending | `Shared/Magic/StruggleRules` | 1–2 |
| Flight-vs-flight check and outcomes | `Cast/Delivery` (a `collider` step after moving; `weight` and `tags` on `Flight`) | 1 |
| Beam memory, beam vs flight, beam vs beam | `CastService` (strike for `beam`), `Targeting` | 1 |
| Clash look | `Fx/ClashFx`, cue `clash` | 1 |
| The struggle itself | `Cast/Struggle` (server, 10 Hz) and `Services/StruggleService` (intents, admin, log) | 2 |
| Action state `struggling` | `Data/CombatAnimations`, `Magic/ActionRules`, `Cast/ActionState` | 2 |
| Input | `CastClient` (holding and tapping cast while struggling send `StruggleIntent`) | 2 |
| Look | `Controllers/StruggleController`, `Fx/StruggleFx` (beams, knot, sparks, the losing edge) | 2 |
| NPC mages | `NPC/NPCCombat` (feed and surge from courage) | 2 |
| Joining, reactions at the knot, memories, Journal, Wildborn | `Cast/Struggle`, `NPC/MemoryService` kinds, `JournalService`, `Wildborn/WildbornMoves` | 3 |
| Flags | `spell_collisions_enabled` (stage 1), `struggles_enabled` (stage 2) | 1–2 |
| Admin | `clash` (fire two test bolts at each other in front of you, at chosen weights), `struggle start <npc>` (a struggle against a nearby NPC mage or a dummy that feeds steadily), `struggle list`, `struggle end` | 1–2 |
| Log | `spell_clash` { outcome, w, domains }, `struggle_started`, `struggle_ended` { how, seconds, winner, surges } | 1–2 |
| Specs | `Tests/Struggle.spec`: weight ordering, outcome bands, own spells never collide, blocked players pass through, point step and endings, surge cap, Timestop freeze | 1–2 |

## 9. Risks

- **Performance:**
  - Flight-vs-flight is O(n²) per step. It's fine for the few dozen flights `maxActive` allows, and the grid keeps it cheap past that.
  - Struggles run at 10 Hz and are capped at 6 per server.
  - The cue at 10 Hz goes only to players within 300 studs.
- **Exploits:**
  - Autoclickers are capped at 4 surges a second, and each surge costs reservoir, so clicking faster gains nothing.
  - A client never reports the point.
  - A struggle can't be used to root someone forever: letting go always ends it, and `maxSeconds` caps it.
  - Starting a struggle needs a real head-on meeting checked on the server.
- **Griefing:** forcing someone into a struggle costs the attacker the same. Letting go and dashing gives an out. Blocked players never collide.
- **Feel:** whether tapping feels good, and whether 8 s is too long, can only be judged in play, so the numbers stay in data.
- **Things that could look wrong:**
  - Two bolts that are visually close but don't collide on the server, because the client draws from the launch, not the server's position. Snapping to the server's clash point hides it.
  - Instant beams need the 0.6 s memory to meet at all.

## 10. Open questions for the owner

1. **Controls in a struggle:** hold to feed and tap to surge (the default above)? Or hold only, so it's purely strength and reservoir? Or also sway the knot sideways with your aim?
2. **Which spells can struggle:** bolts and beams (the default), or beams only, the classic look?
3. **Allies' spells:** pass through each other (the default), or can friends' spells collide by accident too?
4. **Who you can struggle:** players and NPC mages in stage 2, Wildborn bosses in stage 3 (the default)?
5. **The loser:** both spells land on them (the default), or only the winner's?
6. **Any on-screen meter at all?** The default is none, only the knot and the darkening edge when you're losing.
7. **Where it goes in the queue:** right now, before group 3 (NPCs noticing)? Or with the Spellcraft group (group 4, next to Catch and throw and Spell seizure, which it overlaps)?
