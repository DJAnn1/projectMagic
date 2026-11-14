# Overheard rumours (#39)

Built 2026-11-14 (group 3, "NPCs noticing"). Townspeople talk to each other about real things nearby, and you overhear them. Nothing is announced: it's two people in chat bubbles.

## Overheard

Every 4 s, for each player standing in a town, the service looks for two free townspeople within 9 studs of each other and 24 studs of the player. "Free" means drawn, awake, not fighting, talking to someone, on a scene leash or sheltering. The more outgoing one brings something up, with the direction from where they stand: "Someone saw lights in that old library out east." The other answers 2–3 s later ("Is that right?", "Someone should clear them out.", "Don't. I won't sleep."). They face each other while they talk. Everyone within earshot has overheard it.

What they talk about (`RumorRules.choose`): something real between 40 and 900 studs from the town, that you haven't overheard this session. Nearer things are likelier.

| Source | Kind | Asking tells the story here? |
|---|---|---|
| Visible POIs: library, academy, hermit tower, mine, vent, fault, trench, singing caverns, hollow grove, sunken shrine, quiet place, dungeon, the 9 shrines | `library`, `shrine`... | yes |
| Creature dens (6 creatures) | `den_<id>` | yes |
| Wild zones | `zone` | no: WildZoneService already tells it |
| Wildborn lairs with a living boss | `lair` | no: WildbornService already tells it |
| Loose ferals | `feral` | no: FeralService already tells it |

Towns and the hidden mythic sites are never talked about.

**Limits:** one talk per town per 90 s, a player overhears at most once per 45 s, each thing once per player per session.

## Asked

Ask anyone in that town for rumours (the "rumor" topic) within 30 minutes and, for places and dens, they tell you more, with a direction from them. It goes in the Journal (…, "I asked about something I'd overheard."), and 80 studs of map around it are uncovered. Each overheard thing is told once.

## Code

- `Rumors/RumorRules`: pure rules and tuning.
- `Rumors/Data/RumorLines`: the lines, in Barks shape, so job, traits, child, mage and fears shape them.
- `Services/RumorService`.
- Read-only getters: `CreatureService:dens()`, `WildZoneService:places()`, `WildbornService:lairs()`, `FeralService:loose()`.
- Flag `rumors_enabled` (also needs `ambient_life_enabled`).
- Admin: `rumors` (what could be talked about near you, nearest first, and what you've heard; `rumors clear`), `rumornow` (the nearest two people talk now).
- Log: `rumor_overheard`, `rumor_told`.
- Spec: `Tests/Rumors.spec` (4).

## What still feels like a game

- Rumours are always true. Real gossip grows in the telling.
- Two people only talk about it when you're close: nobody gossips to an empty street (cheap, and invisible).

## Open questions

1. Should some rumours be wrong or exaggerated (a den of rats becomes "something big")?
2. Should the people who talked remember telling it, so they bring it up when you return ("Did you go out east?")?
3. Should quest situations (a missing pet, a crisis) be talked about too? That overlaps #40 Trouble at the den.
