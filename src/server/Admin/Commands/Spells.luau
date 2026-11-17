--!strict
--[[
	Spell testing tools.

	cheat <infinite|nocooldown|nobacklash> [on|off]   per player, this session (CastService)
	overpower                     your next normal cast ignores knowledge, tier and power caps
	density [value] [radius] [minutes]   ambient magic density at your position (0..3, nexus = 3);
	                              no value = remove your override
	cast <branch> <property> <verb> <form> <power> [at] [modifiers]
	                              any recipe through the real pipeline at a point (@cursor),
	                              ignoring knowledge, tier, caps, range and line of sight
	spellstats <branch> <property> <verb> <form> <power> [modifiers]
	                              computed stats (power, cost, range, duration, area, instability...)
	                              for you here, and for an unbound caster when you can't cast it
	dummy <spawn|heal|clear> [hp] [at]   a target that shows the damage it takes
	spellaudit [power] [domain]   every recipe the grammar allows, counted by where it lands: how many
	                              are plain damage or do nothing (docs/SpellOverhaul.md §2G)
	magichealth [player]          how much health their magic gives them, part by part
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Util = require(script.Parent.Parent.Util)
local SpellAudit = require(game:GetService("ReplicatedStorage").Shared.Magic.SpellAudit)
local MagicHealth = require(game:GetService("ReplicatedStorage").Shared.Magic.MagicHealth)
local SpellExamples = require(game:GetService("ReplicatedStorage").Shared.Magic.Data.SpellExamples)
local CombatAnimations = require(game:GetService("ReplicatedStorage").Shared.Magic.Data.CombatAnimations)

local DUMMY_TAG = "AdminTestDummy"

return function(admin: any, deps: any)
	local cast = deps.cast
	local world = deps.world
	local reservoirs = deps.reservoirs
	local playerData = deps.playerData

	admin:Register({
		name = "cheat", category = "Spells", description = "Spell cheats for you this session: infinite reservoir, no cooldowns, no backlash",
		args = {
			{ name = "kind", type = "enum", options = { "infinite", "nocooldown", "nobacklash", "all", "none" } },
			{ name = "on", type = "boolean", optional = true },
		},
		handler = function(ctx, a)
			local c = cast:cheats(ctx.player)
			local map = { infinite = "infinite", nocooldown = "noCooldown", nobacklash = "noBacklash" }
			if a.kind == "all" or a.kind == "none" then
				for _, field in map do
					(c :: any)[field] = a.kind == "all"
				end
			else
				-- Naming a cheat turns it on, whatever state it was in. Only "off" turns it off: this
				-- used to toggle, so `cheat infinite` after `cheat all` quietly switched it off.
				local value = if a.on == nil then true else a.on;
				(c :: any)[map[a.kind]] = value
			end
			-- Resolvers with cooldowns of their own (Effects/Ultimate) read this.
			ctx.player:SetAttribute("CheatNoCooldown", c.noCooldown == true)
			-- The reservoir itself knows, so everything that spends from it agrees (Shared/Magic/Reservoir).
			local reservoir = reservoirs:get(ctx.player)
			if reservoir then
				reservoir.infinite = c.infinite == true
				if c.infinite then
					reservoir.current, reservoir.strain, reservoir.burnoutUntil = reservoir.max, 0, 0
					table.clear(reservoir.lockouts)
				end
				reservoirs:push(ctx.player)
			end
			return string.format("infinite %s · nocooldown %s · nobacklash %s", tostring(c.infinite == true), tostring(c.noCooldown == true), tostring(c.noBacklash == true))
		end,
	})

	admin:Register({
		name = "overpower", category = "Spells", description = "Your next cast ignores knowledge, tier and power caps (once)",
		handler = function(ctx)
			cast:cheats(ctx.player).overpowerOnce = true
			return "next cast is unbound by caps"
		end,
	})

	admin:Register({
		name = "density", category = "Spells", description = "Override ambient magic density around you (no value = remove)",
		args = {
			{ name = "value", type = "number", min = 0, max = 3, optional = true, slider = true },
			{ name = "radius", type = "number", min = 8, max = 1000, default = 120 },
			{ name = "minutes", type = "number", min = 1, max = 600, default = 30 },
		},
		handler = function(ctx, a)
			local id = "admin_density_" .. ctx.player.UserId
			world:removeModifier(id)
			if a.value == nil then
				return "density override removed"
			end
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local p = root.Position
			local base = math.max(world:densityAt(p.X, p.Z), 0.01)
			world:addModifier({ id = id, x = p.X, z = p.Z, radius = a.radius, density = a.value / base, expiresAt = os.time() + a.minutes * 60 })
			return string.format("density %.2f (was %.2f) within %d studs for %d min", world:densityAt(p.X, p.Z), base, a.radius, a.minutes)
		end,
	})

	local function recipeOf(a: any): any
		return {
			branch = a.branch,
			property = a.property,
			verb = a.verb,
			form = a.form,
			power = a.power,
			modifiers = Util.splitList(a.modifiers),
		}
	end

	local recipeArgs = function(extra: { any }): { any }
		local args: { any } = {
			{ name = "branch", type = "branch" },
			{ name = "property", type = "property" },
			{ name = "verb", type = "verb" },
			{ name = "form", type = "form" },
			{ name = "power", type = "integer", min = 1, max = 10, default = 3, slider = true },
		}
		for _, e in extra do
			table.insert(args, e)
		end
		table.insert(args, { name = "modifiers", type = "text", optional = true, hint = "modifier ids, comma separated" })
		return args
	end

	admin:Register({
		name = "cast", category = "Spells", description = "Cast any recipe at a point through the real pipeline (caps, range and line of sight ignored)",
		args = recipeArgs({ { name = "at", type = "vector3", optional = true, hint = "@cursor (default: 20 studs ahead)" } }),
		handler = function(ctx, a)
			local at: Vector3? = a.at or Util.ahead(ctx.player, world, 20)
			if not at then
				return "no character"
			end
			local reason = cast:castAs(ctx.player, recipeOf(a), at, nil)
			return if reason then "refused: " .. reason else "cast at " .. Util.fmt(at)
		end,
	})

	admin:Register({
		name = "spellstats", aliases = { "inspectspell" }, category = "Spells", description = "Computed stats for a recipe, as you would cast it here",
		args = recipeArgs({}),
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			local recipe = recipeOf(a)
			local stats, err = cast:preview(ctx.player, recipe, if root then root.Position else nil, false)
			local note = ""
			if not stats then
				note = "You can't cast this (" .. tostring(err) .. "). Unbound stats:\n"
				stats, err = cast:preview(ctx.player, recipe, if root then root.Position else nil, true)
				if not stats then
					return "invalid recipe: " .. tostring(err)
				end
			end
			local s: any = stats
			return note .. string.format(
				"%s\npower %.2f · cost %.1f (reservoir %.1f, ambient %.1f, hp %.1f)\nrange %.1f · area %.1f · duration %.1fs · cast %.2fs · cooldown %.1fs\ninstability %.3f · backfire %.3f · tier %d · harmful %s%s",
				s.key, s.power, s.cost or (s.costBreakdown.reservoir + s.costBreakdown.ambient), s.costBreakdown.reservoir, s.costBreakdown.ambient, s.costBreakdown.vitalHp,
				s.range, s.area, s.duration, s.castTime, s.cooldown, s.instability, s.backfireChance, s.masteryTier, tostring(s.harmful),
				if s.warnings and #s.warnings > 0 then "\nwarnings: " .. table.concat(s.warnings, ", ") else ""
			)
		end,
	})

	-- ─── Test dummies ───────────────────────────────────────────────────────

	local function spawnDummy(at: Vector3, hp: number): Model?
		local ok, model = pcall(function()
			-- The same rig as players and NPCs, so the combat clips play on dummies too.
			local rig = (Enum.HumanoidRigType :: any)[CombatAnimations.rigType] :: Enum.HumanoidRigType
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), rig)
		end)
		if not ok or not model then
			return nil
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
		model.Name = "Test Dummy"
		model:SetAttribute("PracticeTarget", true) -- hitting it is never a crime
		humanoid.MaxHealth = hp
		humanoid.Health = hp
		humanoid.BreakJointsOnDeath = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromOffset(220, 50)
		billboard.StudsOffset = Vector3.new(0, 3.5, 0)
		billboard.AlwaysOnTop = true
		billboard.MaxDistance = 150
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 0.4
		label.BackgroundColor3 = Color3.new(0, 0, 0)
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.Code
		label.TextScaled = true
		label.Parent = billboard
		billboard.Parent = model:FindFirstChild("Head") or model.PrimaryPart
		local total, last = 0, 0
		local previous = hp
		local function render()
			label.Text = string.format("DUMMY %.0f / %.0f\nlast %.1f · total %.1f", humanoid.Health, humanoid.MaxHealth, last, total)
		end
		humanoid.HealthChanged:Connect(function(health)
			if health < previous then
				last = previous - health
				total += last
			end
			previous = health
			render()
		end)
		render()
		CollectionService:AddTag(model, DUMMY_TAG)
		model:PivotTo(CFrame.new(at + Vector3.new(0, 3, 0)))
		model.Parent = workspace
		return model
	end

	admin:Register({
		name = "dummy", category = "Spells", description = "Spawn, heal or clear test dummies (they show damage taken)",
		args = {
			{ name = "action", type = "enum", options = { "spawn", "heal", "clear" }, default = "spawn" },
			{ name = "hp", type = "number", min = 1, max = 1000000, default = 1000 },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor (default: 12 studs ahead)" },
		},
		handler = function(ctx, a)
			local dummies = CollectionService:GetTagged(DUMMY_TAG)
			if a.action == "clear" then
				for _, d in dummies do
					d:Destroy()
				end
				return "removed " .. #dummies .. " dummies"
			elseif a.action == "heal" then
				for _, d in dummies do
					local h = d:FindFirstChildOfClass("Humanoid")
					if h and h.Health > 0 then
						h.Health = h.MaxHealth
					end
				end
				return "healed " .. #dummies .. " dummies"
			end
			if #dummies >= 20 then
				return "20 dummies already; dummy clear first"
			end
			local at: Vector3? = a.at or Util.ahead(ctx.player, world, 12)
			if not at then
				return "no character"
			end
			return if spawnDummy(at, a.hp) then "dummy (" .. a.hp .. " hp) at " .. Util.fmt(at) else "couldn't build a dummy rig"
		end,
	})
	--[[
		moveshow <domain> [gap] [maxPower] [from]   (docs/Smoothness.md stage 7)
		Casts every example spell of a domain (Data/SpellExamples, weakest first) at a dummy 18 studs
		ahead, one every `gap` seconds, through the real pipeline (castAs: knowledge, tier and caps
		waived; no cooldowns while it runs), so you can record and compare. The spell's name shows
		over the dummy, with the refusal if one is refused; the dummy is healed before each. `from`
		starts part way down the list. `moveshowstop` (or starting another show) ends a running one.
		Use `cheat all on` for the reservoir. Everyone nearby sees the spells (they're real casts).
	]]
	local shows: { [Player]: number } = {}
	admin:Register({
		name = "moveshowstop", category = "Spells",
		description = "End your running moveshow at its next spell",
		args = {},
		handler = function(ctx, _a)
			local player: Player = ctx.player
			local running = shows[player] ~= nil
			shows[player] = (shows[player] or 0) + 1 -- the running show sees a newer token and stops
			return if running then "show stopped" else "no show running"
		end,
	})
	admin:Register({
		name = "moveshow", category = "Spells",
		description = "Cast every example spell of a domain at a dummy, one after another, for recording (moveshowstop ends it)",
		args = {
			{ name = "domain", type = "domain" },
			{ name = "gap", type = "number", min = 1, max = 15, default = 3.5, hint = "seconds between spells" },
			{ name = "maxPower", type = "number", min = 1, max = 10, default = 10 },
			{ name = "from", type = "number", min = 1, max = 500, default = 1, hint = "start at this spell in the list" },
		},
		handler = function(ctx, a)
			local player: Player = ctx.player
			local token = (shows[player] or 0) + 1
			shows[player] = token -- any show already running stops at its next spell
			local list = {}
			for _, example in SpellExamples do
				if example.domain == a.domain and example.recipe.power <= a.maxPower then
					table.insert(list, example)
				end
			end
			table.sort(list, function(x, y)
				if x.recipe.power ~= y.recipe.power then
					return x.recipe.power < y.recipe.power
				end
				return x.name < y.name
			end)
			local first = math.max(1, math.floor(a.from))
			if first > #list then
				return string.format("%s has %d example spells at power %d or less", a.domain, #list, a.maxPower)
			end
			local at = Util.ahead(player, world, 18)
			if not at then
				return "no character"
			end
			local dummy = spawnDummy(at, 1000000)
			if not dummy then
				return "couldn't build a dummy rig"
			end
			-- The spell's name over the dummy, above its health label.
			local billboard = Instance.new("BillboardGui")
			billboard.Size = UDim2.fromOffset(360, 60)
			billboard.StudsOffset = Vector3.new(0, 6.5, 0)
			billboard.AlwaysOnTop = true
			billboard.MaxDistance = 200
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 0.35
			label.BackgroundColor3 = Color3.new(0, 0, 0)
			label.TextColor3 = Color3.new(1, 1, 1)
			label.Size = UDim2.fromScale(1, 1)
			label.Font = Enum.Font.GothamBold
			label.TextScaled = true
			label.Text = a.domain
			label.Parent = billboard
			billboard.Parent = dummy:FindFirstChild("Head") or dummy.PrimaryPart
			local cheats = cast:cheats(player)
			local hadNoCooldown = cheats.noCooldown
			cheats.noCooldown = true
			task.spawn(function()
				for i = first, #list do
					if shows[player] ~= token or not player.Parent or not dummy.Parent then
						break
					end
					local example = list[i]
					local humanoid = dummy:FindFirstChildOfClass("Humanoid")
					local root = dummy:FindFirstChild("HumanoidRootPart")
					if not humanoid or not root or not root:IsA("BasePart") then
						break
					end
					humanoid.Health = humanoid.MaxHealth
					label.Text = string.format("%d/%d  %s  · power %d %s", i, #list, example.name, example.recipe.power, example.recipe.form)
					local recipe = table.clone(example.recipe) :: any
					recipe.modifiers = if recipe.modifiers then table.clone(recipe.modifiers) else {}
					local reason = cast:castAs(player, recipe, root.Position, dummy)
					if reason then
						label.Text ..= "\nrefused: " .. tostring(reason)
					end
					task.wait(a.gap)
				end
				if shows[player] == token then
					shows[player] = nil
				end
				cheats.noCooldown = hadNoCooldown
				task.wait(2)
				if dummy.Parent then
					dummy:Destroy()
				end
			end)
			return string.format("moveshow %s: %d spells from #%d, one every %.1f s (moveshowstop ends it)", a.domain, #list - first + 1, first, a.gap)
		end,
	})

	admin:Register({
		name = "spellaudit", category = "Spells",
		description = "Every recipe the grammar allows (any mastery) at one power, counted by the effect it routes to: how many are plain damage (harm) or do nothing (manifest)",
		args = {
			{ name = "power", type = "number", min = 1, max = 10, default = 5 },
			{ name = "domain", type = "string", optional = true },
		},
		handler = function(_ctx, a)
			local started = os.clock()
			local report = SpellAudit.run({ power = math.floor(a.power), domain = a.domain, yield = task.wait })
			local lines = SpellAudit.lines(report, 14)
			table.insert(lines, string.format("(%.1f s)", os.clock() - started))
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "magichealth", category = "Spells", description = "How much health a player's magic gives them: best tier, breadth, Life affinity",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx, a)
			local data = playerData:get(a.player)
			local caster = data and data.caster
			if not caster then
				return "no data for them yet"
			end
			local parts = MagicHealth.of(caster)
			local humanoid = a.player.Character and a.player.Character:FindFirstChildOfClass("Humanoid")
			return string.format("best tier %d: +%d · %d other branches at Novice+: +%d · Life: +%.0f%% · max health now %s",
				parts.best, parts.tierFlat, parts.breadth, parts.breadthFlat, parts.pct * 100,
				if humanoid then tostring(math.floor(humanoid.MaxHealth)) else "?")
		end,
	})
end
