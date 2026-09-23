-- Port of OpenFrontIO src/core/execution/utils/AiAttackBehavior.ts.
--
-- Ported so far: the parts tribes (bots) use — attackRandomTarget,
-- getNeighborTraitorToAttack, sendAttack and their helpers.
-- TODO(port): nation-only behaviour (maybeAttack, attackBestTarget,
-- assistAllies, attackBots, attackWithRandomBoat, emoji/alliance behaviours).

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local AttackExecution = require(script.Parent.AttackExecution)
local ExecUtil = require(script.Parent.ExecUtil)
local TransportShipExecution = require(script.Parent.TransportShipExecution)
local TransportShipUtils = require(Core.TransportShipUtils)

local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode
local UnitType = GameTypes.UnitType
local Structures = GameTypes.Structures

local AiAttackBehavior = {}
AiAttackBehavior.__index = AiAttackBehavior

function AiAttackBehavior.new(random, game, player, triggerRatio: number, reserveRatio: number, expandRatio: number, allianceBehavior, emojiBehavior)
	return setmetatable({
		random = random,
		game = game,
		player = player,
		triggerRatio = triggerRatio,
		reserveRatio = reserveRatio,
		expandRatio = expandRatio,
		allianceBehavior = allianceBehavior,
		emojiBehavior = emojiBehavior,
		_botAttackTroopsSent = 0,
		_nbuf = { 0, 0, 0, 0 },
	}, AiAttackBehavior)
end

function AiAttackBehavior:_hasReserveRatioTroops(): boolean
	local maxTroops = self.game:config():maxTroops(self.player)
	return self.player:troops() / maxTroops >= self.reserveRatio
end

function AiAttackBehavior:_hasTriggerRatioTroops(): boolean
	local maxTroops = self.game:config():maxTroops(self.player)
	return self.player:troops() / maxTroops >= self.triggerRatio
end

function AiAttackBehavior:findIncomingAttackPlayer()
	local player = self.player
	local largestAttack = 0
	local largestAttacker = nil
	for _, attack in player:incomingAttacks() do
		if player:isFriendly(attack:attacker()) then
			continue
		end
		-- Ignore bot attacks if we are not a bot.
		if player:type() ~= PlayerType.Bot and attack:attacker():type() == PlayerType.Bot then
			continue
		end
		if attack:troops() <= largestAttack then
			continue
		end
		largestAttack = attack:troops()
		largestAttacker = attack:attacker()
	end
	return largestAttacker
end

function AiAttackBehavior:attackRandomTarget()
	-- Save up troops until we reach the trigger ratio
	if not self:_hasTriggerRatioTroops() then
		return
	end

	-- Retaliate against incoming attacks
	local incomingAttackPlayer = self:findIncomingAttackPlayer()
	if incomingAttackPlayer then
		if self:sendAttack(incomingAttackPlayer, true) then
			return
		end
	end

	-- Select a traitor as an enemy
	local toAttack = self:getNeighborTraitorToAttack()
	if toAttack ~= nil then
		if self.random:chance(3) then
			if self:sendAttack(toAttack) then
				return
			end
		end
	end

	-- Choose a new enemy randomly
	local neighbors = self.player:nearby()
	for _, neighbor in self.random:shuffleArray(neighbors) do
		if not neighbor:isPlayer() then
			continue
		end
		if self.player:isFriendly(neighbor) then
			continue
		end
		if neighbor:type() == PlayerType.Nation or neighbor:type() == PlayerType.Human then
			if self.random:chance(2) then
				continue
			end
		end
		if self:sendAttack(neighbor) then
			return
		end
	end
end

function AiAttackBehavior:getNeighborTraitorToAttack()
	if self.game:config():disableAlliances() then
		return nil
	end
	local traitors = {}
	for _, n in self.player:nearby() do
		if n:isPlayer() and self.player:isFriendly(n) == false and n:isTraitor() then
			table.insert(traitors, n)
		end
	end
	return if #traitors > 0 then self.random:randElement(traitors) else nil
end

function AiAttackBehavior:forceSendAttack(target)
	self.game:addExecution(
		AttackExecution.new(self.player:troops() / 2, self.player, if target:isPlayer() then target:id() else nil)
	)
end

function AiAttackBehavior:sendAttack(target, force: boolean?): boolean
	if not force and not self:shouldAttack(target) then
		return false
	end
	if target:isPlayer() then
		if self.player:sharesBorderWith(target) then
			return self:_sendLandAttack(target)
		end
		return self:_sendBoatAttack(target)
	end
	-- sharesBorderWith(TerraNullius) counts water as TN, so use a land-only
	-- adjacency check to decide land vs boat attack.
	if self:_hasLandBorderWithTerraNullius() then
		return self:_sendLandAttack(target)
	end
	return self:_sendBoatAttackToNearbyTerraNullius()
end

function AiAttackBehavior:_hasLandBorderWithTerraNullius(): boolean
	local map = self.game:map()
	local nbuf = self._nbuf
	for border in self.player:borderTiles() do
		local n = map:neighbors4(border, nbuf)
		for i = 1, n do
			local neighbor = nbuf[i]
			if map:isLand(neighbor) and not map:isImpassable(neighbor) and not map:hasOwner(neighbor) then
				return true
			end
		end
	end
	return false
end

-- The player's shore border tiles, in border-set order.
function AiAttackBehavior:_shoreTiles(player): { number }
	local out = {}
	for t in player:borderTiles() do
		if self.game:isShore(t) then
			table.insert(out, t)
		end
	end
	return out
end

-- Scans every 10th shore border tile for unowned land within 5 water tiles
-- in each cardinal direction and sends a boat to the first match.
local DIRECTIONS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }
function AiAttackBehavior:_sendBoatAttackToNearbyTerraNullius(): boolean
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return false
	end
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return false
	end
	local shores = self:_shoreTiles(player)
	for i = 1, #shores, 10 do
		local border = shores[i]
		local bx, by = game:x(border), game:y(border)
		for _, d in DIRECTIONS do
			local dx, dy = d[1], d[2]
			local x1, y1 = bx + dx, by + dy
			if not game:isValidCoord(x1, y1) or not game:isWater(game:ref(x1, y1)) then
				continue
			end
			local nx, ny = bx + dx * 5, by + dy * 5
			if not game:isValidCoord(nx, ny) then
				continue
			end
			local tile = game:ref(nx, ny)
			if not game:isLand(tile) or game:isImpassable(tile) or game:hasOwner(tile) or game:hasFallout(tile) then
				continue
			end
			if not TransportShipUtils.canBuildTransportShip(game, player, tile) then
				continue
			end
			local troops = math.min(player:troops() / 5, self:_troopSendCapForExpansion())
			if troops < 1 then
				return false
			end
			game:addExecution(TransportShipExecution.new(player, tile, troops))
			return true
		end
	end
	return false
end

function AiAttackBehavior:shouldAttack(other): boolean
	if
		-- Always attack Terra Nullius, non-humans and traitors
		other:isPlayer() == false
		or other:type() ~= PlayerType.Human
		or other:isTraitor()
		-- Always attack if we are a bot or in an HvN game
		or self.player:type() == PlayerType.Bot
		or self.game:config():gameConfig().playerTeams == GameTypes.HumansVsNations
	then
		return true
	end
	-- Prevent attacking of humans on lower difficulties
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy and self.random:nextInt(0, 4) ~= 0 then
		return false
	end
	if difficulty == Difficulty.Medium and self.random:chance(4) then
		return false
	end
	return true
end

-- Hard & Impossible nations in FFA: true if `troops` < 20% of the target's.
function AiAttackBehavior:_isAttackTooWeak(troops: number, target): boolean
	if self.player:type() == PlayerType.Bot then
		return false
	end
	if self.game:config():gameConfig().gameMode == GameMode.Team then
		return false
	end
	if #self.player:incomingAttacks() > 0 then
		return false
	end
	local difficulty = self.game:config():gameConfig().difficulty
	return (difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible) and troops < target:troops() * 0.2
end

-- Hard & Impossible nations in FFA: max troops sendable without dropping
-- below a fraction of the strongest non-allied neighbor. Infinity if no cap.
function AiAttackBehavior:_troopSendCap(): number
	local player = self.player
	if player:type() == PlayerType.Bot then
		return math.huge
	end
	if self.game:config():gameConfig().gameMode == GameMode.Team then
		return math.huge
	end
	local difficulty = self.game:config():gameConfig().difficulty
	local retainFraction
	if difficulty == Difficulty.Hard then
		retainFraction = 0.75
	elseif difficulty == Difficulty.Impossible then
		retainFraction = 0.9
	else
		return math.huge
	end

	local maxNeighborTroops = 0
	for _, n in player:nearby() do
		if n:isPlayer() and not player:isFriendly(n) and n:type() ~= PlayerType.Bot and n:troops() > maxNeighborTroops then
			maxNeighborTroops = n:troops()
		end
	end

	local cap
	if maxNeighborTroops == 0 then
		cap = math.huge
	else
		local minRetained = math.ceil(maxNeighborTroops * retainFraction)
		cap = math.max(0, player:troops() - minRetained)
	end

	local incoming = player:incomingAttacks()
	if #incoming > 0 then
		local totalIncoming = 0
		for _, a in incoming do
			totalIncoming += a:troops()
		end
		cap = math.max(cap, totalIncoming)
	end
	return cap
end

-- Like troopSendCap(), floored above 0: Terra Nullius can't fight back.
function AiAttackBehavior:_troopSendCapForExpansion(): number
	local cap = self:_troopSendCap()
	if cap > 0 then
		return cap
	end
	return math.ceil(self.player:troops() * 0.05)
end

function AiAttackBehavior:_calculateAttackTroops(target, nonBotTroops: (number) -> number): number?
	local player = self.player
	local maxTroops = self.game:config():maxTroops(player)
	local botWithStructures = false
	if target:isPlayer() and target:type() == PlayerType.Bot then
		for _, u in target:units() do
			if Structures.has(u:type()) then
				botWithStructures = true
				break
			end
		end
	end
	-- Expand ratio when attacking a bot that owns structures (recapture ASAP).
	local useReserve = target:isPlayer() and not botWithStructures
	local reserveRatio = if useReserve then self.reserveRatio else self.expandRatio
	local targetTroops = maxTroops * reserveRatio

	local troops
	local isBotAttack = target:isPlayer() and target:type() == PlayerType.Bot and player:type() ~= PlayerType.Bot
	if isBotAttack then
		troops = self:_calculateBotAttackTroops(target, player:troops() - targetTroops - self._botAttackTroopsSent)
	else
		troops = nonBotTroops(targetTroops)
	end

	troops = math.min(troops, if target:isPlayer() then self:_troopSendCap() else self:_troopSendCapForExpansion())

	if troops < 1 then
		return nil
	end

	if target:isPlayer() and self:_isAttackTooWeak(troops, target) then
		return nil
	end

	if target:isPlayer() and player:type() == PlayerType.Nation then
		-- TODO(port): NationEmojiBehavior.maybeSendAttackEmoji
		if self.emojiBehavior then
			self.emojiBehavior:maybeSendAttackEmoji(target)
		end
	end

	if isBotAttack then
		self._botAttackTroopsSent += troops
	end
	return troops
end

function AiAttackBehavior:_sendLandAttack(target): boolean
	local troops = self:_calculateAttackTroops(target, function(targetTroops)
		return self.player:troops() - targetTroops
	end)
	if troops == nil then
		return false
	end
	self.game:addExecution(AttackExecution.new(troops, self.player, if target:isPlayer() then target:id() else nil))
	return true
end

function AiAttackBehavior:_sendBoatAttack(target): boolean
	local game = self.game
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return false
	end
	local _, closestY = ExecUtil.closestTwoTiles(game, self:_shoreTiles(self.player), self:_shoreTiles(target))
	if closestY == nil then
		return false
	end
	if not TransportShipUtils.canBuildTransportShip(game, self.player, closestY) then
		return false
	end
	local troops = self:_calculateAttackTroops(target, function()
		return self.player:troops() / 5
	end)
	if troops == nil then
		return false
	end
	game:addExecution(TransportShipExecution.new(self.player, closestY, troops))
	return true
end

function AiAttackBehavior:_calculateBotAttackTroops(target, maxTroops: number): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return maxTroops
	end
	local troops = target:troops() * 4
	-- Don't send more troops than maxTroops (keep reserve)
	if troops > maxTroops then
		if maxTroops < target:troops() * 2 then
			troops = 0
		else
			troops = maxTroops
		end
	end
	return troops
end

return AiAttackBehavior
