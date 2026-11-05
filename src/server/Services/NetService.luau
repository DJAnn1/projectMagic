--!strict
-- NetService: creates the remotes at boot and connects Net to the signal bus.
-- Services that register Net handlers list it as a dependency so the boot order is explicit.

local Net = require(game:GetService("ReplicatedStorage").Shared.Net)

local NetService = {
	name = "NetService",
	dependencies = {},
}

function NetService.init(_self: any, ctx: any)
	Net.start(ctx.bus)
end

return NetService
