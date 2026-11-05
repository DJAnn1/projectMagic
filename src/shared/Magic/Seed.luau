--!strict
--[[
	Seed
	Deterministic seeds for procedural generation, derived from (worldSeed, entityId, system).
	The same inputs always give the same Random stream, on any server, forever, so any
	generated thing can be reproduced instead of saved.

	Hash: 32-bit FNV-1a. The multiply by the FNV prime (16777619 = 2^24 + 403) is split so
	intermediate values stay below 2^53 and double precision never rounds them.
]]

local Seed = {}

local FNV_OFFSET = 2166136261
local TWO_32 = 4294967296

local function fnv1a(str: string): number
	local h = FNV_OFFSET
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (bit32.lshift(h, 24) + h * 403) % TWO_32
	end
	return h
end

-- worldSeed must be an integer. salt distinguishes repeated draws (e.g. a cast counter).
function Seed.derive(worldSeed: number, entityId: string, system: string, salt: number?): number
	return fnv1a(string.format("%.0f|%s|%s|%.0f", worldSeed, entityId, system, salt or 0))
end

function Seed.random(worldSeed: number, entityId: string, system: string, salt: number?): Random
	return Random.new(Seed.derive(worldSeed, entityId, system, salt))
end

return Seed
