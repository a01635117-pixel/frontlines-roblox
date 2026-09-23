-- Client entry point: receives the match from the server, draws the map and
-- territories, and turns clicks into intents (spawn / attack), like OpenFront.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ColorAllocator = require(Shared:WaitForChild("ColorAllocator"))
local DetMath = require(Shared:WaitForChild("DetMath"))
local GameMap = require(Shared:WaitForChild("GameMap"))
local MapLoader = require(Shared:WaitForChild("MapLoader"))
local Net = require(Shared:WaitForChild("Net"))
local TerrainColors = require(Shared:WaitForChild("TerrainColors"))

local Format = require(script.Parent:WaitForChild("Format"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local MapCamera = require(script.Parent:WaitForChild("MapCamera"))
local TerritoryRenderer = require(script.Parent:WaitForChild("TerritoryRenderer"))

local player = Players.LocalPlayer
workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable

-- GUI ----------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "OpenFront"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local bg = TerrainColors.BACKGROUND_BASE
local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.fromRGB(bg[1], bg[2], bg[3])
background.BorderSizePixel = 0
background.Parent = gui

local hud = Hud.new(gui)
hud:setStatus("Waiting for the match to start…")
gui.Parent = player:WaitForChild("PlayerGui")

-- Match state --------------------------------------------------------------------

local state = Net.GameState.OnClientEvent:Wait()
local gameMap, _mini, manifest = MapLoader.load(Shared.Maps[state.mapId])
local W, H = gameMap:width(), gameMap:height()

local camera = MapCamera.new(background, W, H)
local renderer = TerritoryRenderer.new(camera, gameMap)
local theme = ColorAllocator.Theme.new()

local roster = {} -- smallID -> entry
local stats = {} -- smallID -> { tiles, troops, gold }
local mySmallID: number? = nil
local inSpawnPhase = state.inSpawnPhase
local spawnPhaseTurns = state.spawnPhaseTurns
local tickBase, tickClock = state.tick, os.clock()
local gameOver = false

local function addPlayers(entries)
	for _, e in entries do
		roster[e.smallID] = e
		local c = theme:territoryColor(e.id, e.type)
		renderer:setPlayerColor(e.smallID, c.rgb, c.border)
		if e.clientID == state.yourClientID then
			mySmallID = e.smallID
		end
	end
end

addPlayers(state.players)
renderer:loadState(Net.unwrap(state.tiles))
camera:fit()

local function estimatedTick(): number
	return tickBase + math.floor((os.clock() - tickClock) * 10)
end

-- Upstream Config.maxTroops for a human (no cities yet).
local function maxTroopsForHuman(tiles: number): number
	return 2 * (DetMath.pow(tiles, 0.6) * 1000 + 50000)
end

local terrainNames = {}
for name, value in GameMap.TerrainType do
	terrainNames[value] = name
end

-- Server events ------------------------------------------------------------------

Net.Roster.OnClientEvent:Connect(addPlayers)

Net.Tick.OnClientEvent:Connect(function(buf)
	local tick = Net.unpackTiles(buf, function(tile, s)
		renderer:setState(tile, s)
	end)
	tickBase, tickClock = tick, os.clock()
end)

local function refreshBoard()
	local rows = {}
	for smallID, s in stats do
		local e = roster[smallID]
		if e and s.tiles > 0 then
			table.insert(rows, { name = e.name, pct = s.tiles / gameMap:numLandTiles(), troops = s.troops, isMe = smallID == mySmallID, tiles = s.tiles })
		end
	end
	table.sort(rows, function(a, b)
		return a.tiles > b.tiles
	end)
	-- Always show the local player, even outside the top 10.
	local top = {}
	for i = 1, math.min(10, #rows) do
		top[i] = rows[i]
	end
	if mySmallID and #top == 10 then
		local shown = false
		for _, r in top do
			shown = shown or r.isMe
		end
		if not shown then
			for _, r in rows do
				if r.isMe then
					top[10] = r
				end
			end
		end
	end
	hud:setLeaderboard(top)
end

Net.Stats.OnClientEvent:Connect(function(buf)
	Net.unpackStats(buf, function(smallID, tiles, troops, gold)
		stats[smallID] = { tiles = tiles, troops = troops, gold = gold }
	end)
	local mine = mySmallID and stats[mySmallID]
	if mine then
		hud:setMyStats(mine.troops, maxTroopsForHuman(mine.tiles), mine.gold)
	end
	refreshBoard()
end)

Net.Event.OnClientEvent:Connect(function(evt)
	if evt.type == "SpawnPhaseEnd" then
		inSpawnPhase = false
	elseif evt.type == "Win" then
		gameOver = true
		hud:showWinner(if evt.winnerSmallID == mySmallID then "You won!" else `{evt.winnerName} has won the game`)
	end
end)

-- Input ----------------------------------------------------------------------------

local function tileAtScreen(p: Vector2): number?
	local x, y = camera:mapPos(p)
	if gameMap:isValidCoord(x, y) then
		return gameMap:ref(x, y)
	end
	return nil
end

camera.onClick = function(p: Vector2)
	if gameOver or mySmallID == nil then
		return
	end
	local tile = tileAtScreen(p)
	if tile == nil or not gameMap:isLand(tile) or gameMap:isImpassable(tile) then
		return -- TODO(port): boats (clicking water / across water)
	end
	local owner = renderer:ownerAt(tile)
	if inSpawnPhase then
		if owner == 0 then
			Net.Intent:FireServer({ type = "spawn", tile = tile })
		end
		return
	end
	if owner == mySmallID then
		return
	end
	Net.Intent:FireServer({ type = "attack", targetSmallID = owner, ratio = hud.ratio })
end

camera.onHover = function(p: Vector2)
	local tile = tileAtScreen(p)
	if tile == nil then
		hud:setHover(nil)
		return
	end
	local owner = renderer:ownerAt(tile)
	local e = roster[owner]
	if e then
		local s = stats[owner]
		hud:setHover(if s then `{e.name}  ·  {Format.renderTroops(s.troops)} troops` else e.name)
	elseif gameMap:isWater(tile) then
		hud:setHover(if gameMap:isOcean(tile) then "Ocean" else "Lake")
	else
		hud:setHover(`Unclaimed {terrainNames[gameMap:terrainType(tile)]}`)
	end
end

-- Frame loop ------------------------------------------------------------------------

RunService.RenderStepped:Connect(function()
	renderer:flush()
	if gameOver then
		hud:setStatus("")
	elseif inSpawnPhase then
		local left = math.max(0, math.ceil((spawnPhaseTurns - estimatedTick()) / 10))
		local mine = mySmallID and stats[mySmallID]
		local chosen = mine ~= nil and mine.tiles > 0
		hud:setStatus(if chosen then `Spawn chosen · game starts in {left}s` else `Choose your starting location · {left}s`)
	else
		hud:setStatus("")
	end
end)

print(`[Client] joined {manifest.name} {W}x{H}, {#state.players} player(s) in roster, you = {tostring(mySmallID)}`)
