-- Units drawn over the map: transport and trade ships (interpolated between
-- simulation ticks, a ship moves one tile per 100 ms tick) and structures
-- (owner-coloured badges with the upstream icon and their level).
-- Nukes fly on their motion plan (Parabola.motionPath replayed against the
-- estimated tick), SAM missiles and the MIRV carrier are interpolated, and
-- detonations play a flash + shockwave (render-settings nukeShockwave*).
-- TODO(port): warships, trains; incoming-nuke trajectory telegraph.

local Parabola = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Parabola"))

local Format = require(script.Parent.Format)
local Icons = require(script.Parent.Icons)

local NUKE_ICON = { ["Atom Bomb"] = "atomBomb", ["Hydrogen Bomb"] = "hydrogenBomb", MIRV = "mirv" }
-- Config.nukeMagnitudes outer radius, in tiles.
local BLAST_RADIUS = { ["Atom Bomb"] = 30, ["Hydrogen Bomb"] = 100, ["MIRV Warhead"] = 18 }
local SHOCKWAVE_SECONDS = 1.5 -- nukeShockwaveDurationMs
local SHOCKWAVE_FACTOR = 1.5 -- nukeShockwaveRadiusFactor

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

local function makeNuke(parent: Instance, id: number, icon: string)
	local l = Icons.label(parent, icon, 20, { white = true })
	l.Name = `Nuke{id}`
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.ZIndex = 8
	l.ImageColor3 = Color3.fromRGB(255, 90, 70)
	return l
end

local function makeWarhead(parent: Instance, id: number)
	local f = Instance.new("Frame")
	f.Name = `Warhead{id}`
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Color3.fromRGB(255, 80, 60)
	f.ZIndex = 8
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	f.Parent = parent
	return f
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
		if u.reachedTarget and BLAST_RADIUS[u.unitType] then
			self:explode(u.targetTile or u.pos, BLAST_RADIUS[u.unitType])
		end
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
	if u.plan then
		self:_applyPlanned(e, u)
		return
	end
	local isMissile = u.unitType == "SAMMissile" or u.unitType == "MIRV"
	if u.unitType ~= "Transport" and u.unitType ~= "Trade Ship" and not isMissile then
		return -- TODO(port): warships, trains
	end
	local now = os.clock()
	if e == nil then
		local frame, label
		if u.unitType == "MIRV" then
			frame = makeNuke(self.container, u.id, "mirv")
		else
			frame, label = makeShip(self.container, u.id, u.unitType == "Transport")
		end
		e = {
			frame = frame,
			label = label,
			from = u.pos,
			to = u.pos,
			t0 = now,
			small = u.unitType == "Trade Ship",
			tiny = u.unitType == "SAMMissile",
			nuke = u.unitType == "MIRV",
			unitType = u.unitType,
		}
		self.units[u.id] = e
	elseif e.to ~= u.pos then
		e.from = e.to
		e.to = u.pos
		e.t0 = now
	end
	e.ownerID = u.ownerID
	if e.nuke then
		return
	end
	local color = if e.tiny then Color3.new(1, 1, 1) else self.colors[u.ownerID] or Color3.new(1, 1, 1)
	e.frame.BackgroundColor3 = if u.isRetreating then color:Lerp(Color3.new(0.5, 0.5, 0.5), 0.6) else color
	if e.label then
		e.label.Text = Format.renderTroops(u.troops or 0)
	end
end

-- Nukes with a motion plan: the path is computed once and replayed.
function UnitLayer:_applyPlanned(e, u)
	if e == nil then
		local icon = NUKE_ICON[u.unitType]
		local frame = if icon then makeNuke(self.container, u.id, icon) else makeWarhead(self.container, u.id)
		local p = u.plan
		e = {
			frame = frame,
			planned = true,
			warhead = icon == nil,
			path = Parabola.motionPath(self.map, p.src, p.dst, p.speed, p.directionUp),
			startTick = p.startTick,
			unitType = u.unitType,
			ownerID = u.ownerID,
		}
		self.units[u.id] = e
	end
end

-- Flash + expanding shockwave ring over a blast of `radius` tiles.
function UnitLayer:explode(tile: number, radius: number)
	local camera, map = self.camera, self.map
	local x, y = map:x(tile), map:y(tile)
	local flash = Instance.new("Frame")
	flash.Name = "Explosion"
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.BorderSizePixel = 0
	flash.BackgroundColor3 = Color3.fromRGB(255, 240, 200)
	flash.ZIndex = 9
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0.5, 0)
	fc.Parent = flash
	local ring = Instance.new("Frame")
	ring.Name = "Shockwave"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 9
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0.5, 0)
	rc.Parent = ring
	local rs = Instance.new("UIStroke")
	rs.Color = Color3.fromRGB(255, 170, 60)
	rs.Thickness = 3
	rs.Parent = ring
	flash.Parent = self.container
	ring.Parent = self.container
	local entry = { flash = flash, ring = ring, stroke = rs, x = x, y = y, radius = radius, t0 = os.clock() }
	self.explosions = self.explosions or {}
	table.insert(self.explosions, entry)
	self:_placeExplosion(entry)
end

function UnitLayer:_placeExplosion(ex): boolean
	local a = (os.clock() - ex.t0) / SHOCKWAVE_SECONDS
	if a >= 1 then
		ex.flash:Destroy()
		ex.ring:Destroy()
		return false
	end
	local camera = self.camera
	local p = camera:screenPos(ex.x, ex.y)
	local rpx = ex.radius * camera.zoom
	-- Flash: full blast disc, gone in the first 40 %.
	local fa = math.clamp(a / 0.4, 0, 1)
	ex.flash.Position = UDim2.fromOffset(p.X, p.Y)
	ex.flash.Size = UDim2.fromOffset(rpx * 2 * (0.6 + 0.4 * fa), rpx * 2 * (0.6 + 0.4 * fa))
	ex.flash.BackgroundTransparency = 0.15 + 0.85 * fa
	-- Shockwave: grows to radius x factor, fading out.
	local ease = 1 - (1 - a) * (1 - a)
	local d = rpx * 2 * SHOCKWAVE_FACTOR * ease
	ex.ring.Position = UDim2.fromOffset(p.X, p.Y)
	ex.ring.Size = UDim2.fromOffset(d, d)
	ex.stroke.Transparency = a
	return true
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
	local tick = if self.tickNow then self.tickNow() else 0
	for _, e in self.units do
		if e.isStructure then
			self:_place(e)
			continue
		end
		if e.planned then
			-- Tile index on the plan: 0 = launch tile until startTick.
			local t = math.max(0, tick - e.startTick + 1)
			local n = #e.path
			local i = math.min(math.floor(t), n - 1)
			local frac = if i >= n - 1 then 0 else t - math.floor(t)
			local a, b = e.path[i + 1], e.path[math.min(i + 2, n)]
			local fx, fy = map:x(a), map:y(a)
			local p = camera:screenPos(fx + (map:x(b) - fx) * frac, fy + (map:y(b) - fy) * frac)
			local s = if e.warhead then math.clamp(camera.zoom * 1.2, 4, 9) else math.clamp(camera.zoom * 3, 14, 30)
			e.frame.Position = UDim2.fromOffset(p.X, p.Y)
			e.frame.Size = UDim2.fromOffset(s, s)
			continue
		end
		local a = math.clamp((now - e.t0) / TICK_SECONDS, 0, 1)
		local fx, fy = map:x(e.from), map:y(e.from)
		local tx, ty = map:x(e.to), map:y(e.to)
		local p = camera:screenPos(fx + (tx - fx) * a, fy + (ty - fy) * a)
		local s = if e.tiny then math.max(4, size * 0.35) elseif e.small then size * 0.6 elseif e.nuke then math.clamp(camera.zoom * 3, 14, 30) else size
		e.frame.Position = UDim2.fromOffset(p.X, p.Y)
		e.frame.Size = UDim2.fromOffset(s, s)
		if e.label then
			e.label.TextSize = math.max(10, size * 0.7)
		end
	end
	if self.explosions then
		local keep = {}
		for _, ex in self.explosions do
			if self:_placeExplosion(ex) then
				table.insert(keep, ex)
			end
		end
		self.explosions = keep
	end
end

return UnitLayer
