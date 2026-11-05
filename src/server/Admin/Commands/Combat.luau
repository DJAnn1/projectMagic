--!strict
--[[
	Combat tools (docs/Combat.md): resistances, gear, knockdowns and NPC fights.

	resists [player]                    every resistance source on a player (innate, ward, gear, manual)
	npcresists [npc]                    the same for an NPC (its rig must exist: T0/T1)
	gear <player> <slot> <item|none>    equip or remove a gear item (Data/Gear)
	resist <player> <key> <value>       manual resistance (key: domain, property or "all"; 0 removes)
	knockdown [player]                  knock a player down (as a heavy hit would)
	npcfight [npc] [player]             the NPC turns on a player: fight or flee by its own courage
	npccourage [npc]                    its courage score, stance and attack spell
]]

local Server = script.Parent.Parent.Parent
local Gear = require(Server.Magic.Data.Gear)
local C = require(Server.Magic.Data.CombatTuning)
local Resistances = require(Server.Magic.Cast.Resistances)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local NPCCombat = require(Server.NPC.NPCCombat)
local Players = game:GetService("Players")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Shared = game:GetService("ReplicatedStorage").Shared
local MagicCore = require(Shared.Magic.MagicCore)
local ActionRules = require(Shared.Magic.ActionRules)
local CombatAnimations = require(Shared.Magic.Data.CombatAnimations)
local ActionState = require(Server.Magic.Cast.ActionState)
local Guard = require(Server.Magic.Cast.Guard)
local GuardRules = require(Shared.Magic.GuardRules)

local function humanoidOf(model: Model?): Humanoid?
	return if model then model:FindFirstChildOfClass("Humanoid") else nil
end

local function describe(humanoid: Humanoid): string
	local lines = Resistances.breakdown(humanoid)
	if #lines == 0 then
		return "no resistances"
	end
	local out: { string } = {}
	for _, line in lines do
		table.insert(out, string.format("%-7s %-12s %+.0f%%", line.source, line.key, line.value * 100))
	end
	return table.concat(out, "\n")
end

return function(admin: any, _deps: any)
	local itemOptions: { string } = { "none" }
	for id in Gear.items do
		table.insert(itemOptions, id)
	end
	table.sort(itemOptions)

	local function npcArg(): any
		return { name = "npc", type = "npc", default = "nearest", hint = "id, name, nearest or @selected" }
	end

	admin:Register({
		name = "resists", category = "Spells", description = "Every resistance on a player, by source (innate, ward, gear, manual)",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local humanoid = humanoidOf(a.player.Character)
			return if humanoid then describe(humanoid) else "no character"
		end,
	})

	admin:Register({
		name = "npcresists", category = "NPCs", description = "Every resistance on an NPC, by source (its rig must be loaded)",
		args = { npcArg() },
		handler = function(_, a)
			local rig = a.npc.rig
			if not rig then
				return a.npc.name .. " has no rig right now (too far away)"
			end
			return a.npc.name .. "\n" .. describe(rig.humanoid)
		end,
	})

	admin:Register({
		name = "gear", category = "Spells", description = "Equip or remove a gear item (resistances; no inventory yet)",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "slot", type = "enum", options = Gear.slots },
			{ name = "item", type = "enum", options = itemOptions },
		},
		handler = function(_, a)
			local humanoid = humanoidOf(a.player.Character)
			if not humanoid then
				return "no character"
			end
			local itemId = if a.item == "none" then nil else a.item
			if not Resistances.setGear(humanoid, a.slot, itemId) then
				local item = itemId and Gear.items[itemId]
				return if item then string.format("%s goes in the %s slot", item.name, item.slot) else "unknown item"
			end
			return describe(humanoid)
		end,
	})

	admin:Register({
		name = "resist", category = "Spells", description = "Set a manual resistance (domain, property or all; -0.5..0.8; 0 removes)",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "key", type = "string" },
			{ name = "value", type = "number", min = -C.damage.maxVulnerability, max = C.damage.maxResist },
		},
		handler = function(_, a)
			local humanoid = humanoidOf(a.player.Character)
			if not humanoid then
				return "no character"
			end
			humanoid:SetAttribute("Resist_" .. a.key, if a.value == 0 then nil else a.value)
			return describe(humanoid)
		end,
	})

	admin:Register({
		name = "knockdown", category = "Spells", description = "Knock a player down, as a heavy hit would",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local humanoid = humanoidOf(a.player.Character)
			if not humanoid then
				return "no character"
			end
			StatusEffects.apply(humanoid, "knockdown", { duration = C.reactions.knockdownSeconds })
			return "knocked down " .. a.player.Name
		end,
	})

	admin:Register({
		name = "npcfight", category = "NPCs", description = "An NPC turns on a player (fight or flee by its own courage)",
		args = { npcArg(), { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local npc = a.npc
			if not npc.rig or npc.tier ~= 0 then
				return npc.name .. " must be close (T0) to fight"
			end
			local stance = NPCCombat.onAttacked(npc, "u:" .. a.player.UserId, 20)
			return string.format("%s will %s %s", npc.name, stance, a.player.Name)
		end,
	})

	admin:Register({
		name = "npccourage", category = "NPCs", description = "An NPC's courage, the stance it would take, and its attack spell",
		args = { npcArg() },
		handler = function(_, a)
			local npc = a.npc
			local rig = npc.rig
			local share = if rig then rig.humanoid.Health / math.max(1, rig.humanoid.MaxHealth) else 1
			local courage = NPCCombat.courage(npc, share)
			local recipe = NPCCombat.attackRecipe(npc)
			local stance = if C.aggro.alwaysFlee[npc.occupation] then "flee (always)"
				elseif courage >= C.aggro.fightAt and recipe then "fight"
				else "flee"
			return string.format("%s: courage %.2f (fights at %.2f) -> %s\nattack: %s%s", npc.name, courage, C.aggro.fightAt, stance,
				if recipe then MagicCore.describe(recipe) else "none",
				if npc.combat then string.format("\nengaged: %s, target %s", npc.combat.stance, tostring(npc.combat.target)) else "")
		end,
	})

	-- ─── Guards (docs/Combat.md §12) ────────────────────────────────────────

	admin:Register({
		name = "npcguard", category = "NPCs", description = "An NPC raises its guard for a while (practise blocks and parries against it)",
		args = { npcArg(), { name = "seconds", type = "number", min = 0.5, max = 60, default = 10 } },
		handler = function(_, a)
			local rig = a.npc.rig
			if not rig then
				return a.npc.name .. " has no rig right now (too far away)"
			end
			local ok, reason = Guard.raise(rig.model, "earth")
			if not ok then
				return a.npc.name .. " can't guard: " .. tostring(reason)
			end
			task.delay(a.seconds, function()
				if Guard.isGuarding(rig.model) then
					Guard.lower(rig.model)
				end
			end)
			return string.format("%s guards for %.0fs (parry window %.2fs from now; meter %.0f%%)", a.npc.name, a.seconds,
				GuardRules.tuning.parryWindow, Guard.meter(rig.model) * 100)
		end,
	})

	admin:Register({
		name = "guard", category = "Spells", description = "A player's guard: meter, broken, guarding",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local character = a.player.Character
			if not character then
				return "no character"
			end
			local broken = character:GetAttribute("GuardBrokenUntil")
			local t = workspace:GetServerTimeNow()
			return string.format("guarding: %s  meter: %.0f%%  broken: %s", tostring(Guard.isGuarding(character)),
				Guard.meter(character) * 100,
				if typeof(broken) == "number" and broken > t then string.format("%.1fs left", broken - t) else "no")
		end,
	})

	-- ─── Animations and action states (docs/Combat.md §11) ─────────────────

	local clipOptions: { string } = {}
	for name in CombatAnimations.animations do
		table.insert(clipOptions, name)
	end
	table.sort(clipOptions)
	local stateOptions: { string } = {}
	for name in CombatAnimations.states do
		table.insert(stateOptions, name)
	end
	table.sort(stateOptions)
	local domainOptions: { string } = { "none" }
	for name in CombatAnimations.domains do
		table.insert(domainOptions, name)
	end
	table.sort(domainOptions)

	local function stateLine(model: Model): string
		local snapshot = ActionRules.read(model)
		local t = workspace:GetServerTimeNow()
		local state = ActionRules.effective(snapshot, t)
		local left = if snapshot.untilTime > 0 then string.format(" %.1fs left", math.max(0, snapshot.untilTime - t)) else ""
		return string.format("%-20s %-10s #%d%s%s", model.Name, state, snapshot.seq, left,
			if snapshot.domain then " (" .. snapshot.domain .. ")" else "")
	end

	-- What a clip really contains: its rig (R15 poses UpperTorso/LowerTorso, R6 poses Torso), its
	-- length and its keyframe markers. Fetching needs the asset to be usable by this place.
	local function inspectClip(id: number): ({ rig: string, length: number, markers: { string } }?, string?)
		local ok, sequence = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync("rbxassetid://" .. tostring(id))
		end)
		if not ok or not sequence then
			return nil, tostring(sequence)
		end
		local rig, length, markers = "unknown", 0, {}
		for _, d in sequence:GetDescendants() do
			if d:IsA("Pose") then
				if d.Name == "UpperTorso" or d.Name == "LowerTorso" then
					rig = "R15"
				elseif d.Name == "Torso" and rig == "unknown" then
					rig = "R6"
				end
			elseif d:IsA("Keyframe") then
				length = math.max(length, d.Time)
			elseif d:IsA("KeyframeMarker") and not table.find(markers, d.Name) then
				table.insert(markers, d.Name)
			end
		end
		sequence:Destroy()
		return { rig = rig, length = length, markers = markers }, nil
	end

	admin:Register({
		name = "anim", category = "Spells", description = "Play a combat clip once on a player's own client (the real playback path)",
		args = { { name = "clip", type = "enum", options = clipOptions }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local character = a.player.Character
			if not character then
				return "no character"
			end
			-- Plays through the player's AnimationController (it logs animation_unavailable if it can't).
			ActionState.react(character, a.clip)
			return string.format("asked %s's client to play %s (id %d). Nothing moves? run animcheck", a.player.Name, a.clip,
				CombatAnimations.animations[a.clip].id)
		end,
	})

	admin:Register({
		name = "animcheck", category = "Spells", description = "Fetch every combat clip: rig (R6/R15) vs your avatar, length, keyframe markers",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local humanoid = humanoidOf(a.player.Character)
			local avatar = if humanoid then humanoid.RigType.Name else "no character"
			local lines = { "avatar rig: " .. avatar }
			for _, name in clipOptions do
				local def = CombatAnimations.animations[name]
				local info, err = inspectClip(def.id)
				if not info then
					table.insert(lines, string.format("✗ %-10s %d  can't fetch: %s", name, def.id, err or "?"))
					continue
				end
				local expected: { string } = {}
				for _, marker in def.markers do
					if not table.find(info.markers, marker.name) then
						table.insert(expected, marker.name)
					end
				end
				local mismatch = humanoid ~= nil and info.rig ~= "unknown" and info.rig ~= avatar
				table.insert(lines, string.format("%s %-10s %d  %s %.2fs  markers: %s%s",
					if mismatch then "✗" else "✓", name, def.id, info.rig, info.length,
					if #info.markers > 0 then table.concat(info.markers, ",") else "none",
					(if #expected > 0 then "  (fallback timing for " .. table.concat(expected, ",") .. ")" else "")
						.. (if mismatch then "  RIG MISMATCH: made for " .. info.rig else "")))
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "npcanim", category = "NPCs", description = "Play a combat clip on an NPC once, bypassing action states",
		args = { { name = "clip", type = "enum", options = clipOptions }, npcArg() },
		handler = function(_, a)
			local rig = a.npc.rig
			if not rig then
				return a.npc.name .. " has no rig right now (too far away)"
			end
			local track = rig.tracks[a.clip]
			if not track then
				return "that rig has no " .. a.clip .. " track (it failed to load)"
			end
			track:Play(0.05)
			return string.format("%s plays %s (length %.2fs)", a.npc.name, a.clip, track.Length)
		end,
	})

	admin:Register({
		name = "actionstate", category = "Spells", description = "Force a player's action state (its clips follow on their client)",
		args = {
			{ name = "state", type = "enum", options = stateOptions },
			{ name = "player", type = "player", default = "me" },
			{ name = "seconds", type = "number", min = 0, max = 30, optional = true, hint = "0 = until changed; default = the state's" },
			{ name = "domain", type = "enum", options = domainOptions, default = "none" },
		},
		handler = function(_, a)
			local character = a.player.Character
			if not character then
				return "no character"
			end
			ActionState.set(character, a.state, {
				duration = a.seconds,
				domain = if a.domain == "none" then nil else a.domain,
				force = true,
			})
			return stateLine(character)
		end,
	})

	admin:Register({
		name = "npcstate", category = "NPCs", description = "Force an NPC's action state (its rig's clips follow at T0)",
		args = {
			{ name = "state", type = "enum", options = stateOptions },
			npcArg(),
			{ name = "seconds", type = "number", min = 0, max = 30, optional = true },
		},
		handler = function(_, a)
			local rig = a.npc.rig
			if not rig then
				return a.npc.name .. " has no rig right now (too far away)"
			end
			ActionState.set(rig.model, a.state, { duration = a.seconds, force = true })
			return stateLine(rig.model) .. (if rig.root.Anchored then "\n(T1: anchored, so no clips play)" else "")
		end,
	})

	admin:Register({
		name = "animstate", category = "Spells", description = "Action states of every player and of NPCs near you (labels: flag combat_anim_debug true)",
		args = { { name = "radius", type = "number", min = 10, max = 500, default = 120 } },
		handler = function(ctx, a)
			local lines: { string } = {}
			local here = ctx.player.Character and ctx.player.Character:GetPivot().Position
			for _, player in Players:GetPlayers() do
				if player.Character then
					table.insert(lines, stateLine(player.Character))
				end
			end
			local folder = workspace:FindFirstChild("NPCs")
			if folder and here then
				for _, model in folder:GetChildren() do
					if model:IsA("Model") and (model:GetPivot().Position - here).Magnitude <= a.radius then
						table.insert(lines, stateLine(model))
					end
				end
			end
			if #CombatAnimations.duplicates > 0 then
				for _, pair in CombatAnimations.duplicates do
					table.insert(lines, string.format("! %s and %s share id %d", pair.a, pair.b, pair.id))
				end
			end
			return table.concat(lines, "\n")
		end,
	})
end
