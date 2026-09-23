-- Port of OpenFrontIO src/core/GameRunner.ts (createGameRunner + GameRunner)
-- and src/core/execution/ExecutionManager.ts (Executor).
--
-- gameStart = {
--   gameID: string,
--   config: GameConfig (see Config.luau),
--   players: { { username, clientID, isLobbyCreator?, clanTag?, friends?, teamIndex? } },
--   tribes: { { name } }?,  -- purchased tribe names
-- }
-- Intents mirror upstream's wire intents: { type = "attack" | "spawn" |
-- "cancel_attack" | "boat" | "cancel_boat", clientID, ... }.

local Shared = game:GetService("ReplicatedStorage").Shared
local MapLoader = require(Shared.MapLoader)
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Config = require(script.Parent.Config)
local GameImpl = require(script.Parent.GameImpl)
local GameTypes = require(script.Parent.GameTypes)
local Exec = script.Parent.Execution
local AttackExecution = require(Exec.AttackExecution)
local SmallExecutions = require(Exec.SmallExecutions)
local SpawnExecution = require(Exec.SpawnExecution)
local TribeSpawner = require(Exec.TribeSpawner)
local TransportShipExecution = require(Exec.TransportShipExecution)

local PlayerType = GameTypes.PlayerType
local GameType = GameTypes.GameType

-- Executor ----------------------------------------------------------------------

local Executor = {}
Executor.__index = Executor

function Executor.new(mg, gameID: string, purchasedTribeNames: { string }?, mapThemes: { string }?)
	return setmetatable({
		mg = mg,
		gameID = gameID,
		purchasedTribeNames = purchasedTribeNames or {},
		mapThemes = mapThemes,
		-- Add one to avoid id collisions with tribes.
		random = PseudoRandom.new(Util.simpleHash(gameID) + 1),
	}, Executor)
end

function Executor:createExec(intent)
	local player = self.mg:playerByClientID(intent.clientID)
	if not player then
		warn(`player with clientID {intent.clientID} not found`)
		return SmallExecutions.NoOpExecution.new()
	end
	local t = intent.type
	if t == "attack" then
		return AttackExecution.new(intent.troops, player, intent.targetID, nil)
	elseif t == "cancel_attack" then
		return SmallExecutions.RetreatExecution.new(player, intent.attackID)
	elseif t == "spawn" then
		-- fromIntent: subject to the spawn-phase gate.
		return SpawnExecution.new(self.gameID, player:info(), intent.tile, true)
	elseif t == "boat" then
		return TransportShipExecution.new(player, intent.dst, intent.troops)
	elseif t == "cancel_boat" then
		return SmallExecutions.BoatRetreatExecution.new(player, intent.unitID)
	end
	-- TODO(port): alliances, targeting, emoji, donations, embargo,
	-- build/upgrade/delete units, quick chat, disconnect marking, pause.
	warn(`TODO(port): intent type {t}`)
	return SmallExecutions.NoOpExecution.new()
end

function Executor:spawnTribes(numTribes: number)
	local nationCells = {}
	for _, n in self.mg:nations() do
		if n.spawnCell ~= nil then
			table.insert(nationCells, n.spawnCell)
		end
	end
	return TribeSpawner.new(self.mg, self.gameID, nationCells, self.mapThemes)
		:spawnTribes(numTribes, self.purchasedTribeNames)
end

-- GameRunner --------------------------------------------------------------------

local GameRunner = {}
GameRunner.__index = GameRunner
GameRunner.Executor = Executor

function GameRunner.create(gameStart, mapModule: ModuleScript)
	local config = Config.new(gameStart.config)
	local gameMap, miniGameMap, manifest = MapLoader.load(mapModule)
	local random = PseudoRandom.new(Util.simpleHash(gameStart.gameID))

	local humans = {}
	for _, p in gameStart.players or {} do
		table.insert(
			humans,
			GameTypes.PlayerInfo(
				p.username,
				PlayerType.Human,
				p.clientID,
				random:nextID(),
				p.isLobbyCreator or false,
				p.clanTag,
				p.friends or {},
				p.teamIndex
			)
		)
	end

	-- TODO(port): NationCreation.createNationsForGame + NationExecution.
	-- With nations "disabled" upstream returns [] without touching `random`.
	local nations = {}
	if config:spawnNations() then
		warn("TODO(port): nations are not ported yet; starting without nations")
	end

	local game = GameImpl.new(humans, nations, gameMap, miniGameMap, config, manifest.teamGameSpawnAreas)
	local purchased = {}
	for _, t in gameStart.tribes or {} do
		table.insert(purchased, t.name)
	end
	local runner = setmetatable({
		game = game,
		manifest = manifest,
		execManager = Executor.new(game, gameStart.gameID, purchased, manifest.themes),
	}, GameRunner)
	runner:init()
	return runner
end

function GameRunner:init()
	local game = self.game
	local config = game:config()
	if config:gameConfig().gameType ~= GameType.Singleplayer then
		game:addExecution(SmallExecutions.SpawnTimerExecution.new())
	end
	-- TODO(port): nation executions (config:spawnNations()).
	if config:isRandomSpawn() then
		-- TODO(port): PlayerSpawner (random spawn for humans).
		warn("TODO(port): random spawn")
	end
	if config:bots() > 0 then
		game:addExecution(table.unpack(self.execManager:spawnTribes(config:bots())))
	end
	game:addExecution(SmallExecutions.WinCheckExecution.new())
	-- TODO(port): DoomsdayClockExecution; RecomputeRailClusterExecution
	-- (factories). Neither affects territory until those systems exist.
end

-- Runs one tick with this turn's intents. Returns the tick's game updates.
function GameRunner:executeNextTick(intents: { any }?)
	for _, intent in intents or {} do
		self.game:addExecution(self.execManager:createExec(intent))
	end
	return self.game:executeNextTick()
end

return GameRunner
