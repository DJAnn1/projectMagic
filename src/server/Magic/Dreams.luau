--!strict
--[[
	Dreams: what someone dreams, from their innate profile (docs/Dreams.md; lines in Data/Dreams,
	the service is Services/DreamService). Pure: no services, no instances.

	SERVER ONLY. It reads hidden latents, so nothing here may be required from the client, and only
	the finished line ever leaves the server.

		eligible(profile) -> { Latent }        hidden latents a dream may hint at: unrevealed, never
		                                       Mythic, never on a mythic domain, and only kinds with lines
		clarity(prior, knowledge) -> 1..3      how clear a dream about one latent is, from how many
		                                       dreams about it came before and self-knowledge
		compose(latent, clarity, rng) -> text  image (1) + "it was mine" (2) + what might wake it (3)
		pick(profile, record, knowledge, worldSeed) -> Pick
		                                       tonight's dream; deterministic from
		                                       Seed.random(worldSeed, entityId, "dream", record.count)
		recalled(latent, worldSeed, entityId) -> text   the line when a dreamt latent awakens
		isNight(hour), sleepNeeded(hour)       how long you must lie in a bed before you drift off
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Magic = ReplicatedStorage.Shared.Magic
local Types = require(Magic.Types)
local Seed = require(Magic.Seed)
local Domains = require(Magic.Data.Domains)
local Data = require(script.Parent.Data.Dreams)

export type Record = {
	count: number, -- dreams had, ever (the seed's salt)
	lastAt: number, -- os.time() of the last dream
	lastDay: number, -- WorldClock.day() of the last dream
	seen: { [string]: number }, -- latent id -> dreams about it
	recalled: { [string]: number }, -- latent id -> os.time() you wrote that the dream came true
}

export type Pick = {
	text: string,
	ordinary: boolean,
	latentId: string?,
	kind: string?,
	clarity: number,
}

local Dreams = {}

local function choose(list: { string }, rng: Random): string
	return list[rng:NextInteger(1, #list)]
end

local function domainUsable(domainId: string): boolean
	local def = (Domains :: any)[domainId]
	return def ~= nil and def.rarity ~= "Mythic" and Data.domains[domainId] ~= nil
end

local function imagesFor(latent: Types.Latent): { string }?
	if latent.kind == "Domain" or latent.kind == "Amplify" then
		return if domainUsable(latent.target) then Data.domains[latent.target] else nil
	elseif latent.kind == "Capacity" then
		return Data.capacity
	elseif latent.kind == "Temperament" then
		return Data.temperaments[latent.target]
	end
	return nil -- Mythic, or a kind with no lines: never dreamt
end

function Dreams.eligible(profile: Types.InnateProfile): { Types.Latent }
	local out = {}
	for _, latent in (profile.latents or {}) :: { Types.Latent } do
		if not latent.revealed and latent.kind ~= "Mythic" and imagesFor(latent) ~= nil then
			table.insert(out, latent)
		end
	end
	return out
end

function Dreams.clarity(prior: number, knowledge: number): number
	local steps = math.floor(math.max(0, prior) / Data.clarityStep)
	if knowledge >= Data.knowledgeBonusAt then
		steps += 1
	end
	return math.clamp(1 + steps, 1, 3)
end

function Dreams.compose(latent: Types.Latent, clarity: number, rng: Random): string
	local images = imagesFor(latent)
	if not images then
		return choose(Data.ordinary, rng)
	end
	local parts = { choose(images, rng) }
	local kind = Data.kinds[latent.kind]
	if clarity >= 2 and kind then
		table.insert(parts, choose(kind.mine, rng))
	end
	if clarity >= 3 then
		local hints = {}
		for _, category in latent.triggers do
			if Data.triggers[category] then
				table.insert(hints, category)
			end
		end
		if #hints > 0 then
			table.sort(hints) -- stable order, so the seed alone decides
			table.insert(parts, choose(Data.triggers[hints[rng:NextInteger(1, #hints)]], rng))
		end
	end
	return table.concat(parts, " ")
end

function Dreams.pick(profile: Types.InnateProfile, record: Record, knowledge: number, worldSeed: number): Pick
	local rng = Seed.random(worldSeed, profile.entityId, "dream", record.count)
	local latents = Dreams.eligible(profile)
	if #latents == 0 or rng:NextNumber() < Data.ordinaryChance then
		return { text = choose(Data.ordinary, rng), ordinary = true, clarity = 0 }
	end
	table.sort(latents, function(a, b)
		return a.id < b.id
	end)
	local total = 0
	for _, latent in latents do
		total += math.max(latent.strength, 0.05)
	end
	local roll = rng:NextNumber() * total
	local chosen = latents[#latents]
	for _, latent in latents do
		roll -= math.max(latent.strength, 0.05)
		if roll <= 0 then
			chosen = latent
			break
		end
	end
	local clarity = Dreams.clarity(record.seen[chosen.id] or 0, knowledge)
	return {
		text = Dreams.compose(chosen, clarity, rng),
		ordinary = false,
		latentId = chosen.id,
		kind = chosen.kind,
		clarity = clarity,
	}
end

function Dreams.recalled(latent: Types.Latent, worldSeed: number, entityId: string): string
	local kind = Data.kinds[latent.kind] or Data.kinds.Domain
	local rng = Seed.random(worldSeed, entityId, "dream_recalled:" .. latent.id)
	return choose(kind.recalled, rng)
end

function Dreams.isNight(hour: number): boolean
	return hour >= Data.sleep.nightFrom or hour < Data.sleep.nightTo
end

function Dreams.sleepNeeded(hour: number): number
	return if Dreams.isNight(hour) then Data.sleep.night else Data.sleep.day
end

return Dreams
