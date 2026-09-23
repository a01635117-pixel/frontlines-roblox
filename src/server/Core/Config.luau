-- Port of OpenFrontIO src/core/configuration/Config.ts (simulation subset).
--
-- Formulas are transcribed exactly (same DetMath calls, same operation order)
-- so attacks, troop growth and gold match the original game.
-- Gold is a plain integer-valued number (upstream: bigint); bigint division
-- truncates, so it is written as floor division on non-negative gold.
--
-- Unit costs / nukes / trains / SAM tuning arrive with the stages that port
-- those systems.

local Shared = game:GetService("ReplicatedStorage").Shared
local DetMath = require(Shared.DetMath)
local GameMap = require(Shared.GameMap)
local Util = require(Shared.Util)
local GameTypes = require(script.Parent.GameTypes)

local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local GameType = GameTypes.GameType
local UnitType = GameTypes.UnitType
local TerrainType = GameMap.TerrainType

local log, pow = DetMath.log, DetMath.pow
local within, sigmoid = Util.within, Util.sigmoid

-- attackLogic tunables
local LARGE_TERRITORY_MIDPOINT = 300000
local LARGE_TERRITORY_STEEPNESS = 2.5
local LARGE_ATTACKER_DEPTH = 0.7
local LARGE_DEFENDER_DEPTH = 0.3
local BOT_DEFENDER_LOSS_MULT = 0.7
local TERRA_NULLIUS_COST_SCALE = 2000
local TERRA_NULLIUS_MIN_COST = 5
local TERRA_NULLIUS_MAX_COST = 100
local ATTACKER_LOSS_BASE = 0.463
local ATTACKER_LOSS_PER_DENSITY = 0.0039
local SPEED_COST_DIVISOR = 8.55
local LARGE_ATTACKER_SPEED_DEPTH = 0.73

local DEFAULT_SPAWN_IMMUNITY_TICKS = 5 * 10
local PERCENT_TILES_OWNED_TO_WIN = 80

local OVERTIME_DEFAULTS = { enabled = false, startMinutes = 30, dropPercentPerMinute = 2 }

-- Logistic in log(tiles): ~1 for small territories, easing down to
-- 1 - depth for huge ones, halfway at LARGE_TERRITORY_MIDPOINT.
local function largeTerritoryBonus(numTiles: number, depth: number): number
	return 1 - depth * sigmoid(log(numTiles), LARGE_TERRITORY_STEEPNESS, log(LARGE_TERRITORY_MIDPOINT))
end

local function terrainAttackBase(terrain: number): (number, number)
	if terrain == TerrainType.Plains then
		return 80, 16.5
	elseif terrain == TerrainType.Highland then
		return 100, 20
	elseif terrain == TerrainType.Mountain then
		return 120, 25
	elseif terrain == TerrainType.Impassable then
		error("impassable terrain cannot be attacked")
	end
	error(`terrain type {terrain} not supported`)
end

local Config = {}
Config.__index = Config

--[[
	gameConfig fields (upstream GameConfigSchema): gameMap, difficulty,
	donateGold, donateTroops, gameType, gameMode, gameMapSize, bots,
	randomSpawn, infiniteGold, infiniteTroops, instantBuild, disabledUnits,
	playerTeams, nations, startingGold, goldMultiplier, spawnImmunityDuration,
	customAllianceDuration, disableAlliances, waterNukes, disableNavMesh,
	hostCheats, overtime, doomsdayClock.
]]
function Config.new(gameConfig: { [string]: any })
	return setmetatable({ _gameConfig = gameConfig }, Config)
end

function Config:gameConfig()
	return self._gameConfig
end

function Config:traitorDefenseDebuff(): number
	return 0.5
end
function Config:traitorSpeedDebuff(): number
	return 0.8
end
function Config:traitorDuration(): number
	return 30 * 10
end
function Config:teamLandShareWinThresholdTenths(): number
	return 7
end

function Config:overtimeConfig()
	local c = self._gameConfig.overtime
	return {
		enabled = if c and c.enabled ~= nil then c.enabled else OVERTIME_DEFAULTS.enabled,
		startMinutes = if c and c.startMinutes ~= nil then c.startMinutes else OVERTIME_DEFAULTS.startMinutes,
		dropPercentPerMinute = OVERTIME_DEFAULTS.dropPercentPerMinute,
	}
end

function Config:doomsdayClockConfig()
	-- TODO(port): Doomsday Clock (anti-stall mode) — only `enabled` is read so far.
	local c = self._gameConfig.doomsdayClock
	return { enabled = c ~= nil and c.enabled == true }
end

function Config:spawnImmunityDuration(): number
	return self._gameConfig.spawnImmunityDuration or DEFAULT_SPAWN_IMMUNITY_TICKS
end
function Config:nationSpawnImmunityDuration(): number
	return DEFAULT_SPAWN_IMMUNITY_TICKS
end
function Config:hasExtendedSpawnImmunity(): boolean
	return self:spawnImmunityDuration() > DEFAULT_SPAWN_IMMUNITY_TICKS
end

function Config:cityTroopIncrease(): number
	return 250000
end

-- falloutRatio is between 0 and 1, so the modifier is between [5, 2.5].
function Config:falloutDefenseModifier(falloutRatio: number): number
	return 5 - falloutRatio * 2
end

function Config:msPerTick(): number
	return 100
end
function Config:SAMCooldown(): number
	return 90
end
function Config:SiloCooldown(): number
	return 90
end
function Config:defensePostRange(): number
	return 30
end
function Config:defensePostDefenseBonus(): number
	return 5
end
function Config:defensePostSpeedBonus(): number
	return 3
end

function Config:playerTeams()
	return self._gameConfig.playerTeams or 0
end
function Config:spawnNations(): boolean
	return self._gameConfig.nations ~= "disabled"
end
function Config:isUnitDisabled(unitType: string): boolean
	local disabled = self._gameConfig.disabledUnits
	return disabled ~= nil and table.find(disabled, unitType) ~= nil
end
function Config:bots(): number
	return self._gameConfig.bots
end
function Config:instantBuild(): boolean
	return self._gameConfig.instantBuild == true
end
function Config:disableNavMesh(): boolean
	return self._gameConfig.disableNavMesh == true
end
function Config:disableAlliances(): boolean
	-- customAllianceDuration == 0 disables alliances; the legacy boolean is honored too.
	return self._gameConfig.customAllianceDuration == 0 or self._gameConfig.disableAlliances == true
end
function Config:waterNukes(): boolean
	return self._gameConfig.waterNukes == true
end
function Config:isRandomSpawn(): boolean
	return self._gameConfig.randomSpawn == true
end
function Config:infiniteGold(): boolean
	return self._gameConfig.infiniteGold == true
end
function Config:donateGold(): boolean
	return self._gameConfig.donateGold == true
end
function Config:infiniteTroops(): boolean
	return self._gameConfig.infiniteTroops == true
end
function Config:donateTroops(): boolean
	return self._gameConfig.donateTroops == true
end
function Config:goldMultiplier(): number
	return self._gameConfig.goldMultiplier or 1
end

function Config:_hostCheats()
	return self._gameConfig.hostCheats or {}
end

function Config:startingGold(playerInfo): number
	if playerInfo.playerType == PlayerType.Bot then
		return 0
	end
	local base = self._gameConfig.startingGold or 0
	local hc = self:_hostCheats()
	if hc.startingGold and playerInfo.isLobbyCreator then
		return base + hc.startingGold
	end
	return base
end

function Config:_hasInfiniteTroopsFor(player): boolean
	if self:infiniteTroops() then
		return true
	end
	return self:_hostCheats().infiniteTroops == true and player:isLobbyCreator()
end

function Config:_hasInfiniteTroopsForInfo(playerInfo): boolean
	if self:infiniteTroops() then
		return true
	end
	return self:_hostCheats().infiniteTroops == true and playerInfo.isLobbyCreator
end

function Config:_goldMultiplierFor(player): number
	local hc = self:_hostCheats()
	if hc.goldMultiplier and player:isLobbyCreator() then
		return hc.goldMultiplier
	end
	return self:goldMultiplier()
end

function Config:conquerGoldAmount(captured): number
	local t = captured:type()
	if t == PlayerType.Bot or t == PlayerType.Nation then
		return captured:gold()
	end
	return captured:gold() // 2
end

function Config:defaultDonationAmount(sender): number
	return math.floor(sender:troops() / 3)
end
function Config:donateCooldown(): number
	return 10 * 10
end
function Config:embargoAllCooldown(): number
	return 10 * 10
end
function Config:deletionMarkDuration(): number
	return 30 * 10
end
function Config:deleteUnitCooldown(): number
	return 30 * 10
end
function Config:emojiMessageDuration(): number
	return 5 * 10
end
function Config:emojiMessageCooldown(): number
	return 5 * 10
end
function Config:quickChatCooldown(): number
	return 3 * 10
end
function Config:targetDuration(): number
	return 10 * 10
end
function Config:targetCooldown(): number
	return 15 * 10
end
function Config:allianceRequestDuration(): number
	return 20 * 10
end
function Config:allianceRequestCooldown(): number
	return 30 * 10
end
function Config:allianceDuration(): number
	-- Host-set duration in minutes (1-15); falls back to 5 minutes.
	local m = self._gameConfig.customAllianceDuration
	if type(m) == "number" and m > 0 then
		return m * 60 * 10
	end
	return 300 * 10
end
function Config:temporaryEmbargoDuration(): number
	return 300 * 10
end
function Config:minDistanceBetweenPlayers(): number
	return 30
end
function Config:allianceExtensionPromptOffset(): number
	return 300
end

function Config:percentageTilesOwnedToWin(elapsedGameSeconds: number): number
	local base = PERCENT_TILES_OWNED_TO_WIN
	local sd = self:overtimeConfig()
	if not sd.enabled then
		return base
	end
	local secondsPastStart = math.floor(elapsedGameSeconds) - sd.startMinutes * 60
	if secondsPastStart <= 0 then
		return base
	end
	return math.max(0, base - math.floor((secondsPastStart * sd.dropPercentPerMinute) / 60))
end

function Config:armyLimitWarningThreshold(): number
	return 0.8
end

function Config:boatMaxNumber(): number
	if self:isUnitDisabled(UnitType.TransportShip) then
		return 0
	end
	return 3
end

function Config:numSpawnPhaseTurns(): number
	if self._gameConfig.gameType == GameType.Singleplayer then
		return 100
	end
	if self:isRandomSpawn() then
		return 150
	end
	return 200
end

function Config:numBots(): number
	return self:bots()
end

--[[
	Per-tile attack outcome. Pure: depends only on `input` and tunables.
	Returns attackerTroopLoss, defenderTroopLoss, tickFraction.

	input = {
		terrain, attackTroops,
		attacker = { type, numTiles },
		defender = { type, numTiles, troops, isTraitor, isDisconnectedTeammate } | nil,
		defenderHasDefensePost, falloutRatio (number | nil), borderSize,
	}
]]
function Config:attackLogic(input): (number, number, number)
	local attackTroops = input.attackTroops
	local attacker = input.attacker
	local defender = input.defender
	local mag, tileCost = terrainAttackBase(input.terrain)

	if defender ~= nil and input.defenderHasDefensePost then
		mag *= self:defensePostDefenseBonus()
		tileCost *= self:defensePostSpeedBonus()
	end
	if input.falloutRatio ~= nil then
		local fallout = self:falloutDefenseModifier(input.falloutRatio)
		mag *= fallout
		tileCost *= fallout
	end

	if defender == nil then
		local tickBudget = input.borderSize * 2
		return mag / (if attacker.type == PlayerType.Bot then 10 else 5),
			0,
			within((TERRA_NULLIUS_COST_SCALE * tileCost) / attackTroops, TERRA_NULLIUS_MIN_COST, TERRA_NULLIUS_MAX_COST)
				/ tickBudget
	end

	if defender.isDisconnectedTeammate then
		-- No troop loss if defender is disconnected and on same team
		mag = 0
	end
	if (attacker.type == PlayerType.Human or attacker.type == PlayerType.Nation) and defender.type == PlayerType.Bot then
		mag *= BOT_DEFENDER_LOSS_MULT
	end

	local largeAttackerBonus = largeTerritoryBonus(attacker.numTiles, LARGE_ATTACKER_DEPTH)
	local largeDefenderBonus = largeTerritoryBonus(defender.numTiles, LARGE_DEFENDER_DEPTH)

	local traitorLossMod = if defender.isTraitor then self:traitorDefenseDebuff() else 1
	local traitorCostMod = if defender.isTraitor then self:traitorSpeedDebuff() else 1

	-- Defender loses its average troops-per-tile.
	local defenderTroopLoss = defender.troops / defender.numTiles

	local troopRatio = defender.troops / attackTroops
	local attackerTroopLoss = mag
		* traitorLossMod
		* within(troopRatio, 0.6, 2)
		* (ATTACKER_LOSS_BASE * largeAttackerBonus * largeDefenderBonus + ATTACKER_LOSS_PER_DENSITY * defenderTroopLoss)

	local speedCost = (within(troopRatio, 0.82, 7.5) * within(troopRatio / 20, 1, 50)) / SPEED_COST_DIVISOR
	local largeAttackerSpeedBonus = largeTerritoryBonus(attacker.numTiles, LARGE_ATTACKER_SPEED_DEPTH)
	return attackerTroopLoss,
		defenderTroopLoss,
		(speedCost * tileCost * largeAttackerSpeedBonus * largeDefenderBonus * traitorCostMod) / input.borderSize
end

function Config:boatAttackAmount(attacker, _defender): number
	return math.floor(attacker:troops() / 5)
end

function Config:attackAmount(attacker, _defender): number
	if attacker:type() == PlayerType.Bot then
		return attacker:troops() / 20
	end
	return attacker:troops() / 5
end

function Config:startManpower(playerInfo): number
	if playerInfo.playerType == PlayerType.Bot then
		return 10000
	end
	if playerInfo.playerType == PlayerType.Nation then
		local d = self._gameConfig.difficulty
		if d == Difficulty.Easy then
			return 12500
		elseif d == Difficulty.Medium then
			return 18750
		elseif d == Difficulty.Hard then
			return 25000 -- Like humans
		elseif d == Difficulty.Impossible then
			return 31250
		end
		error(`Unexpected difficulty: {d}`)
	end
	return if self:_hasInfiniteTroopsForInfo(playerInfo) then 1000000 else 25000
end

function Config:maxTroops(player): number
	local maxTroops
	if player:type() == PlayerType.Human and self:_hasInfiniteTroopsFor(player) then
		maxTroops = 1000000000
	else
		local cityLevels = 0
		for _, city in player:units(UnitType.City) do
			if not city:isUnderConstruction() then
				cityLevels += city:level()
			end
		end
		maxTroops = 2 * (pow(player:numTilesOwned(), 0.6) * 1000 + 50000) + cityLevels * self:cityTroopIncrease()
	end

	local t = player:type()
	if t == PlayerType.Bot then
		return maxTroops / 3
	end
	if t == PlayerType.Human then
		return maxTroops
	end
	local d = self._gameConfig.difficulty
	if d == Difficulty.Easy then
		return maxTroops * 0.5
	elseif d == Difficulty.Medium then
		return maxTroops * 0.75
	elseif d == Difficulty.Hard then
		return maxTroops * 1 -- Like humans
	elseif d == Difficulty.Impossible then
		return maxTroops * 1.25
	end
	error(`Unexpected difficulty: {d}`)
end

function Config:troopIncreaseRate(player): number
	local max = self:maxTroops(player)

	local toAdd = 10 + pow(player:troops(), 0.73) / 4

	local ratio = 1 - player:troops() / max
	toAdd *= ratio

	local t = player:type()
	if t == PlayerType.Bot then
		toAdd *= 0.5
	end

	if t == PlayerType.Nation then
		local d = self._gameConfig.difficulty
		if d == Difficulty.Easy then
			toAdd *= 0.9
		elseif d == Difficulty.Medium then
			toAdd *= 0.95
		elseif d == Difficulty.Hard then
			toAdd *= 1 -- Like humans
		elseif d == Difficulty.Impossible then
			toAdd *= 1.05
		else
			error(`Unexpected difficulty: {d}`)
		end
	end

	return math.min(player:troops() + toAdd, max) - player:troops()
end

-- Units ----------------------------------------------------------------------------

local SAM_CONSTRUCTION_TICKS = 30 * 10
Config.SAM_CONSTRUCTION_TICKS = SAM_CONSTRUCTION_TICKS

function Config:_hasInfiniteGoldFor(player): boolean
	if self:infiniteGold() then
		return true
	end
	return self:_hostCheats().infiniteGold == true and player:isLobbyCreator()
end

-- Cost counts built units of `types` (owned vs constructed, whichever is lower).
function Config:_costWrapper(costFn: (number) -> number, ...: string)
	local types = { ... }
	return function(_game, player, extraUnits: number?): number
		if player:type() == PlayerType.Human and self:_hasInfiniteGoldFor(player) then
			return 0
		end
		local numUnits = 0
		for _, t in types do
			numUnits += math.min(player:unitsOwned(t), player:unitsConstructed(t))
		end
		return math.floor(costFn(numUnits + (extraUnits or 0)))
	end
end

local function free()
	return 0
end

-- UnitInfo: { cost(game, player, extraUnits?) -> gold, maxHealth?, damage?,
-- constructionDuration?, upgradable? }
function Config:unitInfo(unitType: string)
	self._unitInfoCache = self._unitInfoCache or {}
	local cached = self._unitInfoCache[unitType]
	if cached then
		return cached
	end
	local pow2 = DetMath.pow2
	local instant = self:instantBuild()
	local info
	if unitType == UnitType.TransportShip then
		info = { cost = free }
	elseif unitType == UnitType.Warship then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, (n + 1) * 250000)
			end, UnitType.Warship),
			maxHealth = 1000,
		}
	elseif unitType == UnitType.Shell then
		info = { cost = free, damage = 250 }
	elseif unitType == UnitType.SAMMissile then
		info = { cost = free }
	elseif unitType == UnitType.Port then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, pow2(n) * 125000)
			end, UnitType.Port, UnitType.Factory),
			constructionDuration = if instant then 0 else 5 * 10,
			upgradable = true,
		}
	elseif unitType == UnitType.AtomBomb then
		info = { cost = self:_costWrapper(function()
			return 750000
		end, UnitType.AtomBomb) }
	elseif unitType == UnitType.HydrogenBomb then
		info = { cost = self:_costWrapper(function()
			return 5000000
		end, UnitType.HydrogenBomb) }
	elseif unitType == UnitType.MIRV then
		info = {
			cost = function(game, player)
				if player:type() == PlayerType.Human and self:_hasInfiniteGoldFor(player) then
					return 0
				end
				return 25000000 + game:stats():numMirvsLaunched() * 15000000
			end,
		}
	elseif unitType == UnitType.MIRVWarhead or unitType == UnitType.TradeShip or unitType == UnitType.Train then
		info = { cost = free }
	elseif unitType == UnitType.MissileSilo then
		info = {
			cost = self:_costWrapper(function()
				return 1000000
			end, UnitType.MissileSilo),
			constructionDuration = if instant then 0 else 10 * 10,
			upgradable = true,
		}
	elseif unitType == UnitType.DefensePost then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(250000, (n + 1) * 50000)
			end, UnitType.DefensePost),
			constructionDuration = if instant then 0 else 5 * 10,
		}
	elseif unitType == UnitType.SAMLauncher then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(3000000, (n + 1) * 1500000)
			end, UnitType.SAMLauncher),
			constructionDuration = if instant then 0 else SAM_CONSTRUCTION_TICKS,
			upgradable = true,
		}
	elseif unitType == UnitType.City then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, pow2(n) * 125000)
			end, UnitType.City),
			constructionDuration = if instant then 0 else 2 * 10,
			upgradable = true,
		}
	elseif unitType == UnitType.Factory then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, pow2(n) * 125000)
			end, UnitType.Factory, UnitType.Port),
			constructionDuration = if instant then 0 else 2 * 10,
			upgradable = true,
		}
	else
		error(`Unexpected unit type: {unitType}`)
	end
	self._unitInfoCache[unitType] = info
	return info
end

function Config:defaultSamRange(): number
	return 70
end
function Config:maxSamRange(): number
	return 150
end
function Config:samRange(level: number): number
	return self:maxSamRange() - 480 / (level + 5)
end
function Config:samUpgradeDuration(): number
	return math.floor(self:SAMCooldown() / 2)
end
function Config:dynamicSamRange(sam, currentTick: number): number
	local state = sam:samLauncherState()
	if state == nil or state.upgradeStartTick == nil then
		return self:samRange(sam:level())
	end
	local duration = state.duration or self:samUpgradeDuration()
	local elapsed = currentTick - state.upgradeStartTick
	if elapsed >= duration then
		return self:samRange(state.targetLevel)
	end
	local targetRange = self:samRange(state.targetLevel)
	return state.startRange + ((targetRange - state.startRange) * elapsed) / duration
end
function Config:defaultSamMissileSpeed(): number
	return 12
end
function Config:structureMinDist(): number
	return 15
end
function Config:shellLifetime(): number
	return 50
end
function Config:warshipShellLifetime(): number
	return 20
end
function Config:warshipPatrolRange(): number
	return 100
end
function Config:warshipTargettingRange(): number
	return 130
end
function Config:warshipShellAttackRate(): number
	return 20
end
function Config:warshipDockingRange(): number
	return 5
end
function Config:warshipPortHealingBonusPerLevel(): number
	return 5
end
function Config:warshipRetreatHealthPercent(): number
	return 75
end
function Config:warshipPassiveHealing(): number
	return 1
end
function Config:warshipPassiveHealingRange(): number
	return 150
end
function Config:warshipPortSwitchThreshold(): number
	return 0.75
end
function Config:warshipMaxVeterancy(): number
	return 3
end
function Config:warshipVeterancyHealthBonus(): number
	return 20
end
function Config:warshipVeterancyShellDamageBonus(): number
	return 20
end
function Config:warshipVeterancyTransportKills(): number
	return 10
end
function Config:warshipVeterancyTradeCaptures(): number
	return 25
end
function Config:defensePostShellAttackRate(): number
	return 100
end
function Config:safeFromPiratesCooldownMax(): number
	return 20
end
function Config:defensePostTargettingRange(): number
	return 75
end
function Config:radiusPortSpawn(): number
	return 20
end

function Config:goldAdditionRate(player): number
	local multiplier = self:_goldMultiplierFor(player)
	local baseRate = if player:type() == PlayerType.Bot then 50 else 100
	return math.floor(baseRate * multiplier)
end

return Config
