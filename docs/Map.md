# The map

From the ideas round on 2026-11-06, approved with "If nothing is wrong build the next step". It's what makes rumours, dens, mentors and later Rifts findable. Built 2026-11-06, not yet run.

Rules and looks: `Shared/World/MapData`. Server: `Services/MapService`. Client: `Controllers/MapController`, and `QuestPinsController` for the waypoint in the world. Specs: `Tests/Map.spec`. Flag: `map_enabled`.

## Using it

**M** opens it, and it's also a tab on every screen.

- **The island starts dark** and uncovers around you as you go: 192 studs on the ground, up to 448 from high up, so flying and Wind Glide chart faster. It's saved.
- **Pins:** you (an arrow turning with your camera), places you've found, your quests, your house, your party, a shared event, and your waypoint. Each is a glyph, some with a word.
- **Zoom:** the + and − buttons or the mouse wheel, ×1, ×2 or ×4. Zoomed in, it stays centred on you.
- **Waypoint:** click the map, or a place on the list. Click near it again to clear it. A ✚ appears in the world with the distance, and the edge arrow points to it, ahead of your tracked quest and "Show the way". It clears when you arrive.
- **Places you've found:** a list by distance, on wide screens.

## What a client is told

The server sends only what you've uncovered, so a cheating client can't read the rest.

- **Ground:** `RequestMap` returns the grid with every other cell hidden, and `MapReveal` sends new cells as you uncover them.
- **Places:** only those in ground you've uncovered, and only id, type, position and a town's name. No grants or hints.
- **Hidden mythic sites never leave the server,** even if you stand on one. Their ground shows, their pin doesn't.
- **Removed:** `PoiMarkers`, which sent every visible place to every client on join. Nothing read it.

## How it's stored

The grid is 64 × 64 cells of 64 studs, built once from the generator, one row a frame. What you've uncovered is a bitset in `data.discoveries.map`: string keys, 30 bits a word, at most 137 numbers before compression. Old saves get it by reconcile.

## Budget

- **Server:** one pass over players every 2 s. A message only when something's new.
- **Client:** frames exist only while the map is open, one per run of same-coloured cells in a row, at most 4,096. Pins redraw twice a second.

## Known limits

Couldn't be checked without running it:
- How many frames a fully explored map really draws, and whether opening it hitches.
- The click position under the UI scale. It uses the input's position against the canvas, the usual way, but scaling is where this goes wrong.
- A waypoint's height: it uses your own height when you set it, so its marker can sit above or under the ground far away.

Known gaps:
- **The grid is coarse.** At 64 studs a cell, it shows regions rather than paths, and roads aren't drawn.
- **Dragging to pan isn't built.** Zooming in follows you.
- **The place list and its text are hidden on narrow screens** to leave room for the map.
- **A redraw per reveal:** the open map rebuilds its ground whenever new cells arrive, about every 2 s while you explore with it open.
- **No minimap on the HUD yet.**
- **Old hints are unchanged:** rumours and quests don't mark the map yet.

## Admin

`maprevealall [player]` uncovers everything (hidden sites stay hidden). `mapreset [player]` forgets it, and shows on their next join.
