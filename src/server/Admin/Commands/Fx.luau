--!strict
--[[
	VFX tools (docs/Combat.md §8).

	fxpreview <domain> [power] [property] [tier]
		Plays one domain's whole visual vocabulary in front of you, ~8 s, to YOUR client only:
		cast circle → projectile (muzzle flash, streak trail, impact) → beam → chain → burst →
		zone → two blade slashes. Nothing is cast: no reservoir, damage, XP or crime, and nobody
		else sees it. `property` changes the look where it matters: `charge` draws the beam and
		chain as lightning. `tier` is the mastery tier index 0..8 (polish: rings, runes, wobble).
		Use it after changing DomainFx textures or SpellFx tuning to compare domains side by side.
]]

local Server = script.Parent.Parent.Parent
local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local ActionState = require(Server.Magic.Cast.ActionState)
local Util = require(script.Parent.Parent.Util)

local previewIds = 1_000_000 -- far above Delivery's projectile ids, so keys never collide

return function(admin: any, deps: any)
	admin:Register({
		name = "fxpreview",
		category = "Spells",
		description = "Play a domain's spell visuals in front of you (only you see them; nothing is cast)",
		args = {
			{ name = "domain", type = "domain" },
			{ name = "power", type = "number", min = 1, max = 10, default = 5 },
			{ name = "property", type = "property", optional = true, hint = "charge = lightning" },
			{ name = "tier", type = "number", min = 0, max = 8, default = 5, hint = "mastery tier index 0..8" },
		},
		handler = function(ctx, a)
			local player: Player = ctx.player
			local root = Util.rootOf(player)
			local character = player.Character
			if not root or not character then
				return "no character"
			end
			local power: number = a.power
			local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			look = if look.Magnitude > 0.05 then look.Unit else Vector3.zAxis
			local right = look:Cross(Vector3.yAxis).Unit
			local function ground(offset: Vector3): Vector3
				local p = root.Position + offset
				return Vector3.new(p.X, deps.world:surfaceHeight(p.X, p.Z), p.Z)
			end
			local target = ground(look * 26)
			local hand = root.Position + look * 1.5 + Vector3.new(0, 1, 0)

			-- Every cue carries the same spell identity; the stage-specific fields are added per call.
			local function send(fields: { [string]: any })
				local message: { [string]: any } = {
					kind = "spell",
					caster = player.UserId,
					domain = a.domain,
					property = a.property,
					power = power,
					masteryTier = a.tier,
					harmful = true,
					radius = 0,
					lod = 2,
					origin = root.Position,
					castTime = 0.7,
				}
				for k, v in fields do
					message[k] = v
				end
				message.position = message.point or message.origin
				Net.fire("WorldEffect", player, message)
			end
			local function at(seconds: number, fn: () -> ())
				task.delay(seconds, function()
					if root.Parent then
						fn()
					end
				end)
			end

			-- 0.0 s  cast circle
			send({ stage = "begin", form = "projectile" })
			-- 0.8 s  projectile: launch (muzzle + streak), then the impact when it arrives
			at(0.8, function()
				previewIds += 1
				local id = previewIds
				local speed = 55
				local distance = (target - hand).Magnitude
				send({ stage = "launch", form = "projectile", projectileId = id, origin = hand, point = target, velocity = (target - hand).Unit * speed, gravity = 0, lifetime = distance / speed + 0.3 })
				at(distance / speed, function()
					send({ stage = "resolve", form = "projectile", projectileId = id, point = target, normal = Vector3.yAxis })
				end)
			end)
			-- 2.4 s  beam to the right of the first impact
			at(2.4, function()
				send({ stage = "resolve", form = "beam", point = ground(look * 22 + right * 8) + Vector3.new(0, 1, 0) })
			end)
			-- 3.5 s  chain: three hops across in front
			at(3.5, function()
				local points = {
					hand,
					ground(look * 14 - right * 6) + Vector3.new(0, 2, 0),
					ground(look * 20) + Vector3.new(0, 2, 0),
					ground(look * 16 + right * 9) + Vector3.new(0, 2, 0),
				}
				send({ stage = "chain", form = "chain", points = points, point = points[2] })
			end)
			-- 4.6 s  burst, 5.9 s  zone
			at(4.6, function()
				send({ stage = "resolve", form = "burst", point = target, radius = 7, normal = Vector3.yAxis })
			end)
			at(5.9, function()
				send({ stage = "resolve", form = "zone", point = ground(look * 14 - right * 10), radius = 8, normal = Vector3.yAxis })
			end)
			-- 7.2 s / 7.8 s  two blade slashes in the domain's colours (sets the real action
			-- state, so the Slash1/Slash2 clips play and every nearby client draws the arcs)
			at(7.2, function()
				ActionState.set(character, "slashing", { duration = 0.5, variant = "Slash1", domain = a.domain, force = true })
			end)
			at(7.8, function()
				ActionState.set(character, "slashing", { duration = 0.55, variant = "Slash2", domain = a.domain, force = true })
			end)

			return string.format(
				"previewing %s at power %g, tier %g%s: cast circle, projectile, beam, chain, burst, zone, slashes (~8 s, only you see the spells)",
				a.domain,
				power,
				a.tier,
				if a.property then ", property " .. a.property else ""
			)
		end,
	})
end
