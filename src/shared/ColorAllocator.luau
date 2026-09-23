-- Port of OpenFrontIO src/client/theme/ColorAllocator.ts and the territory
-- colour dispatch from ThemeProvider.ts (default theme, FFA).
--
-- CIEDE2000 distances come precomputed from colord (Data/ThemeColors), so
-- "most distinct colour" picks are identical to upstream.

local PseudoRandom = require(script.Parent.PseudoRandom)
local Util = require(script.Parent.Util)
local ThemeColors = require(script.Parent.Data.ThemeColors)

local ColorAllocator = {}
ColorAllocator.__index = ColorAllocator

-- pool: list of { rgb, border }; delta: row-major CIEDE2000 matrix for pool.
-- fallback: extra colours used once the pool is exhausted.
function ColorAllocator.new(pool, delta: { number }?, fallback)
	local n = #pool
	local all = table.clone(pool)
	for _, c in fallback do
		table.insert(all, c)
	end
	local available = {}
	for i = 1, n do
		available[i] = i
	end
	local fallbackIdx = {}
	for i = 1, #all do
		fallbackIdx[i] = i
	end
	return setmetatable({
		_all = all, -- index -> colour
		_poolSize = n,
		_delta = delta,
		_available = available, -- list of indices into _all
		_fallback = fallbackIdx,
		_assigned = {}, -- id -> index
		_assignedOrder = {}, -- indices in assignment order
	}, ColorAllocator)
end

-- Delta between two colours by index. Fallback entries that repeat the pool
-- (the nation allocator uses its pool as fallback) map back onto the pool.
function ColorAllocator:_deltaE(a: number, b: number): number
	local n = self._poolSize
	local pa = if a > n and self._all[a] == self._all[a - n] then a - n else a
	local pb = if b > n and self._all[b] == self._all[b - n] then b - n else b
	if pa > n or pb > n or self._delta == nil then
		error("ColorAllocator: no CIEDE2000 data for fallback colours")
	end
	return self._delta[(pa - 1) * n + pb]
end

function ColorAllocator:assignColor(id: string)
	local idx = self._assigned[id]
	if idx then
		return self._all[idx]
	end
	if #self._available == 0 then
		self._available = table.clone(self._fallback)
	end

	local assignedCount = #self._assignedOrder
	local selected
	if assignedCount == 0 or assignedCount > 50 then
		-- First colour, or past 50 (distinct selection is O(n^2)): random.
		local rand = PseudoRandom.new(Util.simpleHash(id))
		selected = rand:nextInt(0, #self._available) + 1
	else
		-- Most perceptually different from those already handed out.
		local maxDeltaE, maxIndex = 0, 1
		for i, candidate in self._available do
			local minD = math.huge
			for _, assigned in self._assignedOrder do
				minD = math.min(minD, self:_deltaE(candidate, assigned))
			end
			if minD > maxDeltaE then
				maxDeltaE = minD
				maxIndex = i
			end
		end
		selected = maxIndex
	end

	local chosen = table.remove(self._available, selected) :: number
	self._assigned[id] = chosen
	table.insert(self._assignedOrder, chosen)
	return self._all[chosen]
end

-- Theme: territory colour per player, like ThemeProvider.territoryColor.
local Theme = {}
Theme.__index = Theme

function Theme.new()
	-- Nation fallback is the nation pool itself (upstream: new ColorAllocator(nationColors, nationColors)).
	return setmetatable({
		human = ColorAllocator.new(ThemeColors.human, ThemeColors.humanDelta, ThemeColors.fallback),
		nation = ColorAllocator.new(ThemeColors.nation, ThemeColors.nationDelta, ThemeColors.nation),
	}, Theme)
end

-- playerType: "HUMAN" | "BOT" | "NATION". Returns { rgb = {r,g,b}, border = {r,g,b} }.
-- TODO(port): team games (teamColorForPlayer with generated team palettes).
function Theme:territoryColor(playerId: string, playerType: string)
	if playerType == "HUMAN" then
		return self.human:assignColor(playerId)
	elseif playerType == "BOT" then
		-- Tribes use the flat Bot team colour in every mode.
		return ThemeColors.team.Bot
	end
	return self.nation:assignColor(playerId)
end

ColorAllocator.Theme = Theme
return ColorAllocator
