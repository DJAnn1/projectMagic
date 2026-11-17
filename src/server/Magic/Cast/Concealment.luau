--!strict
--[[
	Concealment: is someone hidden from whoever is looking for them? One rule for everything that picks
	a target: Wildborn (Services/WildbornService), creatures (Services/CreatureService) and NPCs who fight
	(NPC/NPCCombat).

		hidden(model, humanoid)               veiled (the status) or Unseen (Void, attribute `Unseen`)
		hiddenFrom(model, humanoid, from, blind?)   hidden, or the looker is blind, and further away than
		                                            seenThrough: close enough, a veil doesn't save you
]]

local StatusEffects = require(script.Parent.StatusEffects)

local Concealment = {}

Concealment.seenThrough = 12 -- studs: closer than this, a veil (or a blind looker) doesn't hide you
Concealment.screenReach = 4 -- studs: behind a False Wall you're only seen from closer than this

-- Set by Services/ArtService: is there an illusion (Mind's False Wall) between these two points?
Concealment.screened = nil :: ((Vector3, Vector3) -> boolean)?

function Concealment.hidden(model: Model, humanoid: Humanoid?): boolean
	local h = humanoid or model:FindFirstChildOfClass("Humanoid")
	if h and StatusEffects.has(h, "veiled") then
		return true
	end
	local unseen = model:GetAttribute("Unseen")
	return typeof(unseen) == "number" and unseen > workspace:GetServerTimeNow()
end

function Concealment.hiddenFrom(model: Model, humanoid: Humanoid?, from: Vector3, blind: boolean?): boolean
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local d = Vector3.new(root.Position.X - from.X, 0, root.Position.Z - from.Z).Magnitude
	-- Behind a False Wall: the looker sees a wall, not you.
	local screened = Concealment.screened
	if screened and d > Concealment.screenReach and screened(from + Vector3.new(0, 1.5, 0), root.Position) then
		return true
	end
	if not blind and not Concealment.hidden(model, humanoid) then
		return false
	end
	return d > Concealment.seenThrough
end

return Concealment
