--!strict
--[[
	AdminConfig: who may open the Admin/Developer Panel, and where it exists at all.
	Read ONLY on the server (AdminService). Nothing here is ever sent to a client except the
	toggle key, and only to admins.

	AdminUserIds          the only accounts that ever receive the panel or its remotes
	OwnerUserId           may also run owner-only commands (reseed: rewrites the shared world)
	EnableInLiveServers   false = the panel exists only in Studio; flip to true to use it live
	StudioTestPlayers     Studio "Start Server + Players" sessions use negative UserIds; allow
	                      them in Studio only (negative ids can't exist on a live server)
	ToggleKey             keyboard toggle (KeyCode name); touch players get an on-screen button
	RateLimit             commands per admin: burst capacity and sustained per-second refill
	LogCapacity           audit entries kept for the in-panel log
]]

return {
	AdminUserIds = { 17476255, 489106246, 1103430971 } :: { number },
	OwnerUserId = 17476255,
	EnableInLiveServers = true,
	StudioTestPlayers = true,
	ToggleKey = "F2",
	RateLimit = { capacity = 10, perSecond = 4 },
	LogCapacity = 200,
}
