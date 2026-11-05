--!strict
--[[
	Light: luminosity conjured as a light source (Glow Mote, Lantern). Touch and aura lights
	follow the caster; the light lasts the spell's duration (clamped by CastTuning.light) and
	counts toward the caster's construct cap and the server's light cap (budget.maxLights: dynamic
	lights are the most expensive thing a client renders). Colour: the domain's first palette colour.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Constructs = require(Cast.Constructs)
local EffectBudget = require(Cast.EffectBudget)

local Light = {}

function Light.precheck(_params: { [string]: any }, _stats: any, _player: Player): string?
	return if EffectBudget.available("lights") <= 0 then "WORLD_STRAINED" else nil
end

function Light.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		-- A flash in the caster's own eyes: nothing lasting.
		return { effective = false, hits = 0, note = "The light flares and gutters out in your hands." }
	end
	if not EffectBudget.acquire("lights") then
		return { effective = false, hits = 0, note = "The air here is already full of light." }
	end
	local stats = ctx.stats
	local domain = Registry.domains[stats.domains[1]]
	local follows = stats.recipe.form == "touch" or stats.recipe.form == "aura"

	local part = Instance.new("Part")
	part.Name = "MagicLight"
	part.Size = Vector3.new(0.4, 0.4, 0.4)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = not follows
	part.CFrame = if follows then ctx.root.CFrame * CFrame.new(0, 2.5, 0) else CFrame.new(ctx.point + Vector3.new(0, 1, 0))

	local light = Instance.new("PointLight")
	light.Color = domain.feel.palette[1]
	light.Range = math.min(T.light.maxRange, 6 + T.light.rangePerPower * math.sqrt(math.max(0, ctx.power)))
	light.Brightness = 1 + 0.3 * stats.recipe.power
	light.Shadows = stats.recipe.power >= 4
	light.Parent = part

	if follows then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = ctx.root
		weld.Part1 = part
		weld.Parent = part
	end
	part.Parent = if follows then ctx.character else workspace
	part.Destroying:Connect(function()
		EffectBudget.release("lights")
	end)
	Constructs.track(ctx.player, part, math.clamp(stats.duration, T.light.minLifetime, T.light.maxLifetime))
	return { effective = true, hits = 0 }
end

return Light
