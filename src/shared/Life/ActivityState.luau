--!strict
--[[
	ActivityState: the one replicated record of what an NPC is doing (docs/Activities.md §1).

	The server (Services/ActivityService) owns it and writes it as ONE string attribute on the NPC's rig,
	NpcActivity, only when something changes (a new activity, a new phase). Clients decode it and render
	everything locally from it plus the shared clock (workspace:GetServerTimeNow()): which props are out,
	the pose, its rhythm, how far the work has got. Nothing per frame crosses the network.

		"<index>|<phase>|<phaseAt>|<start>|<duration>|<station>|<reason>|<variant>|<item>|<tier>|<domain>"

		index     ActivityLibrary index (0 = none)
		phase     T Travelling · P Preparing · W Performing · F Finishing · I Interrupted
		phaseAt   server time the phase began (Preparing and Finishing blend the pose in and out)
		start     server time the work began. Progress is (now - start) / duration and loops: each loop is
		          one finished piece (a blade done, the next begun). An interruption moves start on by
		          its length, so progress carries on from where it stopped instead of jumping.
		duration  seconds for one piece of work
		station   the station's StationId, or "" at a spot
		reason    ActivityLibrary.reasons id
		variant   which of the pose's variants this person moves with
		item      which of the activity's items this piece is (the next piece takes the next one)
		tier      their mastery tier in the activity's domain (magic practice; 0 otherwise)
		domain    the magic domain shown (practice), or ""
]]

export type Phase = "T" | "P" | "W" | "F" | "I"

export type State = {
	index: number,
	phase: Phase,
	phaseAt: number,
	start: number,
	duration: number,
	station: string,
	reason: string,
	variant: number,
	item: number,
	tier: number,
	domain: string,
}

local ActivityState = {}

ActivityState.ATTR = "NpcActivity"
ActivityState.PREPARE_SECONDS = 1.4 -- getting the tools out, settling in
ActivityState.FINISH_SECONDS = 1.4 -- putting them away

ActivityState.phaseNames = table.freeze({
	T = "Travelling",
	P = "Preparing",
	W = "Performing",
	F = "Finishing",
	I = "Interrupted",
}) :: { [string]: string }

function ActivityState.new(index: number, now: number): State
	return {
		index = index,
		phase = "T",
		phaseAt = now,
		start = now,
		duration = 60,
		station = "",
		reason = "",
		variant = 1,
		item = 1,
		tier = 0,
		domain = "",
	}
end

local function clean(s: string): string
	return (string.gsub(s, "|", "/"))
end

function ActivityState.encode(s: State): string
	return string.format(
		"%d|%s|%.2f|%.2f|%.1f|%s|%s|%d|%d|%d|%s",
		s.index, s.phase, s.phaseAt, s.start, s.duration, clean(s.station), clean(s.reason), s.variant, s.item, s.tier, clean(s.domain)
	)
end

-- Nil for anything that isn't a well-formed record (an old server, a cleared attribute).
function ActivityState.decode(raw: any): State?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local f = string.split(raw, "|")
	if #f < 11 then
		return nil
	end
	local phase = f[2]
	if not ActivityState.phaseNames[phase] then
		return nil
	end
	local index = tonumber(f[1])
	if not index then
		return nil
	end
	return {
		index = index,
		phase = phase :: Phase,
		phaseAt = tonumber(f[3]) or 0,
		start = tonumber(f[4]) or 0,
		duration = math.max(tonumber(f[5]) or 60, 1),
		station = f[6],
		reason = f[7],
		variant = tonumber(f[8]) or 1,
		item = tonumber(f[9]) or 1,
		tier = tonumber(f[10]) or 0,
		domain = f[11],
	}
end

-- (progress through the current piece 0..1, pieces finished so far). Before the work starts: (0, 0).
function ActivityState.progress(s: State, now: number): (number, number)
	if s.phase ~= "W" and s.phase ~= "I" and s.phase ~= "F" then
		return 0, 0
	end
	local elapsed = math.max(0, now - s.start)
	if s.phase == "I" then
		elapsed = math.max(0, s.phaseAt - s.start) -- frozen where they stopped
	end
	local pieces = math.floor(elapsed / s.duration)
	return (elapsed - pieces * s.duration) / s.duration, pieces
end

-- How much of the pose shows (0..1): it eases in while Preparing and out while Finishing.
function ActivityState.weight(s: State, now: number): number
	if s.phase == "W" then
		return 1
	elseif s.phase == "P" then
		return math.clamp((now - s.phaseAt) / ActivityState.PREPARE_SECONDS, 0, 1)
	elseif s.phase == "F" then
		return 1 - math.clamp((now - s.phaseAt) / ActivityState.FINISH_SECONDS, 0, 1)
	end
	return 0
end

-- Are the held props out in this phase? Finishing puts them away part-way through the ease-out.
function ActivityState.propsOut(s: State, now: number, carry: boolean?, interrupt: string?): boolean
	if s.phase == "W" or s.phase == "P" then
		return true
	elseif s.phase == "F" then
		return now - s.phaseAt < ActivityState.FINISH_SECONDS * 0.6
	elseif s.phase == "I" then
		return interrupt ~= "setDown"
	end
	return carry == true -- Travelling
end

return ActivityState
