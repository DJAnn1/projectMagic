--!strict
--[[
	SpellAudit: what the spell grammar can actually DO (docs/SpellOverhaul.md §2G). Enumerates
	every recipe the grammar allows (branch x its properties x verbs x forms, by the same rules as
	MagicCore.listAvailableRecipes, but ignoring anyone's mastery: what's possible at all) at one
	power, sends each through SpellRoute.find (the router CastService and the Composer use), and
	counts where they land. The number to watch over the spell overhaul is the share that lands in
	the two catch-alls: `harm` (plain damage, Effects/Impact) and `manifest` (no real effect).

		SpellAudit.run(opts) -> Report
			opts.power    recipe power (routes have minPower: disasters need 5+, tsunami 8)
			opts.domain   only branches of this domain
			opts.yield    called every few thousand recipes (an admin command passes task.wait)
		SpellAudit.lines(report, top) -> { string }   a readable summary
		SpellAudit.firstDead(power?) -> recipe?       a still-dead recipe, if any is left
]]

local Registry = require(script.Parent.Registry)
local SpellRoute = require(script.Parent.SpellRoute)
local Behaviours = require(script.Parent.Data.PropertyBehaviours)

export type Report = {
	power: number,
	total: number,
	byRoute: { [string]: number },
	harmByProperty: { [string]: number },
	manifestByProperty: { [string]: number },
}

local SpellAudit = {}

local YIELD_EVERY = 4000

function SpellAudit.run(opts: { power: number?, domain: string?, yield: (() -> ())? }): Report
	local power = opts.power or 5
	local report: Report = { power = power, total = 0, byRoute = {}, harmByProperty = {}, manifestByProperty = {} }
	local sinceYield = 0
	for _, branchId in Registry.branchIds do
		local branch = Registry.branches[branchId]
		if opts.domain and not table.find(branch.domains, opts.domain) then
			continue
		end
		for _, propertyId in branch.properties do
			local category = Registry.properties[propertyId].category
			for _, verbId in Registry.verbIds do
				if Registry.verbs[verbId].minTier > branch.tier or Registry.verbPropertyEff[verbId][propertyId] <= 0 then
					continue
				end
				for _, formId in Registry.formIds do
					local form = Registry.forms[formId]
					if form.minTier > branch.tier or Registry.formVerbEff[formId][verbId] <= 0 or Registry.formCategoryBlocked[formId][category] then
						continue
					end
					local route = SpellRoute.find({ branch = branchId, property = propertyId, verb = verbId, form = formId, power = power } :: any)
					report.total += 1
					report.byRoute[route.id] = (report.byRoute[route.id] or 0) + 1
					if route.id == "harm" then
						report.harmByProperty[propertyId] = (report.harmByProperty[propertyId] or 0) + 1
					elseif route.id == "manifest" then
						report.manifestByProperty[propertyId] = (report.manifestByProperty[propertyId] or 0) + 1
					end
					sinceYield += 1
					if opts.yield and sinceYield >= YIELD_EVERY then
						sinceYield = 0
						opts.yield()
					end
				end
			end
		end
	end
	return report
end

-- The first recipe the grammar allows that still does nothing (routes to `manifest`), or nil when
-- none is left (the goal of stages 1b to 1d). The specs use it for the "dead spell" cases instead
-- of naming one that a later stage would fix.
function SpellAudit.firstDead(power: number?): { [string]: any }?
	local p = power or 3
	for _, branchId in Registry.branchIds do
		local branch = Registry.branches[branchId]
		for _, propertyId in branch.properties do
			local category = Registry.properties[propertyId].category
			for _, verbId in Registry.verbIds do
				if Registry.verbs[verbId].minTier > branch.tier or Registry.verbPropertyEff[verbId][propertyId] <= 0 then
					continue
				end
				for _, formId in Registry.formIds do
					local form = Registry.forms[formId]
					if form.minTier > branch.tier or Registry.formVerbEff[formId][verbId] <= 0 or Registry.formCategoryBlocked[formId][category] then
						continue
					end
					local recipe = { branch = branchId, property = propertyId, verb = verbId, form = formId, power = p }
					if SpellRoute.find(recipe :: any).id == "manifest" then
						return recipe
					end
				end
			end
		end
	end
	return nil
end

local function sorted(map: { [string]: number }): { { id: string, n: number } }
	local out: { { id: string, n: number } } = {}
	for id, n in map do
		table.insert(out, { id = id, n = n })
	end
	table.sort(out, function(a, b)
		return if a.n == b.n then a.id < b.id else a.n > b.n
	end)
	return out
end

local function pct(n: number, total: number): string
	return string.format("%.1f%%", if total > 0 then n / total * 100 else 0)
end

function SpellAudit.lines(report: Report, top: number): { string }
	local total = report.total
	local harm = report.byRoute.harm or 0
	local manifest = report.byRoute.manifest or 0
	local plain = 0 -- harm with no property behaviour: still nothing but damage
	for propertyId, n in report.harmByProperty do
		if not Behaviours[propertyId] then
			plain += n
		end
	end
	local lines = {
		string.format("%d recipes the grammar allows at power %d (any mastery)", total, report.power),
		string.format("plain damage (harm): %d (%s) · no real effect (manifest): %d (%s) · everything else: %s",
			harm, pct(harm, total), manifest, pct(manifest, total), pct(total - harm - manifest, total)),
		string.format("of the harm, %d (%s) have a property behaviour; still nothing but damage: %d (%s)",
			harm - plain, pct(harm - plain, total), plain, pct(plain, total)),
		"routes, most used first:",
	}
	for i, entry in sorted(report.byRoute) do
		if i > top then
			break
		end
		table.insert(lines, string.format("  %-16s %6d  %s", entry.id, entry.n, pct(entry.n, total)))
	end
	local harmList = {}
	for _, entry in sorted(report.harmByProperty) do
		table.insert(harmList, string.format("%s %d%s", entry.id, entry.n, if Behaviours[entry.id] then "" else " (no behaviour)"))
	end
	table.insert(lines, "harm by property: " .. (if #harmList > 0 then table.concat(harmList, ", ") else "none"))
	local deadList = {}
	for i, entry in sorted(report.manifestByProperty) do
		if i > top then
			break
		end
		table.insert(deadList, string.format("%s %d", entry.id, entry.n))
	end
	table.insert(lines, "no effect by property (top): " .. (if #deadList > 0 then table.concat(deadList, ", ") else "none"))
	return lines
end

return SpellAudit
