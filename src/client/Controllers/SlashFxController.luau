--!strict
--[[
	SlashFxController: draws a slash arc (Fx/SlashFx) whenever someone nearby swings. Purely
	cosmetic. It reads the server-written action state (Shared/Magic/ActionRules): every time a
	character's ActionStateSeq changes to a "slashing" state, the arc appears at the hit moment
	(HIT_AT of the swing's duration, matching MeleeTuning / WeaponTuning hitFrom ≈ 0.3).

	COLOUR   a spellblade (character attribute AttunedDomain, or the state's domain) uses the
	         caster's style (SpellFx.styleFor: domain palette tinted by the Signature) and glows;
	         a weapon swing with no spell is steel and only gleams.
	BUDGET   only characters within RANGE studs of the camera; SlashFx caps live arcs.
	LATENCY  your own arc follows the server's state, so it lands one round-trip after the
	         predicted animation (~50–150 ms). Fine for now; see docs/Combat.md §8.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ActionRules = require(Shared.Magic.ActionRules)

local Client = script.Parent.Parent
local SpellFx = require(Client:WaitForChild("Fx").SpellFx)
local SlashFx = require(Client.Fx.SlashFx)

local RANGE = 120
local HIT_AT = 0.3
local REACH = 4.5
local STEEL = Color3.fromRGB(225, 230, 240)
local STEEL_EDGE = Color3.fromRGB(170, 182, 200)

local SlashFxController = {
	name = "SlashFxController",
	dependencies = {},
}

local function onSeq(player: Player, character: Model)
	local snapshot = ActionRules.read(character)
	if snapshot.state ~= "slashing" then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	if not root or not root:IsA("BasePart") or not camera then
		return
	end
	if (root.Position - camera.CFrame.Position).Magnitude > RANGE then
		return
	end
	local attuned = character:GetAttribute("AttunedDomain")
	local domain = if typeof(attuned) == "string" then attuned else snapshot.domain
	local primary, secondary, glow = STEEL, STEEL_EDGE, false
	if domain then
		local style = SpellFx.styleFor(player.UserId, domain)
		primary, secondary, glow = style.primary, style.secondary, true
	end
	local duration = if snapshot.duration > 0 then snapshot.duration else 0.5
	local seq = snapshot.seq
	task.delay(duration * HIT_AT, function()
		-- A newer action (a dash, a block) cancelled the swing before it landed: no arc.
		if ActionRules.read(character).seq ~= seq or not root.Parent then
			return
		end
		SlashFx.arc(root, {
			clip = snapshot.variant,
			swing = seq,
			primary = primary,
			secondary = secondary,
			glow = glow,
			reach = REACH,
			duration = math.clamp(duration * 0.45, 0.14, 0.32),
		})
	end)
end

local function watchCharacter(player: Player, character: Model)
	character:GetAttributeChangedSignal(ActionRules.ATTR.seq):Connect(function()
		onSeq(player, character)
	end)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
	end)
	if player.Character then
		watchCharacter(player, player.Character)
	end
end

function SlashFxController.init(_self: any, _ctx: any) end

function SlashFxController.start(_self: any, _ctx: any)
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return SlashFxController
