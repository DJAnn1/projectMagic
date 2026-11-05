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
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Util = require(script.Parent.Parent.Util)
local CombatAnimations = require(game:GetService("ReplicatedStorage").Shared.Magic.Data.CombatAnimations)

local DUMMY_TAG = "AdminTestDummy"

return function(admin: any, deps: any)
	local cast = deps.cast
	local world = deps.world
	local reservoirs = deps.reservoirs

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
				local field = map[a.kind]
				local current = (c :: any)[field] == true
				local value = if a.on == nil then not current else a.on;
				(c :: any)[field] = value
			end
			if c.infinite then
				local reservoir = reservoirs:get(ctx.player)
				if reservoir then
					reservoir.current = reservoir.max
					reservoirs:push(ctx.player)
				end
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
end
