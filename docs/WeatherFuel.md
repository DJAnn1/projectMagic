# Weather as fuel

Idea #14 from the 2026-11-07 ideas list, picked by the owner 2026-11-09. Built 2026-11-09, not yet run.

## What it does

The weather where a spell lands feeds some magic and starves other magic. A storm overhead makes lightning stronger. Rain makes water easier to move and fire harder to light. Heat helps flame and fights frost, and cold does the opposite. Nothing on screen says so: the spell simply comes out stronger or weaker. The first time a kind of weather noticeably does that to you, you write about it in your Journal, in the first person (glyph ☁). Each kind is written once, ever.

There's no weather system yet. The facts come from what already exists: `WorldStateService.environmentAt` (biome climate plus active world events). Storm events add 0.6 to 0.8 storm charge, heatwaves and eruptions add temperature, and droughts take moisture away. Once a real weather system exists, it only has to feed those same facts.

## Rules (`Shared/Magic/Data/WeatherFuel`)

| Rule | Fact | Spells | Ramp | At full |
|---|---|---|---|---|
| storm_charge | stormCharge | charge | 0.55 → 1 | +25% |
| storm_wind | stormCharge | Air flow, pressure, buoyancy | 0.55 → 1 | +12% |
| rain_water | moisture | Water flow, pressure, humidity, viscosity, phase, buoyancy | 0.7 → 1 | +15% |
| drought_water | moisture | the same | 0.2 → 0 | −15% |
| rain_fire | moisture | combustion and temperature, when heating | 0.7 → 1 | −15% |
| dry_fire | moisture | combustion, when heating | 0.25 → 0 | +10% |
| heat_fire | temperature | combustion and temperature, when heating | 0.75 → 1 | +12% |
| cold_fire | temperature | the same | 0.25 → 0 | −8% |
| cold_ice | temperature | temperature and phase, when cooling (`reduce`) | 0.25 → 0 | +15% |
| heat_ice | temperature | the same | 0.75 → 1 | −10% |
| rain_growth | moisture | growth | 0.7 → 1 | +8% |

"When heating" means the verbs generate, amplify and release. The rules that match a spell add together, then the total is clamped to 0.8 to 1.3. The weather changes power only, not area or cost. Every biome's own storm value is at most 0.5, below the storm ramp, so it's the weather that makes lightning stronger, not the place. Deserts and tundra do lean fire and frost their own way through temperature and moisture.

## Code

- `Shared/Magic/WeatherFuel`: `factor(property, verb, domains, environment)`, pure.
- `MagicCore.computeStats`: `power *= weatherFactor`; stats carry `weatherFactor` and `weatherRule`. With no context (the Composer's previews), the factor is 1.
- `CastService`: the flag `weather_fuel_enabled` off divides the factor back out. `SpellResolved` carries `weatherFactor` and `weatherRule`.
- `Services/WeatherFuelService`: the Journal line. It's written only if the spell worked, didn't backfire, and the factor is at least 8% away from 1. The save field is `data.weather.noted` (rule id → time); reconcile fills old saves.
- Admin: `weatherfuel [player]` (the sky where they stand, and each rule's strength there), `weathernotes [player] [clear]`.
- Log: `weather_noticed`.
- Spec: `Tests/WeatherFuel.spec` (10).

## Test

1. `startevent tempest` (it centres on a player and adds 0.8 storm charge), then `weatherfuel`: storm charge should be above 0.55, and `storm_charge` should show a share.
2. Cast a charge spell at something. Read your Journal: one ☁ line. Cast again: no second line.
3. `weathernotes` lists `storm_charge`. `weathernotes me clear` lets the line be written again.
4. `flag weather_fuel_enabled false`, then cast: the stats should show no weather factor and no new Journal line.

## Not yet decided

- NPC casters don't use it yet (`NPCCombat` doesn't go through `computeStats` with a context).
- Should NPCs ever remark on it ("lightning loves you in this weather")? It would fit, but would cost a bark category.
- When a real weather system arrives, rain should raise `moisture` locally and fall with the clouds.
