--!strict
--[[
	NavQueue.spec: the NPC path queue (NPC/NavigationService). It once jammed itself: people re-asking added
	new jobs at the back, the old ones went stale but still took turns, and nearly nobody got a path.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Navigation = require(ServerScriptService.Server.NPC.NavigationService)

local function job(nav: any, id: number): any
	return { nav = nav, id = id }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("The path queue", function()
		it("keeps one place per person, however many times they ask", function()
			local a, b = {}, {}
			local queue: { any } = {}
			Navigation.enqueue(queue, job(a, 1), 80)
			Navigation.enqueue(queue, job(b, 2), 80)
			Navigation.enqueue(queue, job(a, 3), 80)
			Navigation.enqueue(queue, job(a, 4), 80)
			expect(#queue).toBe(2)
		end)

		it("asking again keeps your place and updates your job", function()
			local a, b = {}, {}
			local queue: { any } = {}
			Navigation.enqueue(queue, job(a, 1), 80)
			Navigation.enqueue(queue, job(b, 2), 80)
			Navigation.enqueue(queue, job(a, 3), 80)
			expect(queue[1].nav).toBe(a)
			expect(queue[1].id).toBe(3)
		end)

		it("can't go stale by waiting: everyone re-asking still gets served in order", function()
			-- What used to jam: 40 people, each re-asking before their turn came round.
			local people: { any } = {}
			local latest: { [any]: number } = {}
			local queue: { any } = {}
			for i = 1, 40 do
				people[i] = {}
			end
			local id = 0
			local function askAll()
				for _, person in people do
					id += 1
					latest[person] = id
					Navigation.enqueue(queue, job(person, id), 80)
				end
			end
			askAll()
			local served = 0
			for round = 1, 40 do
				if round % 5 == 0 then
					askAll()
				end
				local next = Navigation.nextJob(queue, function(candidate: any): boolean
					return latest[candidate.nav] == candidate.id
				end)
				if next then
					served += 1
				end
			end
			expect(served >= 39).toBe(true)
		end)

		it("drops the oldest when it's truly full of different people", function()
			local a, b, c = {}, {}, {}
			local queue: { any } = {}
			Navigation.enqueue(queue, job(a, 1), 2)
			Navigation.enqueue(queue, job(b, 2), 2)
			Navigation.enqueue(queue, job(c, 3), 2)
			expect(#queue).toBe(2)
			expect(queue[1].nav).toBe(b)
		end)

		it("skips stale jobs without using up a turn", function()
			local a, b = {}, {}
			local queue: { any } = { job(a, 1), job(a, 2), job(b, 3) }
			local next = Navigation.nextJob(queue, function(candidate: any): boolean
				return candidate.id == 3
			end)
			expect(next ~= nil and next.id == 3).toBe(true)
			expect(#queue).toBe(0)
		end)

		it("has nothing to give from an empty queue", function()
			expect(Navigation.nextJob({}, function(_: any): boolean
				return true
			end)).toBe(nil)
		end)
	end)
end
