--!strict
--[[
	Audio.spec: Shared/Audio/AudioLibrary is well formed. Every domain has its three spell sounds
	(DomainFx reads "<domain>.cast/launch/impact"), every entry has a real-looking asset id and a
	sane volume, and the roles the client code asks for by name exist.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local AudioLibrary = require(Shared.Audio.AudioLibrary)
local Registry = require(Shared.Magic.Registry)

-- Roles the client plays by name (Theme.sounds, CombatFeedback, GuardFx, WeaponFx, AudioController...).
local USED = {
	"ui.open", "ui.close", "ui.click", "ui.confirm", "ui.error", "ui.notify",
	"sting.tierUp", "sting.breakthrough", "sting.discovery", "sting.awakening", "sting.questDone",
	"spell.backfire", "lightning.zap", "lightning.strike",
	"combat.hit", "combat.crit", "combat.kill", "combat.knockdown", "combat.block", "combat.parry",
	"combat.slash", "combat.dash", "weapon.bowRelease", "weapon.arrowHit",
	"music.explore", "music.town", "music.night", "music.combat", "music.event", "music.mystic", "music.snow", "music.desert",
	"amb.town", "amb.night",
}

return function(t: any)
	t.describe("AudioLibrary", function()
		t.it("gives every domain a cast, launch and impact sound", function()
			for _, domain in Registry.domainIds do
				for _, kind in { "cast", "launch", "impact" } do
					if not AudioLibrary.get(domain .. "." .. kind) then
						error("no sound for " .. domain .. "." .. kind)
					end
				end
			end
		end)

		t.it("has well-formed entries", function()
			for role, entry in AudioLibrary.entries do
				t.expect(entry.id > 1000).toBe(true)
				t.expect(entry.volume > 0 and entry.volume <= 1).toBe(true)
				t.expect(string.find(role, "%.") ~= nil).toBe(true) -- "<group>.<name>"
				for _, alt in (entry.alt or {}) :: { { id: number, name: string } } do
					t.expect(alt.id > 1000).toBe(true)
				end
			end
			t.expect(AudioLibrary.idOf("energy.impact")).toBe("rbxassetid://" .. tostring((AudioLibrary.get("energy.impact") :: any).id))
			t.expect(AudioLibrary.idOf("no.such.role")).toBe(nil)
		end)

		t.it("has every role the client plays by name", function()
			for _, role in USED do
				if not AudioLibrary.get(role) then
					error("missing role " .. role)
				end
			end
		end)
	end)
end
