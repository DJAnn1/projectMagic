--!strict
--[[
	PromptRouter: one place every server ProximityPrompt's action is registered, so a click can
	use it without going through Roblox's prompt input (InteractClickController).

		PromptRouter.connect(prompt, fn)   fn(player) -> (ok?, reason?, text?) runs on a validated
		                                   UsePrompt intent, and ONLY then (never prompt.Triggered:
		                                   see connect). Use this instead of prompt.Triggered.
		                                   Returning nothing counts as success; return false and a
		                                   reason code (and optionally a sentence) to refuse.
		PromptRouter.onIntent(player, prompt, phase, seq)   the UsePrompt handler (InteractionService)
		PromptRouter.setLog(log)           InteractionService hands over its logger

	WHY  Clicks first called prompt:InputHoldBegin() on the client: it fired late or not at all.
	     Then the intent was checked here but refused SILENTLY, while the client had already
	     started its hold bar and ignored further clicks on the same thing until it filled: so a
	     refused click looked like "nothing happened, then it worked on the third click". Now every
	     intent gets exactly one final answer.

	UsePrompt(prompt, "begin" | "end", seq)
		begin  checked now (in order, first failure answers):
		         INVALID      not a registered prompt, or no longer in the workspace
		         NOT_READY    in the workspace but its service hasn't registered it yet (the client
		                      retries once)
		         DISABLED     prompt.Enabled is false (an asleep NPC, a used-up heart)
		         DEAD         no living character
		         RATE_LIMITED a begin less than COOLDOWN after the last one (the first after a gap
		                      always passes)
		         TOO_FAR      nearest surface of the thing > MaxActivationDistance + Reach.SLACK
		         NO_SIGHT     RequiresLineOfSight and something solid stands between head and thing
		       HoldDuration 0 -> runs at once. Otherwise "accepted, pending" is answered at once and
		       the hold is timed HERE: after HoldDuration, still held and still in reach -> runs.
		       A client can't shorten a hold.
		end    lets go (a hold not yet finished is dropped; the client already knows).
	One hold per player at a time; a new begin replaces it.

	UsePromptResult { seq, ok, reason?, text?, pending?, hold? }  (server -> that client)
		pending = true: a hold was accepted and is running; a final answer with the same seq follows.
		The handler's own refusals come through too (LOCKED, IN_USE, DENIED, ...).

	SIGHT  A ray from the head to the thing's centre, past (at most 6 times): other characters and
	       NPC rigs, parts that are both non-collidable and mostly see-through, anything tagged
	       NoInteract. Hitting the thing, or any part of the same model, counts as seeing it (so a
	       tavern barrel behind its own bar counter still opens, as before).

	LOG  `use_prompt` for every decision: Info for a player with the InteractDebug attribute
	     (admin `interactdebug`), Debug otherwise.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Reach = require(Shared.World.Reach)

local COOLDOWN = 0.15 -- seconds between two begins by one player
local SIGHT_PASSES = 6

local PromptRouter = {}

type Handler = (Player) -> (boolean?, string?, string?)
type Hold = { prompt: ProximityPrompt, seq: number }

local handlers: { [ProximityPrompt]: Handler } = setmetatable({}, { __mode = "k" }) :: any
local holds: { [Player]: Hold } = {}
local lastBegin: { [Player]: number } = {}
local log: any = nil

function PromptRouter.setLog(logger: any)
	log = logger
end

local function report(player: Player, prompt: ProximityPrompt, seq: number, phase: string, ok: boolean, reason: string?)
	if not log then
		return
	end
	local fields = {
		player = player.Name,
		prompt = prompt:GetFullName(),
		action = prompt.ActionText,
		phase = phase,
		seq = seq,
		ok = ok,
		reason = reason,
	}
	if player:GetAttribute("InteractDebug") == true then
		log:info("use_prompt", fields)
	else
		log:debug("use_prompt", fields)
	end
end

local function reply(player: Player, prompt: ProximityPrompt, seq: number, phase: string, ok: boolean, reason: string?, text: string?, hold: number?)
	report(player, prompt, seq, phase, ok, reason)
	if player.Parent then
		Net.fire("UsePromptResult", player, { seq = seq, ok = ok, reason = reason, text = text, pending = hold ~= nil, hold = hold })
	end
end

-- Runs a prompt's action. Returns (ok, reason?, text?).
local function run(player: Player, prompt: ProximityPrompt): (boolean, string?, string?)
	local fn = handlers[prompt]
	if not fn then
		return false, "NOT_READY", nil
	end
	local called, ok, reason, text = pcall(fn, player)
	if not called then
		if log then
			log:error("use_prompt_failed", { prompt = prompt:GetFullName(), err = tostring(ok) })
		end
		return false, "ERROR", nil
	end
	if ok == false then
		return false, reason or "REFUSED", text
	end
	return true, nil, nil
end

function PromptRouter.connect(prompt: ProximityPrompt, fn: Handler)
	handlers[prompt] = fn
	-- No prompt.Triggered path: Roblox's own prompt input is off on every client
	-- (InteractClickController), and when it was on it claimed every mouse button and used the
	-- nearest prompt with none of the checks below (2026-11-12: right click and stray clicks
	-- opened barrels). UsePrompt is the only way in.
	prompt.Destroying:Connect(function()
		handlers[prompt] = nil
	end)
end

-- Does this part stop the line of sight? People, see-through ghosts and NoInteract parts don't.
local function blocksSight(part: BasePart): boolean
	if CollectionService:HasTag(part, "NoInteract") then
		return false
	end
	if not part.CanCollide and part.Transparency >= 0.5 then
		return false
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return false -- another character or an NPC walking past
	end
	return true
end

local function canSee(character: Model, holder: Instance, point: Vector3): boolean
	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	local fromPart = if head and head:IsA("BasePart") then head elseif root and root:IsA("BasePart") then root else nil
	if not fromPart then
		return false
	end
	local from = fromPart.Position
	local owner = holder:FindFirstAncestorOfClass("Model") or (if holder:IsA("Model") then holder else nil)
	local exclude: { Instance } = { character }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	for _ = 1, SIGHT_PASSES do
		params.FilterDescendantsInstances = exclude
		local hit = workspace:Raycast(from, point - from, params)
		if not hit then
			return true
		end
		local part = hit.Instance
		if part == holder or part:IsDescendantOf(holder) or (owner ~= nil and part:IsDescendantOf(owner)) then
			return true
		end
		if blocksSight(part) then
			return false
		end
		table.insert(exclude, part)
	end
	return false
end

-- Can this player use this prompt right now? (ok, reason?)
local function check(player: Player, prompt: ProximityPrompt): (boolean, string?)
	if not prompt:IsDescendantOf(workspace) then
		return false, "INVALID"
	end
	if not handlers[prompt] then
		-- A prompt in the world that nobody registered: a service still setting up (NOT_READY),
		-- or one that never goes through the router (an NPC's Talk prompt: INVALID).
		return false, if prompt.Name == "Interact" or prompt:GetAttribute("Routed") then "NOT_READY" else "INVALID"
	end
	if not prompt.Enabled then
		return false, "DISABLED"
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return false, "DEAD"
	end
	local point, holder = Reach.holderOf(prompt)
	if not point or not holder then
		return false, "INVALID"
	end
	if Reach.toPrompt(prompt, root.Position) > prompt.MaxActivationDistance + Reach.SLACK then
		return false, "TOO_FAR"
	end
	if prompt.RequiresLineOfSight and not canSee(character, holder, point) then
		return false, "NO_SIGHT"
	end
	return true, nil
end

function PromptRouter.onIntent(player: Player, prompt: ProximityPrompt, phase: string, seq: number)
	if phase == "end" then
		local held = holds[player]
		if held and held.seq == seq then
			holds[player] = nil
			report(player, prompt, seq, phase, true, "LET_GO")
		end
		return
	end
	local now = os.clock()
	local last = lastBegin[player]
	if last and now - last < COOLDOWN then
		reply(player, prompt, seq, phase, false, "RATE_LIMITED")
		return
	end
	lastBegin[player] = now
	local usable, why = check(player, prompt)
	if not usable then
		reply(player, prompt, seq, phase, false, why)
		return
	end
	if prompt.HoldDuration <= 0 then
		holds[player] = nil
		local ok, reason, text = run(player, prompt)
		reply(player, prompt, seq, phase, ok, reason, text)
		return
	end
	local hold: Hold = { prompt = prompt, seq = seq }
	holds[player] = hold
	reply(player, prompt, seq, phase, true, nil, nil, prompt.HoldDuration)
	task.delay(prompt.HoldDuration, function()
		if holds[player] ~= hold then
			return -- let go, or started another: the client has moved on
		end
		holds[player] = nil
		local stillOk, stillWhy = check(player, prompt)
		if not stillOk then
			reply(player, prompt, seq, "finish", false, stillWhy)
			return
		end
		local ok, reason, text = run(player, prompt)
		reply(player, prompt, seq, "finish", ok, reason, text)
	end)
end

-- Admin and debug: the hold a player has running, if any.
function PromptRouter.holdOf(player: Player): (ProximityPrompt?, number?)
	local held = holds[player]
	if held then
		return held.prompt, held.seq
	end
	return nil, nil
end

Players.PlayerRemoving:Connect(function(player)
	holds[player] = nil
	lastBegin[player] = nil
end)

return PromptRouter
