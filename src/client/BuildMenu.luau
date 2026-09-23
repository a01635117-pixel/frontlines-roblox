-- Build controls, following OpenFront's UnitDisplay hotbar + build ghost +
-- radial menu:
--   * bottom hotbar with every enabled buildable: glyph, owned levels, hotkey;
--     hover shows name and price
--   * keys 1..0 (and numpad) or a hotbar click pick a unit; a ghost follows
--     the cursor (green = can build, blue = upgrades the structure in range,
--     red = not here) and a left click places it; Esc / right click cancels
--   * right click on the map opens a context menu with the build options for
--     that tile and "Delete" for our closest structure (upstream radius 5)
-- The server resolves build vs upgrade exactly like upstream; availability
-- comes from Net.Query (PlayerImpl:buildableUnits on the server).

local UserInputService = game:GetService("UserInputService")

local Format = require(script.Parent.Format)

local PANEL_COLOR = Color3.fromRGB(24, 26, 32)
local TEXT = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(150, 155, 165)
local GOLD = Color3.fromRGB(255, 214, 90)
local OK_COLOR = Color3.fromRGB(80, 200, 120)
local UPGRADE_COLOR = Color3.fromRGB(80, 160, 255)
local BAD_COLOR = Color3.fromRGB(230, 70, 70)
local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

-- Upstream BuildMenus order with the default keybinds (UserSettings).
local ITEMS = {
	{ unit = "City", key = Enum.KeyCode.One, numpad = Enum.KeyCode.KeypadOne, hotkey = "1" },
	{ unit = "Factory", key = Enum.KeyCode.Two, numpad = Enum.KeyCode.KeypadTwo, hotkey = "2" },
	{ unit = "Port", key = Enum.KeyCode.Three, numpad = Enum.KeyCode.KeypadThree, hotkey = "3" },
	{ unit = "Defense Post", key = Enum.KeyCode.Four, numpad = Enum.KeyCode.KeypadFour, hotkey = "4" },
	{ unit = "Missile Silo", key = Enum.KeyCode.Five, numpad = Enum.KeyCode.KeypadFive, hotkey = "5" },
	{ unit = "SAM Launcher", key = Enum.KeyCode.Six, numpad = Enum.KeyCode.KeypadSix, hotkey = "6" },
	{ unit = "Warship", key = Enum.KeyCode.Seven, numpad = Enum.KeyCode.KeypadSeven, hotkey = "7" },
	{ unit = "Atom Bomb", key = Enum.KeyCode.Eight, numpad = Enum.KeyCode.KeypadEight, hotkey = "8" },
	{ unit = "Hydrogen Bomb", key = Enum.KeyCode.Nine, numpad = Enum.KeyCode.KeypadNine, hotkey = "9" },
	{ unit = "MIRV", key = Enum.KeyCode.Zero, numpad = Enum.KeyCode.KeypadZero, hotkey = "0" },
}

local GLYPH = {
	City = "C",
	Factory = "F",
	Port = "P",
	["Defense Post"] = "D",
	["Missile Silo"] = "M",
	["SAM Launcher"] = "S",
	Warship = "W",
	["Atom Bomb"] = "A",
	["Hydrogen Bomb"] = "H",
	MIRV = "V",
}

local QUERY_INTERVAL = 0.12 -- s between ghost availability queries

local BuildMenu = {}
BuildMenu.__index = BuildMenu

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function text(parent: Instance, name: string, s: string, size: number, font: Enum.Font?, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font or FONT
	l.TextSize = size
	l.TextColor3 = color or TEXT
	l.Text = s
	l.Parent = parent
	return l
end

-- deps: { gui, camera, map, net, unitLayer, tileAt(Vector2) -> tile?,
--         mySmallID() -> number?, canAct() -> boolean }
function BuildMenu.new(deps)
	local self = setmetatable({
		deps = deps,
		costs = {}, -- unit -> gold | false (disabled)
		gold = 0,
		selected = nil :: string?,
		ghostTile = nil :: number?,
		ghostInfo = nil,
		queryBusy = false,
		lastQuery = 0,
		buttons = {},
	}, BuildMenu)
	self:_buildHotbar()
	self:_buildGhost()
	self:_buildContextMenu()
	self:_bindKeys()
	return self
end

-- Hotbar -----------------------------------------------------------------------------

function BuildMenu:_buildHotbar()
	local bar = Instance.new("Frame")
	bar.Name = "BuildBar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0, 0, 1, -12)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Size = UDim2.fromOffset(0, 64)
	bar.BackgroundColor3 = PANEL_COLOR
	bar.BackgroundTransparency = 0.2
	bar.BorderSizePixel = 0
	bar.Active = true
	bar.Visible = false
	corner(bar, 8)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 4), UDim.new(0, 4)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
	pad.Parent = bar
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = bar
	bar.Parent = self.deps.gui
	self.bar = bar

	local tip = Instance.new("Frame")
	tip.Name = "BuildTooltip"
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Position = UDim2.new(0, 0, 1, -84)
	tip.AutomaticSize = Enum.AutomaticSize.XY
	tip.BackgroundColor3 = PANEL_COLOR
	tip.BackgroundTransparency = 0.1
	tip.BorderSizePixel = 0
	tip.Visible = false
	corner(tip, 6)
	local tpad = Instance.new("UIPadding")
	tpad.PaddingLeft, tpad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	tpad.PaddingTop, tpad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	tpad.Parent = tip
	local tipText = text(tip, "Text", "", 15, FONT_BOLD)
	tipText.AutomaticSize = Enum.AutomaticSize.XY
	tipText.RichText = true
	tip.Parent = self.deps.gui
	self.tip, self.tipText = tip, tipText

	for i, item in ITEMS do
		local b = Instance.new("TextButton")
		b.Name = item.unit
		b.LayoutOrder = i
		b.Size = UDim2.fromOffset(52, 56)
		b.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		b.AutoButtonColor = true
		b.Text = ""
		b.Visible = false
		corner(b, 6)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = OK_COLOR
		stroke.Enabled = false
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = b
		local glyph = text(b, "Glyph", GLYPH[item.unit], 22, FONT_BOLD)
		glyph.Size = UDim2.new(1, 0, 0, 30)
		glyph.Position = UDim2.fromOffset(0, 6)
		local count = text(b, "Count", "0", 12, FONT_BOLD, MUTED)
		count.Size = UDim2.new(1, -6, 0, 14)
		count.Position = UDim2.fromOffset(0, 38)
		count.TextXAlignment = Enum.TextXAlignment.Right
		local key = text(b, "Key", item.hotkey, 11, FONT_BOLD, MUTED)
		key.Size = UDim2.fromOffset(14, 14)
		key.Position = UDim2.fromOffset(4, 2)
		key.TextXAlignment = Enum.TextXAlignment.Left
		b.Parent = bar
		b.Activated:Connect(function()
			self:select(if self.selected == item.unit then nil else item.unit)
		end)
		b.MouseEnter:Connect(function()
			self.hovered = item.unit
			self:_refreshTip()
		end)
		b.MouseLeave:Connect(function()
			if self.hovered == item.unit then
				self.hovered = nil
				self:_refreshTip()
			end
		end)
		self.buttons[item.unit] = { button = b, glyph = glyph, count = count, stroke = stroke }
	end
end

function BuildMenu:_refreshTip()
	local u = self.hovered
	local cost = u and self.costs[u]
	self.tip.Visible = u ~= nil and cost ~= nil and cost ~= false
	if self.tip.Visible then
		local color = if cost <= self.gold then "#ffd65a" else "#e64646"
		self.tipText.Text = `{u}  <font color="{color}">{Format.renderNumber(cost)} gold</font>`
	end
end

-- Prices from the server (Net.BuildInfo) and our current gold.
function BuildMenu:setCosts(costs)
	self.costs = costs
	self:refresh()
end

function BuildMenu:setGold(gold: number)
	self.gold = gold
	self:refresh()
end

function BuildMenu:refresh()
	local me = self.deps.mySmallID()
	local visible = self.deps.canAct()
	local any = false
	for _, item in ITEMS do
		local b = self.buttons[item.unit]
		local cost = self.costs[item.unit]
		local enabled = cost ~= nil and cost ~= false
		b.button.Visible = enabled
		any = any or enabled
		if enabled then
			local affordable = cost <= self.gold
			b.glyph.TextColor3 = if affordable then TEXT else MUTED
			b.button.BackgroundTransparency = if affordable then 0 else 0.5
			b.count.Text = if me then tostring(self.deps.unitLayer:totalLevels(me, item.unit)) else "0"
			b.stroke.Enabled = self.selected == item.unit
		end
	end
	self.bar.Visible = visible and any
	-- Centred, but never over the control panel (bottom left, 12 + 300 px).
	local screenW = self.deps.gui.AbsoluteSize.X
	local half = self.bar.AbsoluteSize.X / 2
	self.bar.Position = UDim2.new(0, math.max(screenW / 2, 12 + 300 + 8 + half), 1, -12)
	self.tip.Position = UDim2.new(0, self.bar.Position.X.Offset, 1, -84)
	if not visible and self.selected then
		self:select(nil)
	end
	self:_refreshTip()
end

-- Ghost ------------------------------------------------------------------------------

function BuildMenu:_buildGhost()
	local ghost = Instance.new("Frame")
	ghost.Name = "BuildGhost"
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.BackgroundTransparency = 0.35
	ghost.BorderSizePixel = 0
	ghost.ZIndex = 20
	ghost.Visible = false
	corner(ghost, 6)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Parent = ghost
	local glyph = text(ghost, "Glyph", "", 18, FONT_BOLD)
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.ZIndex = 21
	local caption = text(ghost, "Caption", "", 13, FONT_BOLD)
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.new(0.5, 0, 1, 4)
	caption.AutomaticSize = Enum.AutomaticSize.XY
	caption.ZIndex = 21
	local cs = Instance.new("UIStroke")
	cs.Thickness = 1.5
	cs.Parent = caption
	ghost.Parent = self.deps.gui
	self.ghost, self.ghostGlyph, self.ghostCaption = ghost, glyph, caption
end

function BuildMenu:select(unit: string?)
	self.selected = unit
	self.ghostTile, self.ghostInfo = nil, nil
	self.ghost.Visible = false
	if unit then
		self:closeContextMenu()
		self.ghostGlyph.Text = GLYPH[unit]
		self:hover(self.deps.mousePos())
	end
	self:refresh()
end

-- Query what we can do at a tile; cb(result) runs on the caller's thread later.
function BuildMenu:_query(tile: number, cb)
	task.spawn(function()
		local ok, result = pcall(function()
			return self.deps.net.Query:InvokeServer({ tile = tile })
		end)
		cb(if ok then result else nil)
	end)
end

function BuildMenu:_infoFor(result, unit: string)
	if result == nil then
		return nil
	end
	for _, u in result.units do
		if u.unit == unit then
			return u
		end
	end
	return nil
end

function BuildMenu:_updateGhost()
	local info = self.ghostInfo
	local color, caption = BAD_COLOR, ""
	if info and info.canUpgrade then
		color, caption = UPGRADE_COLOR, "Upgrade"
	elseif info and info.canBuild then
		color, caption = OK_COLOR, ""
	end
	if info then
		caption = `{caption}{if caption ~= "" then " · " else ""}{Format.renderNumber(info.cost)}`
	end
	self.ghost.BackgroundColor3 = color
	self.ghostCaption.Text = caption
	self.ghostCaption.TextColor3 = if info and info.cost <= self.gold then GOLD else BAD_COLOR
end

-- Mouse moved (screen position); only matters while a unit is selected.
function BuildMenu:hover(p: Vector2)
	if not self.selected then
		return
	end
	local tile = self.deps.tileAt(p)
	self.ghost.Visible = tile ~= nil
	if tile == nil then
		return
	end
	local size = math.clamp(self.deps.camera.zoom * 3, 18, 34)
	self.ghost.Position = UDim2.fromOffset(p.X, p.Y)
	self.ghost.Size = UDim2.fromOffset(size, size)
	if tile ~= self.ghostTile then
		self.ghostTile = tile
		self:_scheduleQuery()
	end
end

function BuildMenu:_scheduleQuery()
	if self.queryBusy then
		self.queryDirty = true
		return
	end
	local wait = QUERY_INTERVAL - (os.clock() - self.lastQuery)
	self.queryBusy = true
	task.delay(math.max(0, wait), function()
		local tile, unit = self.ghostTile, self.selected
		if tile == nil or unit == nil then
			self.queryBusy = false
			return
		end
		self.lastQuery = os.clock()
		self:_query(tile, function(result)
			self.queryBusy = false
			if self.selected == unit and self.ghostTile == tile then
				self.ghostInfo = self:_infoFor(result, unit)
				self:_updateGhost()
			end
			if self.queryDirty then
				self.queryDirty = false
				self:_scheduleQuery()
			end
		end)
	end)
end

-- Left click on the map; returns true when the build menu used it.
function BuildMenu:click(tile: number): boolean
	if self.contextMenu.Visible then
		self:closeContextMenu()
		return true
	end
	if not self.selected then
		return false
	end
	self.deps.net.Intent:FireServer({ type = "place", unit = self.selected, tile = tile })
	self:select(nil)
	return true
end

-- Context menu -------------------------------------------------------------------------

function BuildMenu:_buildContextMenu()
	local menu = Instance.new("Frame")
	menu.Name = "ContextMenu"
	menu.AutomaticSize = Enum.AutomaticSize.Y
	menu.Size = UDim2.fromOffset(210, 0)
	menu.BackgroundColor3 = PANEL_COLOR
	menu.BackgroundTransparency = 0.08
	menu.BorderSizePixel = 0
	menu.Active = true
	menu.Visible = false
	menu.ZIndex = 30
	corner(menu, 8)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.Parent = menu
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = menu
	menu.Parent = self.deps.gui
	self.contextMenu = menu
end

function BuildMenu:closeContextMenu()
	self.contextMenu.Visible = false
	for _, c in self.contextMenu:GetChildren() do
		if c:IsA("TextButton") or c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	self.contextSeq = (self.contextSeq or 0) + 1
end

local function menuRow(menu: Frame, order: number, left: string, right: string, enabled: boolean, color: Color3?)
	local b = Instance.new("TextButton")
	b.LayoutOrder = order
	b.Size = UDim2.new(1, 0, 0, 28)
	b.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
	b.BackgroundTransparency = if enabled then 0 else 0.6
	b.AutoButtonColor = enabled
	b.Text = ""
	b.ZIndex = 31
	corner(b, 5)
	local l = text(b, "Left", left, 14, FONT_BOLD, if enabled then (color or TEXT) else MUTED)
	l.Size = UDim2.new(1, -12, 1, 0)
	l.Position = UDim2.fromOffset(8, 0)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.ZIndex = 32
	local r = text(b, "Right", right, 13, FONT_BOLD, if enabled then GOLD else MUTED)
	r.Size = UDim2.new(1, -8, 1, 0)
	r.TextXAlignment = Enum.TextXAlignment.Right
	r.ZIndex = 32
	b.Parent = menu
	return b
end

-- Right click on the map at screen position p / tile.
function BuildMenu:openContextMenu(p: Vector2, tile: number)
	if self.selected then
		self:select(nil)
		return
	end
	self:closeContextMenu()
	if not self.deps.canAct() then
		return
	end
	local seq = self.contextSeq
	self:_query(tile, function(result)
		if seq ~= self.contextSeq or result == nil then
			return
		end
		local menu = self.contextMenu
		local order = 0
		local title = text(menu, "Title", "Build", 13, FONT_BOLD, MUTED)
		title.Size = UDim2.new(1, 0, 0, 18)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.ZIndex = 31
		for _, item in ITEMS do
			local info = self:_infoFor(result, item.unit)
			if info then
				order += 1
				local enabled = info.canBuild or info.canUpgrade
				local label = if info.canUpgrade then `Upgrade {item.unit}` else item.unit
				local row = menuRow(menu, order, `{item.hotkey}  {label}`, Format.renderNumber(info.cost), enabled)
				if enabled then
					row.Activated:Connect(function()
						self.deps.net.Intent:FireServer({ type = "place", unit = item.unit, tile = tile })
						self:closeContextMenu()
					end)
				end
			end
		end
		if result.deleteUnit then
			order += 1
			local row = menuRow(menu, order, `Delete {result.deleteUnit}`, "", true, BAD_COLOR)
			row.Activated:Connect(function()
				self.deps.net.Intent:FireServer({ type = "delete_at", tile = tile })
				self:closeContextMenu()
			end)
		end
		-- Keep the menu on screen.
		local screen = self.deps.gui.AbsoluteSize
		local h = 30 + order * 31
		menu.Position = UDim2.fromOffset(math.min(p.X + 8, screen.X - 220), math.clamp(p.Y - 10, 8, math.max(8, screen.Y - h - 8)))
		menu.Visible = true
	end)
end

-- Keys ---------------------------------------------------------------------------------

function BuildMenu:_bindKeys()
	local byKey = {}
	for _, item in ITEMS do
		byKey[item.key] = item.unit
		byKey[item.numpad] = item.unit
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			self:select(nil)
			self:closeContextMenu()
			return
		end
		local unit = byKey[input.KeyCode]
		if unit and self.deps.canAct() then
			local cost = self.costs[unit]
			if cost ~= nil and cost ~= false then
				self:select(if self.selected == unit then nil else unit)
			end
		end
	end)
end

return BuildMenu
