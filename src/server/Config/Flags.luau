--!strict
--[[
	Feature flag definitions (server). Change at runtime with the admin console:
		flag net_kick_on_abuse true
	`replicate = true` makes a flag readable by clients. Never replicate anything secret.
]]

return {
	-- Logging
	log_level = { default = "Info", replicate = true, description = "Minimum log level: Debug | Info | Warn | Error." },

	-- Net
	net_kick_on_abuse = { default = false, description = "Kick players whose remote rejections exceed the threshold within a minute." },
	net_violation_threshold = { default = 60, description = "Remote rejections per minute before the abuse kick." },

	-- Data
	data_use_mock_in_studio = { default = true, description = "Use an in-memory DataStore in Studio so play-tests never touch live data." },
	data_autosave_seconds = { default = 60, description = "Autosave interval per session (minimum 15)." },
	data_compression = { default = true, description = "Compress large fields (if EncodingService is available)." },

	-- World
	world_messaging = { default = true, description = "Publish and receive cross-server world events via MessagingService." },
	world_studio_seed = { default = 1337, description = "World seed used in Studio mock mode, so test profiles stay stable." },

	-- World generation
	terrain_generate_at_runtime = { default = true, description = "Generate chunk terrain at runtime. Off = terrain was baked into the place; only edits are replayed." },
	world_build_budget_ms = { default = 4, description = "Per-frame time budget for terrain and world jobs (Scheduler)." },
	world_events_enabled = { default = true, description = "Run the world EventDirector." },

	-- Gameplay kill switches
	pvp_enabled = { default = true, description = "Spells, melee, fire and disasters can hurt other players (the caster is always affected). On for everyone since 2026-11-03." },
	quests_enabled = { default = true, description = "Quest Director: situations, offers, quest progress and outcomes (Services/QuestDirector)." },
	combat_anim_debug = { default = false, replicate = true, description = "Show each nearby character's and NPC's action state over its head (client labels; every client sees them, so Studio use)." },
	combat_debug_log = { default = false, description = "Log every cast's damage breakdown (power, base, each target's damage, crits, kills) at Info level." },
	magic_casting_enabled = { default = true, replicate = true, description = "Global kill switch for casting." },
	npc_enabled = { default = true, description = "Simulate settlement NPCs (NPCService)." },
	npc_day_seconds = { default = 1440, description = "Real seconds per game day (NPC schedules, day/night)." },
	npc_population_mult = { default = 1, description = "Multiplier on every settlement's simulated population (0.25-3)." },
	npc_parallel = { default = true, description = "Score far (Tier 2) NPCs on Actors (ParallelPool) when there are many." },
	npc_day_night = { default = true, description = "Drive Lighting.ClockTime from the NPC game clock." },
	npc_studio_start_hour = { default = 9, description = "Studio (mock store) only: the game hour a fresh world's clock starts at, so NPCs aren't asleep on every Play." },
	npc_llm_dialogue = { default = false, description = "Let DialogueEngine.renderer rewrite NPC lines (output is always text-filtered)." },
	ui_enabled = { default = true, replicate = true, description = "Player interface (HUD, Grimoire, Composer). Off = no player UI (the Admin Panel still works for admins)." },
	awakenings_enabled = { default = true, description = "Allow awakening events to apply." },
	items_enabled = { default = true, replicate = true, description = "Inventory actions (move, equip, use, drop). Off = inventories are read-only (gear still applies)." },
	interact_enabled = { default = true, description = "Prompts on doors, beds, containers and stations do something (InteractionService)." },
	housing_enabled = { default = true, description = "Players can buy houses and place furniture (HousingService). Off hides the for-sale signs." },
	buildings_lock_doors = { default = true, description = "Locked doors need a key, magic or a lockpick. Off = every door opens (testing)." },
	items_debug_log = { default = false, description = "Log every successful inventory operation (op, refs, counts) at Info level." },

	-- Debug (Studio only)
	foundation_markers = { default = true, description = "Red markers where a building's foundation check found terrain above the floor bottom or grass under it (SettlementService)." },
	debug_run_tests = { default = true, description = "Run unit specs and magic examples on Studio boot." },
	debug_profile_stats = { default = true, description = "Run the innate profile statistics on Studio boot (~3 s)." },
	debug_journey_sim = { default = true, description = "Run the 30-hour progression journey simulation on Studio boot." },
}
