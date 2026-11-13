# Omens (idea #35)

Built 2026-11-12. Before a big event, the world shows strange signs. Nothing announces them and nothing names the event: you see the signs, townspeople talk about them, and your Journal remembers. When the event comes, you understand what you saw.

## What comes with an omen

| Event | Signs | Starts | Seen from |
|---|---|---|---|
| Ashwalker Titan | smoke, tremor | 15 min ahead, at its landing point | 1,100 studs |
| Stonefather Titan | tremor, birds | 15 min | 1,100 |
| Stormcrown Titan | dark sky, birds | 15 min | 1,100 |
| Wild Elemental (shared) | motes | 10 min, at its town | 700 |
| Magical Storm (shared) | dark sky, birds | 10 min | 800 |
| Siege (shared) | smoke | 10 min | 900 |
| Fallen Comet (shared) | new star | 10 min | anywhere |
| Rift | motes, birds | 5 min, at its town | 600 |
| Drought | dry haze | 4 min | 900 |
| Wildfire | smoke | 3 min | 900 |
| Magic Storm | motes, dark sky | 3 min | 800 |
| Tempest | dark sky, birds | 4 min | 900 |
| Volcanic Unrest | tremor, smoke | 4 min | 1,000 |
| Migration | birds | 3 min | 900 |
| Plague | sick air | 4 min | 600 |
| Ley Surge | motes | 3 min | 500 |
| Eclipse | red sky | 3 min | anywhere |
| Starfall | new star | 4 min | anywhere |

**Signs** (client styles): birds fleeing away from the place over your head; dark smoke columns at the place; tremors (a small camera shake, stronger near); a tinted sky (dark, red, dry yellow, sickly green); a new star low in the sky toward the place; glowing motes rising out of the ground. Each grows stronger as the event nears (strength 0 to 1 over the lead) and lingers 20 s after it begins.

**World events now wait for their omen.** The EventDirector used to start an event the moment it rolled one. Now a rolled event waits its omen's lead as a *pending* event, then starts. Pending events count toward the caps. Admin `startevent` still starts one at once. With `omens_enabled` off, events start at once as before.

## Telling

- **Sight:** every 2 s, each player is sent only the omens they could see from where they stand (remote `Omens`, only when it changes); `Controllers/OmenController` draws them.
- **Journal (☄):** the first time you notice a sign (within 450 studs unless it's seen from anywhere, at strength ≥ 0.25), a first-person line, once per sign ever. If you noticed or heard of an omen and its event then arrives while you're on the server, a second line ties them together, once per event kind ever (`data.omens`).
- **People:** ask a townsperson within 1,200 studs of a strong omen for news, and they describe one of its signs and the direction ("The birds left all at once this morning, every one of them flying away from the north-east."). This rumour hook goes ahead of the others while an omen is near.

## Code

- `Shared/Magic/Data/Omens` (signs, sources, numbers), `Shared/Magic/OmenRules` (strength, bearing, visibility, rumour text, resend signature).
- `Services/OmenService` (finding, sending, Journal, rumours, admin); `upcoming(within)` on `TitanService`, `SharedEventService` and `RiftService`; `EventDirector` pending events (`pending()`, `foreshadow`).
- `Controllers/OmenController`.
- Flag `omens_enabled`. Log `omen_noticed`, `omen_arrived`, `event_foreshadowed`.

## Testing

Expected boot line: `specs 1048/1049` (6 new in `Tests/Omens.spec`; the one failure is the known Shine Pass item).

- `omen titan_stormcrown 60` raises a test omen 30 studs east of you that peaks in 60 s: watch the sky dim and the birds pass, then the Journal. When it "begins", you get its arrival line (the Titan itself won't come).
- Try each sign: `omen world_wildfire` (smoke), `omen titan_stonefather` (tremor and birds), `omen shared_comet` (new star), `omen rift` (motes), `omen world_plague` (sick air).
- `omens` lists what's coming. `titan schedule`, `sharedevent schedule` and `rift schedule` show when the real ones are due; a real omen starts 15, 10 or 5 minutes before.
- Ask a nearby townsperson "Any news?" while an omen is strong.
- `omennotes` lists the lines written; `omennotes me clear` resets them.

## Unverified

- How the signs read in game: bird size and speed, smoke seen from 1,000 studs (client particles that far away), the star billboard at 1,500 studs, the tremor shake strength.
- `BindToRenderStep` after the camera for the shake (it shouldn't fight the camera scripts).

## Open questions

- Should omens have sounds (distant thunder, a low rumble, wingbeats)? That needs licensed picks.
- Should NPCs react on their own (pointing, hurrying indoors, praying) rather than only when asked?
- Rolled world events now start 3 to 4 minutes later than before. Fine?
