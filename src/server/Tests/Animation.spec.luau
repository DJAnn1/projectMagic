--!strict
-- Unit specs for combat animation data (Data/CombatAnimations), the shared rules
-- (Magic/ActionRules) and the server state machine (Cast/ActionState). docs/Combat.md §11.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Magic.Data.CombatAnimations)
local ActionRules = require(ReplicatedStorage.Shared.Magic.ActionRules)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local ActionState = require(ServerScriptService.Server.Magic.Cast.ActionState)

-- A body outside workspace (parented, so ActionState's expiry keeps it).
local function body(): Model
	local holder = Instance.new("Folder")
	local model = Instance.new("Model")
	model.Name = "SpecBody"
	model.Parent = holder
	return model
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Combat animation data", function()
		it("has a positive integer asset id and sane markers for every clip", function()
			for name, def in Data.animations do
				expect(def.id > 0 and def.id == math.floor(def.id)).toBe(true)
				expect((Enum.AnimationPriority :: any)[def.priority] ~= nil).toBe(true)
				expect(def.approxLength > 0).toBe(true)
				for _, marker in def.markers do
					if not (marker.at > 0 and marker.at <= 1) then
						error(name .. "/" .. marker.name .. ": marker fraction out of range")
					end
				end
			end
		end)
		it("only references clips and states that exist", function()
			for name, state in Data.states do
				if state.animation and not Data.animations[state.animation] then
					error(name .. ": unknown clip " .. state.animation)
				end
				if state.loop and not Data.animations[state.loop] then
					error(name .. ": unknown loop clip " .. state.loop)
				end
				if state.next and not Data.states[state.next] then
					error(name .. ": unknown next state " .. state.next)
				end
				for other in (state.interruptedBy or {}) :: { [string]: boolean } do
					if not Data.states[other] then
						error(name .. ": interruptedBy unknown state " .. other)
					end
				end
				for action in state.allows do
					expect(table.find(Data.actions, action) ~= nil).toBe(true)
				end
			end
			expect(Data.states.idle ~= nil).toBe(true)
		end)
		it("styles only real domains", function()
			for domain in Data.domains do
				expect(Registry.domains[domain] ~= nil).toBe(true)
			end
		end)
		it("reports clips that share an asset id", function()
			local found = false
			for _, pair in Data.duplicates do
				expect(Data.animations[pair.a].id).toBe(Data.animations[pair.b].id)
				if (pair.a == "Run" and pair.b == "Slash1") or (pair.a == "Slash1" and pair.b == "Run") then
					found = true
				end
			end
			-- Run and Slash1 were supplied with the same id; drop this once Run has its own.
			expect(found).toBe(Data.animations.Run.id == Data.animations.Slash1.id)
		end)
	end)

	describe("Action rules", function()
		it("lets anything replace idle but guards a dash", function()
			expect(ActionRules.canEnter("idle", "casting")).toBe(true)
			expect(ActionRules.canEnter("dashing", "casting")).toBe(false)
			expect(ActionRules.canEnter("dashing", "staggered")).toBe(true)
			expect(ActionRules.canEnter("idle", "nonsense")).toBe(false)
		end)
		it("blocks casting while staggered or dashing", function()
			expect(ActionRules.allows("idle", "cast")).toBe(true)
			expect(ActionRules.allows("staggered", "cast")).toBe(false)
			expect(ActionRules.allows("dashing", "move")).toBe(false)
		end)
		it("treats an expired timed state as its next", function()
			local snapshot: ActionRules.Snapshot = { state = "equipping", untilTime = 100, duration = 0.45, seq = 1 }
			expect(ActionRules.effective(snapshot, 99)).toBe("equipping")
			expect(ActionRules.effective(snapshot, 100)).toBe("holding")
			snapshot.state = "casting"
			expect(ActionRules.effective(snapshot, 101)).toBe("idle")
		end)
		it("fits a cast clip's Release marker to the cast time, within the clamp", function()
			local def = Data.animations.CastSpell
			local release = def.markers[1].at
			local speed = ActionRules.playbackSpeed("CastSpell", 2, 2 * release, nil)
			expect(speed).toBeNear(1, 1e-6)
			expect(ActionRules.playbackSpeed("CastSpell", 2, 0.01, nil)).toBe(Data.maxSpeed)
			expect(ActionRules.playbackSpeed("CastSpell", 2, 60, nil)).toBe(Data.minSpeed)
			-- No duration: the domain style sets the speed.
			expect(ActionRules.playbackSpeed("Hold", 1, nil, "air")).toBeNear(Data.domains.air.speed, 1e-6)
		end)
	end)

	describe("ActionState", function()
		it("sets, refuses an illegal change, and forces through", function()
			local model = body()
			expect(ActionState.set(model, "dashing", { duration = 5 })).toBe(true)
			expect(ActionState.get(model)).toBe("dashing")
			expect(ActionState.set(model, "casting")).toBe(false)
			expect((ActionState.can(model, "cast"))).toBe(false)
			expect(ActionState.set(model, "staggered", { force = true })).toBe(true)
			expect(ActionState.get(model)).toBe("staggered")
		end)
		it("counts every set so repeated states replay", function()
			local model = body()
			ActionState.set(model, "casting", { duration = 1 })
			local first = ActionRules.read(model).seq
			ActionState.set(model, "casting", { duration = 1 })
			expect(ActionRules.read(model).seq).toBe(first + 1)
		end)
		it("expires a timed state into its next", function()
			local model = body()
			ActionState.set(model, "equipping")
			ActionState.step(workspace:GetServerTimeNow() + 5)
			expect(ActionRules.read(model).state).toBe("holding")
			expect(ActionRules.read(model).untilTime).toBe(0)
		end)
		it("clears only the named state", function()
			local model = body()
			ActionState.set(model, "blocking")
			ActionState.clear(model, "casting")
			expect(ActionState.get(model)).toBe("blocking")
			ActionState.clear(model, "blocking")
			expect(ActionState.get(model)).toBe("idle")
		end)
		it("fires changed with the previous state", function()
			local model = body()
			local seen: { string } = {}
			local connection = ActionState.changed:Connect(function(m: Model, state: string, previous: string)
				if m == model then
					table.insert(seen, previous .. ">" .. state)
				end
			end)
			ActionState.set(model, "blocking")
			ActionState.set(model, "idle")
			connection:Disconnect() -- handlers start at once (task.spawn), so both have run
			expect(table.find(seen, "idle>blocking") ~= nil).toBe(true)
			expect(table.find(seen, "blocking>idle") ~= nil).toBe(true)
		end)
	end)
end
