--!strict
--[[
	SenseRules: the pure part of Sense sight (docs/SenseSight.md). No Instances, no services, so the
	spec can test all of it.

		SenseRules.kindFor(propertyId)            -> "heat" | "metal" | "ley" | "tracks" | nil
		SenseRules.radiusFor(power, area)         -> studs you see to
		SenseRules.durationFor(power)             -> seconds it lasts
		SenseRules.clipSegment(ax, az, bx, bz, cx, cz, r) -> the part of segment AB inside the circle,
		                                             as (x1, z1, x2, z2), or nil if it misses
		SenseRules.newTracks()                    -> a TrackStore (below)

	TrackStore: where everyone walked lately, on a grid.
		store:step(key, position, now, kind, grounded)   called every sample for every mover; leaves a
		                                                 print once they've moved minStep since their last
		store:query(center, radius, now, exclude?, max)  prints within radius, newest first, at most max;
		                                                 `exclude` is a mover key (the caster)
		store:prune(now)                                 forget prints older than keepSeconds
		store:count()                                    prints held
	A print: { x, y, z, t, heading (radians, 0 = +Z), kind ("person" | "beast"), key }.
	Memory: at most perCell prints per 16-stud cell, and only cells someone walked through.
]]

local Data = require(script.Parent.Data.SenseSight)

local SenseRules = {}

local byProperty: { [string]: string } = {}
for kindId, kind in Data.kinds do
	for _, property in kind.properties do
		byProperty[property] = kindId
	end
end

function SenseRules.kindFor(propertyId: string): string?
	return byProperty[propertyId]
end

function SenseRules.radiusFor(power: number, area: number?): number
	local r = Data.radius
	return math.min(r.max, math.max(area or 0, r.base + r.perPower * math.max(0, power)))
end

function SenseRules.durationFor(power: number): number
	local d = Data.duration
	return math.min(d.max, d.base + d.perPower * math.max(0, power))
end

-- The part of segment A->B (2D, x/z) inside the circle (centre C, radius r).
function SenseRules.clipSegment(ax: number, az: number, bx: number, bz: number, cx: number, cz: number, r: number): (number?, number?, number?, number?)
	local dx, dz = bx - ax, bz - az
	local fx, fz = ax - cx, az - cz
	local a = dx * dx + dz * dz
	if a < 1e-9 then
		if fx * fx + fz * fz <= r * r then
			return ax, az, bx, bz
		end
		return nil, nil, nil, nil
	end
	local b = 2 * (fx * dx + fz * dz)
	local c = fx * fx + fz * fz - r * r
	local disc = b * b - 4 * a * c
	if disc < 0 then
		return nil, nil, nil, nil
	end
	local root = math.sqrt(disc)
	local t1 = math.max(0, (-b - root) / (2 * a))
	local t2 = math.min(1, (-b + root) / (2 * a))
	if t1 > t2 then
		return nil, nil, nil, nil
	end
	return ax + dx * t1, az + dz * t1, ax + dx * t2, az + dz * t2
end

-- ─── Tracks ─────────────────────────────────────────────────────────────────

export type Print = { x: number, y: number, z: number, t: number, heading: number, kind: string, key: string }
type Last = { x: number, z: number, t: number }

local TrackStore = {}
TrackStore.__index = TrackStore

export type TrackStore = typeof(setmetatable({} :: { cells: { [string]: { Print } }, last: { [string]: Last } }, TrackStore))

function SenseRules.newTracks(): TrackStore
	return setmetatable({ cells = {}, last = {} }, TrackStore)
end

local function cellKey(x: number, z: number): string
	local size = Data.tracks.cell
	return math.floor(x / size) .. "," .. math.floor(z / size)
end

function TrackStore.step(self: TrackStore, key: string, position: Vector3, now: number, kind: string, grounded: boolean)
	local last = self.last[key]
	if not last then
		self.last[key] = { x = position.X, z = position.Z, t = now }
		return
	end
	local dx, dz = position.X - last.x, position.Z - last.z
	if dx * dx + dz * dz < Data.tracks.minStep * Data.tracks.minStep then
		return
	end
	last.x, last.z, last.t = position.X, position.Z, now
	if not grounded then
		return -- flying, falling, swimming: you moved but left no print
	end
	local list = self.cells[cellKey(position.X, position.Z)]
	if not list then
		list = {}
		self.cells[cellKey(position.X, position.Z)] = list
	end
	table.insert(list, { x = position.X, y = position.Y, z = position.Z, t = now, heading = math.atan2(dx, dz), kind = kind, key = key })
	while #list > Data.tracks.perCell do
		table.remove(list, 1)
	end
end

-- A mover that left the world (a player gone, an NPC rig released): its next appearance starts fresh.
function TrackStore.forget(self: TrackStore, key: string)
	self.last[key] = nil
end

function TrackStore.query(self: TrackStore, center: Vector3, radius: number, now: number, exclude: string?, max: number): { Print }
	local size = Data.tracks.cell
	local keep = Data.tracks.keepSeconds
	local found: { Print } = {}
	local r2 = radius * radius
	for cx = math.floor((center.X - radius) / size), math.floor((center.X + radius) / size) do
		for cz = math.floor((center.Z - radius) / size), math.floor((center.Z + radius) / size) do
			local list = self.cells[cx .. "," .. cz]
			if list then
				for _, p in list do
					local dx, dz = p.x - center.X, p.z - center.Z
					if now - p.t <= keep and p.key ~= exclude and dx * dx + dz * dz <= r2 then
						table.insert(found, p)
					end
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return a.t > b.t
	end)
	while #found > max do
		table.remove(found)
	end
	return found
end

function TrackStore.prune(self: TrackStore, now: number)
	local keep = Data.tracks.keepSeconds
	for key, list in self.cells do
		while list[1] and now - list[1].t > keep do
			table.remove(list, 1)
		end
		if #list == 0 then
			self.cells[key] = nil
		end
	end
	for key, last in self.last do
		if now - last.t > keep * 4 then
			self.last[key] = nil -- not seen moving for a long while
		end
	end
end

function TrackStore.count(self: TrackStore): number
	local n = 0
	for _, list in self.cells do
		n += #list
	end
	return n
end

return SenseRules
