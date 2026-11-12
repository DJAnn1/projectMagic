--!strict
--[[
	PromptRouter: one place every server ProximityPrompt's action is registered, so a click can
	use it without going through Roblox's prompt input (InteractClickController).

		PromptRouter.connect(prompt, fn)   fn(player) runs on prompt.Triggered (a gamepad, or any
		                                   prompt input Roblox still delivers) AND on a validated
		                                   UsePrompt intent. Use this instead of prompt.Triggered.
		PromptRouter.onIntent(player, prompt, phase)   the UsePrompt handler (InteractionService)

	WHY  Clicks first called prompt:InputHoldBegin() on the client. In play that fired late or not
	     at all (several clicks did nothing, then a later click, even one on a menu's Close,
	     set off the earlier one). An intent the server checks itself has no such hidden state.

	UsePrompt(prompt, "begin" | "end")
		begin  checked now: the prompt is registered, enabled, in the workspace; the player is
		       alive and within MaxActivationDistance (+ SLACK) of it; with RequiresLineOfSight,
		       nothing else stands between their head and it. HoldDuration 0 -> runs at once.
		       Otherwise the hold is timed HERE: after HoldDuration, still held and still in
		       reach -> runs. A client can't shorten a hold.
		end    lets go (a hold not yet finished is dropped).
	One hold per player at a time; a new begin replaces it.
]]

local Players = game:GetService("Players")

local SLACK = 3 -- studs past MaxActivationDistance (latency, and the client measures to the part's surface)

local PromptRouter = {}

local handlers: { [ProximityPrompt]: (Player) -> () } = setmetatable({}, { __mode = "k" }) :: any
local holds: { [Player]: { prompt: ProximityPrompt, id: number } } = {}
local holdCounter = 0

function PromptRouter.connect(prompt: ProximityPrompt, fn: (Player) -> ())
	handlers[prompt] = fn
	prompt.Triggered:Connect(fn)
	prompt.Destroying:Connect(function()
		handlers[prompt] = nil
	end)
end

local function pointOf(prompt: ProximityPrompt): (Vector3?, Instance?)
	local holder = prompt.Parent
	if holder and holder:IsA("Attachment") then
		return holder.WorldPosition, holder.Parent
	elseif holder and holder:IsA("BasePart") then
		return holder.Position, holder
	elseif holder and holder:IsA("Model") then
		return holder:GetPivot().Position, holder
	end
	return nil, nil
end

-- Can this player use this prompt right now?
local function reachable(player: Player, prompt: ProximityPrompt): boolean
	if not handlers[prompt] or not prompt.Enabled or not prompt:IsDescendantOf(workspace) then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return false
	end
	local point, holder = pointOf(prompt)
	if not point or not holder then
		return false
	end
	-- Measure to the part's surface for big parts (a wide door, a Titan's ember).
	local reach = prompt.MaxActivationDistance + SLACK
	if holder:IsA("BasePart") then
		reach += math.min(holder.Size.Magnitude / 2, 6)
	end
	if (root.Position - point).Magnitude > reach then
		return false
	end
	if prompt.RequiresLineOfSight then
		local head = character:FindFirstChild("Head")
		local from = if head and head:IsA("BasePart") then head.Position else root.Position
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(from, point - from, params)
		if hit then
			local model = holder:FindFirstAncestorOfClass("Model")
			local ok = hit.Instance == holder or hit.Instance:IsDescendantOf(holder) or (model ~= nil and hit.Instance:IsDescendantOf(model))
			if not ok then
				return false
			end
		end
	end
	return true
end

local function run(player: Player, prompt: ProximityPrompt)
	local fn = handlers[prompt]
	if fn then
		fn(player)
	end
end

function PromptRouter.onIntent(player: Player, prompt: ProximityPrompt, phase: string)
	if phase == "end" then
		holds[player] = nil
		return
	end
	if not reachable(player, prompt) then
		return
	end
	if prompt.HoldDuration <= 0 then
		holds[player] = nil
		run(player, prompt)
		return
	end
	holdCounter += 1
	local hold = { prompt = prompt, id = holdCounter }
	holds[player] = hold
	task.delay(prompt.HoldDuration, function()
		if holds[player] ~= hold then
			return -- let go, or started another
		end
		holds[player] = nil
		if reachable(player, prompt) then
			run(player, prompt)
		end
	end)
end

Players.PlayerRemoving:Connect(function(player)
	holds[player] = nil
end)

return PromptRouter
