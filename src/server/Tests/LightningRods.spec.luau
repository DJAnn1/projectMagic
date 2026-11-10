--!strict
--[[
	LightningRods.spec: metal draws lightning (docs/LightningRods.md). What matters most: a real rod
	(a lamp post) wins at a fair distance, a nail never does; chain mail draws it, cloth doesn't;
	the reach grows with power and storms but is capped; armour on the person you aimed at holds
	the bolt against a neighbour in the same armour; and worn metal is read from real item data.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local LightningRods = require(Server.Magic.Cast.LightningRods)
local R = require(Server.Magic.Data.LightningRods)
local Flags = require(Server.Config.Flags)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local ItemDatabase = require(ReplicatedStorage.Shared.Items.ItemDatabase)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Lightning rods data", function()
		it("only bends real forms, and has a flag", function()
			for form in R.forms do
				expect(Registry.forms[form] ~= nil).toBe(true)
			end
			expect(R.forms.touch).toBe(nil)
			expect(R.forms.beam).toBe(nil)
			expect((Flags :: any).lightning_rods_enabled ~= nil).toBe(true)
		end)

		it("chain mail is metal and heavy enough to draw lightning; insulated gloves are not", function()
			local mail = ItemDatabase.get("chain_mail")
			expect(mail ~= nil and table.find(mail.tags or {}, "metal") ~= nil).toBe(true)
			expect(LightningRods.weightPull((mail :: any).weight) > R.stay).toBe(true)
			local gloves = ItemDatabase.get("rubber_gloves")
			expect(gloves ~= nil and table.find(gloves.tags or {}, "metal") == nil).toBe(true)
		end)
	end)

	describe("Lightning rods rules", function()
		it("reach grows with power and storms, and is capped", function()
			expect(LightningRods.radiusFor(1, 0)).toBe(R.radiusBase)
			expect(LightningRods.radiusFor(5, 0) > LightningRods.radiusFor(2, 0)).toBe(true)
			expect(LightningRods.radiusFor(5, 1) > LightningRods.radiusFor(5, 0)).toBe(true)
			expect(LightningRods.radiusFor(10, 1)).toBe(R.radiusMax)
		end)

		it("a lamp post at half reach outpulls the aimed spot; a nail never does", function()
			local radius = LightningRods.radiusFor(3, 0)
			local post = LightningRods.partPull(Vector3.new(0.6, 6, 0.6))
			expect(LightningRods.score(post, radius / 2, radius) > R.stay).toBe(true)
			local nail = LightningRods.partPull(Vector3.new(0.1, 0.4, 0.1))
			expect(nail).toBe(0)
			expect(LightningRods.score(nail, 0, radius)).toBe(0)
			expect(LightningRods.score(post, radius + 1, radius)).toBe(0)
		end)

		it("taller metal pulls harder, up to a cap", function()
			local low = LightningRods.partPull(Vector3.new(2, 2, 2))
			local tall = LightningRods.partPull(Vector3.new(1, 10, 1))
			expect(tall > low).toBe(true)
			expect(LightningRods.partPull(Vector3.new(4, 400, 4))).toBe(R.partPullMax)
		end)

		it("armour on the person you aimed at holds the bolt against a neighbour in the same armour", function()
			local radius = LightningRods.radiusFor(4, 0)
			local mail = LightningRods.weightPull(9)
			local stay = R.stay + mail
			expect(LightningRods.score(mail, 2, radius) < stay).toBe(true)
		end)

		it("a little metal (a ring, a knife) draws nothing", function()
			expect(LightningRods.weightPull(R.minWeight - 0.1)).toBe(0)
			expect(LightningRods.weightPull(1000)).toBe(R.personPullMax)
		end)
	end)

	describe("Worn metal", function()
		it("reads NPC gear attributes and the manual attribute", function()
			local model = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = model
			expect(LightningRods.metalWeight(model)).toBe(0)
			humanoid:SetAttribute("Gear_body", "chain_mail")
			local mail = (ItemDatabase.get("chain_mail") :: any).weight
			expect(LightningRods.metalWeight(model)).toBe(mail)
			model:SetAttribute("MetalCarried", 3)
			expect(LightningRods.metalWeight(model)).toBe(mail + 3)
			model:Destroy()
		end)
	end)
end
