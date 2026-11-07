--!strict
--[[
	ActivityService: the single source of truth for what every NPC is visibly doing (docs/Activities.md).

	NPCBrain still decides the ACTION (sleep, work, eat...). This service turns that into an ACTIVITY from
	Shared/Life/Data/ActivityLibrary (blacksmithing, sleeping, eating at the tavern...), claims the station
	it's done at (Life/StationRegistry), runs its phases, and publishes it:

		NPC rig        attribute NpcActivity (Shared/Life/ActivityState), written only on a change
		station part   StationActive / StationUser / StationWork (Shared/Life/Data/StationTypes)

	Clients render props, poses, station effects and the Observe tooltip from those alone.

	PHASES  Travelling (walking to the use point) -> Preparing (arrived, settling in, 1.4 s) -> Performing
	        -> Finishing (putting the tools away, 1.4 s, when the action changes). Interrupted while they
	        talk, are greeted, fight or are led about; the work resumes where it stopped.
	TIERS   T0/T1 NPCs (rigs) get the attribute. T2 NPCs have no rig: their activity is kept as data and
	        counts as Performing, and it still lights their station, so a smithy's forge glows and a
	        hearth's chimney smokes when its user is out of everyone's sight.
	ROUTING NPCService asks this service where an action happens (setActivityHook): the claimed use
	        point, or a spot (a neighbour's door step, a yard), or nothing (the old district spot).
	BUDGET  A 1 Hz sweep over rig NPCs and a 5 s sweep over the rest, sliced across frames (SLICE per
	        frame). Writes are string compares; a station flips at most twice per activity.

	Not here yet (later stages, docs/Activities.md): the other 45+ activities, audio, icons, barks, the town
	overview, join and assist, and the LOD consistency pass.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Registry = require(Shared.Magic.Registry)
local ActivityLibrary = require(Shared.Life.Data.ActivityLibrary)
local ActivityState = require(Shared.Life.ActivityState)
local StationTypes = require(Shared.Life.Data.StationTypes)

local Server = script.Parent.Parent
local StationRegistry = require(Server.Life.StationRegistry)
local ActivityRules = require(Server.Life.ActivityRules)
local ReadabilityReport = require(Server.Life.ReadabilityReport)
local WorldClock = require(Server.NPC.WorldClock)
local NPCLOD = require(Server.NPC.NPCLOD)
local Navigation = require(Server.NPC.NavigationService)
local NPCCombat = require(Server.NPC.NPCCombat)
local DialogueEngine = require(Server.NPC.DialogueEngine)
local Progression = require(Server.Progression.Progression)

type Activity = ActivityLibrary.Activity
type Station = StationRegistry.Station

local A = StationTypes.ATTR
local SLICE = 24 -- NPCs looked at per frame
local RIG_EVERY = 1 -- seconds between looks at an NPC with a rig
local FAR_EVERY = 5 -- and at one without
local SNAP_REACH = 5 -- studs: closer than this to the use point, they step onto it
local OBSERVE_RANGE = 45
local WATCH_GAP = 3 -- seconds: observing again within this keeps the watch going

local ActivityService = {
	name = "ActivityService",
	dependencies = { "AdminService", "NPCService", "PlayerDataService", "SettlementService" },
}

type Record = {
	action: string,
	day: number,
	def: Activity?,
	state: ActivityState.State,
	station: Station?,
	slot: number?,
	spot: Vector3?,
	encoded: string,
	model: Model?,
	pausedAt: number?,
	snapped: boolean,
	started: boolean,
	travelSince: number, -- server time this Travelling phase began (stalls: actphases, actnpc) -- has ever reached Performing (patrols then stay Performing while walking)
	finishing: { def: Activity, state: ActivityState.State, untilAt: number, encoded: string }?,
	forced: { id: string, untilDay: number, station: Station? }?,
}

local log: any = nil
local flags: any = nil
local npcs: any = nil
local settlements: any = nil
local playerData: any = nil
local enabled = true

local cursor = 1
local nextLook: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local watching: { [Player]: { npcId: string, first: number, last: number } } = {}
local debugViewers: { [Player]: boolean } = {}
local stats = { picked = 0, claimed = 0, noStation = 0, snapped = 0, writes = 0 }

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function isEnabled(): boolean
	return enabled and (flags == nil or flags.get("activities_enabled") ~= false)
end

-- ─── Stations ───────────────────────────────────────────────────────────────

local function stationLive(station: Station?): boolean
	return station ~= nil and StationRegistry.usable(station) and not npcs:lotDown(station.lotId)
end

-- Turns a station's look on or off (and its building's passive partner, the smithy's forge).
local function refreshStation(station: Station)
	local part = station.part
	if not part.Parent then
		return
	end
	local user = StationRegistry.firstUser(station)
	local active = user ~= nil
	if part:GetAttribute(A.active) ~= active then
		part:SetAttribute(A.active, active)
	end
	if part:GetAttribute(A.user) ~= (user or "") then
		part:SetAttribute(A.user, user or "")
	end
	local def = StationTypes.types[station.kind]
	if def and def.linked then
		local anyActive = false
		for _, same in StationRegistry.inLot(station.lotId, station.kind) do
			if StationRegistry.firstUser(same) then
				anyActive = true
			end
		end
		for _, partner in StationRegistry.inLot(station.lotId, def.linked) do
			if partner.part:GetAttribute(A.active) ~= anyActive then
				partner.part:SetAttribute(A.active, anyActive)
			end
		end
	end
end

-- What's being made at a station, for its progress look (the blade on the anvil). Only its first user's.
local function setStationWork(npc: any, station: Station?, rec: Record)
	if not station or not rec.def or StationRegistry.firstUser(station) ~= npc.id then
		return
	end
	local s = rec.state
	local work = if s.phase == "W" or s.phase == "I" then StationTypes.encodeWork(s.index, s.start, s.duration, s.item) else ""
	if station.part:GetAttribute(A.work) ~= work then
		station.part:SetAttribute(A.work, work)
	end
end

local function releaseStation(npc: any, rec: Record)
	local station = rec.station
	if station then
		StationRegistry.release(station, npc.id)
		if StationRegistry.firstUser(station) == nil then
			station.part:SetAttribute(A.work, "")
		end
		refreshStation(station)
	end
	rec.station, rec.slot = nil, nil
end

-- The stations this person would use for a kind, best first: their own (bed, table, workplace), then the
-- town's, starting at a seeded place in the list so a town's people spread over its stations.
local function stationOrder(npc: any, kind: string): { Station }
	local out: { Station } = {}
	local function add(list: { Station })
		for _, s in list do
			if not table.find(out, s) then
				table.insert(out, s)
			end
		end
	end
	local home = npc.home
	local homeLot = if npc.shelter and home and npcs:lotDown(home.lot) then npc.shelter.lot elseif home then home.lot else nil
	if kind == "bed" then
		if homeLot then
			local beds = StationRegistry.inLot(homeLot, "bed")
			local slot = if npc.shelter and home and npcs:lotDown(home.lot) then npc.shelter.slot or 1 else (home and home.slot) or 1
			if #beds > 0 then
				local first = beds[(slot - 1) % #beds + 1]
				table.insert(out, first)
				add(beds)
			end
		end
		return out -- nobody sleeps in a stranger's bed
	elseif kind == "table" then
		if homeLot then
			add(StationRegistry.inLot(homeLot, "table"))
		end
		return out
	end
	if npc.work then
		add(StationRegistry.inLot(npc.work.lot, kind))
	end
	if kind == "hearth" and homeLot then
		add(StationRegistry.inLot(homeLot, kind))
	end
	local town = StationRegistry.inTown(npc.settlementId, kind)
	local n = #town
	if n > 0 then
		local offset = (npc.seed or 0) % n
		for i = 1, n do
			local s = town[(offset + i - 1) % n + 1]
			if not table.find(out, s) then
				table.insert(out, s)
			end
		end
	end
	return out
end

local function claimStation(npc: any, rec: Record, kind: string, preferred: Station?): boolean
	local order = stationOrder(npc, kind)
	if preferred then
		table.insert(order, 1, preferred)
	end
	for _, station in order do
		if stationLive(station) then
			local slot = StationRegistry.claim(station, npc.id)
			if slot then
				rec.station, rec.slot = station, slot
				refreshStation(station)
				stats.claimed += 1
				return true
			end
		end
	end
	stats.noStation += 1
	return false
end

local function usePoint(rec: Record): StationRegistry.Point?
	local station, slot = rec.station, rec.slot
	if not station or not slot then
		return nil
	end
	return station.points[slot]
end

-- ─── Spots (station-less activities) ────────────────────────────────────────

local function spotFor(npc: any, def: Activity, day: number): Vector3?
	if def.spot == "door" then
		-- Someone else's front step, a different house each day.
		local homes = settlements:homes(npc.settlementId)
		local others: { string } = {}
		for _, h in homes do
			if not (npc.home and npc.home.lot == h.lotId) and not npcs:lotDown(h.lotId) then
				table.insert(others, h.lotId)
			end
		end
		if #others == 0 then
			return nil
		end
		local lot = others[((npc.seed or 0) + day) % #others + 1]
		local door = settlements:anchor(lot, "Entrance")
		return door
	elseif def.spot == "yard" then
		local lot = npc.home and npc.home.lot
		if not lot or npcs:lotDown(lot) then
			return nil
		end
		local door = settlements:anchor(lot, "Entrance")
		if not door then
			return nil
		end
		local cf, size = settlements:lotBox(lot)
		if cf and size then
			-- Beside the front door, towards the lot's corner: out of the doorway.
			local side = cf.RightVector * math.min(size.X / 2 - 2, 5)
			return door + side
		end
		return door + Vector3.new(4, 0, 0)
	end
	return nil
end

-- ─── Records ────────────────────────────────────────────────────────────────

local function encodeFor(rec: Record): string
	if not rec.def then
		return ""
	end
	return ActivityState.encode(rec.state)
end

local function minutesToSeconds(minutes: number): number
	local perHour = WorldClock.secondsPerHour()
	if perHour == math.huge then
		return 1800
	end
	return math.clamp(minutes / 60 * perHour, 10, 1800)
end

local function blockOf(npc: any): string?
	return npc.lastBlock
end

local function newRecord(npc: any, now: number): Record
	local day = math.floor(WorldClock.now())
	local action = tostring(npc.action)
	local rec: Record = {
		action = action,
		day = day,
		def = nil,
		state = ActivityState.new(0, now),
		station = nil,
		slot = nil,
		spot = nil,
		encoded = "",
		model = nil,
		pausedAt = nil,
		snapped = false,
		started = false,
		travelSince = now,
		finishing = nil,
		forced = nil,
	}
	local forced = npc.activityForced
	local def: Activity? = nil
	local preferred: Station? = nil
	if forced and WorldClock.now() < forced.untilDay and ActivityLibrary.byId[forced.id] then
		def = ActivityLibrary.byId[forced.id]
		preferred = forced.station
		rec.forced = forced
	else
		npc.activityForced = nil
		def = ActivityRules.pick(npc, action, day)
	end
	rec.def = def
	if not def then
		return rec
	end
	stats.picked += 1
	local s = rec.state
	s.index = def.index
	s.reason = if rec.forced then "told" else ActivityRules.reason(npc, action, blockOf(npc))
	s.variant = ActivityRules.variant(def, npc)
	s.item = ActivityRules.item(def, npc, day)
	s.duration = minutesToSeconds(ActivityRules.minutes(def, npc, day, 1))
	if def.domain then
		local domain, tier = ActivityRules.bestDomain(npc)
		s.domain = domain or def.domain
		s.tier = tier
	end
	if def.station then
		if not claimStation(npc, rec, def.station, preferred) and def.altStation then
			claimStation(npc, rec, def.altStation, nil)
		end
		if rec.station then
			s.station = rec.station.id
		end
	elseif def.spot then
		rec.spot = spotFor(npc, def, day)
	end
	return rec
end

-- Where the current activity wants them. NPCService.route asks this first (setActivityHook).
local function targetOf(npc: any): Vector3?
	if not isEnabled() then
		return nil
	end
	local rec: Record? = npc.activity
	if not rec or rec.action ~= tostring(npc.action) then
		return nil -- refreshed by ensureRecord just before route asks
	end
	local point = usePoint(rec)
	if point then
		return point.stand.Position
	end
	return rec.spot
end

-- The record for the NPC's current action: kept, or replaced (the old one finishes visibly).
local function ensureRecord(npc: any, now: number): Record
	local rec: Record? = npc.activity
	local action = tostring(npc.action)
	local day = math.floor(WorldClock.now())
	local forcedChanged = npc.activityForced ~= nil and (rec == nil or rec.forced ~= npc.activityForced)
	if rec and rec.action == action and not forcedChanged and (rec.day == day or rec.state.phase == "W" or rec.state.phase == "I") then
		return rec
	end
	local finishing = nil
	if rec then
		releaseStation(npc, rec)
		Navigation.Face(npc, nil)
		local old = rec.def
		if old and npc.rig and (rec.state.phase == "W" or rec.state.phase == "I" or rec.state.phase == "P") then
			local st = table.clone(rec.state)
			st.phase = "F"
			st.phaseAt = now
			finishing = { def = old, state = st, untilAt = now + ActivityState.FINISH_SECONDS, encoded = ActivityState.encode(st) }
		end
	end
	local fresh = newRecord(npc, now)
	fresh.finishing = finishing
	npc.activity = fresh
	return fresh
end

local function setPhase(rec: Record, phase: ActivityState.Phase, now: number)
	local s = rec.state
	if s.phase == phase then
		return
	end
	if phase == "I" then
		rec.pausedAt = now
	elseif s.phase == "I" and rec.pausedAt then
		-- Back to work: the clock moves on by the pause, so progress carries on from where it stopped.
		s.start += now - rec.pausedAt
		rec.pausedAt = nil
	end
	if phase == "T" then
		rec.travelSince = now
	end
	if phase == "W" and not rec.started then
		rec.started = true
		s.start = now
	end
	s.phase = phase
	s.phaseAt = now
end

local function interrupted(npc: any, def: Activity): boolean
	if npc.knockedOut or NPCCombat.engaged(npc) or npc.leash then
		return true
	end
	if def.interrupt == "stay" then
		return false
	end
	return npc.talk ~= nil or Navigation.IsPaused(npc)
end

-- Steps onto the use point and faces the work, in a few small moves.
local function snap(npc: any, rec: Record)
	local point = usePoint(rec)
	local rig = npc.rig
	if not point or not rig or rig.root.Anchored or rec.snapped then
		return
	end
	local from = rig.root.Position
	local to = point.stand
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z).Magnitude
	if flat > SNAP_REACH then
		return
	end
	rec.snapped = true
	stats.snapped += 1
	local station = rec.station :: Station
	local start = rig.root.CFrame
	task.spawn(function()
		for i = 1, 4 do
			if npc.rig ~= rig or rig.root.Anchored or npc.activity ~= rec then
				return
			end
			rig.model:PivotTo(start:Lerp(to, i / 4))
			task.wait(0.06)
		end
		npc.position = to.Position
		Navigation.Face(npc, station.part.Position)
	end)
end

-- One look at one NPC: the record, its phase, and what's published.
local function step(npc: any, now: number)
	local rec = ensureRecord(npc, now)
	local def = rec.def
	if def then
		local rig = npc.rig
		if not rig then
			setPhase(rec, "W", now) -- out of sight they are simply doing it
		elseif interrupted(npc, def) then
			if rec.state.phase ~= "T" then
				setPhase(rec, "I", now)
			end
		else
			local phase = rec.state.phase
			local here = NPCLOD.arrived(npc)
			if def.spot == "patrol" and rec.started then
				if phase ~= "W" then
					setPhase(rec, "W", now)
				end
			elseif not here and phase ~= "I" and not (phase == "W" and def.spot ~= nil) then
				-- Walked off to somewhere new. (Station-less work moves about, a farmer along the rows,
				-- and stays Performing: the condition above leaves that case alone.)
				if phase ~= "T" then
					setPhase(rec, "T", now)
					rec.snapped = false
				end
			elseif phase == "T" then
				-- Arrived somewhere other than the use point (the walk failed and route() fell back to a
				-- district spot): they can't be at the station, so it isn't theirs any more.
				local point = usePoint(rec)
				if point and not rig.root.Anchored then
					local at = rig.root.Position
					local off = Vector3.new(point.stand.X - at.X, 0, point.stand.Z - at.Z).Magnitude
					if off > SNAP_REACH * 1.6 then
						releaseStation(npc, rec)
						rec.state.station = ""
					end
				end
				setPhase(rec, "P", now)
				snap(npc, rec)
			elseif phase == "P" and now - rec.state.phaseAt >= ActivityState.PREPARE_SECONDS then
				setPhase(rec, "W", now)
			elseif phase == "I" then
				setPhase(rec, "W", now)
				local point = usePoint(rec)
				if point and rec.station then
					Navigation.Face(npc, rec.station.part.Position)
				end
			end
		end
		-- A finished piece: the next one starts on the next item.
		local _, pieces = ActivityState.progress(rec.state, now)
		local pieceItem = ActivityRules.item(def, npc, rec.day) + pieces
		if rec.state.phase == "W" and rec.state.item ~= pieceItem then
			rec.state.item = pieceItem
		end
		setStationWork(npc, rec.station, rec)
	end
	-- Publish: the finishing record until it's put away, then the current one.
	local finishing = rec.finishing
	local encoded = encodeFor(rec)
	if finishing then
		if now < finishing.untilAt and npc.rig then
			encoded = finishing.encoded
		else
			rec.finishing = nil
		end
	end
	rec.encoded = encoded
	local rig = npc.rig
	if rig then
		local model: Model = rig.model
		if rec.model ~= model or model:GetAttribute(ActivityState.ATTR) ~= encoded then
			model:SetAttribute(ActivityState.ATTR, if encoded == "" then nil else encoded)
			rec.model = model
			stats.writes += 1
		end
	end
end

local function sweep()
	if not isEnabled() then
		return
	end
	local all = npcs:all()
	local count = #all
	if count == 0 then
		return
	end
	local now = serverNow()
	local clock = os.clock()
	for _ = 1, math.min(SLICE, count) do
		if cursor > count then
			cursor = 1
		end
		local npc = all[cursor]
		cursor += 1
		if clock >= (nextLook[npc] or 0) then
			nextLook[npc] = clock + (if npc.rig then RIG_EVERY else FAR_EVERY)
			local ok, err = pcall(step, npc, now)
			if not ok then
				log:warn("activity_step_failed", { npc = tostring(npc.id), err = tostring(err) })
				nextLook[npc] = clock + 30
			end
		end
	end
end

-- NPCService.route: refresh the record (a new action, a new day) and say where it happens.
local function routeHook(npc: any): Vector3?
	if not isEnabled() then
		return nil
	end
	ensureRecord(npc, serverNow())
	return targetOf(npc)
end

-- ─── Observe ────────────────────────────────────────────────────────────────

local function mindTier(player: Player): number
	local state = playerData:get(player)
	local p = state and state.data and state.data.progression
	if not p then
		return 0
	end
	local best = 0
	for branchId in (p.unlocked or {}) :: { [string]: any } do
		local branch = Registry.branches[branchId]
		if branch and table.find(branch.domains, "mind") then
			best = math.max(best, (Progression.getMasteryTier(p, branchId)))
		end
	end
	return best
end

local function observe(player: Player, npcId: string, detail: string): any
	local npc = npcs:get(npcId)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not npc or not root or not root:IsA("BasePart") or not npc.rig then
		return nil
	end
	if (root.Position - npc.position).Magnitude > OBSERVE_RANGE then
		return nil
	end
	local clock = os.clock()
	local w = watching[player]
	if not w or w.npcId ~= npcId or clock - w.last > WATCH_GAP then
		w = { npcId = npcId, first = clock, last = clock }
		watching[player] = w
	end
	w.last = clock
	local band = DialogueEngine.band(npc, "u:" .. player.UserId, WorldClock.now())
	local level = ActivityRules.knowledge(band, mindTier(player), clock - w.first)
	local rec: Record? = npc.activity
	local def = rec and rec.def
	local now = serverNow()
	local progress = if rec then (ActivityState.progress(rec.state, now)) else 0
	local title, line = ActivityRules.describe(npc, def, level, {
		detail = detail,
		progress = progress,
		phase = rec and rec.state.phase,
		item = if rec then rec.state.item else 1,
		reason = if rec then rec.state.reason else "",
	})
	return { npcId = npcId, title = title, line = line, level = level }
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function activityOptions(): { string }
	local out: { string } = {}
	for _, def in ActivityLibrary.list do
		table.insert(out, def.id)
	end
	return out
end

-- Why someone is still Travelling: how long, how far, and whether they're actually walking.
local function travelNote(npc: any, rec: Record, now: number): string
	local dest: Vector3? = npc.destination
	local far = if dest then Vector3.new(dest.X - npc.position.X, 0, dest.Z - npc.position.Z).Magnitude else 0
	local how = if Navigation.IsPaused(npc) then "paused"
		elseif Navigation.IsMoving(npc) then "walking"
		elseif npc.enterHome then "heading for the door"
		else "standing (no path yet, or retrying)"
	return string.format(" · travelling %ds, %d studs to go, %s", math.floor(now - rec.travelSince), math.floor(far), how)
end

local function describeRecord(npc: any): string
	local rec: Record? = npc.activity
	if not rec or not rec.def then
		return string.format("%s (%s): action %s, no activity", npc.name, npc.id, tostring(npc.action))
	end
	local s = rec.state
	local now = serverNow()
	local progress = ActivityState.progress(s, now)
	return string.format("%s (%s): %s · %s · station %s · %s · %d%% · tier %d%s", npc.name, npc.id, rec.def.id,
		ActivityState.phaseNames[s.phase], if s.station ~= "" then s.station elseif rec.spot then "spot" else "none",
		ActivityLibrary.reasons[s.reason] or s.reason, math.floor(progress * 100), npc.tier or 2,
		if s.phase == "T" and npc.rig then travelNote(npc, rec, now) else "")
end

local function townNpcs(settlementId: string?): { any }
	local out: { any } = {}
	for _, npc in npcs:all() do
		if not settlementId or npc.settlementId == settlementId then
			table.insert(out, npc)
		end
	end
	return out
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "actlabels", category = "NPCs", description = "Debug labels over every NPC near you: activity, phase, station, reason (only you see them)",
		args = { { name = "on", type = "boolean", default = true } },
		handler = function(ctx: any, a: any)
			debugViewers[ctx.player] = a.on or nil
			Net.fire("ActivityDebug", ctx.player, a.on == true)
			return if a.on then "activity labels on" else "activity labels off"
		end,
	})
	admin:Register({
		name = "actlist", category = "NPCs", description = "NPCs by activity (in a settlement, or everywhere)",
		args = { { name = "settlement", type = "settlement", optional = true } },
		handler = function(_ctx: any, a: any)
			local groups: { [string]: { string } } = {}
			local list = townNpcs(a.settlement and a.settlement.id)
			for _, npc in list do
				local rec: Record? = npc.activity
				local key = if rec and rec.def then rec.def.id else "(" .. tostring(npc.action) .. ", no activity)"
				groups[key] = groups[key] or {}
				table.insert(groups[key], npc.name)
			end
			local keys: { string } = {}
			for k in groups do
				table.insert(keys, k)
			end
			table.sort(keys)
			local lines = { string.format("%d NPCs", #list) }
			for _, k in keys do
				local names = groups[k]
				table.insert(lines, string.format("%s: %d  %s", k, #names, table.concat(names, ", ", 1, math.min(#names, 6)) .. (if #names > 6 then ", ..." else "")))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "actphases", category = "NPCs", description = "How many NPCs with a body are in each activity phase, and why the travellers aren't there yet",
		args = { { name = "settlement", type = "settlement", optional = true } },
		handler = function(_ctx: any, a: any)
			local now = serverNow()
			local phases: { [string]: number } = {}
			local walking, standing, door, paused, long = 0, 0, 0, 0, 0
			local rigs, none = 0, 0
			for _, npc in townNpcs(a.settlement and a.settlement.id) do
				local rec: Record? = npc.activity
				if npc.rig then
					rigs += 1
					if not rec or not rec.def then
						none += 1
					else
						local ph = rec.state.phase
						phases[ph] = (phases[ph] or 0) + 1
						if ph == "T" then
							if Navigation.IsPaused(npc) then
								paused += 1
							elseif Navigation.IsMoving(npc) then
								walking += 1
							elseif npc.enterHome then
								door += 1
							else
								standing += 1
							end
							if now - rec.travelSince > 30 then
								long += 1
							end
						end
					end
				end
			end
			local parts: { string } = {}
			for _, ph in { "T", "P", "W", "F", "I" } do
				table.insert(parts, string.format("%s %d", ActivityState.phaseNames[ph], phases[ph] or 0))
			end
			return string.format("%d NPCs with a body: %s · no activity %d\nTravelling: walking %d · standing (no path yet or retrying) %d · heading for a door %d · paused %d · over 30 s %d",
				rigs, table.concat(parts, " · "), none, walking, standing, door, paused, long)
		end,
	})
	admin:Register({
		name = "actnpc", category = "NPCs", description = "An NPC's activity record: activity, phase, station, reason, progress",
		args = { { name = "npc", type = "npc", default = "nearest" } },
		handler = function(_ctx: any, a: any)
			return describeRecord(a.npc)
		end,
	})
	admin:Register({
		name = "actforce", category = "NPCs", description = "Put an NPC into an activity for a while, at the nearest free station of its kind",
		args = {
			{ name = "activity", type = "enum", options = activityOptions() },
			{ name = "npc", type = "npc", default = "nearest" },
			{ name = "minutes", type = "number", min = 5, max = 600, default = 60, hint = "game minutes" },
		},
		handler = function(_ctx: any, a: any)
			local def = ActivityLibrary.byId[a.activity]
			local npc = a.npc
			local nearest: Station? = nil
			if def.station then
				local best = math.huge
				for _, town in npcs:towns() do
					for _, station in StationRegistry.inTown(town.id, def.station) do
						local d = (station.part.Position - npc.position).Magnitude
						if d < best and stationLive(station) then
							nearest, best = station, d
						end
					end
				end
				if not nearest then
					return "no usable " .. def.station .. " anywhere (stationcheck lists the broken ones)"
				end
			end
			local untilDay = WorldClock.now() + a.minutes / 1440
			npc.activityForced = { id = def.id, untilDay = untilDay, station = nearest }
			local result = npcs:forceAction(npc, def.actions[1], a.minutes, nil)
			return string.format("%s -> %s%s (%s)", npc.name, def.id, if nearest then " at " .. nearest.id else "", tostring(result))
		end,
	})
	admin:Register({
		name = "actpreview", category = "NPCs", description = "Spawn a test NPC beside you doing an activity (it uses the nearest station of the kind)",
		args = { { name = "activity", type = "enum", options = activityOptions() } },
		handler = function(ctx: any, a: any)
			local def = ActivityLibrary.byId[a.activity]
			local character = ctx.player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") then
				return "no character"
			end
			local occupation = if def.occupations then def.occupations[1] else "farmer"
			-- A practice preview needs magic in that domain: its root branch at mastery 60.
			local mastery: { [string]: number }? = nil
			if def.domain then
				for id, branch in Registry.branches do
					if branch.isRoot and branch.domains[1] == def.domain then
						mastery = { [id] = 60 }
					end
				end
			end
			local at = root.Position + root.CFrame.LookVector * 6
			local npc, err = npcs:spawn(at, { occupation = occupation, mastery = mastery })
			if not npc then
				return "couldn't spawn: " .. tostring(err)
			end
			npc.activityForced = { id = def.id, untilDay = WorldClock.now() + 2 / 24, station = nil }
			npcs:forceAction(npc, def.actions[1], 120, nil)
			return string.format("%s (%s) is %s for 2 game hours; it goes to the nearest station if this town has one", npc.name, npc.id, def.name)
		end,
	})
	admin:Register({
		name = "actmissing", category = "NPCs", description = "Activities missing a station, props, an animation, a sound or tooltip text",
		args = {},
		handler = function(_ctx: any, _a: any)
			return table.concat(ReadabilityReport.library(), "\n")
		end,
	})
	admin:Register({
		name = "stationcheck", category = "NPCs", description = "Stations by kind, and every one without a valid use point (and why)",
		args = {},
		handler = function(_ctx: any, _a: any)
			local total, bad = StationRegistry.counts()
			local kinds: { string } = {}
			for k in total do
				table.insert(kinds, k)
			end
			table.sort(kinds)
			local lines = {}
			for _, k in kinds do
				table.insert(lines, string.format("%s: %d (%d without a use point)", k, total[k], bad[k] or 0))
			end
			local broken = StationRegistry.invalid()
			for i = 1, math.min(#broken, 25) do
				table.insert(lines, string.format("  ✗ %s: %s", broken[i].id, broken[i].invalid or "?"))
			end
			if #broken > 25 then
				table.insert(lines, string.format("  ...and %d more", #broken - 25))
			end
			if #lines == 0 then
				return "no stations found yet (buildings may still be building)"
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "actreport", category = "NPCs", description = "Readability Report: simulate a day in a settlement and check each activity is fully visible",
		args = { { name = "settlement", type = "settlement", optional = true } },
		handler = function(ctx: any, a: any)
			local id = a.settlement and a.settlement.id
			if not id then
				local character = ctx.player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local best = math.huge
				for _, town in npcs:towns() do
					local d = if root and root:IsA("BasePart") then (Vector3.new(town.x, 0, town.z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude else 0
					if d < best then
						id, best = town.id, d
					end
				end
			end
			if not id then
				return "no settlement"
			end
			local lines, pass, warn, fail = ReadabilityReport.run(id, townNpcs(id), function(npc, action, day)
				return ActivityRules.pick(npc, action, day)
			end)
			log:info("activity_report", { settlement = id, pass = pass, warn = warn, fail = fail })
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function scanLot(lotId: string, settlementId: string)
	local model = settlements:modelOf(lotId)
	if model then
		StationRegistry.scanLot(lotId, model, settlementId)
	end
end

function ActivityService.init(_self: any, ctx: any)
	log, flags = ctx.log, ctx.flags
	npcs = ctx.get("NPCService")
	settlements = ctx.get("SettlementService")
	playerData = ctx.get("PlayerDataService")
	StationRegistry.setLog(log)
	registerAdmin(ctx.get("AdminService"))
	npcs:setActivityHook(routeHook)
	Net.handle("NpcObserve", function(player: Player, npcId: string, detail: string)
		return observe(player, npcId, detail)
	end)
	ctx.bus:subscribe(Topics.BuildingBuilt, function(payload: any)
		task.defer(scanLot, payload.lotId, payload.settlementId)
	end)
	Players.PlayerRemoving:Connect(function(player)
		watching[player] = nil
		debugViewers[player] = nil
	end)
end

function ActivityService.start(_self: any, _ctx: any)
	-- Buildings that already exist (built before this service subscribed).
	task.spawn(function()
		local scanned = 0
		for _, town in npcs:towns() do
			local layout = settlements:layoutFor(town.id)
			for _, lot in (if layout then layout.lots else {}) :: { any } do
				if settlements:modelOf(lot.id) then
					scanLot(lot.id, town.id)
					scanned += 1
					if scanned % 8 == 0 then
						task.wait()
					end
				end
			end
		end
		-- Most buildings go up after boot (BuildingBuilt scans them as they do), so the count that means
		-- something comes later.
		task.wait(90)
		local total, bad = StationRegistry.counts()
		local n, b = 0, 0
		local byKind: { string } = {}
		for k, v in total do
			n += v
			b += bad[k] or 0
			table.insert(byKind, string.format("%s %d/%d", k, v - (bad[k] or 0), v))
		end
		table.sort(byKind)
		log:info("activity_stations", { atBoot = scanned, stations = n, invalid = b, usable = table.concat(byKind, " ") })
	end)
	RunService.Heartbeat:Connect(sweep)
end

-- For other services and specs.
function ActivityService.recordOf(_self: any, npc: any): any
	return npc.activity
end

function ActivityService.stats(_self: any): { [string]: number }
	return table.clone(stats)
end

return ActivityService
