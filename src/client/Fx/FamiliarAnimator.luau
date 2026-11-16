--!strict
--[[
	FamiliarAnimator: makes familiars and loose spells move (docs/Familiars.md, docs/FeralSpells.md). Cosmetic, and local to
	this client: it writes each part's Weld.C0 here only, so none of it uses the network.

	FamiliarRig tags a part with the Anim attributes, from Data/Familiars:
		wag     swings side to side around the body's centre (tails, a serpent's segments)
		flap    tilts up and down around the body's centre (wings)
		bob     moves up and down (legs, ears, whiskers)
		orbit   circles the body (sparks, motes)
		blink   an eye closes for a moment every few seconds
		tumble  turns over and drifts around where it is (a loose spell's pieces)
		swirl   circles the centre, and the circle breathes in and out
		flicker drifts, and winks out for a moment now and then

	A model's Unstable attribute (0..1) makes all of it faster, wider and less steady: a loose spell shakes
	itself apart as its energy runs out.

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
local FOLDERS = { "Familiars", "FeralSpells", "Creatures" } -- creatures: game animals wag and bob (docs/Hunting.md)

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

-- Wanders around a spot: three waves at unrelated rates, so it never quite repeats.
local function wander(entry: Entry, t: number, amount: number): Vector3
	local p = entry.phase
	return Vector3.new(math.sin(t * entry.speed + p), math.sin(t * entry.speed * 1.37 + p * 2.1), math.cos(t * entry.speed * 0.73 + p * 3.3)) * amount
end

local function pose(entry: Entry, t: number, unstable: number)
	local rate = 1 + unstable * 2.5
	local wild = 1 + unstable * 1.5
	local wave = math.sin(t * entry.speed + entry.phase)
	local kind = entry.kind
	if kind == "tumble" then
		local turn = t * entry.speed * rate + entry.phase
		entry.weld.C0 = (entry.base + wander(entry, t * rate, entry.amount * wild)) * CFrame.Angles(turn, turn * 0.7, turn * 0.4)
		return
	elseif kind == "swirl" then
		local radius = 1 + math.sin(t * entry.speed * 0.6 + entry.phase) * 0.3 * wild
		entry.weld.C0 = CFrame.Angles(0, t * entry.speed * rate + entry.phase, math.sin(t * 0.5 + entry.phase) * 0.5) * (CFrame.new(entry.base.Position * radius) * entry.base.Rotation)
		return
	elseif kind == "flicker" then
		entry.weld.C0 = entry.base + wander(entry, t * rate, entry.amount * wild)
		-- Shut for a little of each cycle, and more of it as it fails.
		local cycle = (t * (0.6 + entry.speed * 0.2) + entry.phase) % 1
		entry.part.LocalTransparencyModifier = if cycle < 0.08 + unstable * 0.35 then 1 else 0
		return
	end
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
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local t = workspace:GetServerTimeNow() % 3600
		local eye = camera.CFrame.Position
		for _, name in FOLDERS do
			local folder = workspace:FindFirstChild(name)
			if folder then
				for _, model in folder:GetChildren() do
					if model:IsA("Model") and model.PrimaryPart and (model.PrimaryPart.Position - eye).Magnitude <= RANGE then
						local unstable = (model:GetAttribute("Unstable") :: number?) or 0
						for _, entry in entriesOf(model) do
							pose(entry, t, unstable)
						end
					end
				end
			end
		end
	end)
end

return FamiliarAnimator
