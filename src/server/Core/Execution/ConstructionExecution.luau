-- Port of OpenFrontIO src/core/execution/ConstructionExecution.ts.
-- Builds a structure (under construction for constructionDuration ticks),
-- then hands it to its structure execution. Nukes / warships delegate to
-- their own executions immediately.

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local StructureExecutions = require(script.Parent.StructureExecutions)

local UnitType = GameTypes.UnitType

local STRUCTURES = {
	[UnitType.Port] = true,
	[UnitType.MissileSilo] = true,
	[UnitType.DefensePost] = true,
	[UnitType.SAMLauncher] = true,
	[UnitType.City] = true,
	[UnitType.Factory] = true,
}

local ConstructionExecution = {}
ConstructionExecution.__index = ConstructionExecution

function ConstructionExecution.new(player, constructionType: string, tile: number, rocketDirectionUp: boolean?, amount: number?)
	return setmetatable({
		player = player,
		constructionType = constructionType,
		tile = tile,
		rocketDirectionUp = rocketDirectionUp,
		amount = amount,
		structure = nil,
		_active = true,
		ticksUntilComplete = 0,
	}, ConstructionExecution)
end

function ConstructionExecution:init(mg)
	self.mg = mg
	if mg:config():isUnitDisabled(self.constructionType) then
		warn(`cannot build construction {self.constructionType} because it is disabled`)
		self._active = false
		return
	end
	if not mg:isValidRef(self.tile) then
		warn(`cannot build construction invalid tile {self.tile}`)
		self._active = false
	end
end

function ConstructionExecution:tick()
	if self.structure == nil then
		local info = self.mg:unitInfo(self.constructionType)
		if not STRUCTURES[self.constructionType] then
			-- Nukes / warships: validation and gold happen in their execution.
			self:_completeConstruction()
			self._active = false
			return
		end
		local spawnTile = self.player:canBuild(self.constructionType, self.tile)
		if spawnTile == false then
			warn(`cannot build {self.constructionType}`)
			self._active = false
			return
		end
		self.structure = self.player:buildUnit(self.constructionType, spawnTile, {})
		local duration = info.constructionDuration or 0
		if duration > 0 then
			self.structure:setUnderConstruction(true)
			self.ticksUntilComplete = duration
			return
		end
		self:_completeConstruction()
		self._active = false
		return
	end

	if not self.structure:isActive() then
		self._active = false
		return
	end
	if self.player ~= self.structure:owner() then
		self.player = self.structure:owner()
	end
	if self.ticksUntilComplete == 0 then
		self.player = self.structure:owner()
		self:_completeConstruction()
		self._active = false
		return
	end
	self.ticksUntilComplete -= 1
end

function ConstructionExecution:_completeConstruction()
	if self.structure then
		self.structure:setUnderConstruction(false)
	end
	local mg, t = self.mg, self.constructionType
	if t == UnitType.Port then
		local PortExecution = require(script.Parent.PortExecution)
		mg:addExecution(PortExecution.new(self.structure))
	elseif t == UnitType.MissileSilo then
		mg:addExecution(StructureExecutions.MissileSiloExecution.new(self.structure))
	elseif t == UnitType.DefensePost then
		mg:addExecution(StructureExecutions.DefensePostExecution.new(self.structure))
	elseif t == UnitType.City then
		mg:addExecution(StructureExecutions.CityExecution.new(self.structure))
	elseif t == UnitType.AtomBomb or t == UnitType.HydrogenBomb or t == UnitType.MIRV then
		warn("TODO(port): nukes") -- NukeExecution / MirvExecution
	elseif t == UnitType.Warship then
		warn("TODO(port): warships") -- WarshipExecution
	elseif t == UnitType.SAMLauncher then
		warn("TODO(port): SAMLauncherExecution")
	elseif t == UnitType.Factory then
		warn("TODO(port): FactoryExecution")
	else
		warn(`unit type {t} cannot be constructed`)
	end
end

function ConstructionExecution:isActive(): boolean
	return self._active
end

function ConstructionExecution:activeDuringSpawnPhase(): boolean
	return false
end

return ConstructionExecution
