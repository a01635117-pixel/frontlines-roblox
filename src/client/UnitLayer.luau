-- Units drawn over the map (transport ships so far). Positions interpolate
-- between simulation ticks (a boat moves one tile per 100 ms tick).
-- TODO(port): warships, trade ships, structures, nukes, trains.

local Format = require(script.Parent.Format)

local TICK_SECONDS = 0.1
local MIN_SIZE, MAX_SIZE = 7, 26 -- px

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
	}, UnitLayer)
end

function UnitLayer:setOwnerColor(smallID: number, rgb: { number })
	self.colors[smallID] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function makeMarker(parent: Instance, id: number)
	local frame = Instance.new("Frame")
	frame.Name = `Unit{id}`
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.ZIndex = 6
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(20, 20, 24)
	stroke.Parent = frame
	local label = Instance.new("TextLabel")
	label.Name = "Troops"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 0, -2)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.ZIndex = 7
	local ls = Instance.new("UIStroke")
	ls.Thickness = 1.2
	ls.Parent = label
	label.Parent = frame
	frame.Parent = parent
	return frame, label
end

-- Apply one unit update { id, unitType, ownerID, pos, troops, isActive, isRetreating }.
function UnitLayer:apply(u)
	local e = self.units[u.id]
	if not u.isActive then
		if e then
			e.frame:Destroy()
			self.units[u.id] = nil
		end
		return
	end
	if u.unitType ~= "Transport" then
		return -- TODO(port): other unit visuals
	end
	local now = os.clock()
	if e == nil then
		local frame, label = makeMarker(self.container, u.id)
		e = { frame = frame, label = label, from = u.pos, to = u.pos, t0 = now }
		self.units[u.id] = e
	elseif e.to ~= u.pos then
		e.from = e.to
		e.to = u.pos
		e.t0 = now
	end
	local color = self.colors[u.ownerID] or Color3.new(1, 1, 1)
	e.frame.BackgroundColor3 = if u.isRetreating then color:Lerp(Color3.new(0.5, 0.5, 0.5), 0.6) else color
	e.label.Text = Format.renderTroops(u.troops or 0)
end

-- Per-frame: interpolate positions and scale with zoom.
function UnitLayer:render()
	local camera, map = self.camera, self.map
	local size = math.clamp(camera.zoom * 2.2, MIN_SIZE, MAX_SIZE)
	local now = os.clock()
	for _, e in self.units do
		local a = math.clamp((now - e.t0) / TICK_SECONDS, 0, 1)
		local fx, fy = map:x(e.from), map:y(e.from)
		local tx, ty = map:x(e.to), map:y(e.to)
		local p = camera:screenPos(fx + (tx - fx) * a, fy + (ty - fy) * a)
		e.frame.Position = UDim2.fromOffset(p.X, p.Y)
		e.frame.Size = UDim2.fromOffset(size, size)
		e.label.TextSize = math.max(10, size * 0.7)
	end
end

return UnitLayer
