-- Port of helpers from OpenFrontIO src/core/execution/Util.ts and
-- src/core/Util.ts used by executions.

local Shared = game:GetService("ReplicatedStorage").Shared
local GameMap = require(Shared.GameMap)

local ExecUtil = {}

-- Tiles within a radius-4 circle of `tile` (flood-filled, upstream order).
-- requireAllValid: returns nil if any of them is owned / water / impassable.
function ExecUtil.getSpawnTiles(gm, tile: number, requireAllValid: boolean?): { number }?
	local spawnTiles = gm:bfs(tile, GameMap.euclDistFN(tile, 4, true)):toArray()
	local function isInvalid(t: number): boolean
		return gm:hasOwner(t) or not gm:isLand(t) or gm:isImpassable(t)
	end
	if not requireAllValid then
		local out = {}
		for _, t in spawnTiles do
			if not isInvalid(t) then
				table.insert(out, t)
			end
		end
		return out
	end
	for _, t in spawnTiles do
		if isInvalid(t) then
			return nil
		end
	end
	return spawnTiles
end

-- Returns (closestRef | nil, distance) by Manhattan distance, first wins ties.
function ExecUtil.closestTile(gm, refs, tile: number): (number?, number)
	local minDistance = math.huge
	local minRef = nil
	for _, ref in refs do
		local distance = gm:manhattanDist(ref, tile)
		if distance < minDistance then
			minDistance = distance
			minRef = ref
		end
	end
	return minRef, minDistance
end

-- Upstream Util.getMode over an insertion-ordered map (PlayerImpl.OrderedMap):
-- first key with the strictly largest count.
function ExecUtil.getMode(counts)
	local mode = nil
	local maxCount = 0
	for item, count in counts:entries() do
		if count > maxCount then
			maxCount = count
			mode = item
		end
	end
	return mode
end

return ExecUtil
