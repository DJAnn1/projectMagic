--!strict
--[[
	Noise: seeded layers over math.noise (Roblox's built-in Perlin noise).

	math.noise has no seed parameter, so each layer gets a seed-derived offset (x, y-plane, z).
	The same seed gives the same offsets on every server, so generation is deterministic.
	Offsets include a fractional part: math.noise returns 0 at integer lattice points.

	Output ranges: fbm ~ [-1, 1] (rarely beyond ±0.7), ridged [0, 1].
]]

local Seed = require(game:GetService("ReplicatedStorage").Shared.Magic.Seed)

export type Layer = {
	ox: number,
	oy: number,
	oz: number,
	scale: number,
	octaves: number,
	lacunarity: number,
	gain: number,
}

export type LayerConfig = {
	scale: number,
	octaves: number,
	lacunarity: number?,
	gain: number?,
	amplitude: number?,
}

local Noise = {}

function Noise.layer(seed: number, name: string, config: LayerConfig): Layer
	local function offset(axis: string): number
		return (Seed.derive(seed, name, "noise:" .. axis) % 200000) / 7.31 + 0.371
	end
	return {
		ox = offset("x"),
		oy = offset("y"),
		oz = offset("z"),
		scale = config.scale,
		octaves = config.octaves,
		lacunarity = config.lacunarity or 2,
		gain = config.gain or 0.5,
	}
end

-- Fractal Brownian motion, normalised by the amplitude sum.
function Noise.fbm(layer: Layer, x: number, z: number): number
	local total, amplitude, frequency, norm = 0, 1, layer.scale, 0
	for _ = 1, layer.octaves do
		total += math.noise(x * frequency + layer.ox, layer.oy, z * frequency + layer.oz) * amplitude
		norm += amplitude
		amplitude *= layer.gain
		frequency *= layer.lacunarity
	end
	return total / norm * 2 -- math.noise mostly stays within ±0.5
end

-- Ridged noise: sharp crests along the zero-crossings of Perlin noise. 0..1.
function Noise.ridged(layer: Layer, x: number, z: number): number
	local total, amplitude, frequency, norm = 0, 1, layer.scale, 0
	for _ = 1, layer.octaves do
		local n = 1 - math.abs(math.noise(x * frequency + layer.ox, layer.oy, z * frequency + layer.oz) * 2)
		total += n * n * amplitude
		norm += amplitude
		amplitude *= layer.gain
		frequency *= layer.lacunarity
	end
	return math.clamp(total / norm, 0, 1)
end

-- 3D fbm (caves).
function Noise.fbm3(layer: Layer, x: number, y: number, z: number): number
	local total, amplitude, frequency, norm = 0, 1, layer.scale, 0
	for _ = 1, layer.octaves do
		total += math.noise(x * frequency + layer.ox, y * frequency + layer.oy, z * frequency + layer.oz) * amplitude
		norm += amplitude
		amplitude *= layer.gain
		frequency *= layer.lacunarity
	end
	return total / norm * 2
end

-- Domain warping: offsets the sample point so coastlines and ridges meander.
function Noise.warp(layer: Layer, x: number, z: number, amplitude: number): (number, number)
	local wx = Noise.fbm(layer, x, z)
	local wz = Noise.fbm(layer, x + 5231.7, z - 3917.3)
	return x + wx * amplitude, z + wz * amplitude
end

function Noise.smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

return Noise
