-- Runs one OpenFront match per Roblox server.
--
-- The simulation is server-authoritative (Core/GameRunner, a faithful port of
-- OpenFrontIO's deterministic core). Clients send intents and receive only
-- what changed: tile ownership deltas, player stats and events.
--
-- Script attributes (optional): Map (default "World"), Bots (default 250),
-- LobbySeconds (default 3 in Studio, 20 live).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local GameRunner = require(script.Parent.Core.GameRunner)

local MAP_ID = script:GetAttribute("Map") or "World"
local BOTS = script:GetAttribute("Bots") or 250
local LOBBY_SECONDS = script:GetAttribute("LobbySeconds") or (if RunService:IsStudio() then 3 else 20)
local TICK_SECONDS = 0.1 -- Config.msPerTick() = 100
local STATS_EVERY = 5 -- ticks between stats broadcasts
local MAX_INTENTS_PER_TICK = 10 -- per player

local function clientIDOf(player: Player): string
	return tostring(player.UserId)
end

-- Lobby ---------------------------------------------------------------------------

while #Players:GetPlayers() == 0 do
	Players.PlayerAdded:Wait()
end
task.wait(LOBBY_SECONDS)

local gameID = string.sub(HttpService:GenerateGUID(false), 1, 8)
local players = {}
for _, p in Players:GetPlayers() do
	table.insert(players, { username = p.DisplayName, clientID = clientIDOf(p) })
end

local runner = GameRunner.create({
	gameID = gameID,
	config = {
		gameMap = MAP_ID,
		difficulty = "Medium",
		donateGold = false,
		donateTroops = false,
		gameType = "Public",
		gameMode = "Free For All",
		gameMapSize = "Compact",
		bots = BOTS,
		randomSpawn = false,
		infiniteGold = false,
		infiniteTroops = false,
		instantBuild = false,
		disabledUnits = {},
		nations = "disabled", -- TODO(port): nations
	},
	players = players,
}, Shared.Maps[MAP_ID])
local mg = runner.game
print(`[GameServer] game {gameID} on {MAP_ID} with {#players} human(s) and {BOTS} bots`)

-- Replication ---------------------------------------------------------------------

local rosterSent = 0

local function rosterEntry(p)
	return {
		smallID = p:smallID(),
		id = p:id(),
		name = p:displayName(),
		type = p:type(),
		clientID = p:clientID(),
		team = p:team(),
	}
end

local function newRosterEntries()
	local all = mg:allPlayers()
	local out = {}
	for i = rosterSent + 1, #all do
		table.insert(out, rosterEntry(all[i]))
	end
	rosterSent = #all
	return out
end

local function fullState(forPlayer: Player)
	local roster = {}
	for _, p in mg:allPlayers() do
		table.insert(roster, rosterEntry(p))
	end
	local state = mg:map():tileStateBuffer()
	local copy = buffer.create(buffer.len(state))
	buffer.copy(copy, 0, state)
	return {
		mapId = MAP_ID,
		tick = mg:ticks(),
		inSpawnPhase = mg:inSpawnPhase(),
		spawnPhaseTurns = mg:config():numSpawnPhaseTurns(),
		yourClientID = clientIDOf(forPlayer),
		players = roster,
		tiles = Net.wrap(copy),
	}
end

local function statsRows()
	local rows = {}
	for _, p in mg:allPlayers() do
		if p:isAlive() or p:hasSpawned() then
			table.insert(rows, { p:smallID(), p:numTilesOwned(), p:troops(), p:gold() })
		end
	end
	return rows
end

local function sendState(player: Player)
	Net.GameState:FireClient(player, fullState(player))
end

for _, p in Players:GetPlayers() do
	sendState(p)
end
rosterSent = #mg:allPlayers()
Players.PlayerAdded:Connect(function(p)
	-- Late joiners watch; TODO(port): lobby/matchmaking for new matches.
	sendState(p)
end)

-- Intents -------------------------------------------------------------------------

local pending = {} -- queued intents for the next tick
local intentCount = {} -- clientID -> count this tick

local function isInt(v): boolean
	return type(v) == "number" and v == math.floor(v)
end

Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if type(intent) ~= "table" then
		return
	end
	local clientID = clientIDOf(player)
	local me = mg:playerByClientID(clientID)
	if me == nil then
		return -- spectator
	end
	local n = (intentCount[clientID] or 0) + 1
	if n > MAX_INTENTS_PER_TICK then
		return
	end
	intentCount[clientID] = n

	local t = intent.type
	if t == "spawn" then
		if isInt(intent.tile) and mg:isValidRef(intent.tile) then
			table.insert(pending, { type = "spawn", clientID = clientID, tile = intent.tile })
		end
	elseif t == "attack" then
		local ratio = intent.ratio
		local target = intent.targetSmallID
		if type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 or not isInt(target) or target < 0 then
			return
		end
		local targetID = nil
		if target ~= 0 then
			local tp = mg:playerBySmallID(target)
			if tp == nil then
				return
			end
			targetID = tp:id()
		end
		-- Troops are computed when the intent is applied (see tick loop).
		table.insert(pending, { type = "attack", clientID = clientID, targetID = targetID, ratio = ratio })
	elseif t == "cancel_attack" then
		if type(intent.attackID) == "string" and #intent.attackID <= 16 then
			table.insert(pending, { type = "cancel_attack", clientID = clientID, attackID = intent.attackID })
		end
	end
end)

-- Tick loop -----------------------------------------------------------------------

local function handleUpdates(updates)
	for _, u in updates do
		if u.type == "SpawnPhaseEnd" then
			Net.Event:FireAllClients({ type = "SpawnPhaseEnd", tick = u.startTick })
		elseif u.type == "Win" then
			local w = u.winner
			Net.Event:FireAllClients({
				type = "Win",
				winnerName = if type(w) == "table" then w:displayName() else tostring(w),
				winnerSmallID = if type(w) == "table" then w:smallID() else nil,
			})
		elseif u.type == "ConquestEvent" then
			Net.Event:FireAllClients({ type = "Conquest", conquerorId = u.conquerorId, conqueredId = u.conqueredId })
		end
	end
end

local lastTile, order, states = {}, {}, {}

local function runTick()
	-- Resolve attack troops against current troop counts.
	local intents = pending
	pending = {}
	table.clear(intentCount)
	for _, intent in intents do
		if intent.type == "attack" then
			local me = mg:playerByClientID(intent.clientID)
			intent.troops = if me then math.floor(me:troops() * intent.ratio) else 0
		end
	end

	local updates = runner:executeNextTick(intents)
	local tick = mg:ticks()

	-- Roster before tiles, so clients know a new player's colour before
	-- drawing their first territory.
	if #mg:allPlayers() > rosterSent then
		Net.Roster:FireAllClients(newRosterEntries())
	end

	-- Tile deltas: keep the last state per tile this tick.
	local flat = mg:tileUpdates()
	table.clear(lastTile)
	table.clear(order)
	table.clear(states)
	for i = 1, #flat, 2 do
		local t = flat[i]
		if lastTile[t] == nil then
			table.insert(order, t)
		end
		lastTile[t] = flat[i + 1] % 65536
	end
	if #order > 0 then
		for i, t in order do
			states[i] = lastTile[t]
		end
		Net.Tick:FireAllClients(Net.packTiles(tick, order, states))
	end

	if tick % STATS_EVERY == 0 then
		Net.Stats:FireAllClients(Net.packStats(tick, statsRows()))
	end
	handleUpdates(updates)
	return mg:getWinner() == nil
end

local accumulator = 0
local running = true
RunService.Heartbeat:Connect(function(dt)
	if not running then
		return
	end
	accumulator += dt
	-- Catch up at most 3 ticks per frame so a hitch can't snowball.
	local steps = 0
	while accumulator >= TICK_SECONDS and steps < 3 do
		accumulator -= TICK_SECONDS
		steps += 1
		running = runTick()
		if not running then
			break
		end
	end
	if accumulator > TICK_SECONDS * 3 then
		accumulator = 0
	end
end)
