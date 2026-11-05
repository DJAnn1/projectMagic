--!strict
--[[
	Codec: packs large structures (discovery logs, world chronicle, NPC memories) into a string
	so they take less of the 4 MB-per-key DataStore limit.

		"Z1:<base64(zstd(json))>"   compressed (EncodingService)
		"J1:<json>"                 uncompressed fallback

	Compression is self-tested at load. If EncodingService or zstd isn't available, or the round
	trip fails, every encode falls back to J1. Decoding understands both formats forever, so
	turning compression on or off never breaks old saves.
	Small values (< MIN_COMPRESS_BYTES of JSON) are stored as J1: the base64 overhead would make them bigger.
]]

local HttpService = game:GetService("HttpService")

local Logger = require(game:GetService("ReplicatedStorage").Shared.Core.Logger)

local Codec = {}

local MIN_COMPRESS_BYTES = 1024
local ZSTD_LEVEL = 3

local log = Logger.new("Codec")
local encodingService: any = nil
local compressionAvailable = false

local function compress(json: string): string
	local input = buffer.fromstring(json)
	local packed = encodingService:CompressBuffer(input, (Enum :: any).CompressionAlgorithm.Zstd, ZSTD_LEVEL)
	return buffer.tostring(encodingService:Base64Encode(packed))
end

local function decompress(text: string): string
	local packed = encodingService:Base64Decode(buffer.fromstring(text))
	return buffer.tostring(encodingService:DecompressBuffer(packed, (Enum :: any).CompressionAlgorithm.Zstd))
end

do
	local ok, service = pcall(game.GetService, game, "EncodingService")
	if ok and service then
		encodingService = service
		local sample = string.rep('{"probe":"compression self-test"}', 64)
		local testOk, roundTrip = pcall(function()
			return decompress(compress(sample))
		end)
		compressionAvailable = testOk and roundTrip == sample
	end
	if not compressionAvailable then
		log:warn("compression_unavailable", { fallback = "J1" })
	end
end

function Codec.isCompressionAvailable(): boolean
	return compressionAvailable
end

function Codec.encode(value: any, allowCompression: boolean?): string
	local json = HttpService:JSONEncode(value)
	if allowCompression ~= false and compressionAvailable and #json >= MIN_COMPRESS_BYTES then
		local ok, packed = pcall(compress, json)
		if ok and #packed + 3 < #json then
			return "Z1:" .. packed
		end
	end
	return "J1:" .. json
end

-- True if `value` looks like something Codec.encode produced.
function Codec.isEncoded(value: any): boolean
	if typeof(value) ~= "string" then
		return false
	end
	local prefix = string.sub(value, 1, 3)
	return prefix == "Z1:" or prefix == "J1:"
end

-- Errors on corrupt input; callers decide whether that's fatal.
function Codec.decode(text: string): any
	local prefix, body = string.sub(text, 1, 3), string.sub(text, 4)
	if prefix == "J1:" then
		return HttpService:JSONDecode(body)
	elseif prefix == "Z1:" then
		assert(encodingService, "Codec: compressed data but EncodingService unavailable")
		return HttpService:JSONDecode(decompress(body))
	end
	error("Codec: unknown format " .. prefix)
end

return Codec
