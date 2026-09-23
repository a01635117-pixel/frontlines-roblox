-- In-game HUD: status line, control panel (troops, gold, attack ratio
-- slider), leaderboard, hover info and the winner banner.
-- Layout follows OpenFront's ControlPanel / leaderboard; visuals are native.

local UserInputService = game:GetService("UserInputService")

local Format = require(script.Parent.Format)

local PANEL_COLOR = Color3.fromRGB(24, 26, 32)
local PANEL_TRANSPARENCY = 0.2
local TEXT = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(160, 165, 175)
local ACCENT = Color3.fromRGB(70, 140, 255)
local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

local Hud = {}
Hud.__index = Hud

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function padding(parent: Instance, px: number)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.Parent = parent
end

local function panel(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = PANEL_COLOR
	f.BackgroundTransparency = PANEL_TRANSPARENCY
	f.BorderSizePixel = 0
	f.Active = true -- sink input so clicks on panels don't reach the map
	corner(f, 8)
	f.Parent = parent
	return f
end

local function label(parent: Instance, name: string, text: string, size: number, font: Enum.Font?, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font or FONT
	l.TextSize = size
	l.TextColor3 = color or TEXT
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.Parent = parent
	return l
end

function Hud.new(gui: ScreenGui)
	local self = setmetatable({ gui = gui, ratio = 0.2, onRatioChanged = nil }, Hud)

	-- Status line (spawn countdown), top left: the leaderboard owns the top
	-- right, and a centred line collides with it on narrow screens.
	local status = panel(gui, "Status")
	status.Position = UDim2.fromOffset(12, 12)
	status.AutomaticSize = Enum.AutomaticSize.XY
	padding(status, 10)
	local statusText = label(status, "Text", "", 18, FONT_BOLD)
	statusText.AutomaticSize = Enum.AutomaticSize.XY
	statusText.TextXAlignment = Enum.TextXAlignment.Center
	self.statusText = statusText

	-- Control panel, bottom left.
	local control = panel(gui, "ControlPanel")
	control.AnchorPoint = Vector2.new(0, 1)
	control.Position = UDim2.new(0, 12, 1, -12)
	control.Size = UDim2.fromOffset(300, 118)
	padding(control, 12)
	local troops = label(control, "Troops", "Troops: 0 / 0", 16, FONT_BOLD)
	troops.Size = UDim2.new(1, 0, 0, 20)
	local troopBar = Instance.new("Frame")
	troopBar.Name = "TroopBar"
	troopBar.Position = UDim2.fromOffset(0, 24)
	troopBar.Size = UDim2.new(1, 0, 0, 6)
	troopBar.BackgroundColor3 = Color3.fromRGB(55, 58, 66)
	troopBar.BorderSizePixel = 0
	corner(troopBar, 3)
	troopBar.Parent = control
	local troopFill = Instance.new("Frame")
	troopFill.Name = "Fill"
	troopFill.Size = UDim2.fromScale(0, 1)
	troopFill.BackgroundColor3 = Color3.fromRGB(90, 200, 120)
	troopFill.BorderSizePixel = 0
	corner(troopFill, 3)
	troopFill.Parent = troopBar
	local gold = label(control, "Gold", "Gold: 0", 16, FONT_BOLD, Color3.fromRGB(255, 214, 90))
	gold.Position = UDim2.fromOffset(0, 36)
	gold.Size = UDim2.new(1, 0, 0, 20)
	local ratioLabel = label(control, "RatioLabel", "Attack ratio: 20%", 14, FONT, MUTED)
	ratioLabel.Position = UDim2.fromOffset(0, 62)
	ratioLabel.Size = UDim2.new(1, 0, 0, 18)
	self.troopsText, self.troopFill, self.goldText, self.ratioText = troops, troopFill, gold, ratioLabel

	-- Attack ratio slider.
	local track = Instance.new("Frame")
	track.Name = "RatioSlider"
	track.Position = UDim2.fromOffset(0, 84)
	track.Size = UDim2.new(1, 0, 0, 10)
	track.BackgroundColor3 = Color3.fromRGB(55, 58, 66)
	track.BorderSizePixel = 0
	track.Active = true
	corner(track, 5)
	track.Parent = control
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = ACCENT
	fill.BorderSizePixel = 0
	corner(fill, 5)
	fill.Parent = track
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(16, 16)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	corner(knob, 8)
	knob.Parent = track
	self.ratioFill, self.ratioKnob = fill, knob

	local dragging = false
	local function setFromX(x: number)
		local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0.01, 1)
		self:setRatio(math.floor(rel * 100 + 0.5) / 100)
		if self.onRatioChanged then
			self.onRatioChanged(self.ratio)
		end
	end
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	self:setRatio(0.2)

	-- Leaderboard, top right.
	local board = panel(gui, "Leaderboard")
	board.AnchorPoint = Vector2.new(1, 0)
	board.Position = UDim2.new(1, -12, 0, 12)
	board.Size = UDim2.fromOffset(260, 0)
	board.AutomaticSize = Enum.AutomaticSize.Y
	padding(board, 10)
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = board
	local header = label(board, "Header", "Leaderboard", 15, FONT_BOLD)
	header.Size = UDim2.new(1, 0, 0, 20)
	header.LayoutOrder = 0
	self.boardRows = {}
	for i = 1, 10 do
		local row = Instance.new("Frame")
		row.Name = `Row{i}`
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 18)
		row.LayoutOrder = i
		row.Parent = board
		local name = label(row, "Name", "", 13)
		name.Size = UDim2.new(0.6, 0, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local pct = label(row, "Pct", "", 13, FONT, MUTED)
		pct.Position = UDim2.fromScale(0.6, 0)
		pct.Size = UDim2.new(0.2, 0, 1, 0)
		pct.TextXAlignment = Enum.TextXAlignment.Right
		local tr = label(row, "Troops", "", 13, FONT, MUTED)
		tr.Position = UDim2.fromScale(0.8, 0)
		tr.Size = UDim2.new(0.2, 0, 1, 0)
		tr.TextXAlignment = Enum.TextXAlignment.Right
		row.Visible = false
		self.boardRows[i] = { frame = row, name = name, pct = pct, troops = tr }
	end

	-- Hover info, above the control panel.
	local hover = panel(gui, "Hover")
	hover.AnchorPoint = Vector2.new(0, 1)
	hover.Position = UDim2.new(0, 12, 1, -140)
	hover.AutomaticSize = Enum.AutomaticSize.XY
	hover.Active = false
	padding(hover, 6)
	local hoverText = label(hover, "Text", "", 14)
	hoverText.AutomaticSize = Enum.AutomaticSize.XY
	hover.Visible = false
	self.hover, self.hoverText = hover, hoverText

	-- Winner banner.
	local win = panel(gui, "Winner")
	win.AnchorPoint = Vector2.new(0.5, 0.5)
	win.Position = UDim2.fromScale(0.5, 0.4)
	win.AutomaticSize = Enum.AutomaticSize.XY
	padding(win, 24)
	local winText = label(win, "Text", "", 32, FONT_BOLD)
	winText.AutomaticSize = Enum.AutomaticSize.XY
	winText.TextXAlignment = Enum.TextXAlignment.Center
	win.Visible = false
	self.win, self.winText = win, winText

	return self
end

function Hud:setStatus(text: string)
	self.statusText.Text = text
	self.statusText.Parent.Visible = text ~= ""
end

function Hud:setRatio(ratio: number)
	self.ratio = ratio
	self.ratioText.Text = `Attack ratio: {math.floor(ratio * 100 + 0.5)}%`
	self.ratioFill.Size = UDim2.fromScale(ratio, 1)
	self.ratioKnob.Position = UDim2.fromScale(ratio, 0.5)
end

function Hud:setMyStats(troops: number, maxTroops: number, gold: number)
	self.troopsText.Text = `Troops: {Format.renderTroops(troops)} / {Format.renderTroops(maxTroops)}`
	self.troopFill.Size = UDim2.fromScale(math.clamp(troops / math.max(1, maxTroops), 0, 1), 1)
	self.goldText.Text = `Gold: {Format.renderNumber(gold)}`
end

-- rows: { { name, pct (0-1), troops, isMe } }
function Hud:setLeaderboard(rows)
	for i, r in self.boardRows do
		local data = rows[i]
		r.frame.Visible = data ~= nil
		if data then
			r.name.Text = `{i}. {data.name}`
			r.name.Font = if data.isMe then FONT_BOLD else FONT
			r.name.TextColor3 = if data.isMe then ACCENT else TEXT
			r.pct.Text = Format.formatPercentage(data.pct)
			r.troops.Text = Format.renderTroops(data.troops)
		end
	end
end

function Hud:setHover(text: string?)
	self.hover.Visible = text ~= nil and text ~= ""
	if text then
		self.hoverText.Text = text
	end
end

function Hud:showWinner(text: string)
	self.winText.Text = text
	self.win.Visible = true
end

return Hud
