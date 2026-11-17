--!strict
--[[
	ScreenFx: what a spell does to your screen and your sky (docs/Smoothness.md stage 4; numbers in
	Shared/Magic/Data/ScreenFx). Client-only and cosmetic.

		ScreenFx.release(power, color, position, own, kick?)
			a spell landed: your own flash by power (and a camera kick unless `kick` is false);
			someone else's only when strong and near, weaker
		ScreenFx.kick(power)                           your own release's recoil
		ScreenFx.ultimate(color, position)             an ultimate's reveal: the full flash and the dip
		ScreenFx.sky(domain, position, holdSeconds)    an ultimate's sky round it, faded by distance

	Two ColorCorrectionEffects of its own in Lighting ("SpellFlash", "SpellSky"), so it never fights
	the weather, the day cycle or other effects; they stack with them. One RenderStepped loop runs
	while anything is showing. The kick turns the camera after the camera scripts have placed it
	(BindToRenderStep, Camera + 2), so it never accumulates. Reduce spell effects or Reduce motion:
	no full flash (a faint tint), no dip, no kick, a weaker sky. At most one flash per `minGap`.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Data = require(Shared.Magic.Data.ScreenFx)

local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

local F, K, S = Data.flash, Data.kick, Data.sky

local ScreenFx = {}

type Flash = { t0: number, peak: number, color: Color3, tint: number, dip: boolean }
type SkyEntry = { look: Data.Sky, position: Vector3, t0: number, ends: number }

local flash: Flash? = nil
local lastFlash = -math.huge
local skies: { SkyEntry } = {}
local kickPeak = 0
local kickAt = -math.huge

local flashCC: ColorCorrectionEffect? = nil
local skyCC: ColorCorrectionEffect? = nil
local loop: RBXScriptConnection? = nil
local kickBound = false

local function enabled(): boolean
	return FeatureFlags.get("screen_fx_enabled") ~= false
end

local function gentle(): boolean
	return Theme.settings.reducedEffects == true or Theme.settings.reducedMotion == true
end

local function effect(name: string): ColorCorrectionEffect
	local made = Instance.new("ColorCorrectionEffect")
	made.Name = name
	made.Enabled = false
	made.Parent = Lighting
	return made
end

local function eyeAt(): Vector3?
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

-- 0..1 brightness/tint envelope of a flash at `t` seconds, and the dip after (negative).
local function envelope(f: Flash, t: number): (number, number)
	if t < F.rise then
		return t / F.rise, 0
	elseif t < F.rise + F.fall then
		local k = 1 - (t - F.rise) / F.fall
		return k * k, 0
	elseif f.dip and t < F.rise + F.fall + F.dipSeconds then
		local k = 1 - (t - F.rise - F.fall) / F.dipSeconds
		return 0, k
	end
	return -1, 0 -- over
end

local function update()
	local now = os.clock()
	local busy = false

	-- Flash.
	local f = flash
	local fcc = flashCC
	if f then
		local bright, dip = envelope(f, now - f.t0)
		if bright < 0 then
			flash = nil
			if fcc then
				fcc.Enabled = false
			end
		else
			busy = true
			fcc = fcc or effect("SpellFlash")
			flashCC = fcc
			local c = fcc :: ColorCorrectionEffect
			c.Enabled = true
			c.Brightness = f.peak * bright + F.dip * dip
			c.TintColor = Color3.new(1, 1, 1):Lerp(f.color, f.tint * bright)
			c.Contrast = 0
			c.Saturation = 0
		end
	end

	-- Sky: the strongest ultimate in view.
	local eye = eyeAt()
	local best, bestLook = 0, nil :: Data.Sky?
	for i = #skies, 1, -1 do
		local s = skies[i]
		if now >= s.ends + S.fadeOut then
			table.remove(skies, i)
			continue
		end
		local time = if now < s.t0 + S.fadeIn then (now - s.t0) / S.fadeIn
			elseif now > s.ends then 1 - (now - s.ends) / S.fadeOut
			else 1
		local d = if eye then (eye - s.position).Magnitude else 0
		local near = 1 - math.clamp((d - S.full) / math.max(1, S.range - S.full), 0, 1)
		local k = math.clamp(time, 0, 1) * near * (if gentle() then S.reducedMult else 1)
		if k > best then
			best, bestLook = k, s.look
		end
	end
	local scc = skyCC
	if bestLook and best > 0.005 then
		busy = true
		scc = scc or effect("SpellSky")
		skyCC = scc
		local c = scc :: ColorCorrectionEffect
		c.Enabled = true
		c.TintColor = Color3.new(1, 1, 1):Lerp(bestLook.tint, best)
		c.Brightness = bestLook.brightness * best
		c.Saturation = bestLook.saturation * best
		c.Contrast = bestLook.contrast * best
	elseif scc then
		scc.Enabled = false
	end
	if #skies > 0 then
		busy = true
	end

	if not busy then
		local l = loop
		if l then
			l:Disconnect()
			loop = nil
		end
	end
end

local function ensureLoop()
	if not loop then
		loop = RunService.RenderStepped:Connect(update)
	end
end

local function startFlash(peak: number, color: Color3, tint: number, dip: boolean)
	local now = os.clock()
	if now - lastFlash < F.minGap then
		return
	end
	lastFlash = now
	flash = { t0 = now, peak = math.min(peak, F.maxBrightness), color = color, tint = tint, dip = dip }
	ensureLoop()
end

-- ─── Public ─────────────────────────────────────────────────────────────────

function ScreenFx.kick(power: number)
	if not K.enabled or not enabled() or gentle() then
		return
	end
	kickPeak = math.min(K.maxDegrees, power * K.degreesPerPower)
	kickAt = os.clock()
	if not kickBound then
		kickBound = true
		RunService:BindToRenderStep("SpellKick", Enum.RenderPriority.Camera.Value + 2, function()
			local t = (os.clock() - kickAt) / K.settle
			local camera = workspace.CurrentCamera
			if t >= 1 or not camera then
				return
			end
			local k = (1 - t) ^ 2
			camera.CFrame *= CFrame.Angles(math.rad(kickPeak * k), 0, 0)
		end)
	end
end

function ScreenFx.release(power: number, color: Color3, position: Vector3, own: boolean, kick: boolean?)
	if not enabled() then
		return
	end
	local strength: number
	if own then
		if power < F.ownFrom then
			return
		end
		strength = 1
		if kick ~= false then
			ScreenFx.kick(power)
		end
	else
		local eye = eyeAt()
		if power < F.othersFrom or not eye or (eye - position).Magnitude > F.othersRange then
			return
		end
		strength = F.othersMult * (1 - (eye - position).Magnitude / F.othersRange)
	end
	local peak = (power - F.ownFrom + 1) * F.brightnessPerPower * strength
	if gentle() then
		startFlash(peak * F.reducedMult, color, F.tint * F.reducedMult, false)
	else
		startFlash(peak, color, F.tint * strength, own and power >= F.dipFrom)
	end
end

function ScreenFx.ultimate(color: Color3, position: Vector3)
	if not enabled() then
		return
	end
	local eye = eyeAt()
	local d = if eye then (eye - position).Magnitude else 0
	local near = 1 - math.clamp((d - S.full) / math.max(1, S.range - S.full), 0, 1)
	if near <= 0 then
		return
	end
	if gentle() then
		startFlash(F.maxBrightness * F.reducedMult * near, color, F.tint * F.reducedMult, false)
	else
		startFlash(F.maxBrightness * near, color, F.tint * near, true)
	end
end

function ScreenFx.sky(domain: string, position: Vector3, holdSeconds: number)
	if not enabled() then
		return
	end
	local look = S.byDomain[domain]
	if not look then
		return
	end
	local now = os.clock()
	table.insert(skies, { look = look, position = position, t0 = now, ends = now + math.max(0.5, holdSeconds) })
	ensureLoop()
end

return ScreenFx
