# Items, inventory and equipment

Stage 1 of the item backbone, written 2026-11-03. It hasn't been run in Studio yet.

Later stages, in the owner's order:
1. loot, containers and harvesting;
2. crafting, alchemy and enchanting;
3. economy and trade;
4. survival and movement.

## 1. Audit (what existed before)

| Thing | State | Decision |
|---|---|---|
| Roblox Backpack / Tools | Already disabled (`InterfaceController` turns off `CoreGuiType.Backpack`); no Tools anywhere | **Keep disabled.** Items never become Tools. Held items are welded models (`GearVisuals`). |
| `data.inventory = { currency, items = {} }` | Placeholder in save v3, never written | **Replaced** by the v4 inventory (migration `[3]`). Coins carry over. |
| Currency | `QuestDirector` read and wrote `data.inventory.currency` directly | **Routed** through `InventoryService:addCurrency`, so it's logged, atomic and pushed to the client. |
| `Server/Magic/Data/Gear` (NPC gear, 9 garments) | Separate definitions | **Kept for NPCs**, now *built from* the ItemDatabase (tag `npc_gear`). Players and NPCs share one definition. |
| Resistances `gear` source | NPC `Gear_<slot>` attributes | **Kept** for NPCs. A new `items` source carries player gear. |

## 2. Data

### 2.1 Where it lives
- **Shared (`ReplicatedStorage.Shared.Items`):**
  - `ItemTypes`
  - `ItemDatabase` (validates everything at require)
  - `ItemInstance`
  - `StatCalc`
  - `Data/Items` (60 items)
  - `Data/Affixes` (65 affixes and 3 sets)
  - `Data/Rarities`
  - `Data/StatDefs`
  - `Data/ItemRules`
- **Server (`ServerScriptService.Server.Items`):**
  - `Inventory` (the pure model)
  - `ItemGenerator`
  - `StatCache`
  - `GearVisuals`
  - `ItemUse`
  - `AdminCommands`
  - plus `Services/InventoryService`.
- **Client:**
  - `Controllers/ItemStateController` (data)
  - `Controllers/InventoryController` (screen and quickbar)
  - `UI/ItemWidgets` (cell and tooltip)

### 2.2 Definitions (`ItemDef`)
- **Common fields:** id, name, description, category, rarity, stack, weight, value, icon (`""` means a generated glyph icon), glyph, color, tags, requires.
- **Per-category blocks:**
  - `equip`: slots, twoHanded, stats, resist, durability, affixClass, attune, bagSlots
  - `focus`: grade, domains, stability
  - `weapon`: kind, damage, damageType, speed, reach, stamina
  - `use`: effects, consume, cooldown, group, needsAim
  - `model`: shape, color, material, glow
  - `unique`, `quest`, `bind`, `data`
- **Categories (16):** weapon, focus, armor, clothing, jewelry, tool, consumable, material, reagent, quest, key, book, furniture, treasure, container, artifact.
- **Ids are permanent.** Renames go through `ItemDatabase.aliases`. Bump `ItemDatabase.VERSION` when existing items change meaning.

### 2.3 Rarities
- **Common:** 0 affixes, band 0–0.4.
- **Uncommon:** 1 affix, band 0–0.5.
- **Rare:** 2 affixes, band 0.2–0.7.
- **Epic:** 3 affixes, band 0.35–0.85.
- **Legendary:** 4 affixes, band 0.55–1.
- **Artifact:** authored and unique; never rolled.

Every rarity also has a glyph (· ◇ ◆ ✦ ★ ✷) and its word, with colours from the Okabe-Ito set.

### 2.4 Affixes and generation
- **Saving:** an affix stores only `id -> roll 0..999`. The value is computed as `min + (max-min) · lerp(band, roll)`, so retuning `Data/Affixes` retunes every existing item.
- **Picking affixes:**
  - one affix per `group`;
  - at most 2 prefixes and 2 suffixes;
  - the item's `affixClass` must be in the affix's `on` list;
  - the affix's `minRarity` must be at or below the item's rarity.
- **Seeding:** `ItemGenerator.rng(worldSeed, sourceId, salt)`. Given items use the uid they're about to receive as `sourceId`.
- **Luck:** multiplies each rarity's weight by `(1+luck)^(index-1)`.

### 2.5 Instances (`Record`, saved)
- **Keys:**
  - `i` id, `n` count, `u` uid, `r` rarity
  - `a` affix rolls, `d` durability, `q` quality
  - `c` crafter, `cn` custom name (filtered), `b` bound
  - `f` flags (1 favourite, 2 locked, 4 new), `ch` charges, `t` minted
- **Stackables** carry no per-instance state and get no uid.
- **Uniques** get the uid `<owner base36>.<counter base36>`. Uids are unique across players because the owner key is part of the uid.

## 3. Inventory

### 3.1 Rules (`Server/Items/Inventory`, pure, unit-tested)
- **Grid:** 24 base slots, plus bag slots, up to a ceiling of 72.
- **Places:** `"s12"` is a grid slot and `"e:head"` an equipment slot. The client also sends `"q2"` for quickslots (use only).
- **Moves:**
  - grid → grid: move, split `n`, merge (the rest stays), or swap;
  - grid → equipment: equip (the old item swaps back);
  - equipment → grid: unequip, or swap with an item that fits;
  - equipment → equipment: swap (rings, hands).
- **Two-handed:** a two-handed weapon pushes the off hand into the grid. While one is held, the off hand is refused (`TWO_HANDED`).
- **Bags:** a bag can't be unequipped (or swapped smaller) while its slots hold items (`BAG_NOT_EMPTY`).
- **Overflow:** if capacity ever shrinks under items, they stay in place and can only be moved out.
- **Sort:** merges stacks, then orders favourites first, then by category, rarity (high first) and name. Locked items keep their slots.
- **Quickslots:** a stackable binds by item id (the first stack is used); a unique binds by uid (it's found wherever it is).

### 3.2 Transactions and anti-duplication
- **Atomic changes:** every change runs in `Inventory.transact`. It snapshots, runs the operation, then checks every invariant:
  - stack caps;
  - uniques have uids, and no uid appears twice;
  - every item fits its slot;
  - nothing new is placed in overflow;
  - two-handed rules hold;
  - currency stays inside its bounds.
- **Rollback:** an error, a refusal or a broken invariant restores the snapshot exactly.
- **Logging:** every operation is logged in memory (the last 200, admin `invlog`) and in the save (`audit`, the last 30). Failures that hit `ERROR` or `INVARIANT` go to `log:error`.
- **Loading:**
  - duplicate uids and malformed records move to `inventory.quarantine` (kept, never deleted);
  - renamed ids resolve through aliases;
  - equipment that no longer fits its slot returns to the grid.
- **Use races:** using an item **takes it first** (atomically), then applies the effects, and refunds it if nothing happened. Two fast uses of a last potion can't both succeed.
- **Saving:** the inventory lives in the session-locked player record, so it's never written by two servers at once. Trades (stage 3) will add `saveNow` after both sides commit.

### 3.3 Equipment slots
- **The 15 slots:** head, amulet, cloak, chest, belt, legs, feet, hands, ring1, ring2, trinket, mainHand, offHand, bag1, bag2.
- **R15 attachments:** `HatAttachment`, `NeckAttachment`, `BodyBackAttachment`, `BodyFrontAttachment`, `WaistCenterAttachment`, `WaistFrontAttachment`, `WaistBackAttachment`, `RightGripAttachment`, `LeftGripAttachment`.

### 3.4 Visuals (`GearVisuals`)
- **Parts:** generated, Massless, with no collision, query or touch.
- **Welding:** each part is welded to its R15 attachment. Held items start at the grip point and point forward; staffs, torches, orbs and tomes are held upright.
- **Limits:** 1–5 parts per item. The torch, Ember Orb and Hourglass each add one PointLight.
- **Rebuilds:** only slots whose item changed are rebuilt, and models are rebuilt on respawn.

### 3.5 Use effects (`ItemUse`)
- **Effects:**
  - heal (now, or over time);
  - reservoir (flat, or a share of max);
  - buff (a timed stat layer);
  - study (a book: `ProgressionService:awardStudy(…,"book")`, once);
  - spell (a scroll: `CastService:castFromItem`, which waives knowledge and caps, but aim, range, LOS and payment are real);
  - repair (the most worn equipped item);
  - cleanse.
- **Checks:** a use goes ahead only if some effect would do something. There's no drinking a potion at full health.
- **Cooldowns:** per item, or per `group` (all potions share one).

## 4. Stats

### 4.1 Calculation order (`StatCalc`)
1. **Base:** 100 health, 60 carry, 100 stamina.
2. **Profile:** reservoir from attunement and traits.
3. **Mastery:** +5 health per tier of your best branch.
4. **Gear:**
   - only items that are unbroken and whose requirements are met;
   - rarity × quality base stats, affixes, focus domain power;
   - attunements and attuned affixes only if you meet them.
5. **Set bonuses:** cumulative by pieces worn.
6. **Buffs.**
7. **Percent:** each `*Pct` with `pctOf` multiplies its target once. Layers 1–6 are summed first.
8. **Load:** from weight / carry. Light ≤ 0.75, Burdened ≤ 1.0 (−10% speed), Overloaded ≤ 1.5 (−35%), then −60%.
9. **Caps:** `StatDefs` min/max.

Every contribution becomes a breakdown line, shown in admin `itemstats` and the screen's "All stats".

### 4.2 Where stats take effect

| Stat | Applied by |
|---|---|
| health, healthPct | `InventoryService` → `Humanoid.MaxHealth` (the current share is kept) |
| healthRegen | `InventoryService` 1 Hz loop |
| moveSpeedPct (+ load) | `WalkSpeed`, or `MagicBaseWalk` while a status owns WalkSpeed |
| reservoirMax / Pct / RegenPct | `ReservoirService` via `StatCache.reservoir` |
| spellPowerPct, power_<domain>, castSpeedPct, costReductionPct, stabilityPct | `CastService` step 7 via `StatCache.applyToCast` |
| backlashResistPct | `CastService` after payment via `StatCache.applyToConsequences` |
| modifierSlots, formTier | `CastService` sets `caster.bonusModifierSlots` / `bonusFormTier`, and `MagicCore.validateRecipe` honours them |
| resistances | the Cast/Resistances `items` source (so DamageModel uses them for every hit) |
| defense, stamina*, attack* | shown, with a note on when they'll matter (weapons, movement stages) |

## 5. Foci (the bare-handed tradeoff)

- **Low power is never gated:** spells below power 6 never need a focus.
- **The penalty:** from power 6, casting without a matching focus costs **+6% reservoir** and adds **+2% backfire chance** per power step. At P10 bare-handed that's +30% cost and +10% backfire.
- **A matching held (major) focus:** removes the penalty and adds its own stability.
- **A worn (minor) focus, or a held focus of another domain:** halves the penalty.
- **What foci add:**
  - domain power (`focus.domains`);
  - extra modifier slots (Tidecall Tome, the *of the Scholar* affix, the Hourglass when attuned);
  - form reach, one tier (*of Ascension*, the Hourglass).
- **Gated effects:** affinity- and mastery-gated effects use `attune` (the Ember Orb, Kindred-flame, Deep-bound, *of the Adept*).

## 6. Network

| Remote | Kind | Args | Notes |
|---|---|---|---|
| `RequestInventory` | Function | – | → InventoryView |
| `RequestStatSheet` | Function | – | → final, resist, lines (≤ 300), load, focus, buffs |
| `InventoryAction` | Function | op, a?, b?, n?, aim? | ops: move equip unequip use drop sort favorite lock quick seen. Rate 12 burst / 6 per s, 160 bytes |
| `InventoryChanged` | Event (server) | InventoryView | the owner only, coalesced to one per frame |

`InventoryView` sends each record plus two server-only flags: `ok` (requirements met) and `att` (attunement on). Affinities stay private; only those booleans leave the server.

**Topics:** `ItemsGained { player, itemId, count }` and `ItemUsed { player, itemId }`.

**Flags:** `items_enabled` (off makes the inventory read-only) and `items_debug_log`.

**Save:** schema **v4**. Migration `[3]` turns v3's placeholder into the real inventory. `validate` checks the inventory's shape, currency and record count (≤ 120).

## 7. UI

- **Inventory screen:** I on keyboard, D-pad up on gamepad, or the HUD's Inventory button.
  - **Wide layout:** paper doll and summary on the left; filters, search, sort, coins, quickslots and the grid in the middle; details on the right (the tooltip, a ▲/▼ comparison with the worn item, and actions).
  - **Compact layout:** one scrolling column.
  - **Mouse:** drag and drop, right-click for the default action, and a hover tooltip.
  - **Touch and gamepad:** select, then Move or the action buttons.
- **Quickbar layer:** Z X V B on keyboard; L1 cycles and L2 uses on gamepad; tap on touch. Cooldown overlays show. Scrolls aim with the crosshair or mouse.
- **Gain toasts:** "+3 Iron Ore" for any increase in an item's total.
- **Accessibility:** rarity always shows a glyph and its word; better/worse uses ▲/▼, met/unmet ✓/✗, and broken items say "broken".

## 8. Admin (category "Items")

- **`give <player> <item> [count] [rarity] [affixes]`:** rarity is `roll` or a fixed rarity; affixes are a comma list.
- **`kit <player> caster|fighter|tools|consumables|materials|all`**
- **`inv`, `iteminfo`, `itemstats`, `invlog`:** inspection.
- **`clearinv`, `setcoins`, `coins`, `repairall`, `wear`:** state changes.
- **`itemroll <item> [n] [luck]`:** rarity shares, affix frequency and stat ranges.

## 9. Not yet (later stages)

- **World drops:** `drop` destroys the item until world drops exist (loot stage). The client asks before destroying.
- **Trading:** player-to-player trades come with the economy stage (Step 5).
- **Weapon XP:** weapon hits don't train anything yet; skills outside magic come with Step 6.
- **Bespoke weapon animations:** every melee kind reuses Slash1/Slash2 and shots reuse the CastSpell wind-up until the clips in `WeaponTuning.animations` exist (§10).
- **NPC weapons:** NPCs still fight with spells only (NPCCombat); they keep `Data/Gear` attributes, and NPC inventories come with the economy stage.
- **Composer UI:** it doesn't yet show focus-granted modifier slots or form reach; the server already allows them.

## 10. Weapons and stamina (Step 2 completion, written 2026-11-03, not yet run)

**When weapons fight.** With no spell readied (equip mode with nothing attuned, or quick mode), the attack inputs go to the main-hand weapon:

| Input | Melee weapon | Bow | Crossbow / bandolier |
|---|---|---|---|
| Left mouse, gamepad R1, touch Cast | swing | hold to draw, release to loose | shoot / throw |
| F, gamepad B, touch Slash | swing | – | – |
| Right mouse, L1, touch Block | block (not daggers) | – | – |

With a spell readied, nothing changes: left click casts, F is the spellblade (which already adds the weapon's damage), right mouse raises a ward. Routing: `CastClient.weapon` hooks, filled by `Controllers/WeaponClient`.

**Code.** Shared `Items/Data/WeaponTuning` (per-kind swings, ranged kinds, hits, stamina, the wanted animation list) and `Items/WeaponRules` (pure maths). Server `Services/WeaponService` (remote `WeaponIntent(op, aim?)`, result `WeaponResult`), `Services/StaminaService`. Client `Controllers/WeaponClient`, `Fx/WeaponFx`.

**Melee.** Each kind has a two-swing combo (sword, axe, spear, dagger, staff) with its own timing, hit box, share, knockback and stamina multiplier. The weapon's speed / 1.2 × (1 + attack speed) scales the timing (clamped 0.7–1.6). The server sweeps the hit box 3 times in the active frames, each character once, never through walls; a block, dash, cast or stagger cancels the rest. A press before the combo window is refused on the server and buffered on the client.

**Ranged.** Ammo is a tag on the weapon (`arrow`, `bolt`, `thrown_knife`); one item carrying it is taken atomically per shot (`InventoryService:transact`). The projectile is a real server flight (`Cast/Delivery`, with `Delivery.newId()`): gravity, walls, and guards can parry it back at the shooter. Clients draw it from the `weapon` WorldEffect cue (`Fx/WeaponFx`; arrows that hit a surface stick for 4 s).
- **Bow:** below 0.25 s the shot is refused (`UNDERDRAWN`); the share grows from 0.35 to 1 at 1 s; past 3 s it drains stamina and weakens. The draw is timed on the server's clock. The HUD's cast bar shows the draw.
- **Crossbow:** always a full shot, 1.6 s reload. **Bandolier:** quick throws, 0.45 s.

**Hits.** `(weapon.damage + attackPower) × share`, × 1.5 on a crit (5% + the kind's bonus + `critChancePct`, seeded per attack), × (1 − resistance to the damage type), × (1 − the victim's defense reduction, players only: `defense / (defense + 60)`, at most 60%), then the spell caps (`maxHit`, `pvpMaxShare`). Through `Cast/Damage` as form `touch` (melee: guards block, a parry staggers the attacker) or `projectile`. Other players only with `pvp_enabled`. The weapon loses 1 durability every 4 hits; a broken weapon can't attack or block.

**Stamina.** `StaminaService`: max = `staminaMax` (100 base), regen 20/s × (1 + `staminaRegenPct`) after 0.9 s without spending (encumbrance already lowers `staminaRegenPct`). Spent by swings (`weapon.stamina × swing.stamina`), shots, over-held draws and weapon blocks (0.6 per point blocked; empty breaks the guard). Replicated as Player attributes `Stamina` / `StaminaMax`; the HUD shows a bar under the reservoir while it isn't full. Admin: `stamina [player] [value]`, `infstamina [player] [on]`.

**Weapon blocks.** `GuardService` lets a blocking weapon raise the guard when no spell is readied (look `steel`, a faint glint in `GuardFxController`). Same guard meter, parry window and stagger rules as a ward; it costs stamina instead of reservoir.

**New items.** `light_crossbow`, `knife_bandolier`, `wooden_arrow` (50), `iron_bolt` (40), `throwing_knife` (20, ammo). The bow now names `ammo = "arrow"`. The `fighter` kit includes them all. `defense`, `staminaMax`, `staminaRegenPct`, `attackPower`, `attackSpeedPct` and `critChancePct` are now wired (no "matters later" note in the breakdown).

**Animations wanted** (R6, owned by the place owner): AxeChop, AxeOverhead, SpearThrust, SpearSweep, DaggerJab, DaggerSlash, StaffSwing, StaffSweep, BowDraw, BowRelease, CrossbowFire, CrossbowReload, Throw. Add each to `Data/CombatAnimations.animations`, then point the swing's `clip` at it.

## 11. Repair (Step 2 completion, written 2026-11-03, not yet run)

**At a station.** `Shared/Items/Repair.quote(rec)` picks the station by the item's first matching tag (`ItemRules.repair.byTag`): metal and glass at the forge, leather, bone, wood and paper at the workbench, cloth at the loom. The price scales with wear: coins `ceil(value × missing share × 0.3)` (at least 1), plus `ceil(missing share × 2)` items of the row's material tag (`metal_ingot`, `gem`, `hide`, `plank`, `cloth`, `paper`). The Crafting screen shows a Repair card above the recipes, with ✓/✗ per cost, per-item Repair buttons and "Repair all". `RepairAction(stationId, ref | "all")` → `CraftingService`: reach check, cooldown, then one atomic transaction (all coins and materials taken and every item mended, or nothing).

**By magic.** Earth magic mends metal, glass, stone and gem items: the Inventory's details panel shows "✦ Mend (+points, reservoir)" when you can. Tier = the Earth root's, or Metallurgy's + 1. Novice restores 25% of max, Adept 40%, Skilled 60%, Expert 80%, Master full. It costs `3 + 0.15 × points` reservoir, has a 2 s cooldown, and gives a little study XP to the branch that did it. `InventoryAction("mend", ref)` → `InventoryService`: the durability change is one transaction; the reservoir is paid only if it commits.

**Spec:** `Tests/Weapons.spec` (weapon data and ammo, combo timing, speed clamps, draw share, defense curve, which weapons block, repair stations and costs, mending tiers).
