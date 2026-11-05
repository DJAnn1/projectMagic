--!strict
--[[
	Controls.spec: Shared/UI/Controls is the one list of every binding (the Controls screen and the
	main controllers read it), so it has to be right:
	- ids are unique, and every action names a known group and known contexts;
	- every key name is a real KeyCode, a mouse input or a stick;
	- no two actions share a key on the same device in contexts that can be live at once, unless
	  each lists the other in `shares` (a deliberate, explained overlap).
	The last rule would have caught the gamepad clash it was written for: L1 raised the guard AND
	cycled the quickbar, L2 readied a spell AND drank the selected potion.
]]

local Controls = require(game:GetService("ReplicatedStorage").Shared.UI.Controls)

return function(t: any)
	t.describe("Controls", function()
		t.it("has unique ids, known groups and known contexts", function()
			local groups: { [string]: boolean } = {}
			for _, g in Controls.groups do
				groups[g.id] = true
			end
			local seen: { [string]: boolean } = {}
			for _, action in Controls.list do
				t.expect(seen[action.id]).toBe(nil)
				seen[action.id] = true
				t.expect(groups[action.group]).toBe(true)
				t.expect(#action.contexts > 0).toBe(true)
				for _, context in action.contexts do
					t.expect(Controls.contexts[context] ~= nil).toBe(true)
				end
			end
		end)

		t.it("names only real keys, mouse inputs and sticks", function()
			for _, action in Controls.list do
				for _, names in { action.keyboard or {}, action.gamepad or {} } :: { { string } } do
					for _, name in names do
						if not Controls.isKnownName(name) then
							error(string.format("%s: unknown key %q", action.id, name))
						end
					end
				end
			end
		end)

		t.it("never binds one key to two live actions on the same device", function()
			local list = Controls.list
			for i = 1, #list do
				for j = i + 1, #list do
					local a, b = list[i], list[j]
					local shared = (a.shares and table.find(a.shares, b.id)) or (b.shares and table.find(b.shares, a.id))
					if shared then
						continue
					end
					local overlap = false
					for _, ca in a.contexts do
						for _, cb in b.contexts do
							if Controls.contextsOverlap(ca, cb) then
								overlap = true
							end
						end
					end
					if not overlap then
						continue
					end
					for _, device in { "keyboard", "gamepad" } do
						local ka = (if device == "gamepad" then a.gamepad else a.keyboard) or {}
						local kb = (if device == "gamepad" then b.gamepad else b.keyboard) or {}
						for _, name in ka do
							if table.find(kb, name) then
								error(string.format("%s and %s both use %s (%s)", a.id, b.id, name, device))
							end
						end
					end
				end
			end
		end)

		t.it("shares are mutual and point at real actions", function()
			for _, action in Controls.list do
				for _, other in (action.shares or {}) :: { string } do
					local def = Controls.byId[other]
					t.expect(def ~= nil).toBe(true)
					t.expect(def.shares ~= nil and table.find(def.shares, action.id) ~= nil).toBe(true)
				end
			end
		end)

		t.it("gives controllers the keys they read", function()
			t.expect(#Controls.keys("hotbar", "keyboard")).toBe(8)
			t.expect(#Controls.keys("quick_items", "keyboard")).toBe(4)
			t.expect(Controls.key("quick_items", "gamepad")).toBe(Enum.KeyCode.DPadDown)
			t.expect(Controls.key("open_controls", "keyboard")).toBe(Enum.KeyCode.H)
			t.expect(Controls.key("cast", "keyboard")).toBe(nil) -- mouse only: use Controls.matches
			t.expect(Controls.display("MouseButton1")).toBe("Left mouse")
		end)
	end)
end
