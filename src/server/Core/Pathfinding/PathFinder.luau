-- Port of OpenFrontIO src/core/pathfinding/PathFinder.ts (water parts),
-- PathFinderStepper.ts and types.ts.
--
-- A water path query runs through a transformer chain shared per game:
--   MiniMap( ShoreCoercing( Smoothing( ComponentCheck( HPA* ) ) ) )
-- or, when the abstract graph is missing / tiny, MiniMap(ShoreCoercing(A*)).
-- TODO(port): WaterPathMemo (trade ships), Rail / Station / Air / Parabola.

local AStarWater = require(script.Parent.AStarWater)
local Transformers = require(script.Parent.Transformers)

local PathFinder = {}

local PathStatus = table.freeze({ NEXT = 0, COMPLETE = 2, NOT_FOUND = 3 })
PathFinder.PathStatus = PathStatus

-- PathFinderStepper -----------------------------------------------------------------

local Stepper = {}
Stepper.__index = Stepper

function Stepper.new(finder, config)
	return setmetatable({
		finder = finder,
		config = config or {
			equals = function(a, b)
				return a == b
			end,
		},
		path = nil,
		pathIndex = 0, -- 0-based, like upstream
		lastTo = nil,
	}, Stepper)
end

-- Next step from `from` toward `to`: { status, node? }.
function Stepper:next(from: number, to: number, dist: number?)
	local config = self.config
	if config.preCheck then
		local r = config.preCheck(from, to)
		if r then
			return r
		end
	end
	if config.equals(from, to) then
		return { status = PathStatus.COMPLETE, node = to }
	end
	if dist ~= nil and dist > 0 and config.distance then
		if config.distance(from, to) <= dist then
			return { status = PathStatus.COMPLETE, node = from }
		end
	end
	if self.lastTo == nil or not config.equals(self.lastTo, to) then
		self.path = nil
		self.pathIndex = 0
		self.lastTo = to
	end
	if self.path == nil then
		local ok, path = pcall(function()
			return self.finder:findPath(from, to)
		end)
		if not ok then
			warn("PathFinder threw an error during findPath", path)
			return { status = PathStatus.NOT_FOUND }
		end
		if path == nil then
			return { status = PathStatus.NOT_FOUND }
		end
		self.path = path
		self.pathIndex = 0
		if #path > 0 and config.equals(path[1], from) then
			self.pathIndex = 1
		end
	end
	local path = self.path
	if self.pathIndex > 0 and not config.equals(from, path[self.pathIndex]) then
		self:invalidate()
		self.lastTo = to
		return self:next(from, to, dist)
	end
	if self.pathIndex >= #path then
		return { status = PathStatus.COMPLETE, node = to }
	end
	local nextNode = path[self.pathIndex + 1]
	self.pathIndex += 1
	return { status = PathStatus.NEXT, node = nextNode }
end

function Stepper:invalidate()
	self.path = nil
	self.pathIndex = 0
	self.lastTo = nil
end

-- Copy of the active path starting at the node most recently returned.
function Stepper:pathAfterNext()
	if self.path == nil or self.pathIndex == 0 then
		return nil
	end
	return table.move(self.path, self.pathIndex, #self.path, 1, {})
end

-- One-shot route without touching the cached route.
function Stepper:findPath(from, to: number)
	local config = self.config
	if config.preCheck then
		local fromArray = if type(from) == "table" then from else { from }
		local allFailed = true
		for _, f in fromArray do
			local r = config.preCheck(f, to)
			if not (r and r.status == PathStatus.NOT_FOUND) then
				allFailed = false
				break
			end
		end
		if allFailed then
			return nil
		end
	end
	return self.finder:findPath(from, to)
end
PathFinder.Stepper = Stepper

-- Shared water chain ------------------------------------------------------------------

local chainCache = setmetatable({}, { __mode = "k" }) -- game -> { version, chain }

local function buildWaterChain(game)
	local hpa = game:miniWaterHPA()
	local graph = game:miniWaterGraph()
	local miniMap = game:miniMap()
	if not hpa or not graph or graph.nodeCount < 100 then
		local chain = AStarWater.new(miniMap)
		chain = Transformers.ShoreCoercing.new(chain, miniMap)
		return Transformers.MiniMap.new(chain, game:map(), miniMap)
	end
	local chain = Transformers.ComponentCheck.new(hpa, function(t)
		return graph:getComponentId(t)
	end)
	chain = Transformers.Smoothing.new(chain, miniMap)
	chain = Transformers.ShoreCoercing.new(chain, miniMap)
	return Transformers.MiniMap.new(chain, game:map(), miniMap)
end

local function sharedWaterChain(game)
	local version = game:waterGraphVersion()
	local cached = chainCache[game]
	if not cached or cached.version ~= version then
		cached = { version = version, chain = buildWaterChain(game) }
		chainCache[game] = cached
	end
	return cached.chain
end
PathFinder.sharedWaterChain = sharedWaterChain

local function tileStepperConfig(game)
	return {
		equals = function(a, b)
			return a == b
		end,
		distance = function(a, b)
			return game:manhattanDist(a, b)
		end,
		preCheck = function(from, to)
			if type(from) ~= "number" or type(to) ~= "number" or not game:isValidRef(from) or not game:isValidRef(to) then
				return { status = PathStatus.NOT_FOUND }
			end
			return nil
		end,
	}
end

-- WaterPathFinder ---------------------------------------------------------------------

local WaterPathFinder = {}
WaterPathFinder.__index = WaterPathFinder
WaterPathFinder.STAGGER_SPREAD = 50

-- stagger: ticks to wait before rebuilding after a water-graph change.
function WaterPathFinder.new(game, stagger: number?)
	return setmetatable({
		game = game,
		_stagger = stagger or 0,
		stepper = Stepper.new(sharedWaterChain(game), tileStepperConfig(game)),
		_version = game:waterGraphVersion(),
		_rebuilt = false,
		_countdown = 0,
		_pendingVersion = -1,
	}, WaterPathFinder)
end

function WaterPathFinder:_ensureFresh()
	local v = self.game:waterGraphVersion()
	if v == self._version then
		return
	end
	if self._pendingVersion ~= v then
		self._pendingVersion = v
		self._countdown = self._stagger
	end
	if self._countdown > 0 then
		self._countdown -= 1
		return
	end
	self._version = v
	self.stepper = Stepper.new(sharedWaterChain(self.game), tileStepperConfig(self.game))
	self._rebuilt = true
end

-- True once after the pathfinder was rebuilt (resets on read).
function WaterPathFinder:rebuilt(): boolean
	self:_ensureFresh()
	local v = self._rebuilt
	self._rebuilt = false
	return v
end

function WaterPathFinder:next(from: number, to: number, dist: number?)
	self:_ensureFresh()
	return self.stepper:next(from, to, dist)
end

function WaterPathFinder:findPath(from, to: number)
	self:_ensureFresh()
	return self.stepper:findPath(from, to)
end

function WaterPathFinder:pathForTraversal(from: number, to: number)
	self:_ensureFresh()
	local path = self.stepper:pathAfterNext() or self.stepper:findPath(from, to)
	if path == nil or #path == 0 then
		return { from }
	end
	if path[1] == from then
		return path
	end
	table.insert(path, 1, from)
	return path
end

function WaterPathFinder:invalidate()
	self.stepper:invalidate()
end
PathFinder.WaterPathFinder = WaterPathFinder

return PathFinder
