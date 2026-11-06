# Domain Travel

From the ideas round on 2026-11-06, approved with "go". Crossing a 4,096-stud island on foot isn't fun, and shared events can land far away. Everyone now gets a fast way to move in their magic's own style. Built 2026-11-06, not yet run. Every number is a first guess.

Data: `Shared/Magic/Data/TravelTuning`. Rules: `Shared/Magic/TravelRules`. Server: `Services/TravelService`. Client: `Controllers/TravelClient`, `Fx/TravelFx`. Specs: `Tests/Travel.spec`. Flag: `travel_enabled`.

## Using it

**Y** sets off and stops. Move keys steer, **Space** climbs, **Shift** sinks. Touch and gamepad get on-screen buttons. While flying, Y still lands, and Domain Travel won't start.

You ride in your **readied spell's domain**, at your best tier in it. With nothing readied, it's your best domain. So readying a spell can change how you travel.

| Domain | Style | Speed | Height (hover + lift) | Crosses water |
|---|---|---|---|---|
| Energy | Flame Jet | ×1.1 | 2 + 14 | yes |
| Earth | Stone Surf (a stone board) | ×1 | 1 + 6 | **no** |
| Water | Wave Ride (a glassy board) | ×1.05 | 1 + 6 | yes |
| Air | Wind Glide | ×1 | 4 + 40 | yes |
| Life | Root Run (a mat of green) | ×0.95 | 0.5 + 8 | **no** |
| Spirit | Ghost Drift | ×1 | 3 + 12 | yes |
| Mind | Thought Step | ×1 | 2 + 10 | yes |
| Void | Shadow Slide (a dark sheet) | ×1.15 | 0.5 + 4 | yes |
| Space | Fold Step | ×1.2 | 2 + 10 | yes |
| Time | Quickstep | ×1.2 | 1 + 6 | yes |
| Gravity | Sideways Fall | ×1.15 | 3 + 30 | yes |
| Reality | Slipstream | ×1.1 | 2 + 10 | yes |

| By tier, Sensing to Transcendent | |
|---|---|
| Speed | 28 to 92 studs/s (walking is 16; Flight tops out at 110) |
| Reservoir per second | 3% down to 0.3% of your max |

Letting go of Space settles you back down, so a glide ends gently. You rise early for slopes and low walls, so you don't hit them.

## What ends it

Empty reservoir, a hit worth 15% of your max health, a knockdown, being held or frozen, being silenced, or taking flight. After being knocked off or running dry, there's a 2 s wait before setting off again. You need 5% of your reservoir to start.

You can cast while riding.

## How it works

Players own their characters' physics, so the client moves you (a `LinearVelocity` and `AlignOrientation`, Humanoid in its Physics state, two rays a frame) and the server checks four times a second. Speed over ×1.5 + 30 studs/s, or height over hover + lift + 45 studs, three times in a row, ends the ride and logs `travel_violation`. That's the same approach as Flight.

**Budget:** one check per rider at 4 Hz, one `RenderStepped` on the rider's own client only while riding, and at most one part and one emitter per rider on each client.

## Known limits

Couldn't be checked without running it:
- How it feels, and whether anything fights the Physics state.
- Whether the look-ahead handles steep cliffs and doors well. You can rise over walls up to about 25 studs, but a tall wall stops you.

Known gaps:
- **No animation:** you stand in one pose while riding. A surf or glide pose per style would help a lot.
- **Only a few styles have a board.** The rest are motes and a colour for now.
- **No sound,** because there's no library pick for it yet.
- **Indoors:** the ground check starts 25 studs above you, so it can read a roof as the ground and lift you into a ceiling. Stop riding before going inside.

## Testing

In Studio, F2:

```
testmage 5 air
travel
travel off
testmage 5 earth
travel
travelstate
```

Or press Y. Readying a spell before pressing Y changes the style. `cheat infinite` removes the reservoir drain.
