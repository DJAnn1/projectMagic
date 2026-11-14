# Spell overhaul: audit and plan

Written 2026-11-12 on the owner's request: "expand on the current spell system to make it similar to those bosses we just did. The spells need to be more fun, a lot of them feel generic in what they do and how they look. Audit the potential spells and what they can do and design a plan on improving them. I also want health to increase with skill increasing as your magic gets stronger."

Stages are at the end, smallest and safest first. **Stage 0 built and confirmed 2026-11-13** (baseline `spellaudit`, power 5: 40,622 recipes; harm 7,496 = 18.5%; manifest 10,683 = 26.3%; power 8 the same). **Stage 1 built 2026-11-13, not yet run:** every harmful property that reached `harm` now has a behaviour (`Shared/Magic/Data/PropertyBehaviours`, `Server/Magic/Cast/PropertyBehaviour`, applied in `Effects/Impact` and `Effects/Thermal`; 9 new statuses). A new stage is needed for the **manifest** pile (26%: presence, density, humidity, perception, warding, growth, hardness, viscosity, distance, emotion, aether, buoyancy, contour, purity), the non-harmful properties with no effect; not in the original plan. Earlier note: (health from magic: `Shared/Magic/MagicHealth`; the audit: `Shared/Magic/SpellAudit`, admin `spellaudit`, `magichealth`), not yet run. The rest is design only.

## 1. Audit: what a spell can be, and what it actually does

### The grammar is huge

A spell is `branch + property + verb + form + power + modifiers`: 12 domains (~130 branches, 10 hybrids), 58 properties, 10 verbs, 11 forms (touch, projectile, beam, chain, burst, zone, aura, wall, pillar, ritual, summon), power 1–10. Tens of thousands of valid recipes.

### But they collapse into a few behaviours

`Shared/Magic/Data/EffectLibrary` sends every recipe to the **first** matching route, out of about 60. The specific routes are rich: Time, Gravity and Reality powers, disasters, fields, statuses, Siphon, Blink, Wave, Metal, Terrain. Everything else falls through to two catch-alls:

- **`harm` → `Effects/Impact`**: any harmful property with an offensive verb that no earlier route claims. Impact does the same thing for all of them: damage to whatever the form reaches. Its only property-specific extras are that charge conducts through metal and water, strong area harm throws loose parts, and a heat or light beam warms the part it hits.
- **`manifest`**: anything not harmful and not claimed. It only sets a hidden attribute; the Composer already labels these "No real effect".

Harmful properties whose offensive casts land **entirely or mostly in `harm`**, and so play the same:

| Property | Domain(s) | Today | What it should feel like |
|---|---|---|---|
| radiation | energy | plain damage | sickness that lingers and ignores armour |
| charge | energy | damage + conduction | lightning: chains, stuns, arcs between metal |
| sound | air, mind | plain damage (reduce = silence) | shockwave cones that knock back and deafen |
| resonance | earth, crystal | plain damage | delayed shatter that breaks guards, wards and constructs |
| phase | water | plain damage (reduce = freeze terrain) | freeze, melt, boil: chill that builds into a freeze |
| breath | air | plain damage | suffocation: drains stamina, slows, stops sprinting |
| cohesion (outside earth) | earth, void | plain damage | armour-crumbling: defence down, things fall apart |
| weight (outside gravity) | gravity, earth | plain damage | slams: knockdown, craters |
| soul | spirit | plain damage | pierces wards, marks the soul (bonus damage after) |
| essence (except transfer) | spirit, life | plain damage | burns the target's reservoir |
| unlife | spirit, void | plain damage | withering: grows worse each second, a kill feeds you |
| age | time | plain damage | ageing: slower, weaker, wears gear out |
| luminosity (projectile, beam, chain) | energy | plain damage | blinding lances, burning light |
| vitality / metabolism (reduce) | life | plain damage | sapping: heal-block and slow |

About **14 of the 28 harmful properties** have no identity of their own. Fire (combustion, temperature), poison, rot and hex (afflict), force (momentum, pressure, flow), seismicity and magnetism do have routes, but even those mostly mean "damage plus one status".

### Verbs barely matter for harm

For a harmful property, the 7 offensive verbs (generate, amplify, reduce, transfer, redirect, release, transmute) all reach the same Impact call. "Amplify fire" and "release fire" do the same thing.

### Looks: domain colour × form shape

`Client/Fx/SpellFx.spell` draws by **form** (an orb in flight, a beam, rings, a rune circle, a column) in the **domain's palette**, tinted by your signature, refined by mastery tier. The **property** changes the look in one place only: charge draws lightning instead of a beam. So the 12 domain looks multiplied by about 8 shapes are all the variety there is. A sound bolt, a radiation bolt and a soul bolt from the same domain look the same.

### What the Wildborn have that spells don't

Every Wildborn move has its own **shape** and its own **rule**: a lob that arcs, a dash with a burning trail, an eruption marching in a line, a zone that pulls, a tether that drains, a rain of warned strikes, an echo that hits twice, a rally that changes the fight. Players have one shape per form, and the rule is always "damage now".

### Health

Player max health is `StatDefs.health.base = 100` plus gear affixes (`Shared/Items/StatCalc`). It never grows with magic. Meanwhile spell damage grows with power (`DamageModel.base = 9 × power^0.6`: about 9 at P1, 36 at P10, before crits and modifiers), and Wildborn bosses hit for 20–77. Late-game players are glass.

## 2. The plan

### A. Each harmful property gets a behaviour (fixes "what it does")

New data, `Shared/Magic/Data/PropertyBehaviours`: one entry per harmful property, read by `Impact` (and by the routes that already exist, so fire and frost gain too). Each behaviour is a **rule on hit** built from parts the game already has: statuses, `Damage.apply`, Conduction, knockback, terrain, Explosion.

| Property | On hit | At higher power or tier |
|---|---|---|
| combustion | burning (a stack of damage over time); fire spreads to flammable ground | P6+: the burn spreads to people next to the target |
| temperature (cold) | chill stacks: each slows more; 3 stacks = a short freeze (root) | ice shell: the next hit on a frozen target shatters for bonus damage |
| charge | jumps to 1 + power/3 nearby (not only chains); a 0.3 s stun on a crit | conducts through every metal part in range, drawn arc to arc |
| radiation | lingering sickness: damage over time that ignores wards and armour | leaves a glowing patch that ticks on whoever stands in it |
| sound | a knockback cone from the caster; deafened (silence for 0.5 s) | P5+: breaks guards outright |
| resonance | marks the target; 1.2 s later it shatters for a second hit (Echo) | double damage on constructs, walls, wards; breaks glass and crystal |
| phase | chill stacks (as cold) or, with amplify, scald (burning); flips ice to water and back | boiling: a steam burst blinds |
| breath | suffocating: drains stamina, slows, no sprint or dash | P6+: a choking zone |
| cohesion | crumbling: defence down, the next hits deal more | breaks walls and constructs it touches |
| weight | slam: knockdown and a small crater outside towns | P6+: crushes everyone near the target too |
| soul | pierces wards; marks the soul (+15% damage from you for 6 s) | a kill frees a wisp that heals your reservoir |
| essence | burns the target's reservoir (players) or stops them casting (NPCs) | drained reservoir comes back to you |
| unlife | withering: damage that grows each second it's left | a kill lets you raise it as a brief ally (the first real "summon") |
| age | ageing: slower and weaker; wears the target's gear | P7+: brittle (crits on them always land) |
| luminosity | blinds on a crit; a beam burns a line on the ground | P6+: a lance that pierces everyone in line |
| vitality / metabolism (reduce) | heal-blocked and sapped (slow) | spreads to whoever heals them |

**Verbs flavour the behaviour** (data, not code per spell):
- generate: the base rule.
- amplify: bigger on a target already affected (detonates stacks).
- reduce: the defensive side (chill, silence, weaken) with less damage.
- transfer: half of it comes back to you (a tether, drawn as one).
- redirect: knockback or pull.
- release: everything you've stored of that property at once (ties into `store`).
- transmute: converts one stack into another (burning into chill, etc.).

### B. Forms get shapes from the boss move library (fixes "how it plays")

Extract the shape parts of `Wildborn/WildbornMoves` into a shared `Magic/Cast/Shapes` used by both Wildborn and player spells, so there's **one** move library. A recipe's shape comes from **form + property category**, in data (`Data/SpellShapes`):

| Form | Shape by category (examples) |
|---|---|
| projectile | orb (energy), arcing lob (material and earth: boulders), homing wisp (spiritual), splitting shards (cold), skipping ripple (sound) |
| beam | lance that pierces in line (light, radiation), drain tether (vital, essence), crackling arc (charge) |
| chain | jumping arcs (charge), hopping spores (toxin), ricochet (momentum) |
| burst | nova rings (thermal), eruption around you (earth spikes, vines), shockwave cone (sound), frost nova |
| zone | lingering ticking area with a look per property: fire field, whirlpool (flow), static field (charge), blizzard (cold), rot bog (decay) |
| pillar | eruption under the target after a warning: flame pillar, geyser, stone spike, lightning strike |
| wall | a barrier whose property acts on whoever crosses it: burning, freezing, shocking, repelling |
| ritual | a rain on warned spots across the area: meteors (fire), skyfall (charge), hail (cold), boulders (earth), at power 8+ |
| touch | echo strike: the hit lands again 0.6 s later (the Chrono Phantom's move) |
| aura | pulses around you every second while it lasts |
| summon | a short-lived conjured ally shaped by the property (an ember sprite, a stone fist, a frost wisp): finally gives summon a body |

Big area shapes (pillar, ritual, wide zones) **show a ground warning to everyone** first, as the bosses do. That's fair in PvP, and readable.

### C. Every property looks like itself (fixes "how it looks")

Extend `Client/Fx/FxRecipes`, which today is per domain, to **per-property looks** layered on the domain palette and your signature tint. Each one has a cast, a flight or trail, an impact and a lingering effect: flames and embers, frost shards and mist, forked lightning, sound ripples bending the air, crystal shards and a hum, green radiation motes, a dark gravity warp, ghostly soul wisps, dust and sand for age, rot spores. Built from the Kenney textures already uploaded; any new sounds need licensed picks. Mastery tier still refines it (more layers, a second rune at Expert, a crown at Grandmaster), and the Spell Hand still shapes your cast.

### D. Spells evolve with mastery (like boss phases)

Per behaviour, data unlocks at tiers: Adept is the base; Expert adds a second effect (a projectile volley of 3, a second ring, a bigger patch); Master adds the "higher power" column of table A; Grandmaster adds a finisher (a shatter on frozen targets, a detonation of stacks). You see and feel your spells grow, the way a boss changes at half health.

### E. Domain ultimates

Ritual form at power 8+ in a domain's signature property becomes that domain's **ultimate**, taken straight from the bosses: Meteor Cascade (fire), Skyfall Tempest (charge), Maelstrom Crucible (flow), Forge of Tyrants (metal), Verdant Storm (growth), Eclipse Erasure (shadow), Causal Collapse (time). Each costs a lot, gets a long cooldown, and is warned to everyone in reach. Time, Gravity and Reality keep the powers they already have.

### F. Health grows with your magic

Add a **"magic" layer** to `StatCalc` (it already gets the caster), so it shows in the Inventory stat breakdown as its own line ("Your magic: +120"):

- **+20 per tier of your best branch** (Sensing +20 … Transcendent +160)
- **+4 per other branch at Novice or above**, at most +60 (breadth matters a little)
- **Life domain affinity:** up to +10% on top

That's 100 at the start, about 180 at Adept, about 260 at Master, and about 330 at Transcendent with breadth. Health keeps its current share when the maximum moves (InventoryService already does this). NPC mages get the same rule from their tier (`NPC/NPCMagicLife`), so fights stay even. The 60% PvP per-hit cap stays.

### G. Tools so we can measure it

- Admin `spellaudit`: enumerate every valid recipe the grammar allows and count them by route and behaviour. It's the number we watch go from "about half land in harm" to "none are plain damage".
- `spellpreview <recipe>`: cast any recipe at a dummy and show its shape, behaviour and look.

## 3. Stages

| Stage | What | Size | Why this order |
|---|---|---|---|
| 0 | F (health from magic) + G (`spellaudit`) | S | Independent, quick, and the audit numbers measure everything after |
| 1 | A (property behaviours) for the 14 generic properties, plus fire and cold | M | The biggest "feels generic" fix, server-only, no new visuals needed to work |
| 1b | Utility for the "no real effect" pile (26% of recipes, non-harmful properties) | M | Found by the stage 0 audit; not in the first plan |
| 2 | C (per-property looks) for the same 16 | M | Makes stage 1 visible |
| 3 | B (shapes from a shared move library) | L | The deepest change: touches CastService, Delivery, Targeting and SpellFx |
| 4 | D (mastery evolutions) + verb flavours | M | Builds on 1–3 |
| 5 | E (domain ultimates) | M | The capstone, reusing the boss moves |

Each stage gets specs (behaviour data valid, every harmful property has a behaviour, shapes routed, health curve), Composer words (`RouteSummaries` says what a spell really does), `SpellExamples` entries, and a playtest before the next.

## 4. Risks

- **Balance:** statuses and shapes add damage on top of `DamageModel`. Each behaviour's extra is budgeted as a share of the base curve, and PvP still caps a hit at 60% of max health.
- **Server cost:** lingering patches, zones and rains are capped like the bosses' (`maxZones`, `EffectBudget`). Shapes reuse the budget slots spells already use.
- **Exploits:** nothing changes on the client side: casts stay intents, every shape is server-decided, and clients only draw cues.
- **Old saves:** recipes don't change shape, so no `RECIPE_VERSION` bump. Routes are resolved at cast time.
- **The world-over-game rule:** behaviours are physical (frost freezes, sound shakes, age wears), told by how they look and the Composer's words, with no new UI.

## 5. Decisions (owner, 2026-11-13)

1. **Health:** about **1000 at the very top**. Now `Data/MagicHealth.byTier`, a curve that climbs faster near the top: Novice ~160, Adept ~210, Master ~380, Transcendent ~940, ~1000 with full breadth, ~1100 with Life affinity. NPC mages follow the same rule. Damage per hit is still 9 (P1) to 36 (P10), so top-level fights now take far more hits: see the open question below.
2. **Domain ultimates (stage 5):** inspired by the boss moves and borrowing from them, not exact copies.
3. **Player-summoned allies: yes, as elementals that depend on the branch** (stage 3's `summon` shape).
4. **Ground warnings for players' own big spells: yes**, as the bosses have (stage 3).
5. **The water freeze route stays crowd control** (no damage).
6. **Per-property sounds: yes, but last**, after the other stages. Stage 2 keeps each domain's sounds.

### Open questions

1. With health at ~1000 at the top and damage unchanged, should damage also grow with mastery (so fights between high-level players don't take 30+ hits), or is a long fight what you want at the top?
2. Is a 1.4 s freeze after three chills too strong for PvP?

## 6. Stage 2 as built (2026-11-13, not yet run)

- `Shared/Magic/Data/PropertyLooks`: a layer per property (all 23 with a behaviour) over the domain look: colour pull, body and spark particles, smoke, light, ground mark, beam style (`lightning`, `ripple`), impact flourishes and a lingering effect.
- `Client/Fx/DomainFx.look(domain, property)` merges it (cached); SpellFx uses it for casting, flight, impact, beams and chains; Fx/Conjure for the spell forming in your hand. New texture roles: shard, ring, mote, wisp, spore, dust, crackle (first picks from the Kenney names, in `DomainFx.UPLOADED`).
- `Client/Fx/PropertyFx`: tint, flourishes (shards, rings, fork, flare, motes, gust, crush, dust, warp, splash, drain, spores, wisps, embers), lingering effects (mist, embers, motes, spores, dust), ripples along beams.
- Statuses on bodies: `Cast/StatusEffects` tags a Humanoid `MagicStatused` while it carries any status; `Shared/Magic/Data/StatusLooks` + `Client/Controllers/StatusLookController` + `Fx/StatusFx` draw them on everyone nearby (140 studs, 40 bodies): frost, an ice shell for frozen, flames, green motes, rot, stars for dazed, and the rest.
- New ground mark `stain`. Flag `property_looks_enabled` (replicated). Spec `Tests/PropertyLooks.spec` (6).
- Test: `fxpreview <domain> 6 <property>` for each property; then real casts at `dummy spawn` to see body statuses.

## 7. Stage 3 as built (2026-11-13, not yet run)

Split in two: **3a shapes** (built) and **3b elementals** (summon by branch, next: an ally that picks targets and fights needs its own step). Wildborn keep their own move library for now; moving them onto the shared shapes is a later cleanup, so nothing that works breaks.

- `Shared/Magic/Data/SpellShapes` (form x property/category/"property.verb" -> shape) and `Shared/Magic/SpellShape.of` (shared by server and Composer). Only damaging routes (harm, thermal, ignite, strike) get a shape: control routes such as the water freeze stay control.
- `Server/Magic/Cast/Shapes`: `before` (lob/homing/skip steer `Cast/Delivery` through new context fields; erupt, rain and big zones send a ground warning to everyone near and wait), `after` (echo, split, lob splash, drain, nova, linger, barrier, erupt lift, rain drops, aura pulses). Every extra hit through DamageModel + PropertyBehaviour + `Targeting.canHarm`. Caps: 16 areas, 3 per player, 9 drops.
- `Client/Fx/ShapeFx` draws warnings (always, even far or reduced), drops, splits, drains, zones and barriers in the spell's own look; `WorldEffect` kind `shape`.
- The Composer appends the shape's line (`SpellOutcome`). Flag `spell_shapes_enabled`. Spec `Tests/SpellShapes.spec` (6).
- Known gaps: hits after the cast resolved aren't judged by settlement law (the pinned delayed-hits item); NPC mages don't use shapes yet (NPCCombat casts its own bolts).

## 8. Stage 3b as built: elementals (2026-11-13, not yet run)

Owner, 2026-11-13: "player elementals by branch, yes". A harmful Summon spell (one whose route lands damage: harm, thermal, ignite, strike) still lands its hit where you aim, and then **takes a body there** and fights beside you. Other Summon spells (heals, wards, the water freeze...) keep landing over the area.

- `Shared/Magic/Data/Elementals`: one per domain (ember wight, stone golem, tide spirit, gale spirit, thorn walker, phantom, wraith, hollow shade, fold walker, worn sentinel, weighted golem, conjured knight) and 31 branch overrides (frost wight, storm wight, iron golem, crystal golem, quake golem, magma golem, treant, bone servant, warden spirit...), each with a style, material, colours from the domain palette, size, speed and sturdiness. `Shared/Magic/Elemental` picks one by walking up the branch tree, and gives health, blow share, the limit and the Composer's words.
- Styles: **strike** (walks in, hits one), **bolt** (keeps its distance, throws the spell, needs line of sight), **slam** (walks in, hits everyone it fights around it).
- Strength: health `(60 + 20 x power + 30 x tier) x kind` (top ~800, under a top player's ~1000); each blow is 0.38–0.45 of the spell's base hit, x (1 + 0.05 x tier).
- `Server/Magic/Cast/Elementals`: an R6 humanoid rig (owner's rule for fighters), no name or health bar. It fights only those who fought you or it, those you fought (a practice dummy you hit counts), and Wildborn it sees; never bystanders. Leash 60 studs from you, follows when idle, steps back to you past 90. Blows go through DamageModel as your spell (wards, guards, PvP caps, kill rewards to you), then the property's behaviour. Ends after 25 s, when killed, or when you die or leave. One at a time, two from Master; a new one replaces the oldest. 40 per server.
- `ElementalOwner` attribute: your own magic never hurts it (`Targeting.canHarm`, `Damage.apply`); others can, where they may fight you.
- `Services/ElementalService`: who's fighting whom among players (TargetDamaged); non-players through the new `Damage.listenAttacked`. Admin `elementals [list|clear] [player]`, `elementalfor <branch> [power] [tier]`. Log `elemental_summoned`, `elemental_faded`, `elemental_killed`, `elemental_refused`. Flag `elementals_enabled`.
- Client: `Fx/ShapeFx` stages `rise` and `fade`; blows reuse `hit` and `split`.
- Composer: "A stone golem takes shape where you aim and fights beside you for 25 s: ..."; SpellHelp and the Expert tier text now say so.
- Spec `Tests/Elementals.spec` (7).
- Defaults said to the owner (open): 25 s, one (two from Master), others can hurt them.
- Known gaps: Wildborn and creatures don't attack elementals back; its hits on townspeople aren't judged by settlement law; it walks straight (no pathfinding); NPC mages don't summon.

## 9. Stage 4 as built: mastery evolutions and verb flavours (2026-11-13, not yet run)

Owner: "build the next stage". Data `Shared/Magic/Data/Evolutions`, rules `Shared/Magic/Evolution` (shared with the Composer), applied in `Cast/Shapes.find` (shape growth), `Cast/PropertyBehaviour` (Master, finishers, flavours) and `Effects/Impact` (the verb's damage share). Specs `Tests/Evolutions.spec` (5).

**Mastery** (tier in the spell's branch):
| Tier | What changes |
|---|---|
| Expert (5) | The shape grows once (`shapeGrowth`): +2 shards, +2 rain drops, +2 s linger, +3 s barrier, +1 pulse ring, +1 skip, a wider and harder nova, a wider lob splash, a harder echo, +10% beam drain, a higher eruption |
| Master (6) | The behaviour's "strong enough" effects (`minPower`) work at any power, and its statuses last ×1.25 |
| Grandmaster (7) | A **finisher** per behaviour (all 23): a hit on someone already carrying its status sets it off. Frozen shatters (0.9 hit), burning flares onto neighbours, dazed is arced by lightning (charge) or knocked flat (sound), sapped is drunk (you heal), crumbling shatters, knocked-down is crushed, withering blooms onto others, aged turns brittle (jinxed)... Once per target per second; checked before this hit's own effects |
| Transcendent (8) | The shape grows a second time; finishers ×1.5 |

**Verb flavours** (the plain-damage `harm` route only; elsewhere the verb already picks the spell): generate plain; amplify ×1.2; reduce ×0.9 and slows 2.5 s; transfer heals you 20% of the damage; redirect pulls them toward you; release ×0.95 and splashes 0.3 onto others within 6 studs; transmute jinxes them 4 s; bind ×0.85 and roots 1.2 s.

**Composer:** the power step lists "As you master it": the verb's flavour, then each tier's change, ✓ reached or ○ not yet (text, not colour alone).

**Test:** `testmage 4 energy`, then `testmage 8 energy`, comparing a cold bolt (`cast cryothermy temperature reduce projectile 6`, or the Composer) on a dummy: shards 3 then 5 then 7. At tier 7+: chill a target into a freeze, then hit it again for the shatter (a nova cue and a big number). Verbs: compare amplify, transfer (watch your health), redirect (on an NPC or `creature spawn`) and release next to two targets, all on a plain-damage property such as sound or momentum.

**Unverified:** finisher balance at ~1000 health (open question 1 still stands: damage doesn't grow with mastery, only these extras do); a redirect pull on a player goes through their client like knockback, untried with a negative speed.

## 10. Stage 5 as built: domain ultimates (2026-11-13, not yet run)

Owner: "go". A **Ritual at power 8+** in a domain's own magic, with an offensive verb, becomes that domain's ultimate. Inspired by the bosses' moves, not copies (owner's decision 2). Time, Gravity and Reality keep the powers they have; the earthquake and the tsunami stay what they were. Data `Shared/Magic/Data/Ultimates` (one `ult_<id>` route each, generated in `Data/EffectLibrary` and `Data/RouteSummaries`), resolver `Cast/Effects/Ultimate`, specs `Tests/Ultimates.spec` (3).

| Ultimate | Domain (properties) | What happens |
|---|---|---|
| Meteor Cascade | Energy (combustion, temperature) | 3 waves of 5 meteors on marked ground, burning it; then the middle explodes and throws them up |
| Skyfall Tempest | Energy (charge, luminosity, radiation, momentum) | 4 lightning strikes under everyone you can hurt, dazing; then the storm breaks over the area (knockdown) |
| Forge of Tyrants | Earth | 3 widening rings of spikes (lift); then a stone anvil crushes the middle (knockdown) |
| Maelstrom Crucible | Water | A 7 s whirlpool that pulls, grinds and slows; then bursts outward |
| Cyclone Throne | Air | A 6 s cyclone that pulls and lifts; then hurls everyone away |
| Verdant Storm | Life | 3 waves of thorns under everyone (root, poison); their life heals you |
| Shattered Mind | Mind | 4 waves of dread: dazed, afraid, dazed, silenced |
| Soulfire Requiem | Spirit | 5 falls of soulfire under everyone (soulmarked), healing you; a last toll |
| Eclipse Erasure | Void | A 5 s darkness that blinds and draws in; then it collapses |
| Fold of Worlds | Space | Everyone dragged to the middle, crushed, then thrown out |

- **Warned:** every strike shows its ground marks first (Fx/ShapeFx "warn"), to everyone near.
- **Hits:** through `DamageModel` (wards, guards, resistances, PvP cap) on people the caster may harm, each at most once per beat; the property's behaviour rides on each hit (so Grandmaster finishers apply). Roughly 2 to 4 base hits in total per target in the middle of it.
- **Limits:** a cooldown per caster per ultimate, 240 s at low tiers down to 90 s at Transcendent (`ULTIMATE_COOLDOWN`; the admin `cheat nocooldown` skips it); at most 4 running on the server (`ULTIMATE_BUSY`). Flag `ultimates_enabled`.
- **Not judged by settlement law** (the known delayed-hits gap).

**Test:** `testmage 8 all`, `cheat all`, then in the Composer a Ritual at power 8+ in each domain (e.g. Energy Pyromancy Combustion Amplify Ritual; Energy Electric Charge Release Ritual; Water Flow Amplify Ritual; Mind Will Amplify Ritual), aimed near a few `creature spawn`s or `wildborn spawn`. The Composer names the ultimate. Without `cheat nocooldown`, a second cast should be refused with "You haven't the strength to call that again yet."

**Unverified:** how the reused cues read at this scale (40+ studs of warnings, a zone the size of a whirlpool); knockback strength on players; server cost of 4 ultimates at once in a crowd (each beat at most 30 targets per spot).

## 11. Stage 1b as built: the properties that did nothing (2026-11-13, not yet run)

Owner: "let's look at stage 1b". The stage 0 audit put 26.3% of all valid recipes in `manifest` (no real effect), mostly 14 non-harmful properties used with verbs no route claimed. 26 new routes in `Data/EffectLibrary` (section "Stage 1b"), placed before the general catch-alls, mostly reusing `Effects/Status` with existing statuses, plus `Dispel`, `Force`, `Restore` and `Terrain`. `Effects/Status` gained:
- `targetsByForm`: a bolt, beam or touch reaches whoever you aim at; an area or aura reaches everyone around (harmful, `FOE`) or you and your allies (helpful, `FRIEND`);
- `reservoir`: refills each player reached (Aether's Wellspring, 8% + 1% per power);
- `extinguish`: fires in the area go out (Dry Air);
- `resist` and `magnitude`: give Evading its damage resistance (Keen Senses, 8% + 2% per power, capped at 50%) and Anchor Weight its extra damage (6% + 1.5% per power).

| Property | Verbs → effect |
|---|---|
| Presence | reduce, transmute: veiled (you; allies as an area) · generate, amplify: jinxed (exposed) |
| Density | generate, amplify: slow on a bolt; Anchor Weight on you and allies as an area · reduce: Featherweight |
| Humidity | generate, amplify (outside Water's pour): a mist veils you and allies · reduce: Dry Air puts out fires and burning |
| Perception | generate, amplify: Evading (dodge part of every hit) · reduce: blind · transmute: dazed |
| Warding | reduce, transmute: dispel · bind, transfer, redirect, release: ward on you and allies |
| Growth | reduce: slow · transmute: rot · release, redirect: heal (Restore) |
| Hardness | point forms (stone shapes stay for Earth's walls, pillars, bursts and zones): stone skin (ward) · reduce: crumbling |
| Viscosity | generate, amplify: slow (a bolt, or everyone in an area) · reduce: haste |
| Distance | generate, amplify, release, redirect, transfer: pushed (Force by verb) · reduce: pulled in |
| Emotion | amplify: courage (haste) · generate, release: fear · transmute, transfer, redirect: charm · bind: calm (Dread and Charm branches keep theirs) |
| Aether | generate, amplify, transfer, release: reservoir back for you and allies (reduce, transmute, bind stay Dispel) |
| Buoyancy | generate, amplify: Featherweight · reduce: sink (slow) |
| Contour | generate, amplify, transmute, bind as a projectile, beam, chain or touch: stone spikes rise where it lands |
| Purity | generate, amplify, transmute: purges poison, rot, hexes, sapping, sickness, withering and burning from you and allies · reduce: crumbling (rust) |

Specs `Tests/Utility.spec` (3): every named status is real; every targeted property and verb reaches a useful route as a touch and as a zone; and a log line (`stage 1b: N of M recipes ... still do nothing`) gives what's left of the pile. Run `spellaudit` for the whole picture against the baseline (manifest 26.3%).

**Still dead on purpose (for now):** verbs that make no sense for a property (presence redirect, humidity transfer...), and `linked`/`silent` modifiers. **Unverified:** whether Evading's resist and Anchor Weight's magnitude read as intended; mist and veil look (Veiled sets transparency 0.85).
