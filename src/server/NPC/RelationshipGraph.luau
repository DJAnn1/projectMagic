--!strict
--[[
	RelationshipGraph: who feels what about whom. Directed edges (A's view of B can differ from
	B's view of A). Nodes are NPC ids or players as "u:<userId>".

		Edge = { affinity -1..1, trust 0..1, rivalry 0..1, bond? }
		bond: "spouse" | "parent" | "child" | "sibling" | "mentor" | "student" | "rival" | "coworker"

	SEEDED from generation (deterministic, so never saved):
		households   spouses (two adults), parent/child (16+ year gap), siblings (the rest)
		coworkers    same occupation in the same settlement: acquaintances
		compatibility  a baseline from how alike their temperaments are and shared values
	CHANGED by events: chatting (compatibility-weighted), gossip-driven opinion, duels, teaching,
	help, attacks, magic seen (quirk likes/distrusts by domain).

	OPINION = affinity on the edge + what memory says (MemoryService.opinion), blended: the edge
	is the long-term relationship, memory is how recent events colour it.
]]

local Quirks = require(script.Parent.Data.Quirks)

export type Edge = { affinity: number, trust: number, rivalry: number, bond: string? }

local RelationshipGraph = {}

local edges: { [string]: { [string]: Edge } } = {}

function RelationshipGraph.clear()
	table.clear(edges)
end

function RelationshipGraph.peek(from: string, to: string): Edge?
	local row = edges[from]
	return row and row[to]
end

function RelationshipGraph.get(from: string, to: string): Edge
	local row = edges[from]
	if not row then
		row = {}
		edges[from] = row
	end
	local edge = row[to]
	if not edge then
		edge = { affinity = 0, trust = 0.2, rivalry = 0 }
		row[to] = edge
	end
	return edge
end

function RelationshipGraph.adjust(from: string, to: string, dAffinity: number, dTrust: number, dRivalry: number?)
	local e = RelationshipGraph.get(from, to)
	e.affinity = math.clamp(e.affinity + dAffinity, -1, 1)
	e.trust = math.clamp(e.trust + dTrust, 0, 1)
	e.rivalry = math.clamp(e.rivalry + (dRivalry or 0), 0, 1)
end

function RelationshipGraph.setBond(from: string, to: string, bond: string?)
	RelationshipGraph.get(from, to).bond = bond
end

-- 0..1: how naturally two people get along (temperament distance + shared values).
function RelationshipGraph.compatibility(a: any, b: any): number
	local diff = 0
	for _, t in { "agreeableness", "extraversion", "openness", "humor", "conscientiousness" } do
		diff += math.abs((a.traits[t] or 0.5) - (b.traits[t] or 0.5))
	end
	local c = 1 - diff / 5
	for _, v in a.values do
		if table.find(b.values, v) then
			c += 0.1
		end
	end
	return math.clamp(c, 0, 1)
end

-- Builds the deterministic part of the graph for a settlement's residents.
function RelationshipGraph.seed(npcs: { any })
	local byHome: { [string]: { any } } = {}
	local byJob: { [string]: { any } } = {}
	for _, npc in npcs do
		byHome[npc.household] = byHome[npc.household] or {}
		table.insert(byHome[npc.household], npc)
		if npc.occupation ~= "child" and npc.occupation ~= "retired" then
			local key = npc.settlementId .. "|" .. npc.occupation
			byJob[key] = byJob[key] or {}
			table.insert(byJob[key], npc)
		end
	end
	for _, members in byHome do
		for _, a in members do
			for _, b in members do
				if a ~= b then
					local gap = a.age - b.age
					local bond = if gap >= 16 then "parent"
						elseif gap <= -16 then "child"
						elseif a.ageBand ~= "child" and b.ageBand ~= "child" and math.abs(gap) < 16 then "spouse"
						else "sibling"
					local e = RelationshipGraph.get(a.id, b.id)
					e.bond = bond
					e.affinity = 0.45 + 0.3 * RelationshipGraph.compatibility(a, b) + 0.15 * (a.traits.loyalty or 0.5)
					e.trust = 0.6 + 0.3 * (a.traits.loyalty or 0.5)
				end
			end
		end
	end
	for _, workers in byJob do
		for _, a in workers do
			for _, b in workers do
				if a ~= b then
					local e = RelationshipGraph.get(a.id, b.id)
					if not e.bond then
						e.bond = "coworker"
						e.affinity = 0.05 + 0.2 * RelationshipGraph.compatibility(a, b)
						e.trust = 0.35
					end
				end
			end
		end
	end
end

-- First impression of someone known to use certain domains (quirk likes/distrusts).
function RelationshipGraph.domainBias(npc: any, domains: { string }): number
	local bias = 0
	for _, q in npc.quirks do
		local e = Quirks.defs[q].effects
		if e.distrustDomain and table.find(domains, e.distrustDomain) then
			bias -= 0.35
		end
		if e.likeDomain and table.find(domains, e.likeDomain) then
			bias += 0.15
		end
	end
	return bias
end

-- A conversation between two NPCs nudges both views by how compatible they are.
function RelationshipGraph.onChat(a: any, b: any)
	local c = RelationshipGraph.compatibility(a, b)
	local warmth = (c - 0.45) * 0.06 + ((a.traits.humor or 0.5) + (b.traits.humor or 0.5) - 1) * 0.01
	RelationshipGraph.adjust(a.id, b.id, warmth, 0.01)
	RelationshipGraph.adjust(b.id, a.id, warmth, 0.01)
	-- Two proud people of the same trade grate on each other.
	if (a.traits.pride or 0) > 0.7 and (b.traits.pride or 0) > 0.7 and a.occupation == b.occupation then
		RelationshipGraph.adjust(a.id, b.id, -0.02, 0, 0.03)
		RelationshipGraph.adjust(b.id, a.id, -0.02, 0, 0.03)
	end
end

-- Strongest relationships from an NPC's point of view (by |affinity| + rivalry + bond).
function RelationshipGraph.top(from: string, count: number): { { id: string, edge: Edge } }
	local list = {}
	for to, edge in (edges[from] or {}) :: { [string]: Edge } do
		table.insert(list, { id = to, edge = edge })
	end
	table.sort(list, function(x, y)
		local sx = math.abs(x.edge.affinity) + x.edge.rivalry + (if x.edge.bond and x.edge.bond ~= "coworker" then 1 else 0)
		local sy = math.abs(y.edge.affinity) + y.edge.rivalry + (if y.edge.bond and y.edge.bond ~= "coworker" then 1 else 0)
		return sx > sy
	end)
	while #list > count do
		table.remove(list)
	end
	return list
end

function RelationshipGraph.bondLabel(bond: string?): string
	return bond or "acquaintance"
end

-- Player edges round-trip through the player's save (PlayerData.relationships).
function RelationshipGraph.loadPlayer(userId: number, saved: { [string]: any })
	for npcId, rel in saved do
		if typeof(rel) == "table" then
			local e = RelationshipGraph.get(npcId, "u:" .. userId)
			e.affinity = math.clamp(tonumber(rel.affinity) or 0, -1, 1)
			e.trust = math.clamp(tonumber(rel.trust) or 0.2, 0, 1)
		end
	end
end

function RelationshipGraph.forgetPlayer(userId: number)
	local node = "u:" .. userId
	for _, row in edges do
		row[node] = nil
	end
end

-- Removes a node entirely (an NPC deleted by the admin panel).
function RelationshipGraph.forget(id: string)
	edges[id] = nil
	for _, row in edges do
		row[id] = nil
	end
end

function RelationshipGraph.edgeCount(): number
	local n = 0
	for _, row in edges do
		for _ in row do
			n += 1
		end
	end
	return n
end

return RelationshipGraph
