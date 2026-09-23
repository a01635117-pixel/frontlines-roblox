-- Player names + troop counts drawn over territories, like OpenFront's
-- NamePass. Placement (x, y, size in map tiles) comes from the server's
-- NameBoxCalculator; on screen the name is size * zoom pixels tall and the
-- troop line below it troopSizeMultiplier (0.6) of that.

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))

local MIN_TEXT = 7 -- px; smaller names are hidden (upstream culls tiny names too)
local MAX_TEXT = 100 -- Roblox TextSize cap
local TROOP_SIZE_MULTIPLIER = 0.6 -- render-settings.json name.troopSizeMultiplier
local BOT_SHADE = 0.4 -- render-settings.json name.nameShadeBot

local NameLayer = {}
NameLayer.__index = NameLayer

function NameLayer.new(parent: GuiObject, camera)
	local container = Instance.new("Frame")
	container.Name = "Names"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 5
	container.Parent = parent
	return setmetatable({ container = container, camera = camera, entries = {} }, NameLayer)
end

local function makeText(parent: Instance, name: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.ZIndex = 5
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Parent = l
	l.Parent = parent
	return l
end

-- color: territory { r, g, b } 0-255, used for the text outline.
function NameLayer:setPlayer(smallID: number, displayName: string, color: { number }, isBot: boolean)
	local e = self.entries[smallID]
	if e == nil then
		e = {
			name = makeText(self.container, `Name{smallID}`),
			troops = makeText(self.container, `Troops{smallID}`),
			x = 0,
			y = 0,
			size = 0,
			alive = false,
		}
		self.entries[smallID] = e
	end
	local outline = Color3.fromRGB(color[1], color[2], color[3])
	local shade = if isBot then BOT_SHADE else 0
	local fill = Color3.new(shade, shade, shade)
	for _, l in { e.name, e.troops } do
		l.TextColor3 = fill
		l:FindFirstChildOfClass("UIStroke").Color = outline
	end
	e.name.Text = displayName
	self:_place(e)
end

function NameLayer:setPlacement(smallID: number, x: number, y: number, size: number)
	local e = self.entries[smallID]
	if e then
		e.x, e.y, e.size = x, y, size
		self:_place(e)
	end
end

-- Upstream nameLocation(): map x, y and font size; nil until placed.
function NameLayer:placement(smallID: number): (number?, number?, number?)
	local e = self.entries[smallID]
	if e == nil or (e.x == 0 and e.y == 0 and e.size == 0) then
		return nil, nil, nil
	end
	return e.x, e.y, e.size
end

function NameLayer:setTroops(smallID: number, troops: number, alive: boolean)
	local e = self.entries[smallID]
	if e then
		e.troops.Text = Format.renderTroops(troops)
		if e.alive ~= alive then
			e.alive = alive
			self:_place(e)
		end
	end
end

function NameLayer:_place(e)
	local px = e.size * self.camera.zoom
	local visible = e.alive and px >= MIN_TEXT
	e.name.Visible = visible
	e.troops.Visible = visible and px * TROOP_SIZE_MULTIPLIER >= MIN_TEXT * 0.8
	if not visible then
		return
	end
	local p = self.camera:screenPos(e.x, e.y)
	local nameSize = math.min(MAX_TEXT, px)
	e.name.TextSize = nameSize
	e.name.Position = UDim2.fromOffset(p.X, p.Y)
	e.troops.TextSize = math.min(MAX_TEXT, px * TROOP_SIZE_MULTIPLIER)
	e.troops.Position = UDim2.fromOffset(p.X, p.Y + nameSize * 0.9)
end

-- Re-layout everything (camera moved / zoomed).
function NameLayer:refresh()
	for _, e in self.entries do
		self:_place(e)
	end
end

return NameLayer
