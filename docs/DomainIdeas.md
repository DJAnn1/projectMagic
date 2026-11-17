# Domain expansion: more spells for the eight ordinary domains (design only)

Written 2026-11-17. Owner: "I just want the domain itself to be expanded with more possible moves that are visually interesting and fun. Do not approach this with an ultimate move mindset. Approach it with naturally expanding the domains with new possible spells that fit." (Replaces the first version of this doc, which pitched one signature power per domain; that one is in git at `67628da`.)

Nothing here is built or approved.

## The problem

Energy, Earth, Water, Air, Life, Mind, Spirit and Void have about 117 routes between them and every other domain, but most offensive recipes still land in a few broad routes (`harm`, `force`, `afflict`, `ward`), given variety by property behaviours and shapes (`docs/SpellOverhaul.md`). So a stone bolt and a fire bolt fly the same way and differ mostly in colour and status. These domains need **more distinct moves**: spells that do a different thing, look like nothing else, and sit naturally in their branch.

## How a new spell fits the grammar

Each spell below is a **recipe**: property · verb · form (plus the branch that opens it). Building one means a specific route in `EffectLibrary` placed **before** the broad routes it would otherwise fall into, a resolver (often a small variant of an existing one), its look in `Fx/`, its words in `RouteSummaries`, and an example in `SpellExamples`. Power changes size and strength, the same as today. None of these are ultimates: most work from power 1–3 and grow with power and mastery like anything else.

Notation: **Name** (`property · verb · form`, branch): what it does. *What it looks like.*

Marks: ✦ = needs a shared piece of tech (see "Shared pieces" at the end). ⚠️ = a design worry, noted.

---

## Energy

### Pyromancy, Conflagration (combustion)
- **Ember Swarm** (`combustion · generate · burst`, Pyromancy): dozens of embers scatter outward and drift down, each one lighting what it lands on (grass, wood, cloth). *A fountain of orange sparks that hang and flicker before falling.*
- **Fire Whip** (`combustion · generate · touch`, power 3+): a lash 14 studs long swung in an arc, hitting everything along it. *A rope of flame that leaves a fading curve of sparks.* ✦ arc hits
- **Flame Serpent** (`combustion · redirect · projectile`, Conflagration): pull the fire out of something already burning and send it winding through the air at a target; it puts the source out. *A ribbon of fire that coils and snakes instead of flying straight.*
- **Ring of Fire** (`combustion · generate · wall`, Conflagration): a circle of flame around you that burns anyone crossing it. *Flames rising from a ring of scorched ground.*
- **Smother** (`combustion · reduce · zone`): fires in the area choke out into thick black smoke that blocks sight for a while. *Fire collapses into rolling smoke.*
- **Kindle Blade** (`combustion · amplify · touch` on an ally or yourself): your weapon burns for a while; hits ignite. *Flame running along the edge.*

### Cryothermy, Stillfrost (temperature, cold)
- **Ice Spike Line** (`temperature · reduce · pillar`): a row of ice spikes erupts from you toward the target, one after another. *Spikes punching up out of the ground in sequence.* ✦ travelling ground line
- **Frost Lance** (`temperature · reduce · projectile`, power 3+): a long icicle that pins whoever it hits in place for a moment, then shatters. *A glinting spear of ice, a burst of shards.*
- **Hoarfrost** (`temperature · reduce · zone`): the ground frosts over and turns slippery: people slide when they turn or stop. *White frost spreading across the ground, a crackle.* ✦ slippery ground (on the Combat.md to-do list)
- **Ice Mirror** (`temperature · transmute · wall`, Stillfrost): a wall of clear ice that bends beams back toward the caster. *A pane of ice with a bright glint.* ✦ beam reflection (Combat.md to-do)
- **Flurry** (`temperature · reduce · aura`): a whirl of snow around you that chills anyone close. *Snowflakes circling you.*

### Calefaction (temperature, heat)
- **Heat Haze** (`temperature · amplify · aura`): shimmering air around you; bolts aimed at you drift off line. *The air wobbles like over a road in summer.*
- **Boil** (`temperature · amplify · touch` on water): the water you touch flashes into a scalding burst of steam. *A white explosion of steam.*
- **Searing Ground** (`temperature · generate · zone`): the ground glows red-hot for a while; standing on it burns. *Cracks of orange light in the soil.*

### Photomancy, Irradiance, Umbramancy (luminosity, radiation, shadow)
- **Prism Bolt** (`luminosity · generate · projectile`): splits on impact into a fan of 3–5 coloured rays that hit what's behind. *A white bolt breaking into a rainbow.*
- **Sunspot** (`luminosity · generate · zone`): a column of hard light from above; foes inside are dazzled, allies glow. *A shaft of sunlight with dust in it.*
- **Wisps** (`luminosity · generate · summon`, non-harmful): small lights that follow you and light the way, and show veiled things they pass. *Floating motes that bob around your head.* ✦ small followers
- **Flash** (`luminosity · release · burst`): a blinding pop; everyone facing you is blinded. *A white flash and a ring of light.*
- **Glowing Poison** (`radiation · generate · touch`, Irradiance): the target glows a sickly green for a while, takes damage over time, and can't hide (they show through Sense and in the dark). *A faint green halo.*
- **Shadow Grasp** (`shadow · generate · touch`, Umbramancy): the shadows of nearby things stretch across the ground and hold the target's feet (root). *Dark hands rising out of shadows.*
- **Shade Cloak** (`shadow · amplify · aura`, Umbramancy): you darken, harder to see at range, stronger in shade and at night. *Your outline goes dim and smoky.*
- **Shadow Puppet** (`shadow · generate · summon`, Umbramancy): your shadow peels off the ground and fights beside you for a short while, copying your strikes weakly. *A flat black figure that stands up.* ✦ small followers

### Kinetic, Impetus, Deflection, Inertia (momentum)
- **Stomp** (`momentum · release · burst`): a shockwave ring along the ground that knocks people off their feet. *A ring of dust racing outward.*
- **Ricochet** (`momentum · generate · projectile`, Impetus): a bolt that bounces between up to 3 targets or off walls. *A glowing pellet pinging off surfaces.*
- **Repulse** (`momentum · redirect · aura`, Deflection): projectiles coming at you curve away. *Bolts bending round a faint bubble.*
- **Inertia Lock** (`momentum · bind · touch`, Inertia): the target can't change direction for a moment and keeps sliding the way they were going. *A blue trail behind them.*
- **Launch** (`momentum · amplify · touch` on an ally or yourself): hurl someone forward through the air. *A burst of force behind them.*

### Electromancy, Galvanism, Arcweaving (charge)
- **Ball Lightning** (`charge · generate · projectile`, Arcweaving): a slow, wandering ball that zaps anyone near it every half second until it pops. *A crackling sphere drifting along.*
- **Static Field** (`charge · generate · zone`): sparks jump between everyone inside; the more people, the more arcs. *Arcs flickering between bodies.*
- **Arc Tether** (`charge · bind · chain`): links two foes with an arc that hurts both while they stay near each other and snaps when they part. *A crackling line between two people.* ✦ tethers
- **Galvanise** (`charge · amplify · touch` on an ally): a burst of speed with sparks at the feet. *Blue sparks trailing their steps.*
- **Arc Fence** (`charge · generate · wall`): a crackling fence that shocks whoever crosses it. *Posts of light with lightning strung between.*

### Energy: built 2026-11-17 (not yet run)

On the owner's "amount of spells is fine, start with energy". All 32 spells above, each a route `energy_<move>` in `Data/EffectLibrary` (after the domain strikes, before the broad `light`/`ignite`/`thermal`/`harm`/`force`), resolved by `Server/Magic/Cast/Effects/EnergyArt`. Numbers in `Shared/Magic/Data/EnergyTuning`. What lasts (rings, fences, burning ground, frost, smoke, mirrors, wisps, the puppet, ball lightning, tethers, kindled hands, auras) runs in `Server/Magic/Cast/ArtRuntime` (was EnergyRuntime; shared with Earth since 2026-11-17) as invisible anchored parts tagged `ArtBody` (8 per player, 80 per server, every domain together), stepped by `Services/ArtService`, which also wraps `Delivery.interceptor` last (Ice Mirror, Heat Haze and Repulse turn bolts) and listens to `Damage.listenAttacked` (Kindle, Shadow Puppet). The client draws them with `Client/Fx/ArtFx` (shared helpers, bodies by `ArtLook`, bolt looks) and EnergyFx's builders (cue kind `energy`). Two small shared changes: a route may set `params.flight` (speed, homing) and `params.look` (the bolt's own body, drawn by `EnergyFx.flight` from `SpellFx.launch`). `RouteSummaries.summons` is new (summon routes that really bring something), and the three walls joined `builds`. Flag `energy_arts_enabled`; admin `arts`/`energy`, `artsclear`/`energyclear [player]`. Expected boot line **`specs 1169/1170`** (4 new in `Tests/Energy.spec`; Cast.spec checks the 32 new examples).

Recipes (Composer Full mode; `testmage 8 all`, `dummy spawn` for a target):

| Spell | Branch | Property · verb · form |
|---|---|---|
| Ember Swarm | Pyromancy | combustion · generate · burst |
| Fire Whip | Pyromancy | combustion · generate · touch (power 2+) |
| Flame Serpent | Conflagration | combustion · redirect · projectile (needs a fire near) |
| Ring of Fire | Pyromancy | combustion · generate/amplify · wall |
| Smother | Thermal (any) | combustion · reduce · touch/projectile/burst/aura/zone |
| Kindled Hands | Pyromancy | combustion · amplify · touch/aura |
| Ice Spike Line | Cryothermy | temperature · reduce · pillar |
| Frost Lance | Cryothermy | temperature · reduce · projectile (power 3+) |
| Hoarfrost | Cryothermy | temperature · reduce · zone |
| Ice Mirror | Cryothermy | temperature · transmute/bind · wall |
| Flurry | Cryothermy | temperature · reduce · aura |
| Heat Haze | Calefaction | temperature · amplify · aura |
| Boil | Calefaction | temperature · amplify · touch/projectile (at water) |
| Searing Ground | Calefaction | temperature · generate/amplify · zone |
| Prism Bolt | Photomancy | luminosity · generate · projectile |
| Sunspot | Photomancy | luminosity · generate/amplify · zone |
| Wisps | Photomancy | luminosity · bind · summon |
| Flash | Photomancy | luminosity · release · burst/aura |
| Glowing Poison | Irradiance | radiation · generate/amplify · touch/projectile/beam |
| Shadow Grasp | Umbramancy | shadow · generate/bind · touch/beam/projectile |
| Shade Cloak | Umbramancy | shadow · amplify · aura |
| Shadow Puppet | Umbramancy | shadow · generate/transmute · summon |
| Stomp | Kinetic (any) | momentum · release · burst |
| Ricochet | Impetus | momentum · generate · projectile |
| Repulse | Deflection | momentum · redirect · aura |
| Inertia Lock | Inertia | momentum · bind · touch/beam |
| Launch | Impetus | momentum · amplify · touch/aura |
| Ball Lightning | Arcweaving | charge · generate · projectile |
| Static Field | Electromancy (any) | charge · generate · zone |
| Arc Tether | Galvanism/Arcweaving | charge · bind · chain |
| Galvanise | Galvanism | charge · amplify · touch/aura |
| Arc Fence | Arcweaving | charge · generate · wall |

Not verified (no Studio run): the ice spike cone mesh (`rbxassetid://1033714`), how the shadow puppet's flat figure reads, Highlight on glowing targets through walls, `bend` from a mirror/haze/repulse redrawing the bolt on the client, slipping on hoarfrost for players (server reads their replicated velocity), and frame cost with many bodies. Defaults chosen: Kindle lights whoever the kindled body hits with anything (spell or weapon); Smother and Wisps aren't crimes; mirrors and hazes turn anyone's bolts but the caster's own (allies' too).

---

## Earth

### Lithomancy, Architectonics (hardness, cohesion, density, contour)
- **Stone Fist** (`hardness · generate · projectile`): a fist of rock tears out of the ground and flies at the target. *Ground cracks, a boulder fist launches, dust trail.*
- **Gravel Burst** (`hardness · release · burst`): the ground under the target bursts into flying stones. *A spray of rock chunks.*
- **Spike Trail** (`contour · generate · pillar`): a line of stone spikes runs from you to the target. *Spikes rising one after another.* ✦ travelling ground line
- **Stone Step** (`contour · generate · pillar` on yourself, power 1+): a column pushes you up to a ledge or rooftop. *A pillar rising under your feet.*
- **Stone Grip** (`cohesion · bind · touch`): stone climbs the target's legs and holds them until it cracks off. *Rock creeping up from the ground.* ✦ prisons
- **Dust Cloud** (`cohesion · reduce · zone`): the ground crumbles to dust and hangs in the air, blinding. *A brown cloud rising.*
- **Ramp** (`contour · transmute · wall`, Architectonics): a sloped stone ramp, for climbing or launching. *Rock rising in a wedge.*
- **Boulder** (`density · generate · projectile`, power 3+): a boulder that rolls along the ground and knocks people flat in its path. *A rock bowling across the ground, bouncing.*

### Metallurgy, Ferromancy, Alloycraft (magnetism, purity)
- **Iron Storm** (`magnetism · generate · zone`, Ferromancy): metal shavings whirl round the area and cut; worse for anyone wearing metal. *A grey whirlwind glinting.*
- **Magnet Pull** and **Magnet Push** (`magnetism · redirect · touch` / `beam`): pull someone in metal toward you, or throw them away. *Lines of force flickering.*
- **Blade Rain** (`magnetism · generate · ritual`): iron shards rain on the marked spots. *Glinting blades falling from above.*
- **Rust** (`purity · reduce · touch`, Alloycraft): armour weakens and weapons dull (item durability). *Orange rust spreading.*
- **Quicksilver Lash** (`magnetism · transmute · touch`, Alloycraft): liquid metal whips out and returns to your hand. *A silver line that ripples.*

### Crystallurgy, Focuscraft (resonance, purity)
- **Crystal Spires** (`resonance · generate · pillar`): a cluster of crystals bursts up; they hum and shatter when struck, hitting everyone near. *Coloured crystals jutting from the ground.*
- **Singing Shard** (`resonance · generate · projectile`): a shard that sticks in the target and pulses damage a few times. *A crystal embedded and glowing in beats.*
- **Crystal Prison** (`resonance · bind · touch`): the target is encased in crystal for a moment. *A faceted shell growing round them.* ✦ prisons
- **Geode Shell** (`purity · amplify · aura`, Focuscraft): crystals grow over you like armour and crack away as you're hit. *Crystal plates that chip off.*

### Seismic, Faultwork, Tremorsense (seismicity)
- **Fissure** (`seismicity · release · beam`, Faultwork): a crack runs along the ground toward the target, knocking down everyone along it. *The ground splitting in a line.* ✦ travelling ground line
- **Ground Ripple** (`seismicity · generate · burst`): a wave travels outward through the ground, lifting people as it passes. *The ground bulging in a ring.*
- **Tremor Ping** (`seismicity · sense · burst`, Tremorsense): everyone walking on the ground nearby is outlined for a moment. *Rings spreading out, figures lit.*

### Sandshaping, Dunecalling (cohesion)
- **Sand Blast** (`cohesion · release · beam`): a cone of sand that blinds and pushes. *A spray of sand.*
- **Quicksand** (`cohesion · reduce · zone`): the ground goes soft; people sink and slow. *The ground rippling and swallowing feet.*
- **Dust Devil** (`cohesion · generate · summon`, Dunecalling): a small sand whirlwind that wanders and blinds whoever it passes. *A spinning column of sand.* ✦ small followers
- **Sand Shroud** (`cohesion · generate · aura`): a whirl of sand that hides you at range and stings anyone close.

### Energy: confirmed 2026-11-17

Log `specs 1169/1170` (the failure the known "Standing room"); Energy spells cast with no `[Energy]` or `fx_failed` warnings. The owner's screenshot showed the Shadow Puppet as flat black slabs drawn on top of the caster (the client snapped every follower to its owner's root). Rebuilt: a dark copy of every part of you (hats and hair too) with a purple rim, posed from your own limbs every frame, rising from the ground a step behind and to your left, joined to your feet by a band of shadow. Not yet seen.

### Earth: built 2026-11-17 (not yet run)

On the owner's "make it better then do earth". 21 spells (the doc's list, minus magnet pull and push, which `metal` already does, Rust and the Tremor Ping, which the generic `sense` route owns), each a route `earth_<move>` resolved by `Server/Magic/Cast/Effects/EarthArt`, numbers in `Shared/Magic/Data/EarthTuning`, looks in `Client/Fx/EarthFx` (cue kind `earth`). Lasting things share `Cast/ArtRuntime` with Energy. Standing stone (spike trail, stone step, ramp, crystal spires) is a real anchored part in `workspace.ArtStone` from `EffectBudget.takeParts`: it blocks and holds weight, is passable where someone stood as it rose, and sinks away when its time is up (nothing saved). Routes are in sub-branches only, so the root and Geomancy keep Raise Stone, Pebble Rise, Slip and Stone Skin; Seismic keeps Tremor and the quakes; Ferromancy keeps Iron Pull. Route `flight` gained `gravity` (a Stone Fist drops). Flag `earth_arts_enabled`. Expected boot line **`specs 1172/1173`** (3 new in `Tests/Earth.spec`).

| Spell | Branch | Property · verb · form |
|---|---|---|
| Stone Fist | Lithomancy | contour · generate · projectile |
| Gravel Burst | Lithomancy | cohesion · reduce · burst |
| Spike Trail | Lithomancy | contour · generate · pillar |
| Stone Step | Lithomancy | contour · amplify · pillar (instant) |
| Stone Grip | Lithomancy | cohesion · bind · touch/beam |
| Ramp | Architectonics | contour · transmute · wall |
| Boulder | Lithomancy | density · generate · projectile |
| Iron Storm | Ferromancy | magnetism · generate · zone |
| Blade Rain | Metallurgy | magnetism · generate · ritual (power 7 or less) |
| Quicksilver Lash | Alloycraft | purity · transmute · touch |
| Crystal Spires | Crystallurgy | resonance · generate · pillar |
| Singing Shard | Crystallurgy | resonance · generate · projectile |
| Crystal Prison | Crystallurgy | resonance · bind · touch/beam |
| Geode Shell | Focuscraft | purity · amplify · aura (instant) |
| Fissure | Faultwork | seismicity · redirect · beam |
| Ground Ripple | Seismic (any) | seismicity · amplify · burst |
| Sand Blast | Sandshaping | cohesion · redirect · beam |
| Dust Cloud | Sandshaping | cohesion · generate · zone |
| Quicksand | Sandshaping | cohesion · reduce · zone |
| Dust Devil | Dunecalling | cohesion · bind · summon |
| Sand Shroud | Sandshaping | cohesion · amplify · aura (instant) |

Not verified (no Studio run): the WedgePart's slope direction for the Ramp (assumed full height at +Z, as BuildingGenerator's roofs; if it slopes the wrong way, flip the lookAt), lifting the caster with `PivotTo` while the Stone Step grows, the boulder rolling over uneven ground, and stone in towns (it isn't refused there). Defaults chosen: standing stone isn't a crime; Iron Storm drags anyone in metal (guards' chain mail) toward its middle.

---

## Water

### Hydromancy, Hydrostatics (pressure, viscosity, flow, humidity)
- **Water Whip** (`flow · generate · touch`): a whip of water that lashes and pulls the target a step toward you. *A water rope with droplets flying.*
- **Pressure Jet** (`pressure · generate · beam`): a cutting jet of water that pushes back hard. *A white high-pressure stream.*
- **Bubble** (`pressure · bind · touch`, Hydrostatics): the target is caught in a floating bubble that drifts up a little and pops after a moment. *A shimmering sphere with them inside.* ✦ prisons
- **Geyser** (`pressure · release · pillar`): water blasts up from the ground and throws people into the air. *A column of water and spray.*
- **Mire** (`viscosity · amplify · zone`): water in the area thickens to slow sludge. *Water turning dark and sticky.*

### Tidal, Tsunamancy (buoyancy)
- **Wave Surge** (`flow · generate · wall`, Tidal): a short wave rolls forward and carries people with it. *A curling wave moving across the ground.*
- **Whirlpool** (`flow · redirect · zone` in water): water spins and pulls people toward the centre. *A spiral on the surface.*
- **Riptide** (`flow · redirect · beam`): a current that drags the target toward you through water or wet ground.
- **Float** (`buoyancy · amplify · touch`): the target bobs up and floats in air for a moment. *Water droplets lifting around them.*

### Glaciation, Permafrost (phase)
- **Ice Slide** (`phase · transmute · beam` on the ground): a strip of ice you can slide along fast. *A gleaming path.* ✦ slippery ground
- **Permafrost** (`phase · bind · zone`, Permafrost): feet freeze to the ground (root). *Ice creeping over boots.*
- **Icicle Rain** (`phase · transmute · ritual`): icicles drop on warned spots. *Icicles forming in the air and falling.*
- **Ice Dome** (`phase · transmute · wall`): a dome of ice over you and allies. *A dome closing overhead.*

### Vapor, Fogweaving (phase)
- **Scald** (`phase · release · burst`, Vaporism): a cloud of scalding steam. *White steam billowing.*
- **Fog Bank** (`phase · generate · zone`, Fogweaving): thick fog that hides everyone inside from those outside. *A grey wall of fog.*
- **Cloud Step** (`phase · transmute · pillar` on yourself): a small cloud under your feet holds you up for a few seconds. *A puff of cloud.*

### Purification, Wellspring (purity)
- **Cleansing Rain** (`purity · generate · zone`): a short rain that washes statuses (poison, burning, blight) off allies. *Soft rain with a glint.*
- **Water Shield** (`purity · amplify · aura`): a sphere of water that swallows the first fire hit. *Water wrapping around you.*
- **Spring** exists (`wellspring`); a smaller **Fountain** (`flow · generate · pillar`) gives water anywhere for a minute (to drink, fill a bucket or wet a fire).

---

## Air

### Aeromancy, Windshaping, Tempest, Vacuity (flow, pressure, buoyancy, breath)
- **Wind Blade** (`flow · generate · projectile`): a crescent of air that cuts. *A visible ripple shaped like a blade, carrying leaves.*
- **Gust** (`pressure · release · beam`): a cone of wind that throws people back. *Streaks of wind and dust.*
- **Twister** (`flow · generate · summon`, Tempest): a small tornado wanders a short path, picking up loose things and people. *A funnel of grey air with debris.* ✦ small followers
- **Updraft** (`buoyancy · generate · pillar`): a column that lifts whoever stands in it. *Leaves spiralling upward.*
- **Cushion** (`buoyancy · amplify · aura`): your falls are caught. *A puff at your feet when you land.*
- **Vacuum** (`breath · reduce · touch`, Vacuity): a bubble of no air around the target's head (the `suffocating` status with its own look). *A clear bubble, rippling.*
- **Pressure Bomb** (`pressure · release · burst`): the air pulls in, then blows out. *Dust drawn inward, then thrown out.*

### Sonics, Echolocation, Thunderclap (sound)
- **Sonic Ring** (`sound · generate · projectile`): a ring of sound that flies forward and hits everyone it passes. *An expanding ring in the air.*
- **Shatter** (`sound · release · touch`): breaks ice, crystal, glass and stone walls. *A high note, cracks spreading.*
- **Echo Pulse** (`sound · sense · burst`, Echolocation): outlines everything around you for a moment, even in the dark. *A white ring tracing every shape.*
- **Thunderclap** (`sound · release · burst`, Thunderclap): a deafening crack that dazes everyone close.
- **Lure** (`sound · generate · zone`): a sound at a spot that draws creatures and people to look. *Ripples at the spot.*

### Weathercraft, Rainmaking, Stormbrewing (humidity, temperature, charge)
- **Raincloud** (`humidity · generate · touch`, Rainmaking): a small cloud follows the target, raining on them: wet, fires go out, lightning finds them. *A grey cloud over someone's head.*
- **Hail** (`temperature · reduce · ritual`): hailstones fall on warned spots. *Ice pellets bouncing.*
- **Call Lightning** (`charge · release · touch` aimed at a spot, Stormbrewing): a bolt from the sky; stronger under real cloud (`WeatherFuel`). *A strike from above.*
- **Clear Sky** (`humidity · reduce · zone`): the rain stops over an area for a while. *Clouds parting, sunlight.*

---

## Life

### Restoration, Mending, Resurgence, Purgation (vitality, metabolism, toxin)
- **Healing Grove** (`vitality · generate · zone`): flowers spring up and heal allies standing among them. *Grass and flowers growing in a circle.*
- **Lifeline** (`vitality · transfer · beam`): give your own health to an ally. *A green ribbon between you.*
- **Petal Ward** (`vitality · amplify · aura`): petals circle an ally; each absorbs one hit. *Petals orbiting, falling as they're struck.*
- **Purge** (`toxin · reduce · touch`, Purgation): draws poison out. *Dark droplets pulled out of the body.*
- **Second Wind** (`metabolism · amplify · touch`): stamina refills. *A breath of green.*

### Floramancy, Arborism, Mycology (growth, decay)
- **Vine Lash** (`growth · generate · touch`): a thorny vine whips out and pulls. *A green whip.*
- **Root Snare** (`growth · bind · touch`): roots burst up and hold the target (root). *Roots wrapping legs.* ✦ prisons
- **Thorn Burst** (`growth · release · burst`): thorns shoot out in all directions. *A spiky bloom.*
- **Bramble Wall** (`growth · generate · wall`): a thicket that scratches anyone pushing through.
- **Sapling** (`growth · generate · pillar`, Arborism): a tree grows in a second as cover, and stays for a while. *A trunk shooting up, leaves unfolding.*
- **Seed Pod** (`growth · generate · projectile`): a seed bursts into a thicket where it lands.
- **Spore Cloud** (`decay · generate · zone`, Mycology): puffballs burst into a sleepy haze (dazed). *Mushrooms popping, yellow dust.*
- **Fairy Ring** (`decay · generate · burst`, Mycology): a ring of mushrooms that springs you into the air when you step in.

### Faunacraft, Beastspeech, Wildshape (instinct, metabolism)
- **Swarm** (`instinct · generate · projectile`): a cloud of bees or wasps flies at the target and stings for a while. *A buzzing dark cloud.* ✦ small followers
- **Flock** (`instinct · generate · burst`): birds burst out of you and swirl round foes, blinding them. *Wings everywhere.*
- **Beast Claws** (`metabolism · amplify · touch`, Wildshape): your hands become claws for a while; slashes hit harder. *Claw marks hanging in the air after a swing.*
- **Beast Senses** (`instinct · amplify · aura`, Wildshape): you smell and hear further (nearby living things outlined).
- **Calm Beast** (`instinct · reduce · touch`, Beastspeech): a wild creature stops fighting and wanders off.

### Blight, Pestilence, Withering (decay, toxin)
- **Rot** (`decay · generate · touch`): wood, bridges and doors rot and break. *Black spreading over the surface.*
- **Withering Field** (`decay · generate · zone`, Withering): grass browns and creatures inside weaken. *Colour draining from the ground.*
- **Plague Flies** (`toxin · generate · projectile`, Pestilence): a swarm that poisons whoever it touches.
- **Corpse Bloom** (`toxin · generate · pillar`): a fat flower bursts into toxic spores when hit or when someone comes near.

---

## Mind

### Perceptics, Farsight, Insight (perception, thought)
- **Far Eye** (`perception · generate · projectile`, Farsight): an eye of light flies where you aim and you look through it for a few seconds. *A glowing eye floating along.*
- **Mark Weakness** (`perception · sense · touch`): the target's weak spot shows; your next hit on them is a critical.
- **Read Intent** (`thought · sense · burst`, Insight): foes nearby show a faint arrow of what they're about to do (charge, flee, cast).

### Empathy, Charm, Dread (emotion)
- **Terror** (`emotion · generate · touch`, Dread): fear with dark tendrils at the edges of the target's screen. (The `fear` route with a look.)
- **Rally** (`emotion · amplify · aura`): allies near you fight harder and shrug off fear. *A warm glow.*
- **Rage** (`emotion · amplify · touch`): the target lashes out at whoever is nearest, friend or foe. *Red at the edges.*
- **Despair** (`emotion · reduce · zone`): everyone inside slows and casts more slowly. *Grey haze.*

### Illusion, Phantasms, Grand Illusion, Veiling (illusion)
- **Mirror Images** (`illusion · generate · aura`): copies of you circle you; each takes one hit and vanishes. *Translucent doubles.* ⚠️ check it's not the discarded Afterimage (#37): that left a ghost behind you; this is decoys around you.
- **Phantom Blade** (`illusion · generate · projectile`, Phantasms): an imaginary blade that hurts only because they believe it (Mind damage, resisted by Mind). *A pale sword that flies and fades.*
- **False Wall** (`illusion · generate · wall`): a wall that looks real; things pass through it. *A wall that ripples when touched.*
- **Phantom Beast** (`illusion · generate · summon`, Phantasms): a monster only the target sees, chasing them (fear). *Shimmering shape.*
- **Vanish** (`illusion · amplify · aura`, Veiling): unseen until you attack. (The `veil` route at higher power.)
- **Pit** (`illusion · generate · zone`, Grand Illusion): the ground looks like a drop; people won't step in.

### Mnemonics, Oblivion (memory)
- **Forget Me** (`memory · reduce · touch`, Oblivion): the target loses track of you (loses aggro and lock-on).
- **Déjà Vu** (`memory · redirect · touch`): the target repeats what they just did.

### Telepathy, Dominion (thought, will)
- **Mind Spike** (`thought · generate · projectile`): a purple bolt that dazes. *A thin violet streak.*
- **Psychic Push** (`thought · release · beam`): an invisible cone that throws people back. *Ripples in the air, nothing else.*
- **Whispers** (`thought · generate · zone`): voices distract everyone inside; casts slow.
- **Puppet** (`will · bind · touch`, Dominion): steer an NPC or creature for a few seconds. Dominion is tagged forbidden: a crime if seen.

---

## Spirit

### Warding, Sanctums, Hallowing, Counterwarding (warding, essence)
- **Glyph Shield** (`warding · generate · wall`): a rune circle stands in front of you and blocks shots. *A glowing ring of runes.*
- **Sigil Trap** (`warding · generate · zone`): a sigil on the ground throws back whoever steps on it. *A faint symbol.* 🔗 close to #34 Rune traps: build them together.
- **Hallowed Ground** (`warding · amplify · zone`, Hallowing): hurts undead and spirits, steadies the living.
- **Reflect** (`warding · redirect · aura`, Counterwarding): the next hostile status cast on you bounces back.

### Hexcraft, Greater Curses (malediction)
- **Hex Bolt** (`malediction · generate · projectile`): a crawling curse. *A black-purple wisp with eyes.*
- **Deepening Curse** (`malediction · amplify · touch`): each hit the target takes adds a little more damage while it lasts.
- **Ill Luck** (`malediction · generate · aura`, Greater Curses): foes near you stumble, miss and drop things.
- **Hex Doll** (`malediction · bind · touch`): a small doll appears; hits on the doll hurt the target. ✦ tethers

### Binding, Pactcraft, Soulbinding (bond, will, soul)
- **Spirit Chains** (`bond · bind · touch`): chains of light rise and hold the target. *Glowing chains from the ground.* ✦ prisons
- **Tether** (`bond · bind · chain`): two targets bound; they can't move apart. ✦ tethers
- **Soul Lantern** (`soul · store · touch`, Soulbinding): catch the spirit of a creature you killed in a small light that you can release as a short-lived ally. *A lantern with a ghost inside.*

### Necrourgy, Deathspeech, Revenancy (unlife, soul)
- **Grave Hand** (`unlife · generate · touch`): a bony hand bursts from the ground and grabs. *Bones and dirt.*
- **Spirit Wolves** (`soul · generate · summon`, Revenancy): a pack of ghost wolves runs down a target. *Pale wolves that flicker.* ✦ small followers
- **Ghost Step** (`soul · transmute · aura`): for a moment you're intangible and pass through people. *Your body goes see-through.*
- **Wail** (`soul · release · burst`): a spirit's scream; fear on everyone near.
- **Grave Mist** (`unlife · generate · zone`): cold mist that slows the living.

---

## Void

### Negation, Dispelling, Antimagic (aether, presence)
- **Null Bolt** (`aether · reduce · projectile`): strips one good status off the target. *A black bolt with a white rim.*
- **Unravel** (`aether · reduce · beam`): a conjured thing (wall, prison, elemental, ward) comes apart. *It unwinds into threads that fade.*
- **Antimagic Shell** (`aether · reduce · aura`, Antimagic): spells that hit you are weaker. *A dark film.*

### Dampening, Silence, Eclipse, Stillness (momentum, sound, luminosity, temperature, charge)
- **Dark** (`luminosity · reduce · zone`, Eclipse): lights go out in an area; it's night inside. *Light draining inward.*
- **Black Sun** (`luminosity · reduce · pillar`, Eclipse): a small dark orb overhead dims an area and chills it. *A black disc with a pale ring.*
- **Ground Out** (`charge · reduce · zone`): lightning and charge spells fizzle inside.
- **Stillness** (`momentum · reduce · touch`, Stillness): the target slows nearly to a stop. (Today's `still`, with a look.)

### Absorption, Siphoning (essence)
- **Sponge** (`essence · store · aura`): the next spell that hits you is swallowed and refills your reservoir. 🔗 #17 Catch and throw.
- **Hungry Mouth** (`essence · redirect · zone`): bolts flying through the zone are pulled in and eaten. *A black hole the size of a fist.*

### Obscurance, Nullsign (presence)
- **Shadow Step** (`presence · redirect · touch`): step from one deep shadow to another in sight. Instant.
- **Rift Mote** (`presence · reduce · projectile`): a small black tear that pulls things near it, then collapses. *A crack in the air with light bending into it.*
- **Black Flame** (`presence · transmute · touch`, Nullsign): a cold black fire that burns magic (reservoir) instead of flesh.
- **Unseen** (`presence · reduce · aura`, Nullsign): you can't be found by Sense, rumours or tracks for a while.

---

## Shared pieces (build once, used everywhere)

Many spells above share a mechanic. Building each piece once makes a domain's spells cheap:

| Piece | Used by |
|---|---|
| **Travelling ground line** (an effect that runs along the ground from you to the target) | Ice Spike Line, Spike Trail, Fissure, Ice Slide |
| **Small followers** (a short-lived thing that moves on its own; not an elemental) | Wisps, Shadow Puppet, Ball Lightning, Dust Devil, Twister, Swarm, Spirit Wolves |
| **Prisons** (the target is held in a shell that cracks after a moment) | Stone Grip, Crystal Prison, Bubble, Root Snare, Spirit Chains |
| **Tethers** (two bodies linked by a line that does something while it holds) | Arc Tether, Tether, Hex Doll |
| **Arc hits** (everything along a swing) | Fire Whip, Water Whip, Vine Lash, Quicksilver Lash |
| **Slippery ground** and **beam reflection** (already on the Combat.md to-do list) | Hoarfrost, Ice Slide, Ice Mirror |

## Suggested order

One domain per stage, about 12–20 spells each, with the shared pieces it needs built as it goes:

1. **Energy** (the most common starting domain; brings small followers, tethers, arc hits)
2. **Earth** (brings the travelling ground line and prisons)
3. **Water**, 4. **Air**, 5. **Life**, 6. **Void**, 7. **Spirit**, 8. **Mind** (Mind and Spirit last: most of their spells act on NPCs and need the most care).

## Risks

- **Existing spells change.** Routes are resolved at cast time, so a saved spell that was a plain `harm` bolt may become Ember Swarm or Ricochet after a stage. That's the point, but players' spellbooks will change under them.
- **Followers, prisons and zones stack** on a crowded server: each needs a cap in `EffectBudget`.
- **Crowd control** (prisons, roots, tethers) needs the same caps as the stage 1c statuses (`Effects/Status` hard-control caps).
- **Mind's NPC spells** (Puppet, Forget Me, Rage on NPCs) touch crime and witnesses.

## Open questions

1. Is this the right density (about 15–20 new spells per domain), or fewer and more polished?
2. Start with Energy, or another domain first?
3. Should old saved spells change into the new moves (default), or keep the old behaviour for spells saved before?
4. Any spells above that don't fit, or ones you'd like that are missing?
