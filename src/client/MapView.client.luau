-- Renders the terrain of a packed map with pan / zoom controls.
--
-- The map is drawn onto EditableImages in a ScreenGui. EditableImage is
-- capped at 1024x1024, and several Compact maps exceed that (Europe is
-- 1452x836), so the map is split into a grid of <=1024 tiles.

local AssetService = game:GetService("AssetService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameMap = require(Shared:WaitForChild("GameMap"))
local MapLoader = require(Shared:WaitForChild("MapLoader"))
local TerrainColors = require(Shared:WaitForChild("TerrainColors"))

local MAP_ID = "World"
local MAX_TILE = 1024 -- EditableImage size limit
local ZOOM_STEP = 1.15
local MAX_ZOOM = 40 -- screen pixels per map tile
local DRAG_THRESHOLD = 4 -- pixels before a press becomes a pan

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
-- No 3D camera control: the wheel and right-drag belong to the map.
camera.CameraType = Enum.CameraType.Scriptable

local t0 = os.clock()
local gameMap, _miniGameMap, manifest = MapLoader.load(Shared:WaitForChild("Maps"):WaitForChild(MAP_ID))
local loadMs = (os.clock() - t0) * 1000
local W, H = gameMap:width(), gameMap:height()

local terrainNames = {}
for name, value in GameMap.TerrainType do
	terrainNames[value] = name
end

-- GUI -----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "MapView"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local bgColor = TerrainColors.BACKGROUND_BASE
local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.fromRGB(bgColor[1], bgColor[2], bgColor[3])
background.BorderSizePixel = 0
background.Parent = gui

local root = Instance.new("Frame")
root.Name = "MapRoot"
root.BackgroundTransparency = 1
root.Parent = background

local function makeLabel(name: string, anchor: Vector2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = anchor
	label.Position = position
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = label
	label.Parent = gui
	return label
end

local infoLabel = makeLabel("Info", Vector2.new(0, 0), UDim2.fromOffset(12, 60))
local hoverLabel = makeLabel("Hover", Vector2.new(0, 1), UDim2.new(0, 12, 1, -12))
local creditLabel = makeLabel("Credit", Vector2.new(1, 1), UDim2.new(1, -12, 1, -12))
creditLabel.TextSize = 12
creditLabel.Text = `Map: {manifest.name} (c) OpenFront, CC BY-SA 4.0  ·  (c) OpenFront and Contributors`

gui.Parent = player:WaitForChild("PlayerGui")

-- Terrain tiles ---------------------------------------------------------------

local tBuild = os.clock()
local lut = TerrainColors.buildLUT()
local cols = math.ceil(W / MAX_TILE)
local rows = math.ceil(H / MAX_TILE)
local tileW = math.ceil(W / cols)
local tileH = math.ceil(H / rows)

type Tile = { label: ImageLabel, x0: number, y0: number, w: number, h: number }
local tiles: { Tile } = {}

for r = 0, rows - 1 do
	for c = 0, cols - 1 do
		local x0, y0 = c * tileW, r * tileH
		local w = math.min(tileW, W - x0)
		local h = math.min(tileH, H - y0)
		local size = Vector2.new(w, h)
		local image = AssetService:CreateEditableImage({ Size = size })
		if not image then
			error(`CreateEditableImage failed for {w}x{h} tile (client memory budget?)`)
		end
		image:WritePixelsBuffer(
			Vector2.zero,
			size,
			TerrainColors.buildRGBA(gameMap:terrainBuffer(), W, x0, y0, w, h, lut)
		)
		local label = Instance.new("ImageLabel")
		label.Name = `Tile_{c}_{r}`
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.ImageContent = Content.fromObject(image)
		label.Parent = root
		table.insert(tiles, { label = label, x0 = x0, y0 = y0, w = w, h = h })
	end
end
local buildMs = (os.clock() - tBuild) * 1000

-- Camera ------------------------------------------------------------------------

local zoom = 1 -- screen pixels per map tile
local panX, panY = 0, 0 -- screen position of the map's top-left corner
local minZoom = 0.1

local function apply()
	root.Position = UDim2.fromOffset(math.round(panX), math.round(panY))
	root.Size = UDim2.fromOffset(math.round(W * zoom), math.round(H * zoom))
	-- Snap tile edges to whole pixels so neighbouring tiles never leave a seam.
	for _, t in tiles do
		local left = math.floor(t.x0 * zoom)
		local top = math.floor(t.y0 * zoom)
		t.label.Position = UDim2.fromOffset(left, top)
		t.label.Size = UDim2.fromOffset(math.floor((t.x0 + t.w) * zoom) - left, math.floor((t.y0 + t.h) * zoom) - top)
	end
end

local function fit()
	local view = background.AbsoluteSize
	zoom = math.min(view.X / W, view.Y / H) * 0.95
	minZoom = zoom * 0.5
	panX = (view.X - W * zoom) / 2
	panY = (view.Y - H * zoom) / 2
	apply()
end

-- Set zoom to `newZoom`, keeping the map point under `anchor` (screen px) fixed.
local function zoomAt(anchor: Vector2, newZoom: number)
	newZoom = math.clamp(newZoom, minZoom, MAX_ZOOM)
	local k = newZoom / zoom
	panX = anchor.X - (anchor.X - panX) * k
	panY = anchor.Y - (anchor.Y - panY) * k
	zoom = newZoom
	apply()
end

-- Map tile under a screen position, or nil when off the map.
local function tileAt(p: Vector2): number?
	local x = math.floor((p.X - panX) / zoom)
	local y = math.floor((p.Y - panY) / zoom)
	if gameMap:isValidCoord(x, y) then
		return gameMap:ref(x, y)
	end
	return nil
end

local function describe(ref: number): string
	local parts = {
		`({gameMap:x(ref)}, {gameMap:y(ref)})`,
		terrainNames[gameMap:terrainType(ref)],
		`magnitude {gameMap:magnitude(ref)}`,
	}
	if gameMap:isShore(ref) then
		table.insert(parts, "shore")
	elseif gameMap:isShoreline(ref) then
		table.insert(parts, "shoreline")
	end
	if gameMap:isOcean(ref) then
		table.insert(parts, "ocean")
	elseif gameMap:isWater(ref) then
		table.insert(parts, "lake")
	end
	return table.concat(parts, "  ·  ")
end

local function updateHover(p: Vector2)
	local ref = tileAt(p)
	hoverLabel.Text = if ref then describe(ref) else "—"
end

-- Input -------------------------------------------------------------------------

-- Mouse coordinates in the same space as an IgnoreGuiInset ScreenGui.
local function mousePos(): Vector2
	return UserInputService:GetMouseLocation()
end

-- Touch InputObject positions exclude the top bar inset; shift them back.
local function touchPos(p: Vector3 | Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(p.X, p.Y) + inset
end

local dragging = false
local dragMoved = false
local dragStart = Vector2.zero
local panStart = Vector2.zero

local panButtons = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if panButtons[input.UserInputType] then
		dragging = true
		dragMoved = false
		dragStart = mousePos()
		panStart = Vector2.new(panX, panY)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if panButtons[input.UserInputType] then
		dragging = false
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local p = mousePos()
		if dragging then
			local delta = p - dragStart
			if dragMoved or delta.Magnitude > DRAG_THRESHOLD then
				dragMoved = true
				panX = panStart.X + delta.X
				panY = panStart.Y + delta.Y
				apply()
			end
		end
		updateHover(p)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
		local factor = if input.Position.Z > 0 then ZOOM_STEP else 1 / ZOOM_STEP
		zoomAt(mousePos(), zoom * factor)
		updateHover(mousePos())
	end
end)

-- Touch: one-finger pan, two-finger pinch zoom.
local touchPanStart = Vector2.zero
UserInputService.TouchPan:Connect(function(positions, translation, _velocity, state, processed)
	if processed or #positions ~= 1 then
		return
	end
	if state == Enum.UserInputState.Begin then
		touchPanStart = Vector2.new(panX, panY)
	elseif state == Enum.UserInputState.Change then
		panX = touchPanStart.X + translation.X
		panY = touchPanStart.Y + translation.Y
		apply()
	end
end)

local pinchZoom = zoom
UserInputService.TouchPinch:Connect(function(positions, scale, _velocity, state, processed)
	if processed or #positions < 2 then
		return
	end
	if state == Enum.UserInputState.Begin then
		pinchZoom = zoom
	elseif state == Enum.UserInputState.Change then
		local center = (touchPos(positions[1]) + touchPos(positions[2])) / 2
		zoomAt(center, pinchZoom * scale)
	end
end)

background:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

fit()
infoLabel.Text = string.format(
	"%s  ·  %dx%d  ·  %d land tiles  ·  %d tile(s)  ·  decode %.0f ms  ·  texture %.0f ms",
	manifest.name,
	W,
	H,
	gameMap:numLandTiles(),
	#tiles,
	loadMs,
	buildMs
)
print(`[MapView] {infoLabel.Text}`)
