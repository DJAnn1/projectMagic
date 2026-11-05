--!strict
--[[
	WorldConfig (server): dimensions, noise layers and budgets for world generation.
	See docs/World.md §1-§2 for why these numbers.

	The world is a square island continent centred on the origin, WORLD_SIZE studs across,
	split into CHUNK_SIZE chunks (built on demand) and REGION_SIZE regions (environment state).
]]

local WorldConfig = {
	WORLD_SIZE = 4096, -- studs; -2048..2048 on X and Z
	CHUNK_SIZE = 256, -- studs (64 voxels); 16 x 16 = 256 chunks
	REGION_SIZE = 128, -- studs; environment/stress cells (32 x 32 = 1024 regions)
	VOXEL = 4,
	SEA_LEVEL = 48,
	BEDROCK_Y = -64,
	MAX_HEIGHT = 480,
	SHELL_DEPTH = 24, -- studs of detailed voxels below the lowest surface point; deeper is one FillBlock of rock
	BIOME_STEP = 4, -- biome inputs sampled every N voxels and reused (cheap; surface materials stay per-voxel)

	-- Build pipeline
	STREAM_RADIUS_CHUNKS = 3, -- chunks kept built around each player (~768 studs)
	SPAWN_RADIUS_CHUNKS = 1, -- built at server start around the spawn
	SLAB_VOXELS = 16, -- vertical voxels per WriteVoxels call (32 x 16 x 32 = 16k cells)

	noise = {
		warp = { scale = 1 / 900, octaves = 2, amplitude = 180 },
		continent = { scale = 1 / 2200, octaves = 4, lacunarity = 2.0, gain = 0.5 },
		hills = { scale = 1 / 260, octaves = 3, lacunarity = 2.1, gain = 0.5 },
		ridges = { scale = 1 / 900, octaves = 4, lacunarity = 2.0, gain = 0.55 },
		temperature = { scale = 1 / 1800, octaves = 2, lacunarity = 2.0, gain = 0.5 },
		moisture = { scale = 1 / 1300, octaves = 3, lacunarity = 2.0, gain = 0.5 },
		magic = { scale = 1 / 1100, octaves = 3, lacunarity = 2.0, gain = 0.5 },
		faults = { scale = 1 / 1400, octaves = 3, lacunarity = 2.0, gain = 0.5 },
		ancient = { scale = 1 / 1600, octaves = 2, lacunarity = 2.0, gain = 0.5 },
		caves = { scale = 1 / 48, octaves = 2, lacunarity = 2.0, gain = 0.5 },
		detail = { scale = 1 / 40, octaves = 1, lacunarity = 2.0, gain = 0.5 },
	},

	terrain = {
		shore = -0.05, -- continental value of the coastline
		edgeFalloffStart = 0.72, -- share of the half-width where the continent starts sinking into ocean
		edgeFalloffStrength = 3.5,
		seaFloorMin = -40,
		landBase = 90, -- studs of rise from coast to inland plateau
		hillAmplitude = 22,
		mountainHeight = 330,
		cliffSlope = 1.15, -- height change per stud above which surfaces become rock
	},

	-- Ley lines
	ley = {
		cell = 560, -- one nexus candidate per cell (jittered grid): 7 x 7 = 49 candidates
		acceptMagic = 0.45, -- magic noise needed for a candidate to become a nexus
		extraEdgeMaxLength = 1500,
		lineWidth = 48, -- studs of strong influence either side of a line
		lineBoost = 0.7, -- added density at the line centre
		nexusRadius = 90,
		nexusBoost = 1.6,
	},

	-- Environment
	stress = {
		regenPerDay = 0.08, -- tectonic stress regained per real day (lazy, computed from timestamps)
		max = 1.0,
		transfer = 0.15, -- share of released stress pushed into neighbouring regions
	},

	-- Persistence
	deltas = {
		maxOpsPerChunk = 600,
		flushSeconds = 45,
		smallOpRadius = 6, -- pruned first when a chunk log is full
	},
}

return WorldConfig
