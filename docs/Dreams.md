# Dreams about your own magic (#43)

Built 2026-11-14. Hook (EngagementIdeas #7): after you rest, a vague dream: "Water, and something under it that isn't water."

## What happens

- **Sleep.** Lie in a bed. After about **25 s at night** (20:00 to 06:00) or **60 s by day**, you drift off: the screen blurs and darkens for about 4 s, then you wake. Getting up first wakes you with no dream. At most **one dream per in-game day**, with **10 real minutes** between dreams.
- **The dream.** Usually about one of your **hidden, non-mythic latents** (weighted by strength). On about 30% of nights, and always if you have no hidden latents, it's an ordinary dream, so dreaming never proves a latent exists.
- **Clarity grows** with each dream about the same latent (`clarityStep` 2):
  1. dreams 1–2: an image of what it touches ("I dreamt of water, and something under it that wasn't water.")
  2. dreams 3–4: plus a sentence saying it felt like *yours* (new domain vs. louder magic vs. a deeper well vs. a way of being)
  3. dream 5 onwards: plus a hint at what might wake it, from the latent's trigger category (Danger, Location, Mentor, Ritual, Emotion, Experiment)
  
  Self-knowledge level 3 makes every dream one step clearer.
- **It comes true.** If a latent you dreamt about later awakens (by any route), a second Journal line: "I've dreamt of this before…".
- **Telling:** first-person Journal lines (kind `dream`, ☾) and the screen dimming. No card, no popup of its own.

## Secrets

- The lines, the rules and the choice live in **ServerScriptService** (`Server/Magic/Dreams`, `Server/Magic/Data/Dreams`). Only the finished line reaches the client; the `Dreaming` remote carries just `"drift"`/`"wake"`.
- **Mythic latents are never dreamt**, and neither is an Amplify latent on a mythic domain: there are no lines for them at all.
- Lines hold no digits and no domain names (spec-checked).
- Deterministic: `Seed.random(worldSeed, entityId, "dream", record.count)`.

## Code

| Piece | Where |
|---|---|
| Lines, timings | `src/server/Magic/Data/Dreams.luau` |
| Rules (eligible, clarity, compose, pick, recalled) | `src/server/Magic/Dreams.luau` |
| Service (sleep, journal, came-true check, admin) | `src/server/Services/DreamService.luau` |
| Who is in a bed | `InteractionService:bedOf(player)` |
| Screen dim | `src/client/Controllers/DreamController.luau` (remote `Dreaming`) |
| Save | `data.dreams { count, lastAt, lastDay, seen, recalled }` (reconcile fills old saves) |
| Spec | `src/server/Tests/Dreams.spec.luau` (5) |

Flag `dreams_enabled`. Admin: `dream [player]` (dream now, prints the choice), `dreams [player] [clear]`. Log: `dream_had` { ordinary, kind, clarity, count }, `dream_came_true`.

## Test

1. `dreams` to see your hidden latents and the clarity of the next dream.
2. `time 22`, lie in a bed (any house; `house claim` or `buildingcheck`), wait ~25 s: the screen dims, a ☾ line appears in the Journal. Get up early once to check it lifts.
3. Lie down again: nothing (one per day). `dreams me clear` resets it.
4. `dream` five or six times to watch a latent's line grow clearer.
5. Awaken a dreamt latent (`awaken …` from the Profile commands); within 10 s a "came true" line.

## Open questions

- Should NPCs ever mention your dreams (a scholar or a mentor interpreting them)? Not built.
- Do naps by day count (60 s now), or nights only?
- Should the Rite of Attunement or meditation mats also bring dreams?
- Is 30% ordinary right, or should a strongly gifted person dream of their latents more often?
