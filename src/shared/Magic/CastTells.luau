--!strict
--[[
	CastTells: what a forming spell gives away (docs/ReadTheCast.md; numbers in Data/CastTells).

		CastTells.kindOf(recipe) -> string        the RouteSummaries kind (Magic/SpellOutcome); the server
		                                          sets it as the character attribute AttunedKind
		CastTells.tellFor(kind) -> Tell           how that kind moves (unknown kinds: the fallback)
		CastTells.scaleFor(power) -> number       how much bigger a stronger spell forms
		CastTells.pitchFor(power) -> number       how much deeper its hum
]]

local Data = require(script.Parent.Data.CastTells)
local SpellOutcome = require(script.Parent.SpellOutcome)

local CastTells = {}

function CastTells.kindOf(recipe: SpellOutcome.RecipeLike): string
	local ok, outcome = pcall(SpellOutcome.of, recipe)
	local kind = if ok and outcome then outcome.kind else nil
	return if typeof(kind) == "string" and Data.kinds[kind] then kind else Data.fallback
end

function CastTells.tellFor(kind: string?): Data.Tell
	return Data.kinds[kind or Data.fallback] or Data.kinds[Data.fallback]
end

function CastTells.scaleFor(power: number?): number
	local p = math.max(1, power or 1)
	return math.min(Data.scaleMax, 1 + Data.scalePerPower * (p - 1))
end

function CastTells.pitchFor(power: number?): number
	local p = math.max(1, power or 1)
	return math.max(Data.pitchMin, 1 - Data.pitchPerPower * (p - 1))
end

return CastTells
