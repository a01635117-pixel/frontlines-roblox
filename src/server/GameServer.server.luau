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
local GameTypes = require(script.Parent.Core.GameTypes)
local Util = require(Shared.Util)
local NameBoxCalculator = require(script.Parent.Core.NameBoxCalculator)

local MAP_ID = script:GetAttribute("Map") or "World"
local BOTS = script:GetAttribute("Bots") or 250
local LOBBY_SECONDS = script:GetAttribute("LobbySeconds") or (if RunService:IsStudio() then 3 else 20)
local TICK_SECONDS = 0.1 -- Config.msPerTick() = 100
local STATS_EVERY = 5 -- ticks between stats broadcasts
local MAX_INTENTS_PER_TICK = 10 -- per player

-- Unit types the build menu may place (upstream BuildMenus order).
local BUILDABLE = { "City", "Factory", "Port", "Defense Post", "Missile Silo", "SAM Launcher", "Warship", "Atom Bomb", "Hydrogen Bomb", "MIRV" }

local function clientIDOf(player: Player): string
	return tostring(player.UserId)
end

-- Per-user settings (upstream keeps them in localStorage). Only the tutorial
-- "Don't show again" flag so far. DataStores fail in Studio without API
-- access; everything here is best effort.
local settingsStore = nil
pcall(function()
	settingsStore = game:GetService("DataStoreService"):GetDataStore("UserSettings")
end)
local userSettings = {} -- UserId -> settings table

local function loadSettings(player: Player)
	if userSettings[player.UserId] then
		return userSettings[player.UserId]
	end
	local data = nil
	if settingsStore then
		pcall(function()
			data = settingsStore:GetAsync(tostring(player.UserId))
		end)
	end
	userSettings[player.UserId] = if type(data) == "table" then data else {}
	return userSettings[player.UserId]
end

local function saveSetting(player: Player, key: string, value: any)
	local settings = loadSettings(player)
	settings[key] = value
	if settingsStore then
		task.spawn(pcall, function()
			settingsStore:SetAsync(tostring(player.UserId), settings)
		end)
	end
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
		-- Solo in Studio behaves like upstream Singleplayer: no spawn timer, the
		-- spawn phase ends when the player picks a location.
		gameType = if RunService:IsStudio() and #players == 1 then "Singleplayer" else "Public",
		gameMode = "Free For All",
		gameMapSize = "Compact",
		bots = BOTS,
		randomSpawn = false,
		infiniteGold = false,
		infiniteTroops = false,
		instantBuild = false,
		-- Not ported yet: rail network (factories).
		disabledUnits = { "Factory" },
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

-- Name placements, recomputed when upstream GameRunner recomputes them.
local names = {} -- smallID -> { x, y, size }

local function nameRows(): { { number } }
	local rows = {}
	for smallID, v in names do
		table.insert(rows, { smallID, v.x, v.y, v.size })
	end
	return rows
end

local function updateNames(wasInSpawnPhase: boolean)
	local changed = {}
	local function set(p, v)
		local old = names[p:smallID()]
		if old == nil or old.x ~= v.x or old.y ~= v.y or old.size ~= v.size then
			names[p:smallID()] = v
			table.insert(changed, { p:smallID(), v.x, v.y, v.size })
		end
	end
	if mg:inSpawnPhase() then
		for _, p in mg:players() do
			if (p:type() == "HUMAN" or p:type() == "NATION") and p:spawnTile() ~= nil then
				set(p, NameBoxCalculator.placeSpawnName(mg, p))
			end
		end
	end
	local spawnJustEnded = wasInSpawnPhase and not mg:inSpawnPhase()
	if spawnJustEnded or mg:ticks() < 3 or mg:ticks() % 30 == 0 then
		for _, p in mg:players() do
			set(p, NameBoxCalculator.placeName(mg, p))
		end
	end
	if #changed > 0 then
		Net.Names:FireAllClients(Net.packNames(changed))
	end
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
		-- Singleplayer has no spawn timer (upstream GameRunner.init).
		hasSpawnTimer = mg:config():gameConfig().gameType ~= "Singleplayer",
		yourClientID = clientIDOf(forPlayer),
		tutorialDismissed = loadSettings(forPlayer).tutorialDismissed == true,
		disabledUnits = (function()
			local d = {}
			for _, u in BUILDABLE do
				d[u] = mg:config():isUnitDisabled(u) or nil
			end
			return d
		end)(),
		players = roster,
		tiles = Net.wrap(copy),
		names = Net.packNames(nameRows()),
		units = (function()
			local list = {}
			for _, u in mg:units() do
				local up = u:toUpdate()
				table.insert(list, { id = up.id, unitType = up.unitType, ownerID = up.ownerID, pos = up.pos, troops = up.troops, isActive = true, isRetreating = up.isRetreating, level = up.level, underConstruction = up.underConstruction, markedForDeletion = up.markedForDeletion ~= false, targetTile = up.targetTile, plan = mg:motionPlan(up.id), health = up.health, maxHealth = up.maxHealth })
			end
			return list
		end)(),
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

-- Studio-only handle for debugging from the command bar / MCP.
if RunService:IsStudio() then
	_G.OpenFront = { game = mg, runner = runner }
end

local function isInt(v): boolean
	return type(v) == "number" and v == math.floor(v)
end

-- Upstream radial menu "delete": closest finished structure of ours within
-- manhattan distance 5 of a land tile we own.
local DELETE_SELECTION_RADIUS = 5
local function deletableAt(me, tile: number)
	if mg:inSpawnPhase() or not me:canDeleteUnit() or not mg:isLand(tile) then
		return nil
	end
	local owner = mg:owner(tile)
	if not owner:isPlayer() or owner:id() ~= me:id() then
		return nil
	end
	local mine = {}
	for _, u in me:units() do
		if
			not u:isUnderConstruction()
			and not u:isMarkedForDeletion()
			and GameTypes.Structures.has(u:type())
			and mg:manhattanDist(u:tile(), tile) <= DELETE_SELECTION_RADIUS
		then
			table.insert(mine, u)
		end
	end
	return Util.findClosestBy(mine, function(u)
		return mg:manhattanDist(u:tile(), tile)
	end)
end

-- Build menu query: what the asking player can build / upgrade / delete at a tile.
Net.Query.OnServerInvoke = function(player: Player, q)
	local me = mg:playerByClientID(clientIDOf(player))
	if me == nil or type(q) ~= "table" or not isInt(q.tile) or not mg:isValidRef(q.tile) then
		return nil
	end
	local list = {}
	for _, u in BUILDABLE do
		if not mg:config():isUnitDisabled(u) then
			table.insert(list, u)
		end
	end
	local out = {}
	for _, bu in me:buildableUnits(q.tile, list) do
		local upgradeTile = nil
		if bu.canUpgrade ~= false then
			local target = mg:unit(bu.canUpgrade)
			upgradeTile = target and target:tile()
		end
		table.insert(out, {
			unit = bu.type,
			cost = bu.cost,
			canBuild = bu.canBuild ~= false,
			canUpgrade = bu.canUpgrade ~= false,
			upgradeCosts = if bu.upgradeCosts then table.move(bu.upgradeCosts, 1, 5, 1, {}) else nil, -- x1 and x5 only
			upgradeTile = upgradeTile,
		})
	end
	local del = deletableAt(me, q.tile)
	local spawnPhase = mg:inSpawnPhase()
	return {
		units = out,
		deleteUnit = if del then del:type() else nil,
		-- Radial menu (RadialMenuElements): centre attack, boat slot, owner.
		canAttack = not spawnPhase and me:canAttack(q.tile),
		canBoat = not spawnPhase and mg:isLand(q.tile) and me:canBuild("Transport", q.tile) ~= false,
		ownerSmallID = mg:ownerID(q.tile),
		inSpawnPhase = spawnPhase,
	}
end

Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if type(intent) ~= "table" then
		return
	end
	local clientID = clientIDOf(player)
	if intent.type == "tutorial_dismiss" then
		saveSetting(player, "tutorialDismissed", true)
		return
	end
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
	elseif t == "click" then
		-- Upstream ClientGameRunner.inputEvent: land attack when the tile is
		-- attackable, else an auto-boat when a launch shore is within 100 tiles.
		local tile, ratio = intent.tile, intent.ratio
		if not isInt(tile) or not mg:isValidRef(tile) or type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 then
			return
		end
		if mg:inSpawnPhase() then
			return
		end
		if me:canAttack(tile) then
			local owner = mg:owner(tile)
			table.insert(pending, { type = "attack", clientID = clientID, targetID = owner:id(), ratio = ratio })
		elseif mg:isLand(tile) then
			local spawn = me:canBuild("Transport", tile)
			if spawn ~= false and mg:euclideanDistSquared(tile, spawn) < 100 * 100 then
				table.insert(pending, { type = "boat", clientID = clientID, dst = tile, ratio = ratio })
			end
		end
	elseif t == "attack_at" or t == "boat_at" then
		-- Radial menu: centre button attack / boat slot (no auto-boat range limit).
		local tile, ratio = intent.tile, intent.ratio
		if not isInt(tile) or not mg:isValidRef(tile) or type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 then
			return
		end
		if mg:inSpawnPhase() then
			return
		end
		if t == "attack_at" then
			if me:canAttack(tile) then
				table.insert(pending, { type = "attack", clientID = clientID, targetID = mg:owner(tile):id(), ratio = ratio })
			end
		elseif mg:isLand(tile) and me:canBuild("Transport", tile) ~= false then
			table.insert(pending, { type = "boat", clientID = clientID, dst = tile, ratio = ratio })
		end
	elseif t == "cancel_attack" then
		if type(intent.attackID) == "string" and #intent.attackID <= 16 then
			table.insert(pending, { type = "cancel_attack", clientID = clientID, attackID = intent.attackID })
		end
	elseif t == "place" then
		-- Build menu placement: upgrade a structure in range when possible,
		-- otherwise build a new one (upstream build ghost behaviour).
		local tile, unitType = intent.tile, intent.unit
		if not isInt(tile) or not mg:isValidRef(tile) or type(unitType) ~= "string" then
			return
		end
		if not table.find(BUILDABLE, unitType) or mg:config():isUnitDisabled(unitType) then
			return
		end
		local bu = me:buildableUnits(tile, { unitType })[1]
		if bu.canUpgrade ~= false then
			local amount = if intent.amount == 5 then 5 else 1 -- uiState.upgradeMultiplier
			table.insert(pending, { type = "upgrade_structure", clientID = clientID, unitId = bu.canUpgrade, amount = amount })
		elseif bu.canBuild ~= false then
			local amount = if unitType == "Atom Bomb" and intent.amount == 5 then 5 else nil
			table.insert(pending, { type = "build_unit", clientID = clientID, unit = unitType, tile = tile, amount = amount })
		end
	elseif t == "move_warship" then
		-- Warship selection: move own warships' patrol point (MoveWarshipExecution
		-- checks ownership and water connectivity).
		local ids = intent.unitIds
		if type(ids) ~= "table" or #ids == 0 or #ids > 100 or not isInt(intent.tile) or not mg:isValidRef(intent.tile) then
			return
		end
		local clean = {}
		for _, id in ids do
			if isInt(id) then
				table.insert(clean, id)
			end
		end
		table.insert(pending, { type = "move_warship", clientID = clientID, unitIds = clean, tile = intent.tile })
	elseif t == "delete_at" then
		if isInt(intent.tile) and mg:isValidRef(intent.tile) then
			local u = deletableAt(me, intent.tile)
			if u then
				table.insert(pending, { type = "delete_unit", clientID = clientID, unitId = u:id() })
			end
		end
	elseif t == "cancel_boat" then
		if isInt(intent.unitID) then
			table.insert(pending, { type = "cancel_boat", clientID = clientID, unitID = intent.unitID })
		end
	end
end)

-- Tick loop -----------------------------------------------------------------------

-- Control panel / hotbar / tutorial data for one human (upstream reads these
-- from its local game view): prices, max troops, troop growth per second,
-- troops out in attacks, and every BORDER_EVERY ticks who we border and
-- whether we own coast (TutorialPanel.refreshBordering).
local BORDER_EVERY = 10
-- Humans that had an outgoing attack on any tick since their last Me message
-- (upstream's tutorial samples every tick; short attacks must not be missed).
local sawAttack = {}
local function meInfo(me, withBorders: boolean)
	local config = mg:config()
	local costs, disabled = {}, {}
	for _, u in BUILDABLE do
		costs[u] = config:unitInfo(u).cost(mg, me)
		disabled[u] = config:isUnitDisabled(u) or nil
	end
	local attackingTroops, attacking = 0, sawAttack[me] == true
	sawAttack[me] = nil
	for _, a in me:outgoingAttacks() do
		attackingTroops += a:troops()
		attacking = true
	end
	local info = {
		costs = costs,
		disabled = disabled,
		maxTroops = config:maxTroops(me),
		troopRate = config:troopIncreaseRate(me) * 10,
		attackingTroops = attackingTroops,
		attacking = attacking,
		allied = #me:alliances() > 0,
		spawnTile = me:spawnTile(),
	}
	if withBorders then
		local myID = me:smallID()
		local seen, bordering, coast = {}, {}, false
		for t in me:borderTiles() do
			if mg:isShore(t) then
				coast = true
			end
			for _, n in mg:neighbors(t) do
				local owner = mg:ownerID(n)
				if owner ~= 0 and owner ~= myID and not seen[owner] then
					seen[owner] = true
					table.insert(bordering, owner)
				end
			end
		end
		info.bordering = bordering
		info.hasCoast = coast
	end
	return info
end

-- Gold pop next to the gold counter (upstream ControlPanel.addGoldGain).
local function sendGoldGain(playerID, gold: number)
	if gold <= 0 then
		return
	end
	local p = mg:player(playerID)
	local clientID = p and p:clientID()
	if clientID == nil then
		return
	end
	for _, plr in Players:GetPlayers() do
		if clientIDOf(plr) == clientID then
			Net.Event:FireClient(plr, { type = "GoldGain", gold = gold })
		end
	end
end

-- Latest state per unit this tick, sent as one Units message.
local unitChanges, unitOrder = {}, {}
-- Units flying on a motion plan (nukes): sent once with the plan, then only
-- when they end; clients replay the path themselves.
local planSent = {}

local function handleUpdates(updates)
	table.clear(unitChanges)
	table.clear(unitOrder)
	for _, u in updates do
		if u.type == "Unit" then
			local plan = mg:motionPlan(u.id)
			if plan and u.isActive and planSent[u.id] and unitChanges[u.id] == nil then
				continue -- in flight: the client already has the plan
			end
			if not u.isActive then
				planSent[u.id] = nil
				mg:clearMotionPlan(u.id)
			elseif plan then
				planSent[u.id] = true
			end
			if unitChanges[u.id] == nil then
				table.insert(unitOrder, u.id)
			end
			unitChanges[u.id] = {
				id = u.id,
				unitType = u.unitType,
				ownerID = u.ownerID,
				pos = u.pos,
				troops = u.troops,
				isActive = u.isActive,
				isRetreating = u.isRetreating,
				level = u.level,
				underConstruction = u.underConstruction,
				markedForDeletion = u.markedForDeletion ~= false,
				reachedTarget = u.reachedTarget,
				targetTile = u.targetTile,
				health = u.health,
				maxHealth = u.maxHealth,
				plan = if u.isActive then plan else nil,
			}
		end
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
			sendGoldGain(u.conquerorId, u.gold or 0)
		elseif u.type == "BonusEvent" then
			sendGoldGain(u.player, u.gold or 0)
		end
	end
	if #unitOrder > 0 then
		local list = table.create(#unitOrder)
		for i, id in unitOrder do
			list[i] = unitChanges[id]
		end
		Net.Units:FireAllClients(list)
	end
end

local lastTile, order, states = {}, {}, {}


local function runTick()
	-- Resolve attack troops against current troop counts.
	local intents = pending
	pending = {}
	table.clear(intentCount)
	for _, intent in intents do
		if (intent.type == "attack" or intent.type == "boat") and intent.ratio then
			local me = mg:playerByClientID(intent.clientID)
			intent.troops = if me then me:troops() * intent.ratio else 0
		end
	end

	local wasInSpawnPhase = mg:inSpawnPhase()
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

	for _, plr in Players:GetPlayers() do
		local me = mg:playerByClientID(clientIDOf(plr))
		if me and #me:outgoingAttacks() > 0 then
			sawAttack[me] = true
		end
	end

	if tick % STATS_EVERY == 0 then
		Net.Stats:FireAllClients(Net.packStats(tick, statsRows()))
		for _, plr in Players:GetPlayers() do
			local me = mg:playerByClientID(clientIDOf(plr))
			if me and me:isAlive() then
				Net.Me:FireClient(plr, meInfo(me, tick % BORDER_EVERY == 0))
			end
		end
	end
	updateNames(wasInSpawnPhase)
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
