--!strict
--[[
	NPCConversation: talking to an NPC as a state the NPC is in, rather than a timer
	(docs/NPCMovement.md). DialogueEngine still writes the words; this holds the body still.

		Conversation.Say(npc, player, text)      a player spoke and the NPC answered: starts or continues
		Conversation.Leave(npc, player)          that player is done (farewell, Close)
		Conversation.Interrupt(npc)              a fight or a hit: over, at once
		Conversation.Step(npc, clock)            10 Hz on T0 rigs
		Conversation.speechSeconds(text)         how long the words take (pure)

	FLOW   Navigation.Pause(npc, "dialogue") stops the walk and cancels any path. The brain's think()
	       checks the pause, so it issues nothing while they talk. The NPC turns to face the player,
	       NPCAnimator plays Talk then Listen. When the last player has gone: a beat, then
	       Navigation.Resume, and the brain chooses what's next.
	ENDS   farewell or Close · walked away over LEAVE_DISTANCE for LEAVE_GRACE seconds · nothing said
	       for IDLE_SECONDS · a fight, or the rig going away.
	SHARED Several players can talk to one NPC at once: it's one conversation, facing whoever spoke last.
]]

local Players = game:GetService("Players")

local Navigation = require(script.Parent.NavigationService)

local LEAVE_DISTANCE = 18 -- the same distance the client's panel closes at
local LEAVE_GRACE = 3
local IDLE_SECONDS = 45
local BEAT = 0.9
local WORDS_PER_SECOND_CHARS = 18
local MIN_SPEECH, MAX_SPEECH = 1, 6

local PARTING = { "Well. Mind how you go.", "...I suppose that's that.", "Off you go, then.", "Safe roads." }

local Conversation = {}

-- Set by NPCService: (npc, text) -> shows a bubble.
Conversation.speak = nil :: ((any, string) -> ())?

function Conversation.speechSeconds(text: string): number
	return math.clamp(#text / WORDS_PER_SECOND_CHARS, MIN_SPEECH, MAX_SPEECH)
end

local function rootOf(player: Player): BasePart?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

function Conversation.Say(npc: any, player: Player, text: string)
	local clock = os.clock()
	local talk = npc.talk
	if not talk then
		talk = { players = {}, speakingUntil = 0, lookAt = nil, endingAt = nil }
		npc.talk = talk
		Navigation.Pause(npc, "dialogue")
	end
	talk.endingAt = nil -- came back during the beat: still talking
	talk.players[player] = { last = clock, awaySince = nil }
	talk.speaker = player
	talk.speakingUntil = clock + Conversation.speechSeconds(text)
	local root = rootOf(player)
	if root then
		talk.lookAt = root.Position + Vector3.new(0, 1.5, 0)
		Navigation.Face(npc, root.Position)
	end
end

local function finish(npc: any)
	npc.talk = nil
	Navigation.Face(npc, nil)
	Navigation.Resume(npc, "dialogue")
	npc.actionUntil = 0 -- the brain chooses again from here
end

function Conversation.Leave(npc: any, player: Player)
	local talk = npc.talk
	if talk then
		talk.players[player] = nil
		if next(talk.players) == nil then
			talk.endingAt = os.clock() + BEAT
		end
	end
end

function Conversation.Interrupt(npc: any)
	if npc.talk then
		finish(npc)
	end
end

function Conversation.Step(npc: any, clock: number)
	local talk = npc.talk
	if not talk then
		return
	end
	if talk.endingAt then
		if clock >= talk.endingAt then
			finish(npc)
		end
		return
	end
	local position: Vector3 = npc.position
	for player, entry in talk.players do
		local root = if player.Parent == Players then rootOf(player) else nil
		local gone = not root
		if root and (root.Position - position).Magnitude > LEAVE_DISTANCE then
			entry.awaySince = entry.awaySince or clock
			gone = clock - entry.awaySince >= LEAVE_GRACE
		elseif root then
			entry.awaySince = nil
		end
		if gone or clock - entry.last >= IDLE_SECONDS then
			talk.players[player] = nil
			if next(talk.players) == nil and root and Conversation.speak then
				(Conversation.speak :: (any, string) -> ())(npc, PARTING[(npc.seed or 0) % #PARTING + 1])
			end
		end
	end
	if next(talk.players) == nil then
		talk.endingAt = clock + BEAT
		return
	end
	-- Keep looking at whoever spoke last, as they shift about.
	local speaker = talk.speaker
	local root = speaker and talk.players[speaker] and rootOf(speaker)
	if root then
		talk.lookAt = root.Position + Vector3.new(0, 1.5, 0)
		Navigation.Face(npc, root.Position)
	end
end

return Conversation
