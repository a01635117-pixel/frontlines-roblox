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
local Shop = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))

-- PlayerScripts are copied one by one: wait for every client module before
-- requiring any (modules require their siblings without WaitForChild).
-- tools/build.mjs checks this list against src/client.
local CLIENT_MODULES = { "ShopScreen", "AttacksDisplay", "BuildMenu", "ChatModal", "ControlPanel", "EmojiTable", "EventsDisplay", "FlagAtlas", "Hud", "Icons", "Lang", "LobbyScreen", "MapCamera", "Modal", "NameLayer", "NukePreview", "PlayerPanel", "RadialMenu", "SendResourceModal", "SpawnRing", "Sprites", "Style", "TerritoryRenderer", "TutorialPanel", "UnitLayer", "WorldText" }
for _, name in CLIENT_MODULES do
	script.Parent:WaitForChild(name)
end

local Lang = require(script.Parent:WaitForChild("Lang"))
Lang.init() -- before any GUI exists, so auto-localisation sees every label
local AttacksDisplay = require(script.Parent:WaitForChild("AttacksDisplay"))
local BuildMenu = require(script.Parent:WaitForChild("BuildMenu"))
local ControlPanel = require(script.Parent:WaitForChild("ControlPanel"))
local EventsDisplay = require(script.Parent:WaitForChild("EventsDisplay"))
local Format = require(Shared:WaitForChild("Format"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local LobbyScreen = require(script.Parent:WaitForChild("LobbyScreen"))
local MapCamera = require(script.Parent:WaitForChild("MapCamera"))
local NameLayer = require(script.Parent:WaitForChild("NameLayer"))
local NukePreview = require(script.Parent:WaitForChild("NukePreview"))
local TerritoryRenderer = require(script.Parent:WaitForChild("TerritoryRenderer"))
local RadialMenu = require(script.Parent:WaitForChild("RadialMenu"))
local SpawnRing = require(script.Parent:WaitForChild("SpawnRing"))
local TutorialPanel = require(script.Parent:WaitForChild("TutorialPanel"))
local UnitLayer = require(script.Parent:WaitForChild("UnitLayer"))
local WorldText = require(script.Parent:WaitForChild("WorldText"))
local PlayerPanel = require(script.Parent:WaitForChild("PlayerPanel"))
local EmojiTable = require(script.Parent:WaitForChild("EmojiTable"))
local ChatModal = require(script.Parent:WaitForChild("ChatModal"))

local player = Players.LocalPlayer
workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
-- Keys 1..0 are build hotkeys (upstream), not backpack slots.
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
-- Our own leaderboard replaces Roblox's player list (it covered the top right).
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
-- No avatar: hide the touch thumbstick and jump button.
game:GetService("GuiService").TouchControlsEnabled = false

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

-- Lobby until the server starts the match (or we join one in progress).
local lobbyScreen = LobbyScreen.new(gui, Net)
local state = Net.GameState.OnClientEvent:Wait()
lobbyScreen:destroy()
-- The server replicates only the selected map.
local gameMap, _mini, manifest = MapLoader.load(Shared:WaitForChild("Maps"):WaitForChild(state.mapId))
local W, H = gameMap:width(), gameMap:height()

local camera = MapCamera.new(background, W, H)
local renderer = TerritoryRenderer.new(camera, gameMap)
local nameLayer = NameLayer.new(background, camera)
local unitLayer = UnitLayer.new(background, camera, gameMap)
local nukePreview = NukePreview.new(background, camera, gameMap)
camera.onChanged = function()
	nameLayer:refresh()
	unitLayer:render()
	if nukePreview.data then
		nukePreview:render()
	end
end
if RunService:IsStudio() then
	-- Test hook (Studio only), like the server's _G.OpenFront.
	_G.OpenFrontClient = { camera = camera, renderer = renderer, unitLayer = unitLayer }
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

-- ThemeProvider.borderColor for a custom colour: HSL lightness - 0.125
-- (colord darken(borderDarken)).
local function borderColor(rgb: { number }): { number }
	local r, g, b = rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local l = (mx + mn) / 2
	local h, s = 0, 0
	if mx ~= mn then
		local d = mx - mn
		s = if l > 0.5 then d / (2 - mx - mn) else d / (mx + mn)
		if mx == r then
			h = (g - b) / d + (if g < b then 6 else 0)
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	l = math.max(0, l - 0.125)
	local function hue(p, q, t)
		t %= 1
		if t < 1 / 6 then
			return p + (q - p) * 6 * t
		elseif t < 1 / 2 then
			return q
		elseif t < 2 / 3 then
			return p + (q - p) * (2 / 3 - t) * 6
		end
		return p
	end
	if s == 0 then
		local v = math.floor(l * 255 + 0.5)
		return { v, v, v }
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	return {
		math.floor(hue(p, q, h + 1 / 3) * 255 + 0.5),
		math.floor(hue(p, q, h) * 255 + 0.5),
		math.floor(hue(p, q, h - 1 / 3) * 255 + 0.5),
	}
end

local function addPlayers(entries)
	for _, e in entries do
		roster[e.smallID] = e
		local c = theme:territoryColor(e.id, e.type, e.team)
		local cos0 = e.cosmetics
		if cos0 and cos0.color and e.team == nil then
			-- Custom colour pass (free for all only; teams keep team colours).
			c = { rgb = cos0.color, border = borderColor(cos0.color) }
		end
		renderer:setPlayerColor(e.smallID, c.rgb, c.border)
		nameLayer:setPlayer(e.smallID, e.name, c.rgb, e.type == "BOT")
		unitLayer:setOwnerColor(e.smallID, c.rgb, c.border)
		local cos = e.cosmetics
		local pattern = cos and cos.pattern and Shop.byId[cos.pattern]
		renderer:setPattern(e.smallID, pattern and pattern.rows, pattern and pattern.scale)
		nameLayer:setNameColor(e.smallID, cos and cos.nameColor)
		nameLayer:setFlag(e.smallID, cos and cos.flag)
		local blast = cos and cos.explosion and Shop.byId[cos.explosion]
		unitLayer.explosionColors = unitLayer.explosionColors or {}
		unitLayer.explosionColors[e.smallID] = blast and {
			flash = Color3.fromRGB(blast.flash[1], blast.flash[2], blast.flash[3]),
			ring = Color3.fromRGB(blast.ring[1], blast.ring[2], blast.ring[3]),
		} or nil
		if e.clientID == state.yourClientID then
			mySmallID = e.smallID
			renderer:setLocalPlayer(e.smallID)
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

-- Railroads (upstream RailroadCache): id -> tiles, drawn by the renderer.
local railroads = {}
local function applyRails(remove, add)
	for _, id in remove or {} do
		local tiles = railroads[id]
		if tiles then
			railroads[id] = nil
			renderer:addRail(tiles, -1)
		end
	end
	for _, r in add or {} do
		if railroads[r.id] == nil then
			railroads[r.id] = r.tiles
			renderer:addRail(r.tiles, 1)
		end
	end
end
applyRails(nil, state.rails)
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
local playAgain: () -> () -- defined with the event handlers below

-- Launcher vs local player (NukeTelegraphs.classifyOwner): 0 = self,
-- 1 = teammate or ally, 2 = everyone else (and everything when spectating).
local function relationOf(smallID: number): number
	if mySmallID == nil then
		return 2
	elseif smallID == mySmallID then
		return 0
	end
	local me, them = roster[mySmallID], roster[smallID]
	if me and them and me.team ~= nil and me.team == them.team then
		return 1
	end
	for _, a in myInfo.alliances or {} do
		if a.other == smallID then
			return 1
		end
	end
	return 2
end
unitLayer.relationOf = relationOf
local myBordering = nil -- set of smallIDs we share a border with
local refreshNameIcons -- defined with the name icons below

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
		alliancesDisabled = state.alliancesDisabled == true,
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
		siloReady = unitLayer:siloReady(mySmallID),
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
	isFriendly = function(smallID)
		return relationOf(smallID) == 1
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
	sendIntent = function(t)
		Net.Intent:FireServer(t)
	end,
	alive = function()
		local mine = myStats()
		return mine ~= nil and mine.tiles > 0
	end,
})

-- uiState.rocketDirectionUp (PlayerPanel toggle, sent with nuke placements).
local rocketUp = true
buildMenu.deps.rocketUp = function()
	return rocketUp
end
buildMenu.deps.renderer = renderer

-- BuildPreviewController.updateNukeTrajectoryPreview: arc from the nearest
-- ready silo (Manhattan, like PlayerImpl.nukeSpawn) to the hovered tile,
-- with every SAM that would engage (not ours, not a teammate or ally).
local NUKE_PREVIEW = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true }
local function updateNukePreview(p: Vector2?)
	local sel = buildMenu.selected
	local tile = if p then tileAtScreen(p) else nil
	local best, bestD = nil, math.huge
	if sel and NUKE_PREVIEW[sel] and tile and mySmallID then
		local dx, dy = gameMap:x(tile), gameMap:y(tile)
		for _, e in unitLayer.units do
			if e.ownerID == mySmallID and e.unitType == "Missile Silo" and not e.underConstruction
				and (e.missileTimers == nil or #e.missileTimers < (e.level or 1)) then
				local d = math.abs(gameMap:x(e.pos) - dx) + math.abs(gameMap:y(e.pos) - dy)
				if d < bestD then
					best, bestD = e, d
				end
			end
		end
	end
	if best == nil then
		if nukePreview.data then
			nukePreview:set(nil)
		end
		return
	end
	local sams = {}
	for _, e in unitLayer.units do
		if e.unitType == "SAM Launcher" and e.ownerID ~= mySmallID and relationOf(e.ownerID) ~= 1 then
			table.insert(sams, { x = gameMap:x(e.pos), y = gameMap:y(e.pos), r = NukePreview.samRange(e.level or 1) })
		end
	end
	nukePreview:set({
		srcX = gameMap:x(best.pos),
		srcY = gameMap:y(best.pos),
		dstX = gameMap:x(tile),
		dstY = gameMap:y(tile),
		directionUp = rocketUp,
		sams = sams,
		blocked = gameMap:isImpassable(tile),
	})
end
local emojiTable = EmojiTable.new(gui)
local function onAllianceRequestSent(smallID: number)
	-- Upstream shows "request sent" unless it accepts their pending request.
	for _, id in (myInfo and myInfo.requestsIn) or {} do
		if id == smallID then
			return
		end
	end
	eventsDisplay:add({ type = "Message", message = "events_display.alliance_request_sent", params = { name = playerName(smallID) or "?" }, messageType = 15, focusPlayerID = smallID, keepNames = true })
end
local playerPanel = PlayerPanel.new({
	gui = gui,
	net = Net,
	emojiTable = emojiTable,
	rocketUp = function()
		return rocketUp
	end,
	setRocketUp = function(v)
		rocketUp = v
	end,
	onAllianceRequestSent = function(smallID)
		onAllianceRequestSent(smallID)
	end,
	players = function()
		local list = {}
		for smallID, e in roster do
			local s = stats[smallID]
			if s and s.tiles > 0 and smallID ~= mySmallID then
				table.insert(list, { smallID = smallID, name = e.name, tiles = s.tiles, color = unitLayer.colors[smallID] })
			end
		end
		return list
	end,
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
	playerPanel = playerPanel,
	onAllianceRequestSent = onAllianceRequestSent,
	rocketUp = function()
		return rocketUp
	end,
	myTroops = function()
		local mine = myStats()
		return mine and mine.troops
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
	eventsDisplay:updateAlliances(info)
	refreshNameIcons()
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

-- Name status icons (PlayerIcons.ts): crown, traitor, disconnected, alliance,
-- alliance request, target, embargo, nuke; then the latest emoji for us.
local traitors, disconnected = {}, {}
local emojis = {} -- sender smallID -> { message, recipient, tick }
local EMOJI_DURATION = 50 -- Config.emojiMessageDuration
function refreshNameIcons()
	if mySmallID == nil and next(roster) == nil then
		return
	end
	local me = mySmallID
	local info = myInfo or {}
	local function set(list)
		local out = {}
		for _, id in list or {} do
			out[id] = true
		end
		return out
	end
	local allied, asking, targets, embargoes = {}, set(info.requestsIn), set(info.targets), set(info.embargoes)
	for _, a in info.alliances or {} do
		allied[a.other] = true
	end
	local first, best = nil, -1
	for smallID, s in stats do
		if s.tiles > best then
			first, best = smallID, s.tiles
		end
	end
	local nukeOwners = unitLayer:nukeOwners(renderer, me)
	local now = tickBase + (os.clock() - tickClock) * 10
	for smallID in roster do
		local icons = {}
		if smallID == first and best > 0 then
			table.insert(icons, { icon = "crown" })
		end
		if traitors[smallID] then
			table.insert(icons, { icon = "traitor", color = Color3.fromHex("#ef4444") })
		end
		if disconnected[smallID] then
			table.insert(icons, { icon = "disconnected" })
		end
		if allied[smallID] then
			table.insert(icons, { icon = "alliance", color = Color3.fromHex("#4ade80") })
		end
		if asking[smallID] then
			table.insert(icons, { icon = "allianceRequest" })
		end
		if targets[smallID] then
			table.insert(icons, { icon = "targetRed" })
		end
		if embargoes[smallID] then
			table.insert(icons, { icon = "embargo" })
		end
		local nuke = nukeOwners[smallID]
		if nuke and smallID ~= me then
			table.insert(icons, { icon = if nuke == "me" then "nukeRed" else "atomBomb", color = if nuke == "me" then nil else Color3.new(1, 1, 1) })
		end
		local e = emojis[smallID]
		local emoji = nil
		if e and now - e.tick < EMOJI_DURATION and (e.recipient == 0 or e.recipient == me) then
			emoji = e.message
		end
		nameLayer:setIcons(smallID, icons, emoji, targets[smallID] == true)
	end
end

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
			eventsDisplay:refresh()
			-- The server stops sending Me once we are dead (and drops our
			-- alliances): forget our diplomatic state so no stale icons remain.
			myInfo.alliances, myInfo.requestsIn, myInfo.targets, myInfo.embargoes = {}, {}, {}, {}
			refreshNameIcons()
			if state.canMatchmake then
				hud:showModal("You died", "Spectate", false, "Play again", playAgain)
			else
				hud:showModal("You died", "Spectate")
			end
		end
	end
	refreshPanelVisibility()
	refreshBoard()
end)

-- "Play again": straight to the next match that is about to start (or a
-- fresh singleplayer game when this one was singleplayer).
function playAgain()
	Net.Intent:FireServer({ type = if state.lobbyMode == "solo" then "play_solo" else "find_match" })
end

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
	elseif evt.type == "AllianceRequest" then
		eventsDisplay:allianceRequest(evt.requestor, evt.duration)
	elseif evt.type == "AllianceRequestResolved" then
		eventsDisplay:allianceRequestResolved(evt.requestor)
	elseif evt.type == "AllianceGone" or evt.type == "AllianceExtended" then
		eventsDisplay:allianceGone(evt.allianceID)
	elseif evt.type == "Flags" then
		traitors, disconnected = {}, {}
		for _, id in evt.traitors do
			traitors[id] = true
		end
		for _, id in evt.disconnected do
			disconnected[id] = true
		end
		refreshNameIcons()
	elseif evt.type == "Emoji" then
		emojis[evt.sender] = { message = evt.message, recipient = evt.recipient, tick = evt.tick }
		refreshNameIcons()
		task.delay(EMOJI_DURATION / 10 + 0.2, refreshNameIcons)
	elseif evt.type == "Chat" then
		-- DisplayChatEvent: "From X: msg" / "Sent X: msg".
		local text = ChatModal.phraseText(evt.category, evt.key) or evt.key
		if evt.target then
			local target = evt.target
			text = string.gsub(text, "%[P1%]", function()
				return target
			end)
		end
		eventsDisplay:add({
			type = "Message",
			message = (if evt.isFrom then "From " else "Sent ") .. (evt.other or "") .. ": " .. text,
			raw = true,
			messageType = 20,
			focusPlayerID = evt.otherSmallID,
		})
	elseif evt.type == "MatchInProgress" then
		-- Joined a public server mid-match: offer a lobby about to start and go
		-- there automatically unless the player chooses to watch.
		local cancelled = false
		hud:showModal("Match in progress", "Watch this match", false, "Find new match", function()
			cancelled = true
			Net.Intent:FireServer({ type = "find_match" })
		end)
		local modalButton = hud.modalButton
		local conn
		conn = modalButton.Activated:Connect(function()
			cancelled = true
			conn:Disconnect()
		end)
		task.spawn(function()
			for left = evt.autoSeconds or 8, 1, -1 do
				if cancelled then
					return
				end
				hud.modalTitle.Text = Lang.t("Match in progress — new match in {left} s", { left = left })
				task.wait(1)
			end
			if not cancelled then
				hud.modal.Visible = false
				Net.Intent:FireServer({ type = "find_match" })
			end
		end)
	elseif evt.type == "Rail" then
		applyRails(evt.remove, evt.add)
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
		local myTeam = mySmallID and roster[mySmallID] and roster[mySmallID].team
		local again = if state.canMatchmake then "Play again" else nil
		local againFn = if state.canMatchmake then playAgain else nil
		if evt.winnerSmallID ~= nil and evt.winnerSmallID == mySmallID then
			hud:showModal("You Won!", "OK", true, again, againFn)
		elseif evt.winnerSmallID == nil and myTeam ~= nil and evt.winnerName == myTeam then
			hud:showModal("Your team won!", "OK", true, again, againFn)
		else
			hud:showModal(Lang.t("{name} has won!", { name = evt.winnerName }), "OK", false, again, againFn)
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
		-- Random spawn: the server places us; no manual pick (upstream disables it).
		if not state.randomSpawn and gameMap:isLand(tile) and not gameMap:isImpassable(tile) and renderer:ownerAt(tile) == 0 then
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

-- Touch tap (WarshipSelectionController.onTouch): spawn during the spawn
-- phase, place a ghost structure, water taps go to warships, land taps open
-- the radial menu (attack is its centre button).
camera.onTap = function(p: Vector2)
	if gameOver or mySmallID == nil then
		return
	end
	if radialMenu:isOpen() or (radialMenu.closedAt and os.clock() - radialMenu.closedAt < 0.3) then
		return
	end
	local tile = tileAtScreen(p)
	if tile == nil then
		return
	end
	if buildMenu.selected then
		buildMenu:hover(p)
		camera.onClick(p)
		return
	end
	if inSpawnPhase or gameMap:isWater(tile) then
		camera.onClick(p)
		return
	end
	if selectedWarship then
		camera.onClick(p)
		return
	end
	camera.onRightClick(p)
end

camera.onHover = function(p: Vector2)
	buildMenu:hover(p)
	updateNukePreview(p)
	local tile = tileAtScreen(p)
	if tile == nil then
		hud:setHover(nil)
		return
	end
	local owner = renderer:ownerAt(tile)
	local e = roster[owner]
	if e then
		local s = stats[owner]
		hud:setHover(if s then Lang.t("{name}  ·  {troops} troops", { name = e.name, troops = Format.renderTroops(s.troops) }) else e.name)
	elseif gameMap:isWater(tile) then
		hud:setHover(if gameMap:isOcean(tile) then "Ocean" else "Lake")
	else
		hud:setHover(Lang.t("Unclaimed {terrain}", { terrain = Lang.t(terrainNames[gameMap:terrainType(tile)] or "?") }))
	end
end

if RunService:IsStudio() then
	-- Studio test hook: read-only view for automated players (soak tests).
	_G.OpenFrontClient.buildMenu = buildMenu
	_G.OpenFrontClient.gameMap = gameMap
	_G.OpenFrontClient.snapshot = function()
		return {
			mySmallID = mySmallID,
			inSpawnPhase = inSpawnPhase,
			gameOver = gameOver,
			roster = roster,
			stats = stats,
			myInfo = myInfo,
			bordering = myBordering,
		}
	end
end

-- Frame loop ------------------------------------------------------------------------

RunService.RenderStepped:Connect(function()
	renderer:flush()
	if nukePreview.data and not NUKE_PREVIEW[buildMenu.selected or ""] then
		nukePreview:set(nil)
	end
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
