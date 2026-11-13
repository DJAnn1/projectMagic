--!strict
--[[
	StatusLookController: shows statuses ON BODIES, for everyone nearby (docs/SpellOverhaul.md §2C,
	stage 2). The server tags a Humanoid "MagicStatused" while it carries any status and sets the
	replicated attribute "Status_<id>" per status (Cast/StatusEffects); this only draws what it's
	told, through Fx/StatusFx with the looks in Shared/Magic/Data/StatusLooks.

	DRAWING   Bodies within DRAW_WITHIN studs of the camera, nearest first, at most MAX_BODIES; a
	          body past DROP_BEYOND loses its drawing. Checked four times a second; a status
	          appearing or ending on a tracked body is picked up at once (attribute signal).
	OFF       The flag property_looks_enabled (replicated) turns all of it off.
	REDUCED   The Reduce effects setting thins the particles; the frozen shell stays (it tells you
	          something).

	No remotes, no UI: what's on someone is part of how they look.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local FeatureFlags = require(Shared.Core.FeatureFlags)
local StatusLooks = require(Shared.Magic.Data.StatusLooks)

local Fx = script.Parent.Parent:WaitForChild("Fx")
local StatusFx = require(Fx:WaitForChild("StatusFx"))
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

local TAG = "MagicStatused" -- Cast/StatusEffects.TAG
local DRAW_WITHIN = 140
local DROP_BEYOND = 170
local MAX_BODIES = 40

local StatusLookController = {
	name = "StatusLookController",
	dependencies = {},
}

type Tracked = {
	humanoid: Humanoid,
	drawn: { [string]: StatusFx.Handle },
	near: boolean,
	changed: RBXScriptConnection?,
}

local tracked: { [Humanoid]: Tracked } = {}

local function enabled(): boolean
	return FeatureFlags.get("property_looks_enabled") ~= false
end

local function clear(t: Tracked)
	for id, handle in t.drawn do
		StatusFx.undraw(handle)
		t.drawn[id] = nil
	end
end

-- Bring the drawing in line with the body's current statuses.
local function refresh(t: Tracked)
	local humanoid = t.humanoid
	local model = humanoid.Parent
	if not t.near or not enabled() or not model or not model:IsA("Model") or humanoid.Health <= 0 then
		clear(t)
		return
	end
	local reduced = Theme.settings.reducedEffects == true
	for id in StatusLooks.looks do
		local on = humanoid:GetAttribute("Status_" .. id) ~= nil
		local handle = t.drawn[id]
		if on and not handle then
			local made = StatusFx.draw(model, id, reduced)
			if made then
				t.drawn[id] = made
			end
		elseif not on and handle then
			StatusFx.undraw(handle)
			t.drawn[id] = nil
		end
	end
end

local function track(instance: Instance)
	if not instance:IsA("Humanoid") or tracked[instance] then
		return
	end
	local t: Tracked = { humanoid = instance, drawn = {}, near = false }
	tracked[instance] = t
	t.changed = instance.AttributeChanged:Connect(function(name)
		if string.sub(name, 1, 7) == "Status_" and StatusLooks.looks[string.sub(name, 8)] then
			refresh(t)
		end
	end)
end

local function untrack(instance: Instance)
	local t = tracked[instance :: Humanoid]
	if not t then
		return
	end
	tracked[instance :: Humanoid] = nil
	if t.changed then
		t.changed:Disconnect()
	end
	clear(t)
end

local function rootOf(humanoid: Humanoid): BasePart?
	local model = humanoid.Parent
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Who is close enough to draw: nearest first, capped.
local function cull()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local candidates: { { t: Tracked, d: number } } = {}
	for humanoid, t in tracked do
		local root = rootOf(humanoid)
		if not humanoid.Parent or not root then
			t.near = false
			refresh(t)
			continue
		end
		local d = (root.Position - eye).Magnitude
		if d <= (if t.near then DROP_BEYOND else DRAW_WITHIN) then
			table.insert(candidates, { t = t, d = d })
		elseif t.near then
			t.near = false
			refresh(t)
		end
	end
	table.sort(candidates, function(a, b)
		return a.d < b.d
	end)
	for i, c in candidates do
		local near = i <= MAX_BODIES
		if near ~= c.t.near then
			c.t.near = near
			refresh(c.t)
		end
	end
end

function StatusLookController.init(_self: any, _ctx: any) end

function StatusLookController.start(_self: any, _ctx: any)
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
	for _, instance in CollectionService:GetTagged(TAG) do
		track(instance)
	end
	task.spawn(function()
		while true do
			task.wait(0.25)
			local ok = pcall(cull)
			if not ok then
				task.wait(2)
			end
		end
	end)
end

return StatusLookController
