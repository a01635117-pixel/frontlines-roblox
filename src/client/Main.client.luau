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

local BuildMenu = require(script.Parent:WaitForChild("BuildMenu"))
local Format = require(script.Parent:WaitForChild("Format"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local MapCamera = require(script.Parent:WaitForChild("MapCamera"))
local NameLayer = require(script.Parent:WaitForChild("NameLayer"))
local TerritoryRenderer = require(script.Parent:WaitForChild("TerritoryRenderer"))
local UnitLayer = require(script.Parent:WaitForChild("UnitLayer"))

local player = Players.LocalPlayer
workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
-- Keys 1..0 are build hotkeys (upstream), not backpack slots.
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

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
hud:setCountdown("…", "Waiting for the match to start")
gui.Parent = player:WaitForChild("PlayerGui")

-- Match state --------------------------------------------------------------------

local state = Net.GameState.OnClientEvent:Wait()
local gameMap, _mini, manifest = MapLoader.load(Shared.Maps[state.mapId])
local W, H = gameMap:width(), gameMap:height()

local camera = MapCamera.new(background, W, H)
local renderer = TerritoryRenderer.new(camera, gameMap)
local nameLayer = NameLayer.new(background, camera)
local unitLayer = UnitLayer.new(background, camera, gameMap)
camera.onChanged = function()
	nameLayer:refresh()
	unitLayer:render()
end
local theme = ColorAllocator.Theme.new()

local roster = {} -- smallID -> entry
local stats = {} -- smallID -> { tiles, troops, gold }
local mySmallID: number? = nil
local inSpawnPhase = state.inSpawnPhase
local spawnPhaseTurns = state.spawnPhaseTurns
local tickBase, tickClock = state.tick, os.clock()
local gameOver = false
local haveSpawned = false -- seen our own territory at least once
local shownDeath = false

local function addPlayers(entries)
	for _, e in entries do
		roster[e.smallID] = e
		local c = theme:territoryColor(e.id, e.type)
		renderer:setPlayerColor(e.smallID, c.rgb, c.border)
		nameLayer:setPlayer(e.smallID, e.name, c.rgb, e.type == "BOT")
		unitLayer:setOwnerColor(e.smallID, c.rgb)
		if e.clientID == state.yourClientID then
			mySmallID = e.smallID
		end
	end
end

addPlayers(state.players)
renderer:loadState(Net.unwrap(state.tiles))
Net.unpackNames(state.names, function(smallID, x, y, size)
	nameLayer:setPlacement(smallID, x, y, size)
end)
for _, u in state.units or {} do
	unitLayer:apply(u)
end
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

local function tileAtScreen(p: Vector2): number?
	local x, y = camera:mapPos(p)
	if gameMap:isValidCoord(x, y) then
		return gameMap:ref(x, y)
	end
	return nil
end

local function myStats()
	return mySmallID and stats[mySmallID]
end

local buildMenu = BuildMenu.new({
	gui = gui,
	camera = camera,
	map = gameMap,
	net = Net,
	unitLayer = unitLayer,
	tileAt = tileAtScreen,
	mousePos = function()
		return game:GetService("UserInputService"):GetMouseLocation()
	end,
	mySmallID = function()
		return mySmallID
	end,
	-- Upstream hides the build bar during the spawn phase and once we are dead.
	canAct = function()
		local mine = myStats()
		return not inSpawnPhase and not gameOver and mine ~= nil and mine.tiles > 0
	end,
})
unitLayer.onChanged = function()
	buildMenu:refresh()
end

-- Server events ------------------------------------------------------------------

Net.Roster.OnClientEvent:Connect(addPlayers)

Net.BuildInfo.OnClientEvent:Connect(function(costs)
	buildMenu:setCosts(costs)
end)

Net.Names.OnClientEvent:Connect(function(buf)
	Net.unpackNames(buf, function(smallID, x, y, size)
		nameLayer:setPlacement(smallID, x, y, size)
	end)
end)

Net.Units.OnClientEvent:Connect(function(list)
	for _, u in list do
		unitLayer:apply(u)
	end
end)

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
		nameLayer:setTroops(smallID, troops, tiles > 0)
	end)
	local mine = mySmallID and stats[mySmallID]
	if mine then
		hud:setMyStats(mine.troops, maxTroopsForHuman(mine.tiles), mine.gold)
		buildMenu:setGold(mine.gold)
		if mine.tiles > 0 then
			haveSpawned = true
		elseif haveSpawned and not inSpawnPhase and not shownDeath and not gameOver then
			-- Upstream WinModal: shown once when our player is no longer alive.
			shownDeath = true
			hud:showModal("You died", "Spectate")
		end
	end
	refreshBoard()
end)

Net.Event.OnClientEvent:Connect(function(evt)
	if evt.type == "SpawnPhaseEnd" then
		inSpawnPhase = false
		buildMenu:refresh()
	elseif evt.type == "Win" then
		gameOver = true
		if evt.winnerSmallID ~= nil and evt.winnerSmallID == mySmallID then
			hud:showModal("You Won!", "Keep Playing", true)
		else
			hud:showModal(`{evt.winnerName} has won!`, "Keep Playing")
		end
	end
end)

-- Input ----------------------------------------------------------------------------

camera.onClick = function(p: Vector2)
	if gameOver or mySmallID == nil then
		return
	end
	local tile = tileAtScreen(p)
	if tile == nil then
		return
	end
	if buildMenu:click(tile) then
		return
	end
	if inSpawnPhase then
		if gameMap:isLand(tile) and not gameMap:isImpassable(tile) and renderer:ownerAt(tile) == 0 then
			Net.Intent:FireServer({ type = "spawn", tile = tile })
		end
		return
	end
	-- The server decides land attack vs boat, exactly like the upstream client.
	Net.Intent:FireServer({ type = "click", tile = tile, ratio = hud.ratio })
end

camera.onRightClick = function(p: Vector2)
	local tile = tileAtScreen(p)
	if tile ~= nil and not gameOver then
		buildMenu:openContextMenu(p, tile)
	end
end

camera.onHover = function(p: Vector2)
	buildMenu:hover(p)
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
	unitLayer:render()
	if inSpawnPhase and not gameOver then
		local left = math.max(1, math.ceil((spawnPhaseTurns - estimatedTick()) / 10))
		local mine = mySmallID and stats[mySmallID]
		local chosen = mine ~= nil and mine.tiles > 0
		if state.hasSpawnTimer == false then
			hud:setCountdown("", "Click the map to choose where to start")
		else
			hud:setCountdown(left, if chosen then "Spawn chosen — get ready" else "Click the map to choose where to start")
		end
	else
		hud:setCountdown(nil)
	end
end)

print(`[Client] joined {manifest.name} {W}x{H}, {#state.players} player(s) in roster, you = {tostring(mySmallID)}`)
