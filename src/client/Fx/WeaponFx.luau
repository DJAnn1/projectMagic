--!strict
--[[
	WeaponFx: arrows, bolts and thrown knives in flight (docs/Items.md §10). Purely visual: the
	server flies the real projectile (Cast/Delivery via Services/WeaponService) and sends
	"weapon" WorldEffect cues:
		launch  { projectileId, origin, velocity, gravity, lifetime, look }   simulate the same arc
		impact  { projectileId, point, struck, expired }                      snap there; an arrow
		                                                                      that hit a surface
		                                                                      sticks for a while
	One RenderStepped connection steps every flight; at most MAX_LIVE parts exist at once (the
	oldest is dropped first), so a volley can never flood the client.
]]

local RunService = game:GetService("RunService")

local Audio = require(script.Parent.Parent:WaitForChild("Audio").Audio)

local MAX_LIVE = 40
local STICK_SECONDS = 4

type Look = { size: Vector3, color: Color3, material: Enum.Material }

local LOOKS: { [string]: Look } = {
	arrow = { size = Vector3.new(0.12, 0.12, 2.6), color = Color3.fromRGB(170, 135, 90), material = Enum.Material.Wood },
	bolt = { size = Vector3.new(0.16, 0.16, 1.5), color = Color3.fromRGB(150, 150, 158), material = Enum.Material.Metal },
	knife = { size = Vector3.new(0.1, 0.3, 1.1), color = Color3.fromRGB(200, 200, 210), material = Enum.Material.Metal },
}

type Flight = {
	part: Part,
	origin: Vector3,
	velocity: Vector3,
	gravity: number,
	lifetime: number,
	age: number,
	spin: boolean,
	landed: boolean,
}

local WeaponFx = {}

local flights: { [number]: Flight } = {}
local order: { number } = {}
local folder: Folder? = nil
local stepper: RBXScriptConnection? = nil

local function container(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local created = Instance.new("Folder")
	created.Name = "WeaponFx"
	created.Parent = workspace
	folder = created
	return created
end

local function remove(id: number)
	local flight = flights[id]
	if flight then
		flight.part:Destroy()
		flights[id] = nil
	end
	local i = table.find(order, id)
	if i then
		table.remove(order, i)
	end
end

local function positionAt(f: Flight, t: number): Vector3
	return f.origin + f.velocity * t + Vector3.new(0, -0.5 * f.gravity * t * t, 0)
end

local function step(dt: number)
	for id, f in flights do
		if f.landed then
			continue
		end
		f.age += dt
		if f.age >= f.lifetime then
			remove(id)
			continue
		end
		local at = positionAt(f, f.age)
		local ahead = positionAt(f, f.age + 0.02)
		local cf = if (ahead - at).Magnitude > 0.001 then CFrame.lookAt(at, ahead) else CFrame.new(at)
		if f.spin then
			cf *= CFrame.Angles(f.age * 25, 0, 0) -- a thrown knife tumbles
		end
		f.part.CFrame = cf
	end
	if next(flights) == nil and stepper then
		stepper:Disconnect()
		stepper = nil
	end
end

local function ensureStepper()
	if not stepper then
		stepper = RunService.RenderStepped:Connect(step)
	end
end

function WeaponFx.cue(cue: any)
	local id = cue.projectileId
	if typeof(id) ~= "number" then
		return
	end
	if cue.stage == "launch" then
		if typeof(cue.origin) ~= "Vector3" or typeof(cue.velocity) ~= "Vector3" then
			return
		end
		remove(id)
		while #order >= MAX_LIVE do
			remove(order[1])
		end
		local look = LOOKS[cue.look] or LOOKS.arrow
		local part = Instance.new("Part")
		part.Name = "Projectile"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Size = look.size
		part.Color = look.color
		part.Material = look.material
		part.CFrame = CFrame.new(cue.origin)
		part.Parent = container()
		flights[id] = {
			part = part,
			origin = cue.origin,
			velocity = cue.velocity,
			gravity = if typeof(cue.gravity) == "number" then cue.gravity else 0,
			lifetime = math.clamp(if typeof(cue.lifetime) == "number" then cue.lifetime else 2, 0.1, 6),
			age = 0,
			spin = cue.look == "knife",
			landed = false,
		}
		table.insert(order, id)
		ensureStepper()
		-- The release: a bow or crossbow twang, a thrown knife's whoosh (Combat group).
		Audio.play(if cue.look == "knife" then "combat.slash" else "weapon.bowRelease", { position = cue.origin })
	elseif cue.stage == "impact" then
		local f = flights[id]
		if not f then
			return
		end
		if typeof(cue.point) == "Vector3" and not cue.expired then
			Audio.play("weapon.arrowHit", { position = cue.point })
		end
		if typeof(cue.point) == "Vector3" and not cue.struck and not cue.expired then
			-- Stuck in a wall or the ground: leave it there a moment, pointing the way it flew.
			f.landed = true
			local before = positionAt(f, math.max(0, f.age - 0.05))
			local dir = cue.point - before
			f.part.CFrame = if dir.Magnitude > 0.01 then CFrame.lookAt(cue.point - dir.Unit * f.part.Size.Z * 0.3, cue.point) else CFrame.new(cue.point)
			task.delay(STICK_SECONDS, function()
				if flights[id] == f then
					remove(id)
				end
			end)
		else
			remove(id)
		end
	end
end

return WeaponFx
