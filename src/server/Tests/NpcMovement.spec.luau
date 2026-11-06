--!strict
--[[
	NpcMovement.spec: the pure rules of NavigationService, NPCAnimator and NPCConversation, and the
	door setup (docs/NPCMovement.md). Real paths need a Play: the owner's test plan covers them.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Navigation = require(Server.NPC.NavigationService)
local NPCAnimator = require(Server.NPC.NPCAnimator)
local Conversation = require(Server.NPC.NPCConversation)
local Doors = require(Server.Interact.Doors)

return function(t: any)
	t.describe("NPC navigation", function()
		t.it("sizes an agent from the body, and always fits a doorway", function()
			t.expect(Navigation.agentRadius(2)).toBe(1.25) -- an R6 torso
			t.expect(Navigation.agentRadius(1.6)).toBe(1.25) -- a child
			t.expect(Navigation.agentRadius(1)).toBe(0.75)
			t.expect(Navigation.agentRadius(20)).toBe(Navigation.T.agentMaxRadius) -- doorways are 3.5-4 wide
			t.expect(Navigation.T.agentMaxRadius * 2 < 3.5).toBe(true)
		end)

		t.it("rejects an absurdly long path, not a reasonable detour", function()
			t.expect(Navigation.pathAcceptable(60, 40)).toBe(true)
			t.expect(Navigation.pathAcceptable(100, 2)).toBe(false)
			t.expect(Navigation.pathAcceptable(2000, 100)).toBe(false)
		end)

		t.it("escalates in order, and the teleport is last", function()
			t.expect(Navigation.escalation(1)).toBe("jump")
			t.expect(Navigation.escalation(2)).toBe("repath")
			t.expect(Navigation.escalation(3)).toBe("alternate")
			t.expect(Navigation.escalation(4)).toBe("lastResort")
			t.expect(Navigation.escalation(9)).toBe("lastResort")
		end)

		t.it("tries the goal first, then spots around it, closer ones sooner", function()
			t.expect(Navigation.ringOffset(1)).toBe(Vector3.zero)
			local near = Navigation.ringOffset(2).Magnitude
			local far = Navigation.ringOffset(6).Magnitude
			t.expect(near > 0 and near < far).toBe(true)
			t.expect((Navigation.ringOffset(2) - Navigation.ringOffset(3)).Magnitude > 1).toBe(true)
		end)

		t.it("gives each person their own pace, in the right order of styles", function()
			t.expect(Navigation.speedFor("hurry", 50) > Navigation.speedFor("walk", 50)).toBe(true)
			t.expect(Navigation.speedFor("walk", 50) > Navigation.speedFor("stroll", 50)).toBe(true)
			t.expect(Navigation.speedFor("walk", 3) ~= Navigation.speedFor("walk", 90)).toBe(true)
			t.expect(Navigation.speedFor("no such style", 0) > 0).toBe(true)
		end)

		t.it("doesn't send anyone back to a place they just failed to reach", function()
			local npc: any = { navFails = { { p = Vector3.new(10, 0, 10), untilAt = os.clock() + 60 } } }
			t.expect(Navigation.RecentlyFailed(npc, Vector3.new(11, 0, 10))).toBe(true)
			t.expect(Navigation.RecentlyFailed(npc, Vector3.new(90, 0, 10))).toBe(false)
			npc.navFails[1].untilAt = os.clock() - 1
			t.expect(Navigation.RecentlyFailed(npc, Vector3.new(11, 0, 10))).toBe(false)
			t.expect(Navigation.RecentlyFailed({} :: any, Vector3.zero)).toBe(false)
		end)

		t.it("lets paths cross a door, by a modifier on its leaf", function()
			local leaf = Instance.new("Part")
			leaf:SetAttribute("ClosedCFrame", CFrame.new(50000, 0, 50000))
			Doors.register(leaf)
			local modifier = leaf:FindFirstChildOfClass("PathfindingModifier")
			t.expect(modifier ~= nil).toBe(true)
			t.expect((modifier :: PathfindingModifier).PassThrough).toBe(true)
			Doors.unregister(leaf)
			leaf:Destroy()
		end)
	end)

	t.describe("NPC animation", function()
		t.it("walks from real speed, with hysteresis so it can't flicker", function()
			t.expect(NPCAnimator.nextMoving(false, 0)).toBe(false)
			t.expect(NPCAnimator.nextMoving(false, 1)).toBe(false)
			t.expect(NPCAnimator.nextMoving(false, 3)).toBe(true)
			t.expect(NPCAnimator.nextMoving(true, 1)).toBe(true) -- between the two: stays as it was
			t.expect(NPCAnimator.nextMoving(true, 0.2)).toBe(false)
		end)

		t.it("scales the walk cycle with real speed, within limits", function()
			t.expect(NPCAnimator.clipSpeed(13)).toBe(1)
			t.expect(NPCAnimator.clipSpeed(7) < NPCAnimator.clipSpeed(13)).toBe(true)
			t.expect(NPCAnimator.clipSpeed(0)).toBe(0.5)
			t.expect(NPCAnimator.clipSpeed(100)).toBe(1.5)
		end)

		t.it("times speech by the length of the words", function()
			t.expect(Conversation.speechSeconds("Hi.")).toBe(1)
			t.expect(Conversation.speechSeconds(string.rep("x", 54))).toBe(3)
			t.expect(Conversation.speechSeconds(string.rep("x", 900))).toBe(6)
		end)
	end)
end
