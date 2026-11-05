# Player Interface

How players see, learn and use magic: the HUD, the Grimoire, the Spell Composer, and the screens still to build.
Code lives in `src/client/Controllers/*` and `src/client/UI/*`; shared settings live in `src/shared/UI/Settings.luau`.

Status (2026-11-02): **built**: HUD, Grimoire, Spell Composer (Guided + Full), Settings, server reservoir stream, hotbar and settings persistence.
**Designed only** (this doc): Skill/Path view, Self-awareness panel, Journal, NPC interaction.

---

## 1. Principles

1. **Show the grammar, don't explain it.** Every unavailable option is still shown, with the reason in a few words ("Unlocks at Adept", "Conflicts with Silent"). Players learn the rules by bumping into them.
2. **The book grows with you.** Nothing the player hasn't earned is named. Undiscovered branches are hints, then rumours (`???`), then not drawn at all.
3. **Never colour alone.** Every status has a glyph or word (✓ ✗ ! ▲ ▼ ×). Every domain has a colour *and* a two-letter monogram *and* a rarity shape.
4. **The client asks; the server decides.** Every number the UI computes is an estimate marked `≈`. Casts, saves, unlocks and settings are requests that are validated server-side.
5. **One tap from anything.** Touch, gamepad and keyboard reach every action. There are no hover-only affordances, and touch targets are at least 44 px.

## 2. Framework choice: plain Luau + `Kit` (recommended for a small team)

| | React-Lua (Roact 17) | Fusion 0.3 | **Plain Luau + Kit** |
|---|---|---|---|
| Dependency | Wally package + its runtime (~10k lines) | Wally package (~3k lines) | none: `UI/Kit.luau`, ~230 lines |
| Strict typing | weak (props are `any`-ish) | decent, but its generics are noisy under `--!strict` | full; it's our own types |
| Learning curve | hooks, reconciler, keys | scopes, Computed, Observers | four functions |
| Fits this project | heavy; our screens rebuild rarely | good fit | good fit, nothing to install (the toolchain has no Wally) |

**Recommendation: plain Luau with `Kit`.** The UI is a handful of screens fed by a few server snapshots, the team is small, and the project has no package manager. Kit provides `value`, `computed`, `scope`, `create` and `dynamic`. Its names mirror Fusion's on purpose: if the UI grows past ~15 screens, or the team grows, porting to Fusion is a mechanical rename.

Pattern used everywhere:
- **Data** lives in `MagicStateController` as Kit Values. It is the only UI code that talks to the server.
- **Screens** are `build(scope, container, args)` functions. A screen re-renders a region with `Kit.dynamic(scope, deps, render)`. Changes in the same frame are batched, and the previous render's scope is destroyed, so nothing leaks.
- **Rebuild on rare change.** A layout, input-mode, text-size or palette change rebuilds the HUD and the open screen from scratch. Labels never bind to settings.
- **Text boxes live outside dynamic regions**, so typing never loses focus.

## 3. Architecture

```
ReplicatedStorage.Shared
  UI/Settings                  setting ids, allowed values, labels (server validates; client builds the screen)
  Net/Remotes                  + SetHotbarSlot, RequestSettings, SetSetting, ReservoirState; CastResult contract
  Core/Topics                  + ScreenChanged
ServerScriptService.Server
  Services/ReservoirService    live ReservoirState per player; 4 Hz regen; snapshot to owner on change
  Services/PreferencesService  RequestSettings / SetSetting
  Services/SpellbookService    + hotbar (data.hotbar), RequestSpellbook returns (spells, hotbar)
  Persistence/Schemas          + hotbar, settings defaults from Shared/UI/Settings (reconcile; no version bump)
StarterPlayerScripts.Client
  Controllers/MagicStateController   Values: progression, profile, spellbook, hotbar, settings, region,
                                     reservoir, cooldowns, known, focusBranch; events Signal
  Controllers/InterfaceController    GUI roots, UIScale, layout + input mode, screen stack, keys, Settings screen
  Controllers/HudController          HUD layer + casting input
  Controllers/GrimoireController     Grimoire screen
  Controllers/ComposerController     Spell Composer screen
  UI/Kit, UI/Theme, UI/DomainStyles, UI/Components, UI/KnownCaster
```

Data flow:

```
server pushes ──► MagicStateController Values ──► Kit.dynamic regions re-render
  RegionInfo, ReservoirState, ProgressionChanged, CastResult, Notify
UI intent ──► MagicStateController:saveSpell / setHotbarSlot / unlockBranch / sendCast ──► Net ──► server validates
```

**Previews.** `UI/KnownCaster` builds a `CasterProfile` from what the player knows about themselves:
- unlocked branches and mastery (from the progression view);
- affinity values or bands (from the visible profile);
- neutral traits.

MagicCore runs locally on it for instant previews, which are always shown as `≈` estimates. Band guesses are deliberately *not* ProfileTuning's band edges, and no new remote reveals the hidden profile. Better self-knowledge (Studied, then Introspective) makes previews more accurate, which is a reward in itself.

## 4. Screens

### 4.1 UI flow chart

```
                         ┌────────────── Awakening moment (domain wakes) ──────────────┐
                         ▼                                                             │
 Join ─► HUD ─┬─ [G]/Y/tap "Grimoire" ─► GRIMOIRE ─┬─ select domain ─► branch tree ─► page
              │                                    │      page: "Edit" / "Try" ──────► COMPOSER (Full, recipe loaded)
              │                                    │      page: "Learn this branch" ─► UnlockBranch ─► toast
              │                                    │      page: "Attempt breakthrough" ─► toast / message
              ├─ [C]/X/tap "Composer" ─► COMPOSER ─┬─ Guided: card ─► Save to hotbar ─► HUD slot filled
              │                                    │          card ─► Customize ─► Full (recipe loaded)
              │                                    └─ Full: Branch ► Property ► Verb ► Form ► Modifiers ► Power
              │                                             └─► Save ─► Place in hotbar (slot picker)
              ├─ empty slot "+" ───────────────────► COMPOSER
              ├─ right-click slot ─────────────────► COMPOSER (Full, that spell)
              ├─ 1-8 / R2 / tap slot ─► CastIntent ─► CastResult ─► feedback / backlash / toasts
              ├─ ⚙ ─► SETTINGS (text size, palette, motion, effects, composer mode)
              └─ (planned) PATH · SELF · JOURNAL tabs; NPC dialogue opens from a ProximityPrompt
 Any screen: tabs switch screens · ✕ / ButtonB / same key closes · one screen open at a time
```

### 4.2 HUD (built)

```
Wide (1280x720 reference)
┌──────────────────────────────────────────────────────────────────────────────┐
│┌Region──────────────┐                                   ┌Mastery───────────┐│
││Aldmere · Highlands │                                   │Pyromancy         ││
││Ambient: Rich ●●○   │                                   │██████░░░░ Novice ││
││[En]▲ [Wa]▼          │                                   │next: Adept       ││
│└────────────────────┘                                   └──────────────────┘│
│                                                         ┌Toast: Tier up ───┐│
│                              +  (crosshair: touch/pad)  └──────────────────┘│
│                                                                              │
│                    ✗ Backlash: Scorched Channels (-12 HP)    ← cast feedback │
│[Grimoire [G]]       [✗ BURNOUT 12s] [Wa × 8s]             ← status chips    │
│[Composer [C]]      ▁▁▁▁▁▁▁▁▁▁ strain ▁▁▁▁▁▁▁▁▁                                │
│[⚙]                 ██████████████░░░░░░  Reservoir 212 / 340                 │
│                   [1 En][2 En][3 Wa!][4 ][5 ][6 ][7 ][8 +]                  │
└──────────────────────────────────────────────────────────────────────────────┘
```
- **Reservoir.** Fill = current/max. A strain line appears above it when strain > 0. An overdraw bar appears below it when below zero. Below 20% the bar border turns orange and pulses (the pulse is static with reduced motion) and the label says "! low". Burnout and lockout chips count down.
- **Hotbar slot.** Shows the domain badge, the filtered name, the key hint, and a cooldown sweep with seconds. **!** means the estimated cost would overdraw; **×** means the domain is locked out. An empty slot shows **+** and opens the Composer. Right-click opens the spell in the Composer.
- **Region.** Biome or settlement, then a density word with pips (Dead zone / Thin / Steady / Rich / Nexus). Resonance shows **▲/▼** only for *your* domains.
- **Mastery tracker.** Shows the branch that most recently changed, its progress inside the current tier, and "! Held" when a breakthrough is due.

### 4.3 Grimoire (built)

```
┌ Grimoire [G] │ Spell Composer [C] │ Settings ──────────────────────────────── ✕ ┐
│┌Domains──────┐┌Tree───────────────────┐┌Page──────────────────────────────────┐│
││(En) Energy  ││(En) Energy · Overview ││(En) Pyromancy              [badges]  ││
││    Novice   ││  Thermal      Adept   ││ Controlled flame and its spread.     ││
││(Wa) Water   ││    Pyromancy  Novice ◄││ Novice · tier 2 of 8                 ││
││    Sensing  ││      ???  A whisper   ││ ██████░░░░ 1840 / 3200 toward Adept   ││
││[Li] Life    ││    Cryomancy ✓ Ready  ││ Breakthrough to Expert               ││
││  faint stir ││  Luminous   Not yet   ││  ✓ Reach Expert XP  ✗ Survive a ...  ││
││<?> Void     ││ Confluences            ││ What you can shape                   ││
││  not in you ││  Steam Arts  Not yet  ││  Verbs: Generate, Sense, Amplify...  ││
││(?) Torn     ││                        ││  At Adept: Transfer, Beam, Wall...   ││
││   pages     ││                        ││ Your spells   Candle Flame   [Edit]  ││
│└─────────────┘└────────────────────────┘│ Techniques    Hearthflame    [Try]   ││
│                                         │               ??? (at Skilled)       ││
│                                         └──────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────────────────┘
```
| Node state | Shown as | Page |
|---|---|---|
| known | name, tier, `! held` | progress, breakthrough checklist and button, shapes now and next tier, your spells (Edit), techniques (Try) plus one veiled, deeper paths |
| ready | dim badge, "✓ Ready to learn", blue border | requirements ✓/✗, **Learn this branch** |
| hint | dim, "Not yet within reach" | requirements ✓/✗, disabled button |
| rumor | `???` "A whisper" | "Whispers speak of something beyond *Parent*" |
| hidden | not drawn | – |

| Domain state | Shown as |
|---|---|
| Awakened | full colour. Overview shows your band, overdraw risk, kinship |
| Stirring | dim. "You feel a faint stirring" (from the visible profile) |
| Sealed | dim. "Not awakened in you. Others carry it" |
| Mythic, unawakened | collapsed into **one** "Torn pages" entry that names none and doesn't count them |

### 4.4 Spell Composer (built)

Guided (default for new players):
```
┌ [Guided] [Full] ──────────────────────────────────────────────────────────┐
│ ┌(En) First spark: Energy ──────┐ ┌(En) Glow Mote ─────────────────────┐ │
│ │ Sense Temperature as Touch.   │ │ Spark a tiny glow on a fingertip.  │ │
│ │ Power [1]                     │ │ Power [1][2]                       │ │
│ │ ≈ cost 3 · range 4 · cd 1s    │ │ ≈ cost 4 · range 4 · cd 1s · 0%    │ │
│ │ [Save to hotbar] [Customize]  │ │ [Save to hotbar] [Customize]       │ │
│ └───────────────────────────────┘ └────────────────────────────────────┘ │
│ Within reach later: Lantern (Energy, at Novice); ...                      │
└───────────────────────────────────────────────────────────────────────────┘
```
Full:
```
┌ [Guided] [Full] [Start over] ─────────────────────────────────────────────┐
│┌Steps────────┐┌What will you do to it?────────┐┌Preview──────────────────┐│
││1. Branch    ││ ✓ Generate  Create from power ││Generate Luminosity as   ││
││  Luminous   ││   Amplify   Increase ...      ││Beam                     ││
││2. Property  ││   Transfer  Unlocks at Adept  ││Luminous · power 3       ││
││  Luminosity ││   Bind      Needs a deeper br.││Cost       ≈ 14.2        ││
││3. Verb ◄    ││   ...                         ││Power      ≈ 3.4         ││
││4. Form  -   ││                               ││Backfire   ≈ 4%          ││
││5. Modifiers ││                               ││▆▆▆░░░ of your reservoir ││
││6. Power     ││                               ││Range 60 · Cooldown 3 s  ││
│└─────────────┘└───────────────────────────────┘│! Overreaching: ...      ││
│                                                │≈ Estimates...           ││
│                                                │[Name it (optional)    ] ││
│                                                │[Save to spellbook]      ││
│                                                │Place in hotbar 1 2 3 .. ││
│                                                └─────────────────────────┘│
└────────────────────────────────────────────────────────────────────────────┘
```
- Choosing an earlier step **prunes** later choices the new choice no longer allows, keeps those still valid, and clamps power.
- The Power step shows 10 segments: within comfort plain, overreach in orange plus a caption, beyond the cap disabled. The cost source (Reservoir / Ambient / Vital) shows its reason when ambient is too thin here.
- Errors and warnings appear in plain words (`ERRORS`, `WARNINGS` tables). An environment fact the client can't know shows as "Depends on the world where you cast it: enough water nearby."

### 4.5 Skill/Path view (designed)

A zoomable, pannable graph. It's a `ScrollingFrame` canvas with a `UIScale` driven by pinch, the mouse wheel and the gamepad triggers; panning uses drag, the right stick or the arrow keys.
```
            ( Time )?        ┌─ legend: ● known  ◐ ready  ○ hint  ? rumor  ⚑ oath ─┐
                  ╲
   (Energy)━━━━━━━(Steam Arts)◐━━━━━━━(Water)
     ┃  ┃ focus 62%                     ┃ focus 21%
 Thermal● Luminous○                 Hydro●
     ┃
 Pyromancy⚑ ── Specialization: Flamebound (+power, -Cryomancy)
```
- Domain roots sit on a ring, with the angle fixed per domain so the layout is stable. Branches radiate outward by tier. Hybrids sit between their domains.
- Edge thickness = focus share (`progression.focus`). An oath shows as a ⚑ on its branch, with its weakened branches hatched.
- Selecting a node opens the same page component as the Grimoire (shared builder).
- Hybrid possibilities: for each `Registry.hybridsByDomain` entry where one domain is awake, a dashed edge to a `?` node. With both domains awake, it shows requirements.
- Data: the progression view (`commitments`, `focus`, `activeLines`, `breadthMultiplier`). No new remotes.
- Performance: draw at most ~200 nodes. Rumour depth is capped at 1, as in the Grimoire. Lines are `Frame`s rotated between centres and are rebuilt only on data change.

### 4.6 Self-awareness panel (designed)

```
┌ Self ─────────────────────────────────────────────────────────┐
│ You are: Gifted (Rare)          Knowledge: Aware ▸ Studied ▸ … │
│ Energy   ████████░░  Formidable (0.70 at Studied)              │
│ Water    █████░░░░░  Strong                                    │
│ Life     ░░░░░░░░░░  a faint stirring                          │
│ Temperament: Steadfast · Curious     Growth: Late bloomer      │
│ Reservoir: Deep (1.18 at Introspective)   Learns best by: Study│
│ Untapped depths: "danger", "mentorship"   (Introspective only) │
│ Signature: [■][■][■] ember motes · rising hum                  │
└────────────────────────────────────────────────────────────────┘
```
- Built from `RequestProfileView`. Each knowledge level unveils rows, and locked rows show what would reveal them ("Study yourself to learn more").
- Latent potentials **never** appear by name. At Introspective, only their trigger categories are hinted.

### 4.7 Journal (built 2026-11-03: Quests, Log, Factions tabs; People and Discoveries still designed)

Four tabs:
- **Quests:** QuestDirector hooks. Each entry has a title, a short line and a map pin.
- **Rumours:** POI lore hints, MemoryStore rumours and mythic hints, with where you heard each.
- **People:** NPC notes from `relationships` (affinity and trust as words, last three memories).
- **Discoveries:** `discoveries.recipes` and world firsts ★, filterable by domain.

Data: new remote `RequestJournal(tab, page)`, paginated at 20 entries per page with a rate limit of 0.5/s. The server filters every player-authored string.

### 4.8 NPC interaction (designed)

```
┌ Maren, river-witch (Water · Adept) ─────────── trust ●●○ ┐
│ "The current remembers what you take from it."             │
│ [Ask about the river]  [Ask to teach Hydro]  [Trade lore]  │
│ [Show a spell]          [Leave]                            │
└────────────────────────────────────────────────────────────┘
```
- Opened by a `ProximityPrompt`. Options come from NPC personality and relationship: a guarded NPC hides "teach" until trust ≥ 2; a vain NPC adds "Flatter".
- **Teaching:** an apprenticeship offer shows cost, duration and what it unlocks, then calls `ProgressionService:awardStudy` server-side.
- **Trading knowledge:** a lore-for-lore exchange. Both sides are listed and the server validates.
- Compact layout: a bottom sheet with full-width buttons. Gamepad: the list is selectable and B leaves.

## 5. Onboarding: discovery, not text walls

The first five minutes, with no tutorial screens:
1. **Spawn.** The HUD shows only the region chip and the menu. A centred card reads *"Something stirs in you. Reach for it and see what answers."* with one button, **Reach inward [C]**. The hotbar shows **+** slots.
2. **Reach inward** opens the Composer in Guided mode. The first card is **First spark: <your strongest domain>**, the smallest valid recipe of that domain. One button: **Save to hotbar**. It lands in slot 1.
3. **First cast** (key 1, or tap). The reservoir bar dips and refills: the resource is learned by seeing it. The first CastResult grants practice XP and a *Discovered: …* toast.
4. **Awakening moment.** Whenever a domain awakens (an `unlock` event on a root branch), a full-screen moment plays: the badge grows, the domain name appears in its colour with its concept line, and *"It was always yours. Try it."* sounds over the domain's cue. A first-join awakening that happens before the client listens is covered by step 1.
5. **Natural next steps**, in any order:
   - the Grimoire's "✓ Ready to learn" glow;
   - "Within reach later" in Guided mode;
   - an "!" overdraw marker teaching cost;
   - a backlash message naming the domain's risk;
   - a Rich/Nexus region showing "▲" for your domain.

Rules for any future hint: one sentence, attached to the thing it explains, gone once the player has done the thing. No modal popups.

## 6. Style guide

### 6.1 Domains

Shape encodes rarity: Common ● circle, Uncommon ■ square, Rare ◆ diamond, Mythic ◎ double ring.

| Domain | Mono | Shape | Signature | Colour-safe | Icon motif (brief) | UI sound cue (from Domains.feel) |
|---|---|---|---|---|---|---|
| Energy | En | ● | `#FF8C28` | `#E69F00` | radiating spark, uneven rays | crackle + rising hum |
| Earth | Ea | ● | `#B08C64` | `#A6761D` | three heavy strata bands | low grind, deep thud |
| Water | Wa | ● | `#4696EB` | `#3A8FD6` | drop over a ripple line | droplet, soft rush |
| Air | Ai | ● | `#DCEBF5` | `#9AD0EC` | three curling gusts | whoosh, whistle |
| Life | Li | ■ | `#5AC85A` | `#009E73` | sprout, two leaves, a root | breath, heartbeat |
| Mind | Mi | ■ | `#C878FF` | `#CC79A7` | eye in concentric waves | whisper, reversed tone |
| Spirit | Sp | ■ | `#A0E6FF` | `#F0E442` | wisp over a flame sigil | bell, choir drone |
| Void | Vo | ◆ | `#8269AF` | `#8E7CC3` | ring spiralling inward | sound drop-out, sub-bass |
| Space | Sc | ◆ | `#96A0FF` | `#6E6EE8` | folded square, star in crease | phase sweep |
| Time | Ti | ◎ | `#E6C878` | `#D8C690` | cracked hourglass | tick, slowing pitch |
| Gravity | Gr | ◎ | `#A082D2` | `#B05A7A` | orbits collapsing to a dot | pressure hum, creak |
| Reality | Re | ◎ | `#FF50C8` | `#FFFFFF` | square drawn twice, misaligned | glitch stutter, silence |

High contrast mode draws every domain in parchment ink: the monogram and shape carry identity. The source is `UI/DomainStyles.luau`; change colours there, not in code.

### 6.2 Interface tokens (`UI/Theme.luau`)

| Token | Value | Use |
|---|---|---|
| bg / panel / panelRaised | `#100E16` / `#1E1B26` / `#2A2634` | cover, pages, selected cards |
| ink / inkDim / inkFaint | `#EEE8DA` / `#ACA496` / `#706A62` | text, secondary, disabled/silhouette |
| accent | `#D6B25E` gold | selection, focus, primary buttons |
| good / warn / danger | `#56B4E9` / `#E69F00` / `#D55E00` | ✓ / ! / ✗ (Okabe-Ito; never green vs red) |
| Fonts | Fondamento (titles), Builder Sans (body/UI), Roboto Mono (changing numbers) | |
| Text sizes | 13 / 16 / 17 / 21 / 28 / 40 × text-size setting | caption / body / label / heading / title / display |
| Spacing | 4 / 8 / 12 / 16 / 24 | xs … xl |
| Radius | 4 / 8 / 14 | chips / cards / screen panel |
| Motion | 0.12 / 0.22 / 0.45 s, Quad Out; 0 with reduced motion | fast / normal / slow |
| Touch target | ≥ 44 px (pre-scale) | every button |

### 6.3 Asset checklist

Every entry in `Theme.sounds` and `DomainStyles.icon` is `""` until delivered; components fall back to monogram badges and silence.

| Asset | Count | Spec | Goes in |
|---|---|---|---|
| Domain icons | 12 | 256² white-on-transparent PNG, 12 px safe margin, readable at 20 px; follows the motif brief | `DomainStyles[*].icon` |
| Rarity frames (optional) | 4 | 9-slice PNG: circle, square, diamond, double ring | Components.badge |
| UI sounds | 11 | open, close, select, confirm, deny, tierUp, discovery, awaken, backlash, lowReservoir, castFail; ≤ 1.5 s, −14 LUFS, no music | `Theme.sounds` |
| Domain cues | 12 | `domain_<id>`: 0.8–1.5 s sting matching the sound column above | `Theme.sounds` |
| Cursor / crosshair | 2 | 32² default + "can't cast here" variant | HudController (crosshair is text "+" for now) |
| Grimoire textures (optional) | 3 | page grain, cover leather, ribbon tab (tileable, ≤ 512²) | Interface panel / Grimoire |
| Fonts | 0 to buy | Fondamento, Builder Sans and Roboto Mono are built-in Roblox fonts | `Theme.font` |

## 7. Mobile and controller

**Layout switch.** The layout is **Compact** when the viewport is under 760 × 520 (phones in landscape, small tablets). The UIScale reference is 760 × 400 for Compact and 1280 × 720 for Wide, clamped to 0.7–1.6. Roots are sized `1/scale`, so the scaled root still fills the screen.

| Element | Wide | Compact (phone) |
|---|---|---|
| Hotbar | 8 slots bottom-centre, keys 1-8 | 2 × 2 slots left of the jump button + page toggle (5-8) |
| Reservoir | above the hotbar | top-centre, 300 px |
| Region chip | top-left with resonance | top-left, no resonance row |
| Mastery tracker | top-right | hidden (it's in the Grimoire) |
| Menu | bottom-left column with key hints | top-right row of short buttons |
| Toasts | top-right, max 4 | top-centre, max 2 |
| Screens | centred panel, max 1200 × 780 | full-bleed; the HUD hides while a screen is open |
| Grimoire | 3 columns | one column at a time: Domains › Tree › Page, with ‹ Back |
| Composer (Full) | rail / options / preview | step chips across the top; options 55% / preview 45%; Details expands the stats |
| Aim | mouse | screen-centre crosshair (tap a slot to cast where the camera looks) |
| Insets | — | HUD uses CoreUISafeInsets, screens use DeviceSafeInsets (notches) |

**Gamepad:**
- Y = Grimoire, X = Composer, B = close.
- D-pad ←/→ selects a hotbar slot (gold outline); R2 casts it.
- Screens auto-select their first button (`GuiService:Select`).
- Disabled buttons stay selectable so their reason can be read.

**Keyboard:**
- G = Grimoire, C = Composer, 1-8 = cast. Pressing the same key again closes the screen.
- Escape is left to the Roblox menu.
- The F2 console blocks all UI keys while it's open.

## 8. Accessibility

All of these live in Settings, are saved per player, and are applied instantly with a rebuild:
- **Text size:** 85–150%.
- **Domain colours:** Signature / Colour-safe / High contrast.
- **Reduce motion:** no tweens or pulses.
- **Reduce spell effects:** for the VFX controller (planned).
- **Composer:** Guided / Full.

Beyond the settings:
- Colour is never the only channel (§1.3).
- Every interactive element is ≥ 44 px and reachable by gamepad selection.
- Sounds are never the only cue: every sound pairs with a toast or a visual change.

## 9. Performance and exploit notes

- **No per-frame rebuilds.** Hotbar sweeps and markers update at 15 Hz on existing instances. Reservoir chips rebuild only when their countdown text changes. `listAvailableRecipes` is cached per caster revision and per branch.
- **Server load.** `ReservoirService` ticks every player at 4 Hz in one loop (O(players)). It sends only on a visible change (whole numbers) via `UnreliableRemoteEvent`, so a full, idle reservoir costs nothing.
- **Network.** Refetches are debounced at 1.5 s, inside the Function remotes' 0.5/s limits. Writes are optimistic and corrected from the server's reply.
- **Trust.** The client sends only recipes, aim points, targets, slot numbers and setting values, all schema-validated (`Remotes.luau`). Settings are checked against `Shared/UI/Settings` options; hotbar keys must exist in the player's own spellbook. Cooldowns, costs and affordability on the client are display-only.
- **Secrets.** Previews use only the visible profile; band guesses are not the real band edges. Torn pages reveal neither names nor counts of mythic domains.
- **Text.** Spell names shown anywhere come from `SpellbookService:displayName()` (filtered). The name box caps at 32 characters client-side; the server re-checks.

## 10. CastResult contract (for CastService)

`CastResult` (server → owner) must send:

```lua
{ ok = boolean, key = recipeKey, reason = "INSUFFICIENT_RESERVOIR" | "BURNED_OUT" | "DOMAIN_LOCKED" | "ON_COOLDOWN"
  | "OUT_OF_RANGE" | "NO_LINE_OF_SIGHT" | "NO_TARGET" | "ENVIRONMENT_BLOCKED" | "CASTING_DISABLED" | "NOT_LOADED" | ...,
  cost = number?, hpCost = number?, cooldownUntil = serverTime?, backfired = boolean?,
  consequences = { Consequence }?, xp = { branch = string, gained = number }? }
```

After a spend, CastService must also call `ReservoirService:push(player)` so the bar moves at once instead of on the next tick.
