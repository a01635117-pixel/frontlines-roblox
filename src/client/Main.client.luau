-- Client entry point: receives the match from the server, draws the map and
-- territories, and turns clicks into intents (spawn / attack), like OpenFront.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ColorAllocator = require(Shared:WaitForChild("ColorAllocator"))
local GameMap = require(Shared:WaitForChild("GameMap"))
local MapLoader = require(Shared:WaitForChild("MapLoader"))
local Net = require(Shared:WaitForChild("Net"))
local TerrainColors = require(Shared:WaitForChild("TerrainColors"))

local AttacksDisplay = require(script.Parent:WaitForChild("AttacksDisplay"))
local BuildMenu = require(script.Parent:WaitForChild("BuildMenu"))
local ControlPanel = require(script.Parent:WaitForChild("ControlPanel"))
local EventsDisplay = require(script.Parent:WaitForChild("EventsDisplay"))
local Format = require(Shared:WaitForChild("Format"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local MapCamera = require(script.Parent:WaitForChild("MapCamera"))
local NameLayer = require(script.Parent:WaitForChild("NameLayer"))
local TerritoryRenderer = require(script.Parent:WaitForChild("TerritoryRenderer"))
local RadialMenu = require(script.Parent:WaitForChild("RadialMenu"))
local SpawnRing = require(script.Parent:WaitForChild("SpawnRing"))
local TutorialPanel = require(script.Parent:WaitForChild("TutorialPanel"))
local UnitLayer = require(script.Parent:WaitForChild("UnitLayer"))
local WorldText = require(script.Parent:WaitForChild("WorldText"))

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
local controlPanel = ControlPanel.new(gui)
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
local matchEndsAt: number? = nil -- set when the match is over

local function addPlayers(entries)
	for _, e in entries do
		roster[e.smallID] = e
		local c = theme:territoryColor(e.id, e.type)
		renderer:setPlayerColor(e.smallID, c.rgb, c.border)
		nameLayer:setPlayer(e.smallID, e.name, c.rgb, e.type == "BOT")
		unitLayer:setOwnerColor(e.smallID, c.rgb, c.border)
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

-- Fractional tick for motion-plan playback (capped one tick ahead of the last update).
unitLayer.tickNow = function(): number
	return tickBase + math.min((os.clock() - tickClock) * 10, 1.5)
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

local myInfo = { disabled = state.disabledUnits or {} } -- latest Net.Me payload
local myBordering = nil -- set of smallIDs we share a border with

local buildMenu = BuildMenu.new({
	gui = gui,
	hotbarParent = controlPanel.hotbarParent,
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
	myColor = function()
		return mySmallID and unitLayer.colors[mySmallID]
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

local UserInputService = game:GetService("UserInputService")

-- TutorialPanel.buildContext
local function tutorialContext()
	if mySmallID == nil then
		return nil
	end
	local mine = myStats()
	local disabled = myInfo.disabled or {}
	local costs = myInfo.costs or {}
	local botsExist, nationsExist = false, false
	for smallID, e in roster do
		local s = stats[smallID]
		if s and s.tiles > 0 then
			botsExist = botsExist or e.type == "BOT"
			nationsExist = nationsExist or e.type == "NATION"
		end
	end
	local function has(unitType)
		return unitLayer:totalLevels(mySmallID, unitType)
	end
	return {
		dead = haveSpawned and not inSpawnPhase and (mine == nil or mine.tiles == 0),
		hasSpawned = haveSpawned,
		inSpawnPhase = inSpawnPhase,
		attacking = myInfo.attacking == true,
		boatsDisabled = false,
		boatAfloat = unitLayer:hasUnit(mySmallID, "Transport"),
		botsExist = botsExist,
		nationsExist = nationsExist,
		alliancesDisabled = true, -- TODO(port): alliances
		allied = myInfo.allied == true,
		gold = if mine then mine.gold else 0,
		costs = costs,
		cityCost = costs.City,
		cityDisabled = disabled.City == true,
		cities = has("City"),
		portDisabled = disabled.Port == true,
		ports = has("Port"),
		defensePostDisabled = disabled["Defense Post"] == true,
		defensePosts = has("Defense Post"),
		factoryDisabled = disabled.Factory == true,
		factories = has("Factory"),
		warshipDisabled = disabled.Warship == true,
		warships = if unitLayer:hasUnit(mySmallID, "Warship") then 1 else 0,
		siloDisabled = disabled["Missile Silo"] == true,
		silos = has("Missile Silo"),
		atomDisabled = disabled["Atom Bomb"] == true,
		siloReady = false, -- TODO(port): silo cooldowns with nukes
		atomInFlight = unitLayer:hasUnit(mySmallID, "Atom Bomb"),
		hydrogenDisabled = disabled["Hydrogen Bomb"] == true,
		mirvDisabled = disabled.MIRV == true,
		samDisabled = disabled["SAM Launcher"] == true,
	}
end

local tutorial = TutorialPanel.new({
	slot = controlPanel.tutorialSlot,
	mapLayer = background,
	camera = camera,
	net = Net,
	dismissed = state.tutorialDismissed == true,
	context = tutorialContext,
	isTouch = function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end,
	namePlacement = function(smallID)
		return nameLayer:placement(smallID)
	end,
	mySmallID = function()
		return mySmallID
	end,
	players = function()
		local list = {}
		for smallID, e in roster do
			local s = stats[smallID]
			table.insert(list, { smallID = smallID, type = e.type, alive = s ~= nil and s.tiles > 0 })
		end
		return list
	end,
	bordering = function()
		return myBordering
	end,
	hasCoast = function()
		return myInfo.hasCoast
	end,
	isFriendly = function(_smallID)
		return false -- TODO(port): alliances / teams
	end,
	setHighlight = function(target)
		controlPanel:setHighlight(target)
		buildMenu:setHighlight(target)
	end,
})
tutorial:setAttackRatio(controlPanel.ratio)
controlPanel.onRatioChanged = function(ratio)
	tutorial:setAttackRatio(ratio)
end
camera.onShiftScroll = function(z)
	controlPanel:shiftScroll(z)
end

local spawnRing = SpawnRing.new(background, camera, gameMap)
local worldText = WorldText.new(background, camera)

local function focusPlayer(smallID: number)
	local x, y = nameLayer:placement(smallID)
	if x then
		camera:centerOn(x, y, 3)
	end
end
local function focusUnit(id: number)
	local tile = unitLayer:unitTile(id)
	if tile then
		camera:centerOn(gameMap:x(tile), gameMap:y(tile), 3)
	end
end
local function playerName(smallID: number): string?
	local e = roster[smallID]
	return e and e.name
end
local function hudVisible(): boolean
	local mine = myStats()
	return not inSpawnPhase and not gameOver and mine ~= nil and mine.tiles > 0
end

local eventsDisplay = EventsDisplay.new({
	gui = gui,
	tickNow = function()
		return tickBase + (os.clock() - tickClock) * 10
	end,
	unitActive = function(id)
		return unitLayer:isActiveUnit(id)
	end,
	playerName = playerName,
	focusPlayer = focusPlayer,
	focusUnit = focusUnit,
	visible = hudVisible,
})

local attacksDisplay = AttacksDisplay.new({
	parent = controlPanel.column,
	net = Net,
	playerName = playerName,
	playerType = function(smallID)
		local e = roster[smallID]
		return e and e.type
	end,
	myTroops = function()
		local mine = myStats()
		return if mine then mine.troops else 0
	end,
	ratio = function()
		return controlPanel.ratio
	end,
	boats = function()
		if mySmallID == nil then
			return {}
		end
		local out = {}
		for _, b in unitLayer:boatsOf(mySmallID) do
			local target = "Wilderness"
			if b.targetTile then
				local owner = renderer:ownerAt(b.targetTile)
				if owner ~= 0 then
					target = playerName(owner) or ""
				end
			end
			table.insert(out, { id = b.id, troops = b.troops, targetName = target })
		end
		return out
	end,
	focusPlayer = focusPlayer,
	focusUnit = focusUnit,
	visible = hudVisible,
	myColors = function()
		local id = mySmallID or 0
		return unitLayer.colors[id] or Color3.new(1, 1, 1), unitLayer.borders[id] or Color3.new(0, 0, 0)
	end,
})

local radialMenu = RadialMenu.new({
	gui = gui,
	net = Net,
	buildMenu = buildMenu,
	mySmallID = function()
		return mySmallID
	end,
	ratio = function()
		return controlPanel.ratio
	end,
})

local function refreshPanelVisibility()
	local mine = myStats()
	controlPanel:setVisible(not inSpawnPhase and mine ~= nil and mine.tiles > 0)
end

-- Server events ------------------------------------------------------------------

Net.Roster.OnClientEvent:Connect(addPlayers)

Net.Me.OnClientEvent:Connect(function(info)
	-- bordering / hasCoast only arrive every few updates; keep the last ones.
	if info.bordering then
		local set = {}
		for _, id in info.bordering do
			set[id] = true
		end
		myBordering = set
	else
		info.hasCoast = myInfo.hasCoast
	end
	myInfo = info
	attacksDisplay:setAttacks(info.incoming, info.outgoing)
	worldText:setAttacks(gameMap, info.outgoing, info.incoming)
	controlPanel:setInfo(info)
	buildMenu:setInfo(info)
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
		controlPanel:setStats(mine.troops, mine.gold)
		buildMenu:setGold(mine.gold)
		if mine.tiles > 0 then
			haveSpawned = true
		elseif haveSpawned and not inSpawnPhase and not shownDeath and not gameOver then
			-- Upstream WinModal: shown once when our player is no longer alive.
			shownDeath = true
			hud:showModal("You died", "Spectate")
		end
	end
	refreshPanelVisibility()
	refreshBoard()
end)

Net.Event.OnClientEvent:Connect(function(evt)
	if evt.type == "SpawnPhaseEnd" then
		inSpawnPhase = false
		buildMenu:refresh()
		refreshPanelVisibility()
	elseif evt.type == "MatchEnding" then
		-- No "keep playing" on Roblox servers: a new match starts shortly.
		matchEndsAt = os.clock() + evt.seconds
	elseif evt.type == "MatchReset" then
		-- Fresh match: rebuild the client from scratch (clone this script).
		local fresh = script:Clone()
		gui:Destroy()
		fresh.Parent = script.Parent
		script:Destroy()
	elseif evt.type == "GoldGain" then
		controlPanel:goldGain(evt.gold)
	elseif evt.type == "Message" or evt.type == "Incoming" then
		eventsDisplay:add(evt)
	elseif evt.type == "Conquest" then
		-- Conquest popup at the conquered player's name (our conquests only).
		if evt.conqueror == mySmallID then
			local x, y = nameLayer:placement(evt.conquered)
			if x then
				worldText:conquest(x, y, evt.gold or 0)
			end
		end
	elseif evt.type == "Bonus" then
		worldText:bonus(gameMap:x(evt.tile), gameMap:y(evt.tile), evt.gold)
	elseif evt.type == "Win" then
		gameOver = true
		if evt.winnerSmallID ~= nil and evt.winnerSmallID == mySmallID then
			hud:showModal("You Won!", "OK", true)
		else
			hud:showModal(`{evt.winnerName} has won!`, "OK")
		end
	end
end)

-- Input ----------------------------------------------------------------------------

local WARSHIP_SELECTION_RADIUS = 10
local selectedWarship: number? = nil

camera.onClick = function(p: Vector2)
	if gameOver or mySmallID == nil then
		return
	end
	-- The radial menu handles its own clicks (on mouse down).
	if radialMenu:isOpen() or (radialMenu.closedAt and os.clock() - radialMenu.closedAt < 0.3) then
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
	-- Warship select / move (WarshipSelectionController): water clicks only.
	if gameMap:isWater(tile) then
		if selectedWarship and unitLayer:isActiveUnit(selectedWarship) then
			Net.Intent:FireServer({ type = "move_warship", unitIds = { selectedWarship }, tile = tile })
			selectedWarship = nil
			unitLayer:setSelected(nil)
			return
		end
		local near = unitLayer:warshipsNear(mySmallID, tile, WARSHIP_SELECTION_RADIUS)
		if near[1] then
			selectedWarship = near[1]
			unitLayer:setSelected(selectedWarship)
		end
		return
	end
	if selectedWarship then
		selectedWarship = nil
		unitLayer:setSelected(nil)
	end
	-- The server decides land attack vs boat, exactly like the upstream client.
	Net.Intent:FireServer({ type = "click", tile = tile, ratio = controlPanel.ratio })
end

camera.onRightClick = function(p: Vector2)
	if selectedWarship then
		selectedWarship = nil
		unitLayer:setSelected(nil)
		return
	end
	-- A ghost structure is cancelled by right click; otherwise open the radial menu.
	if buildMenu.selected then
		buildMenu:select(nil)
		return
	end
	local tile = tileAtScreen(p)
	if tile ~= nil and not gameOver and mySmallID ~= nil then
		buildMenu:query(tile, function(info)
			if info then
				radialMenu:openAt(p, tile, info)
			end
		end)
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
	tutorial:renderOverlays()
	worldText:render()
	-- Spawn ring: during the spawn phase once we picked a spot, and while the
	-- tutorial points at our territory (syncSpawnOverlay).
	local showRing = not gameOver and ((inSpawnPhase and haveSpawned) or tutorial:wantsSpawnRing())
	spawnRing:set(if showRing then myInfo.spawnTile else nil)
	spawnRing:render()
	if inSpawnPhase and not gameOver then
		local left = math.max(1, math.ceil((spawnPhaseTurns - estimatedTick()) / 10))
		local mine = mySmallID and stats[mySmallID]
		local chosen = mine ~= nil and mine.tiles > 0
		if state.hasSpawnTimer == false then
			hud:setCountdown("", "Click the map to choose where to start")
		else
			hud:setCountdown(left, if chosen then "Spawn chosen — get ready" else "Click the map to choose where to start")
		end
	elseif matchEndsAt then
		hud:setCountdown(math.max(0, math.ceil(matchEndsAt - os.clock())), "New match starting soon")
	else
		hud:setCountdown(nil)
	end
end)

print(`[Client] joined {manifest.name} {W}x{H}, {#state.players} player(s) in roster, you = {tostring(mySmallID)}`)
