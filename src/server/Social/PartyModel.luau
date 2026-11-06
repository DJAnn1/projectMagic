--!strict
--[[
	PartyModel: parties and invites as pure data, with no Players, remotes or clocks of its own, so
	every rule can be specced (Tests/Social.spec). Services/PartyService is the live wrapper.

	Rules (docs/Social.md §3)
		size        2-5. A party exists from the first accepted invite; at one member it disbands.
		invites     from a leader or from someone with no party. They expire. A "no" blocks the same
		            pair for a while, and one person can have only so many open at once, so an
		            invite can't be used to pester someone.
		leader      can kick and promote. If the leader leaves, the longest-standing member leads.

	Refusals are reason codes (the client words them): SELF, IN_PARTY, NOT_LEADER, FULL, EXPIRED,
	COOLDOWN, TOO_MANY_INVITES, ALREADY_INVITED, NOT_IN_PARTY, NOT_MEMBER.
]]

export type Party = { id: string, leader: number, members: { number } }
export type Invite = { from: number, to: number, expires: number }

export type Book = {
	parties: { [string]: Party },
	byUser: { [number]: string },
	invites: { [number]: { [number]: Invite } }, -- to -> from -> invite
	declined: { [string]: number }, -- "from|to" -> time the cooldown ends
	counter: number,
}

local PartyModel = {}

PartyModel.MAX_MEMBERS = 5
PartyModel.INVITE_SECONDS = 45
PartyModel.DECLINE_COOLDOWN = 30
PartyModel.MAX_OPEN_INVITES = 5

function PartyModel.new(): Book
	return { parties = {}, byUser = {}, invites = {}, declined = {}, counter = 0 }
end

function PartyModel.partyOf(book: Book, userId: number): Party?
	local id = book.byUser[userId]
	return if id then book.parties[id] else nil
end

local function openInvitesFrom(book: Book, from: number): number
	local count = 0
	for _, incoming in book.invites do
		if incoming[from] then
			count += 1
		end
	end
	return count
end

function PartyModel.invite(book: Book, from: number, to: number, now: number): (boolean, string?)
	if from == to then
		return false, "SELF"
	end
	if book.byUser[to] then
		return false, "IN_PARTY"
	end
	local party = PartyModel.partyOf(book, from)
	if party then
		if party.leader ~= from then
			return false, "NOT_LEADER"
		end
		if #party.members >= PartyModel.MAX_MEMBERS then
			return false, "FULL"
		end
	end
	local cooldown = book.declined[from .. "|" .. to]
	if cooldown and now < cooldown then
		return false, "COOLDOWN"
	end
	local incoming = book.invites[to]
	if incoming and incoming[from] and now < incoming[from].expires then
		return false, "ALREADY_INVITED"
	end
	if openInvitesFrom(book, from) >= PartyModel.MAX_OPEN_INVITES then
		return false, "TOO_MANY_INVITES"
	end
	incoming = incoming or {}
	book.invites[to] = incoming
	incoming[from] = { from = from, to = to, expires = now + PartyModel.INVITE_SECONDS }
	return true
end

local function dropInvite(book: Book, from: number, to: number)
	local incoming = book.invites[to]
	if incoming then
		incoming[from] = nil
		if next(incoming) == nil then
			book.invites[to] = nil
		end
	end
end

-- Joining a party ends every other invite you had open.
local function clearInvitesTo(book: Book, to: number)
	book.invites[to] = nil
end

function PartyModel.accept(book: Book, to: number, from: number, now: number): (boolean, string?, Party?)
	local invite = book.invites[to] and book.invites[to][from]
	if not invite or now >= invite.expires then
		dropInvite(book, from, to)
		return false, "EXPIRED"
	end
	if book.byUser[to] then
		return false, "IN_PARTY"
	end
	local party = PartyModel.partyOf(book, from)
	if party and #party.members >= PartyModel.MAX_MEMBERS then
		dropInvite(book, from, to)
		return false, "FULL"
	end
	if not party then
		book.counter += 1
		local created: Party = { id = "party" .. book.counter, leader = from, members = { from } }
		book.parties[created.id] = created
		book.byUser[from] = created.id
		clearInvitesTo(book, from)
		party = created
	end
	local joined = party :: Party
	table.insert(joined.members, to)
	book.byUser[to] = joined.id
	clearInvitesTo(book, to)
	return true, nil, joined
end

function PartyModel.decline(book: Book, to: number, from: number, now: number)
	dropInvite(book, from, to)
	book.declined[from .. "|" .. to] = now + PartyModel.DECLINE_COOLDOWN
end

-- Removes someone. Returns the party they were in and whether it disbanded (with the one person
-- left behind in `orphan`, who is no longer in any party).
function PartyModel.leave(book: Book, userId: number): (Party?, boolean, number?)
	local party = PartyModel.partyOf(book, userId)
	if not party then
		return nil, false, nil
	end
	book.byUser[userId] = nil
	local index = table.find(party.members, userId)
	if index then
		table.remove(party.members, index)
	end
	if #party.members <= 1 then
		local orphan = party.members[1]
		if orphan then
			book.byUser[orphan] = nil
		end
		book.parties[party.id] = nil
		return party, true, orphan
	end
	if party.leader == userId then
		party.leader = party.members[1]
	end
	return party, false, nil
end

function PartyModel.kick(book: Book, by: number, target: number): (boolean, string?)
	local party = PartyModel.partyOf(book, by)
	if not party then
		return false, "NOT_IN_PARTY"
	end
	if party.leader ~= by then
		return false, "NOT_LEADER"
	end
	if by == target then
		return false, "SELF"
	end
	if book.byUser[target] ~= party.id then
		return false, "NOT_MEMBER"
	end
	PartyModel.leave(book, target)
	return true
end

function PartyModel.promote(book: Book, by: number, target: number): (boolean, string?)
	local party = PartyModel.partyOf(book, by)
	if not party then
		return false, "NOT_IN_PARTY"
	end
	if party.leader ~= by then
		return false, "NOT_LEADER"
	end
	if book.byUser[target] ~= party.id then
		return false, "NOT_MEMBER"
	end
	party.leader = target
	return true
end

-- Drops expired invites and finished cooldowns. Returns the user ids whose invite list changed.
function PartyModel.expire(book: Book, now: number): { number }
	local changed: { number } = {}
	for to, incoming in book.invites do
		local dropped = false
		for from, invite in incoming do
			if now >= invite.expires then
				incoming[from] = nil
				dropped = true
			end
		end
		if dropped then
			table.insert(changed, to)
		end
		if next(incoming) == nil then
			book.invites[to] = nil
		end
	end
	for key, ends in book.declined do
		if now >= ends then
			book.declined[key] = nil
		end
	end
	return changed
end

-- Removes every invite to or from someone (they left the server). Returns who lost one.
function PartyModel.forgetInvites(book: Book, userId: number): { number }
	local changed: { number } = {}
	book.invites[userId] = nil
	for to, incoming in book.invites do
		if incoming[userId] then
			incoming[userId] = nil
			table.insert(changed, to)
			if next(incoming) == nil then
				book.invites[to] = nil
			end
		end
	end
	return changed
end

return PartyModel
