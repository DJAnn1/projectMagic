# Break the charge

Idea #30 from the 2026-11-07 ideas list, picked by the owner 2026-11-09. Built 2026-11-10, not yet run.

## What it does

Holding a charge takes focus. If you're hurt enough while holding one, your focus breaks: the spell comes apart in your hands. Nothing is paid and nothing is cast, and there's a 0.8 s wait before you can start again. This happens with any harm: a spell, an arrow, a creature's bite, a fall.

How much you can take before it breaks is a share of your max health:

| | Limit |
|---|---|
| Novice (tier 0) | 10% |
| Each mastery tier | +1.5% |
| Cap | 25% |
| Overcharged | half of the above |

A grandmaster holding a plain charge can take 22%. Overcharging, the same grandmaster breaks at 11%, about as easily as a novice. Heals during the hold don't give back what you lost.

NPC mages follow the same rule during their telegraphed wind-up, using the health they lost between starting it and releasing it. NPCs never overcharge.

Already true before this, and kept: a knockdown or stagger, a dash or raising a guard ends a charge.

## How you know

- The spell you were conjuring falls apart in your hand (the existing cancel effect in `Fx/Conjure`).
- One line by the charge meter: "The hit breaks your focus. The spell comes apart in your hands."
- No card, no icon.

## Fixed on the way

When the server ended a charge (a stagger, and now a broken focus), the client didn't know, so letting go of the button afterwards cast the spell as a quick tap. The server now sends a refusal for that spell, and `CastClient` already drops its charge on one.

## Code

- `Shared/Magic/Data/ChargeTuning` `focus`, plus `Charge.focusLimit` and `Charge.focusBreaks`.
- `CastService`: the hold watches `Humanoid.HealthChanged` (disconnected when the hold ends), `breakFocus` (lockout, `FOCUS_BROKEN` refusal), and the stagger refusal.
- `NPC/NPCCombat.castBolt`: the check at release.
- `HudController`: the `FOCUS_BROKEN` text.
- Flag: `charge_break_enabled`. Admin: `hurt [percent] [delay] [player]`. Log: `charge_broken`, and `admin_hurt` (with `wasCharging`, `broke` and `limit`).
- Spec: `Tests/BreakTheCharge.spec` (5).

## Test

1. Ready a projectile spell. Run `hurt 15 2`, then hold to charge straight away. At low mastery the charge should break, the spell should fall apart and the line should show. Let go: nothing should be cast.
2. `hurt 5 2` while holding: it should hold, and the cast goes off normally.
3. `testmage 8 all`, then `hurt 15 2` while holding a plain charge: it should hold (limit 22%). Overcharge, then `hurt 15`: it should break (limit 11%).
4. `npcfight` an NPC mage and hit it hard while it winds up: the bolt shouldn't come.
5. `flag charge_break_enabled false`: nothing breaks.
