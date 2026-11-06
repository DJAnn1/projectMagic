--!strict
--[[
	EmoteFx: magic flourishes tinted by the emoter's Signature (docs/Social.md §5). Each viewer draws
	them locally, through the same pooled effects as spells, so FxPool's caps and the quality setting
	apply to them and a crowd of light shows can't outgrow the budget.

		EmoteFx.play(kind, userId, character) -> stop()

	Colour comes from the player's MagicSignature attribute through SpellFx.styleFor, using its accent
	(the part of a style that's purely the signature) so two players' shows look different.
]]

local Audio = require(script.Parent.Parent:WaitForChild("Audio").Audio)
local FxLayers = require(script.Parent.FxLayers)
local Recipes = require(script.Parent.FxRecipes)
local SpellFx = require(script.Parent.SpellFx)

export type Style = SpellFx.Style

local EmoteFx = {}

local function signatureStyle(userId: number): Style
	local base = SpellFx.styleFor(userId, "energy")
	return { primary = base.accent, secondary = base.secondary, accent = base.accent, particle = base.particle, motion = base.motion }
end

local function rootPosition(character: Model): Vector3?
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- Five bursts climbing around the body, then one above the head.
local function lightShow(style: Style, character: Model, alive: () -> boolean)
	local tier = Recipes.tiers[4]
	local quality = SpellFx.quality()
	for i = 1, 6 do
		if not alive() then
			return
		end
		local at = rootPosition(character)
		if not at then
			return
		end
		local angle = i * math.pi * 0.7
		local point = at + Vector3.new(math.cos(angle) * 3, -1 + i * 1.2, math.sin(angle) * 3)
		SpellFx.burstAt(point, 1, style, tier, math.floor(26 * quality), { lifetime = 0.9, color = if i % 2 == 0 then style.secondary else style.accent, sizeMult = 1.2 })
		FxLayers.light(point, style.accent, 3, 14, 0.5)
		if i == 1 then
			Audio.play("ui.confirm", { position = point })
		end
		task.wait(0.45)
	end
end

local function halo(style: Style, character: Model)
	local at = rootPosition(character)
	if not at then
		return
	end
	FxLayers.shockwave(at + Vector3.new(0, 3.5, 0), Vector3.yAxis, 4, style.accent, 1.2)
	FxLayers.light(at + Vector3.new(0, 3.5, 0), style.accent, 2, 12, 1.5)
	SpellFx.burstAt(at + Vector3.new(0, 3.5, 0), 2, style, Recipes.tiers[4], math.floor(30 * SpellFx.quality()), { lifetime = 1.4, sizeMult = 0.9 })
	Audio.play("ui.notify", { position = at })
end

-- Slow motes rising while someone meditates: a small burst every couple of seconds until stopped.
local function motes(style: Style, character: Model, alive: () -> boolean)
	while alive() do
		local at = rootPosition(character)
		if not at then
			return
		end
		SpellFx.burstAt(at + Vector3.new(0, -0.5, 0), 2.5, style, Recipes.tiers[4], math.floor(6 * SpellFx.quality()), { lifetime = 2.2, sizeMult = 0.7, speedMult = 0.4 })
		task.wait(2)
	end
end

function EmoteFx.play(kind: string, userId: number, character: Model): () -> ()
	local running = true
	local function alive(): boolean
		return running and character.Parent ~= nil
	end
	local style = signatureStyle(userId)
	if kind == "light_show" then
		task.spawn(lightShow, style, character, alive)
	elseif kind == "halo" then
		halo(style, character)
	elseif kind == "motes" then
		task.spawn(motes, style, character, alive)
	end
	return function()
		running = false
	end
end

return EmoteFx
