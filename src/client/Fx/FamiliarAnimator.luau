--!strict
--[[
	FamiliarAnimator: makes familiars move like living things (docs/Familiars.md). Cosmetic, and local to
	this client: it writes each part's Weld.C0 here only, so none of it uses the network.

	FamiliarRig tags a part with the Anim attributes, from Data/Familiars:
		wag     swings side to side around the body's centre (tails, a serpent's segments)
		flap    tilts up and down around the body's centre (wings)
		bob     moves up and down (legs, ears, whiskers)
		orbit   circles the body (sparks, motes)
		blink   an eye closes for a moment every few seconds

	Budget: 30 updates a second, and only familiars within RANGE of the camera. Each model's parts are
	read once and cached. Under Reduced effects, it all stops.
]]

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local RANGE = 90
local STEP = 1 / 30
local BLINK_EVERY = 4.2
local BLINK_SECONDS = 0.13

type Entry = { part: BasePart, weld: Weld, base: CFrame, kind: string, amount: number, speed: number, phase: number }

local cache: { [Model]: { Entry } } = setmetatable({}, { __mode = "k" }) :: any
local started = false

local FamiliarAnimator = {}

local function entriesOf(model: Model): { Entry }
	local entries = cache[model]
	if entries then
		return entries
	end
	entries = {}
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part:GetAttribute("Anim") then
			local weld = part:FindFirstChild("Pose")
			if weld and weld:IsA("Weld") then
				table.insert(entries, {
					part = part,
					weld = weld,
					base = weld.C0,
					kind = part:GetAttribute("Anim") :: string,
					amount = (part:GetAttribute("AnimAmount") :: number?) or 0,
					speed = (part:GetAttribute("AnimSpeed") :: number?) or 1,
					phase = (part:GetAttribute("AnimPhase") :: number?) or 0,
				})
			end
		end
	end
	-- Atomic streaming sends the whole model at once, but a model seen mid-arrival has no parts yet:
	-- don't remember an empty list.
	if #entries > 0 then
		cache[model] = entries
	end
	return entries
end

local function pose(entry: Entry, t: number)
	local wave = math.sin(t * entry.speed + entry.phase)
	local kind = entry.kind
	if kind == "wag" then
		entry.weld.C0 = CFrame.Angles(0, wave * entry.amount, 0) * entry.base
	elseif kind == "flap" then
		-- Each wing tilts its own way, so the pair beats together.
		local side = if entry.base.Position.X < 0 then -1 else 1
		entry.weld.C0 = CFrame.Angles(0, 0, wave * entry.amount * side) * entry.base
	elseif kind == "bob" then
		entry.weld.C0 = entry.base + Vector3.new(0, wave * entry.amount, 0)
	elseif kind == "orbit" then
		entry.weld.C0 = CFrame.Angles(0, t * entry.speed + entry.phase, 0) * entry.base
	elseif kind == "blink" then
		local shut = (t + entry.phase) % BLINK_EVERY < BLINK_SECONDS
		entry.part.LocalTransparencyModifier = if shut then 1 else 0
	end
end

function FamiliarAnimator.start()
	if started then
		return
	end
	started = true
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < STEP then
			return
		end
		acc = 0
		if Theme.settings.reducedEffects == true then
			return
		end
		local folder = workspace:FindFirstChild("Familiars")
		local camera = workspace.CurrentCamera
		if not folder or not camera then
			return
		end
		local t = workspace:GetServerTimeNow() % 3600
		local eye = camera.CFrame.Position
		for _, model in folder:GetChildren() do
			if model:IsA("Model") and model.PrimaryPart and (model.PrimaryPart.Position - eye).Magnitude <= RANGE then
				for _, entry in entriesOf(model) do
					pose(entry, t)
				end
			end
		end
	end)
end

return FamiliarAnimator
