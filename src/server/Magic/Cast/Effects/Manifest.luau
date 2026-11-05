--!strict
--[[
	Manifest: the fallback for every spell no specific route handles (illusions, wards, time
	slips, bonds...). It marks what it reached with a "MagicTouch" attribute (domain id) and an
	expiry, so future systems (NPC reactions, status effects, mythic runtimes) have a hook. Clients
	see it through the WorldEffect cue CastService sends for every cast.

	Effective when it reached a character or landed on something solid.
]]

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)

local Manifest = {}

function Manifest.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		return { effective = false, hits = 0, note = "The working unravels around you." }
	end
	local expires = workspace:GetServerTimeNow() + math.max(1, ctx.stats.duration)
	local hits = Targeting.select(ctx)
	for _, hit in hits do
		hit.humanoid:SetAttribute("MagicTouch", ctx.stats.domains[1])
		hit.humanoid:SetAttribute("MagicTouchUntil", expires)
	end
	return { effective = #hits > 0 or ctx.onSurface, hits = #hits }
end

return Manifest
