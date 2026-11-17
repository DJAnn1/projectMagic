--!strict
--[[
	CastPoses.spec: bodies cast differently by what the spell does (docs/CastPoses.md). What matters
	most: every kind of spell has a gather and a release pose, no pose touches the legs (walking
	keeps going), every form lands on a known mode, kinds really differ, and the timing is ordered.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local CastPoses = require(Shared.Magic.Data.CastPoses)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local Registry = require(Shared.Magic.Registry)
local SpellHand = require(Shared.Magic.SpellHand)
local Flags = require(ServerScriptService.Server.Config.Flags)

local UPPER = { ["Right Shoulder"] = true, ["Left Shoulder"] = true, ["Neck"] = true, ["RootJoint"] = true }

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Cast poses", function()
		it("every kind of spell has a gather and a release pose", function()
			for kind in RouteSummaries.kinds do
				local p = CastPoses.kinds[kind]
				expect(p ~= nil).toBe(true)
				expect(p.gather ~= nil and p.release ~= nil).toBe(true)
			end
			expect(CastPoses.kinds[CastPoses.fallback] ~= nil).toBe(true)
		end)

		it("poses only the arms, neck and torso, with sane angles", function()
			for kind, p in CastPoses.kinds do
				for _, pose in { p.gather, p.release } do
					for joint, rot in pose.joints do
						if not UPPER[joint] then
							error(kind .. " poses " .. joint)
						end
						for _, a in rot do
							expect(math.abs(a) <= 180).toBe(true)
						end
					end
					for _, m in pose.motion do
						expect(UPPER[m.joint]).toBe(true)
					end
				end
			end
		end)

		it("every form lands on a known mode", function()
			for form in Registry.forms do
				expect(CastPoses.modes[SpellHand.modeFor(form)] ~= nil).toBe(true)
			end
			expect(CastPoses.modes.hand.arm).toBe(0)
		end)

		it("kinds really look different when released", function()
			local attack = CastPoses.kinds.attack.release.joints["Right Shoulder"]
			local heal = CastPoses.kinds.heal.release.joints["Left Shoulder"]
			local land = CastPoses.kinds.land.release
			expect(attack[1] >= 90).toBe(true) -- thrust forward
			expect(CastPoses.kinds.attack.release.joints["Left Shoulder"][1] < heal[1]).toBe(true) -- a heal lifts both hands
			expect(land.joints["RootJoint"][1] <= -30).toBe(true) -- land magic bends low over the ground
			for _, p in CastPoses.kinds do
				-- Nothing lowers the torso: the legs aren't posed, so they'd sink into the ground.
				expect((p.gather.lower or 0) == 0 and (p.release.lower or 0) == 0).toBe(true)
			end
			for _, m in CastPoses.modes do
				expect(m.lower).toBe(0)
			end
			expect(CastPoses.kinds.heal.twoHanded).toBe(true)
			expect(CastPoses.kinds.attack.twoHanded).toBe(false)
		end)

		it("timing is ordered, and there's a client flag", function()
			-- Held poses (stage 5): a quick snap, a short follow-through, a held gather that deepens.
			expect(CastPoses.snap > 0 and CastPoses.snap < 0.3).toBe(true)
			expect(CastPoses.follow > 0 and CastPoses.follow + CastPoses.settle < 1.2).toBe(true)
			expect(CastPoses.overshoot >= 0 and CastPoses.overshoot <= 0.3).toBe(true)
			expect(CastPoses.depthMin > 0 and CastPoses.depthMin <= 1).toBe(true)
			local flag = (Flags :: any).cast_poses_enabled
			expect(flag ~= nil and flag.replicate == true).toBe(true)
		end)
	end)
end
