# Domain ideas: making the eight ordinary domains their own (design only)

Written 2026-11-16 on the owner's "I want ideas on how to improve all the other domains to be more unique and fun". Nothing here is built or approved.

## Why

Space, Time, Gravity and Reality each had their own pass (`docs/Space.md`, `Time.md`, `Gravity.md`, `Reality.md`): powers that only that domain has, cast as ordinary spells, and changing how you move through the world. The other eight (Energy, Earth, Water, Air, Life, Mind, Spirit, Void) share the general machinery: property behaviours, shapes, looks, elementals, ultimates, Sense sight, Travel styles, strikes. That makes them work, but in a fight a fire bolt and a stone bolt still do roughly the same thing, and outside a fight most of them don't do much.

## The test each domain should pass

1. **A verb only it has.** Something you couldn't do with any other domain. That's what makes people pick it.
2. **It touches the simulated world.** The deep systems (NPC memories and opinions, the Chronicle, fire and heat, weather, wild zones, ferals, downed players, crime, towns that repair) should *react* to this domain in a way they don't to others. This is the design rule: causes inside the world, not a layer on top.
3. **A job.** Something an NPC with this magic would do for a living, which a player can do too (feeds #33 Magic as a trade).
4. **Its own way across the world and its own way of seeing.** Travel and Sense exist; these ideas sharpen them.

Same rules as the Space pass: ordinary casts on existing branches (no new keys), routes in `EffectLibrary`, numbers in a `Data/<Domain>Tuning`, server-authoritative, and helpful verbs help (harm only where the property plainly means it).

Ideas marked ⚠️ risk feeling like a game system; ideas marked 🔗 overlap a queued or discarded idea (named).

---

## Energy: power you store and spend

*Identity: energy is never made or lost, only moved. An Energy mage is a battery.*

- **Heat Bank** (Thermal). Draw heat out of a fire, lava, a sunlit rock or a burning enemy, which goes out or cools (`ThermalSim`, `FireSim`), and hold it as a charge you spend on your next fire spells. Cryothermy is the same act turned round: cooling anything *charges* you. The only domain that puts out fires by eating them; towns would ask for it during a blaze.
- **Momentum Bank** (Kinetic/Deflection). Hits you block with a kinetic ward are stored, and your next push releases them all. A falling person can be caught (velocity arrested), the only real fall-saving outside Gravity.
- **Ride the Current** (Electromancy). Travel *along* metal: lamp posts, chain-mailed guards, iron fences, lightning rods. You jump from conductor to conductor as a spark. Uses `LightningRods`' metal finder.
- **Hard Light** (Photomancy). A beam held steady turns solid for a few seconds: a bridge, a step, a shield. A sun-angle twist: stronger at noon, nothing at night without a fire to borrow from.
- **Blinding Flash / Lightbend** (Photomancy). A flash that dazzles everyone facing you, or bend light round yourself to be hard to see at range (not invisible: a shimmer). NPC witnesses half-see you (crime judgement uncertain).
- **Job:** lamplighter, forge-heater, smith's assistant; keeping a town warm in a cold snap.

## Earth: the ground is yours

*Identity: the ground is solid and permanent, and you're the only one who can change that.*

- **Stonewalk** (Geomancy). Sink into the ground and move through it slowly, unseen, surfacing elsewhere. Feel footsteps above (a tremorsense ping of moving bodies on the ground; nothing that flies or swims).
- **Raise and Keep** (Lithomancy). Stairs up a cliff, a bridge over a gully, a shelter for the night that stays for a real while. 🔗 #32 Make your own road: this is the domain that should own it.
- **Disarm and Bend** (Metallurgy). Pull a weapon out of a hand, crush a guard's chain mail into a hindrance, bend a locked iron gate. Metal doors exist (`Buildings`), and guards wear metal (`LightningRods`).
- **Ore and Seams** (Geomancy/Crystallurgy). Sense shows real ore veins and crystal geodes in rock (the open question from Sense sight: "buried metal" has nothing to find yet). Earth mages mine them; smiths buy. A new resource the world needs, not only Earth.
- **Crystal Lens** (Crystallurgy). Grow a crystal anywhere; light and charge spells passed through it are focused (+power, longer range). Ally Energy mages fight next to it. 🔗 partly #34 Rune traps (a crystal holding a spell); keep them apart: a lens bends, a rune trap waits.
- **Quicksand and Burial** (Sandshaping). Turn ground to sand that slows and sinks; bury things (a chest, a purse) and dig up things others buried. Wildborn and robbers could bury loot too.
- **Job:** builder, miner, mason, the person towns call after a quake.

## Water: the sea and the weather inside you

*Identity: water goes anywhere and takes the shape of what holds it; an island world is mostly water.*

- **Part the Water** (Tidal). Push the sea back to walk the seabed for a while. That needs something down there: **wrecks** seeded on the sea floor with old cargo and a story (Chronicle-style lines). The island is 39% ocean that nothing uses.
- **Ice Road** (Glaciation). Freeze a path across a lake or a stretch of sea that stays until it melts (sun, heat spells, Energy mages). Others can use it, and it can be broken under them.
- **Mist Form** (Vaporism). Become mist: slow, can't be hit by weapons, can't cast harmful spells, can pass under doors. Water's escape.
- **Wells and Clean Water** (Purification). Drought events exist: a Water mage can fill a town's well or call water up from the ground, and the farmers remember it (NPC memory, opinion). Purify cleanses statuses (poison, blight, sickness) on others.
- **Breath Under Water** (Hydromancy). Give yourself and your party gills for a while; swim fast. Pairs with wrecks.
- **Job:** well-keeper, fisher, ship's mage, healer's partner.

## Air: what carries

*Identity: air carries: bodies, sound, weather, news.*

- **Far Hearing** (Sonics). Listen to a spot up to a few hundred studs away and hear what's said there: NPC talk, `RumorService` exchanges, two people plotting. The only domain that overhears on purpose. Ties into Rumours (#39) and Noticing.
- **Thrown Voice** (Sonics). Make a sound or a line happen somewhere else: NPCs turn to look, guards go to check, a deer bolts. Distraction and stealth with the real NPC reactions.
- **Call the Weather** (Weathercraft). Bring rain over a field, push a storm away or pull one in, for a few minutes over a real area. It changes `WeatherFuel` for everyone there, wets fires, feeds Lightning rods. Farmers thank you in a drought; a town doesn't when you bring a storm over a festival.
- **Updraft and Glide** (Windshaping). A column that lifts anyone standing in it, and a glide after. Travel has a style already; this is shared lift for a party.
- **Windwall** (Windshaping). A wall of wind that bends arrows and slow bolts aside (not beams). Air's defence.
- **Job:** messenger (🔗 #1 Letters and couriers), farmer's weather-caller, town crier.

## Life: things that grow and keep growing

*Identity: what Life makes is alive, so it keeps going after the spell ends.*

- **Raise Them** (Restoration/Mending). Downed players (`DownedService`) can be brought round on the spot by a Life mage instead of carried off. The carrier-remembers system works the same way: they remember who raised them.
- **Plant It** (Floramancy). Real growth that stays: a tree you plant grows over real hours, a hedge wall, a vine bridge, a garden that ripens food. Uses the town-repair regrowth code.
- **Speak With Beasts** (Faunacraft). Deer, fowl, hares and creatures in dens tell you things (where a Wildborn walked, where a feral went), in a few words. Animals as rumour sources. Calm or turn a wild creature.
- **Take Their Shape** (Faunacraft). Become a deer (fast), a bird (short flights), a hare (small, hidden) for a while. Creature rigs exist (`CreatureRig`). NPCs don't recognise you; guards don't see a criminal.
- **Contagion** (Pestilence). A sickness that spreads from person to person nearby, slowly. Towns react (the healer gets busy, people stay in, a Life mage with Purify is asked for help). ⚠️ needs limits so it can't sweep a whole server; a crime in towns.
- **Job:** healer, gardener, herder, the person who brings the deer back.

## Mind: the people are the content

*Identity: this game has hundreds of NPCs with traits, memories and opinions. Mind is the domain that touches that directly.*

- **Read Them** (Telepathy/Perceptics). See what an NPC is thinking right now: their current action and why, a need that's pressing, how they feel about you, one memory involving you. Nothing new to generate: it's the NPC brain read aloud in first-person lines.
- **Stir and Soothe** (Empathy). Calm a brawl or start one (`NpcFightService`), make a crowd uneasy, make a guard warm to you for a while. The person remembers how they *felt*, not that you did it, unless they're a mage.
- **Make Them Forget** (Mnemonics). Take a memory out of one NPC: they forget they saw your crime, forget a rumour, forget you. Witnesses are how settlement law works, so this matters. A strong mage can notice the gap.
- **Wear a Face** (Illusion). Look like a specific NPC for a while. People treat you as them: their friends greet you, their enemies don't. Breaks when you cast a harmful spell or someone touches you.
- **Read a Place** (Mnemonics). Touch an item with a history (`h`/`hn`/`hl`) or stand at a monument and hear what happened, in the Chronicle's own words. 🔗 different from Echoes (discarded: ghosts replaying moments for everyone); this is private, on demand, text only.
- **Job:** confessor, judge's witness-reader, someone people hire to find a liar.

## Spirit: what comes after, and what's promised

*Identity: Spirit deals with souls, oaths and the dead: things that outlast a body.*

- **Speak With the Dead** (Necrourgy). Named NPCs die permanently in big events (Living History). A Spirit mage at their grave or where they fell can ask them a question; they answer from their own memories. Wildborn bosses' lairs hold old spirits too.
- **Bind a Feral** (Binding). Ferals roam and run down. A binder can catch one in a vessel (a jar, a stone) and carry it: release it later as a one-shot spell, or keep it as a curio. Gives ferals an ending other than a kill.
- **Conditional Hexes** (Hexcraft). A hex that waits on the target's own action: "the next time you cast fire, it turns on you", "the next time you lie to someone, they'll know". NPCs who see a hex mark on someone avoid them.
- **Ward a Door** (Warding/Sanctums). Ward your house or a chest: anyone who opens it is shocked and marked, and the mark is how you find out who. No safe zones (owner's rule): wards can be broken by a stronger Void or Spirit mage.
- **Walk Out of Your Body** (Raw Spirit). Leave your body standing and move as a spirit for a while: scout, pass through walls, see spirits. Your body can be hurt while you're out.
- **Job:** priest, oath-keeper, the one called after a death in town. 🔗 #6 Pacts: bound oaths are Spirit's.

## Void: nothing, on purpose

*Identity: Void takes away. It's the domain that answers all the others.*

- **Swallow a Spell** (Absorption). Catch an incoming spell in your hand, hold it, throw it back as your own. 🔗 #17 Catch and throw: Void should own the strongest form of it.
- **Null Ground** (Negation). Make a patch where no magic works for a while: any domain, including Time's stop and Reality's edicts. The Hollow wild zone already does this permanently; this is a portable version.
- **Unmake the Magical** (Dispelling). End a ward, a hex, a conjured wall, a feral, a Wildborn's zone, a Space seal, a Rift's twist in one room. Every other domain's lasting thing becomes something Void can answer.
- **Silence** (Dampening). A zone of no sound: steps, voices, casting. People inside can't call for help and witnesses outside hear nothing. Stealth and crime with real consequences.
- **Shadowstep** (Obscurance). Step from one deep shadow to another in sight. Stronger at night, weaker at noon. Darkness zones put out lamps (and the lamplighter notices).
- **Job:** curse-breaker, the person a town calls when a mage loses control.

---

## New things: bigger builds that add to the world

Added on the owner's "don't be afraid to also add new things". The ideas above mostly reuse systems that exist. These add new places, creatures, resources and realms, each led by one domain but open to everyone.

### Energy
- **Sun Jars.** Glass jars that catch sunlight by day and glow at night. Photomancers fill them; townspeople buy them for houses that have no fire. A real trade, and towns at night get warmer light where a Photomancer lives.
- **Town Lamp Lines.** Electromancers can wire a town's lamp posts together and light the whole street from one spot. A town with a resident Electromancer is visibly brighter; when that NPC dies or leaves, the street goes dark.
- **Auroras.** When enough Energy is spent on one night (a big fight, several mages), the sky lights up over that region. Everyone sees it; NPCs talk about it the next day. Uses the Omens sky tint.

### Earth
- **Caves and Tunnels.** The caves stage was already planned for the world. Earth makes it a system: Earth mages dig tunnels that stay (saved terrain edits), and seeded caves lie under the island with ore, crystal geodes, old bones and things that live in the dark.
- **A Golem of Your Own** (Clayshaping). A clay body you shape over many sessions: you add stone, metal and crystal, and it gets stronger and changes shape. It carries, guards your house and works a quarry. Slower and heavier than a familiar, and it can be broken.
- **Gemcutting.** Crystals cut into gems that set into gear (a new item slot on weapons and foci). A Crystallurgy trade.

### Water
- **Wrecks and a Drowned Town.** Seeded wrecks on the seabed, and one drowned town far out (a settlement the sea took in the island's past, with its own lines in the Chronicle). Reached by parting the water, breathing under water, or diving.
- **Boats.** Small boats that row, plus sail with an Air mage's wind or ride a Water mage's current. Towns with docks (tidecall culture) gain fishers going out and coming back.
- **Real Tides.** The sea rises and falls on a game-day cycle. Low tide uncovers shore caves and tide pools for a few hours. Tidal mages can push the tide early for a while.
- **Something Large in the Sea.** One sea creature that surfaces now and then, sighted far off. Not a boss to farm: something people report and draw.

### Air
- **Sky Rocks.** A few floating islands high over the island, seeded, reachable only by flying, gliding updrafts or Space. Old nests, a hermit, a wind-shrine. The first content made *for* air travel.
- **Wind Roads.** Steady high winds that cross the island along seeded lines (shown when you see the air). Ride one and you cross a region fast. Changes with the weather.
- **Message Birds.** Teach a bird a short message and send it to a player or an NPC anywhere. 🔗 #1 Letters and couriers.

### Life
- **The Great Tree.** One sapling somewhere on the island that every server shares. Life mages tend it (water, growth spells, clearing blight), and it grows over real days into a landmark. If nobody tends it, it sickens. A world wonder players build together without a progress bar: you see it bigger next time you visit.
- **Grown Houses.** A Floramancer can grow a house from a tree over a few real days: a living home that flowers in spring (🔗 #3 Seasons).
- **Breeding and Herds.** Calmed animals follow you home; two of a kind breed. A Faunacraft player can keep a real herd that NPC hunters respect, or steal from.
- **Grafting.** Combine two plants into a new one with mixed properties: alchemy ingredients nobody else can grow.

### Mind
- **Dreamwalking.** Dreams exist (`DreamService`). A Mind mage can enter a sleeping player's or NPC's dream: a small pocket realm (Hideaway tech) built from that person's memories, latents and fears. Help a player find a latent; learn an NPC's secret; plant an idea.
- **The Mind Palace.** A private room in your own head (another pocket) where you keep what you've learned: memories you took from NPCs, overheard lines, faces you can wear. A journal you walk around in.
- **Ride an Animal's Eyes.** Look out of a bird's eyes and steer it a little. Scouting with real creatures.

### Spirit
- **The Other Side.** A second layer over the world, seen only with spirit sight or when you walk out of your body: the dead of this server (NPCs and Wildborn), spirits tied to places, things people lost. It's the same island, quieter and greyer. The biggest new thing on this list.
- **Graveyards.** Each town gets a burial ground that fills as its people die in big events. Names on the stones, mourners on the day after, and Spirit mages to speak there.
- **Ancestors.** Every NPC household has one dead ancestor a Spirit mage can call on, who knows the family's history and the town's oldest secrets (🔗 #5 Town Mysteries).

### Void
- **The Hollow Beneath.** Things Void erases aren't gone: they go to a dim realm underneath. Destroyed items, dispelled ferals, dropped purses that vanished. A Void mage can go down and bring things back, and something that eats there doesn't like being disturbed.
- **Void Hunger.** A Void mage's own resource: what they swallow (spells, light, heat) fills a hunger. Fed, Void spells grow stronger; left empty too long, it starts eating your reservoir. Unlike any other domain's upkeep.
- **Eclipses.** A rare world event where the sun darkens for a few minutes. Void and Obscurance are at their strongest; Photomancy is weakest; NPCs are frightened. 🔗 Omens foreshadow it.

---

## The eight hybrids, briefly

They inherit from both parents, plus one thing of their own:
- **Clayshaping:** shape clay figures that walk for a while (small workers, decoys).
- **Stormcalling:** a lightning strike called down on a spot from the sky, only under real cloud.
- **Verdancy:** a whole stretch of land turns lush (crops grow, grass returns faster).
- **Magmacraft:** lava that cools into new rock you can stand on (builds land into the sea).
- **Mistweaving:** fog banks that hide a town or a road for a while.
- **Necromancy:** the dead creatures you killed rise to follow you for a fight.
- **Runesmithing:** 🔗 #34 Rune traps belongs here.
- **Nullwarding:** a ward against magic specifically (the Void + Spirit answer to mythic domains).
- **Singularity** and **Mindlink** already have their own work.

## Recommended first pick per domain

If each domain gets one thing first, the one with the most world reach:

| Domain | First pick | Why |
|---|---|---|
| Energy | Heat Bank | Uses fire and heat sims that already exist; puts out town fires |
| Earth | Ore and Seams | Closes the Sense "buried metal" gap and gives smiths a reason to trade |
| Water | Part the Water + wrecks | 39% of the world is unused sea |
| Air | Far Hearing | Rumours and NPC talk already exist; Air makes them reachable |
| Life | Raise Them | DownedService exists; makes Life the friend you want along |
| Mind | Read Them | The NPC sim's depth is mostly invisible today |
| Spirit | Bind a Feral | Gives ferals a better ending |
| Void | Unmake the Magical | Every other domain's lasting effect needs an answer |

Suggested order to build: Mind, Life, Void, Air, Energy, Earth, Spirit, Water (the last needs wrecks built as content first). One stage per domain, the same as Space: 3 to 5 powers, a spec file and a test script.

## Open questions

1. Build one domain fully at a time (like Space), or one first pick per domain across all eight first?
2. Should Mind's Make Them Forget and Wear a Face work on crime witnesses, which weakens settlement law, or should guards be immune?
3. Should Life's Take Their Shape exist? It needs creature rigs for players, the biggest single cost on this list.
4. Is Contagion (Pestilence) wanted at all, given how it could spread through a full server?
5. Seabed wrecks are new world content: worth building for Water, or keep Water to the land?
6. Which of the bigger new things appeal most? The largest are the Other Side (Spirit), Caves (Earth), the Great Tree (Life), Dreamwalking (Mind) and Sky Rocks (Air). Each is its own multi-stage project.
