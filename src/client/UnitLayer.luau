-- Units drawn over the map: transport and trade ships (interpolated between
-- simulation ticks, a ship moves one tile per 100 ms tick) and structures
-- (owner-coloured badges with the upstream icon and their level).
-- TODO(port): warships, nukes, trains.

local Format = require(script.Parent.Format)
local Icons = require(script.Parent.Icons)

local TICK_SECONDS = 0.1
local MIN_SIZE, MAX_SIZE = 7, 26 -- px, ships
local MIN_STRUCT, MAX_STRUCT = 9, 30 -- px, structures

-- Structure icons (tools/pack-icons.mjs).
local STRUCTURE_ICON = {
	City = "city",
	Factory = "factory",
	Port = "port",
	["Defense Post"] = "defensePost",
	["Missile Silo"] = "missileSilo",
	["SAM Launcher"] = "samLauncher",
}

local UnitLayer = {}
UnitLayer.__index = UnitLayer

function UnitLayer.new(parent: GuiObject, camera, gameMap)
	local container = Instance.new("Frame")
	container.Name = "Units"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 6
	container.Parent = parent
	return setmetatable({
		container = container,
		camera = camera,
		map = gameMap,
		units = {}, -- id -> entry
		colors = {}, -- smallID -> Color3
		onChanged = nil :: (() -> ())?, -- structures added / removed / upgraded
	}, UnitLayer)
end

function UnitLayer:setOwnerColor(smallID: number, rgb: { number })
	self.colors[smallID] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function stroked(parent: Instance, thickness: number, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color or Color3.fromRGB(20, 20, 24)
	s.Parent = parent
	return s
end

local function textLabel(parent: Instance, name: string): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.ZIndex = 7
	stroked(label, 1.2)
	label.Parent = parent
	return label
end

local function makeShip(parent: Instance, id: number, withTroops: boolean)
	local frame = Instance.new("Frame")
	frame.Name = `Unit{id}`
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.ZIndex = 6
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	stroked(frame, 1.5)
	local label = nil
	if withTroops then
		label = textLabel(frame, "Troops")
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.new(0.5, 0, 0, -2)
		label.AutomaticSize = Enum.AutomaticSize.XY
	end
	frame.Parent = parent
	return frame, label
end

local function makeStructure(parent: Instance, id: number, icon: string)
	local frame = Instance.new("Frame")
	frame.Name = `Structure{id}`
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.ZIndex = 5
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.25, 0)
	corner.Parent = frame
	local stroke = stroked(frame, 1.5, Color3.new(1, 1, 1))
	local g = Icons.label(frame, icon, 16, { white = true })
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Position = UDim2.fromScale(0.5, 0.5)
	g.Size = UDim2.fromScale(0.78, 0.78)
	g.ZIndex = 6
	local level = textLabel(frame, "Level")
	level.AnchorPoint = Vector2.new(0, 1)
	level.Position = UDim2.fromScale(0.72, 0.28)
	level.AutomaticSize = Enum.AutomaticSize.XY
	level.TextColor3 = Color3.fromRGB(255, 214, 90)
	level.ZIndex = 7
	frame.Parent = parent
	return frame, g, level, stroke
end

-- Apply one unit update { id, unitType, ownerID, pos, troops, isActive,
-- isRetreating, level, underConstruction, markedForDeletion }.
function UnitLayer:apply(u)
	local e = self.units[u.id]
	if not u.isActive then
		if e then
			e.frame:Destroy()
			self.units[u.id] = nil
			if e.isStructure and self.onChanged then
				self.onChanged()
			end
		end
		return
	end
	local icon = STRUCTURE_ICON[u.unitType]
	if icon then
		self:_applyStructure(e, u, icon)
		return
	end
	if u.unitType ~= "Transport" and u.unitType ~= "Trade Ship" then
		return -- TODO(port): warships, nukes, trains
	end
	local now = os.clock()
	if e == nil then
		local frame, label = makeShip(self.container, u.id, u.unitType == "Transport")
		e = { frame = frame, label = label, from = u.pos, to = u.pos, t0 = now, small = u.unitType == "Trade Ship", unitType = u.unitType }
		self.units[u.id] = e
	elseif e.to ~= u.pos then
		e.from = e.to
		e.to = u.pos
		e.t0 = now
	end
	e.ownerID = u.ownerID
	local color = self.colors[u.ownerID] or Color3.new(1, 1, 1)
	e.frame.BackgroundColor3 = if u.isRetreating then color:Lerp(Color3.new(0.5, 0.5, 0.5), 0.6) else color
	if e.label then
		e.label.Text = Format.renderTroops(u.troops or 0)
	end
end

function UnitLayer:_applyStructure(e, u, icon: string)
	if e == nil then
		local frame, g, level, stroke = makeStructure(self.container, u.id, icon)
		e = { frame = frame, glyph = g, levelLabel = level, stroke = stroke, isStructure = true, pos = u.pos }
		self.units[u.id] = e
	end
	e.unitType, e.ownerID, e.pos = u.unitType, u.ownerID, u.pos
	e.level = u.level or 1
	local color = self.colors[u.ownerID] or Color3.new(1, 1, 1)
	e.frame.BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.25)
	-- Structures being built are drawn faded until they finish.
	local building = u.underConstruction == true
	e.frame.BackgroundTransparency = if building then 0.55 else 0
	e.stroke.Transparency = if building then 0.5 else 0
	-- Marked for deletion (removed when the 30 s mark expires): red outline.
	e.stroke.Color = if u.markedForDeletion then Color3.fromRGB(230, 70, 70) else Color3.new(1, 1, 1)
	e.stroke.Thickness = if u.markedForDeletion then 2.5 else 1.5
	e.glyph.ImageTransparency = if building then 0.4 else 0
	e.levelLabel.Text = if e.level > 1 then tostring(e.level) else ""
	self:_place(e)
	if self.onChanged then
		self.onChanged()
	end
end

-- Whether a player has any active unit of a type (ships included).
function UnitLayer:hasUnit(ownerID: number, unitType: string): boolean
	for _, e in self.units do
		if e.ownerID == ownerID and e.unitType == unitType then
			return true
		end
	end
	return false
end

-- Sum of levels of a player's structures of one type (upstream totalUnitLevels).
function UnitLayer:totalLevels(ownerID: number, unitType: string): number
	local n = 0
	for _, e in self.units do
		if e.isStructure and e.ownerID == ownerID and e.unitType == unitType then
			n += e.level
		end
	end
	return n
end

function UnitLayer:_place(e)
	local camera, map = self.camera, self.map
	local size = math.clamp(camera.zoom * 3, MIN_STRUCT, MAX_STRUCT)
	local p = camera:screenPos(map:x(e.pos), map:y(e.pos))
	e.frame.Position = UDim2.fromOffset(p.X, p.Y)
	e.frame.Size = UDim2.fromOffset(size, size)
	e.levelLabel.TextSize = math.max(9, size * 0.5)
end

-- Per-frame: interpolate ship positions and scale everything with zoom.
function UnitLayer:render()
	local camera, map = self.camera, self.map
	local size = math.clamp(camera.zoom * 2.2, MIN_SIZE, MAX_SIZE)
	local now = os.clock()
	for _, e in self.units do
		if e.isStructure then
			self:_place(e)
			continue
		end
		local a = math.clamp((now - e.t0) / TICK_SECONDS, 0, 1)
		local fx, fy = map:x(e.from), map:y(e.from)
		local tx, ty = map:x(e.to), map:y(e.to)
		local p = camera:screenPos(fx + (tx - fx) * a, fy + (ty - fy) * a)
		local s = if e.small then size * 0.6 else size
		e.frame.Position = UDim2.fromOffset(p.X, p.Y)
		e.frame.Size = UDim2.fromOffset(s, s)
		if e.label then
			e.label.TextSize = math.max(10, size * 0.7)
		end
	end
end

return UnitLayer
