--!native
-- Draws terrain + territory onto EditableImage tiles.
--
-- Look matches OpenFront's default theme (TerritoryPass / BorderStampPass):
--   * territory fill: player colour desaturated toward luma by
--     territorySaturation (0.85), alpha-blended over terrain at
--     territoryAlpha (0.588)
--   * border tiles (any 4-neighbour with a different owner): the player's
--     border colour (colord .darken(0.125)), opaque
--
-- Tile state is the simulation's u16 per tile (bits 0-11 owner smallID).
-- Changing a tile dirties it and its 4 neighbours (their border status may
-- flip); flush() recomputes dirty pixels and uploads each image's dirty
-- rectangle only.

local AssetService = game:GetService("AssetService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local TerrainColors = require(Shared:WaitForChild("TerrainColors"))

local MAX_TILE = 1024 -- EditableImage size limit
local TERRITORY_ALPHA = 0.588 -- render-settings.json territoryAlpha
local TERRITORY_SATURATION = 0.85 -- render-settings.json territorySaturation
local OWNER_MASK = 0x0fff
local FALLOUT_BIT = 0x2000 -- GameMap FALLOUT (bit 13)

local band = bit32.band
local readu16, writeu16 = buffer.readu16, buffer.writeu16
local readu32, writeu32 = buffer.readu32, buffer.writeu32

local TerritoryRenderer = {}
TerritoryRenderer.__index = TerritoryRenderer

local function pack(r: number, g: number, b: number): number
	return r + g * 0x100 + b * 0x10000 + 0xff000000
end

-- camera: MapCamera the image tiles are registered with.
function TerritoryRenderer.new(camera, gameMap)
	local W, H = gameMap:width(), gameMap:height()
	local n = W * H

	-- Terrain colour per tile, packed RGBA (little-endian r,g,b,a bytes).
	local terrainRGBA = TerrainColors.buildRGBA(gameMap:terrainBuffer(), W, 0, 0, W, H, TerrainColors.buildLUT())

	local self = setmetatable({
		W = W,
		H = H,
		terrain = terrainRGBA,
		state = buffer.create(n * 2),
		fill = {}, -- smallID -> { r, g, b } (saturated, pre-multiplied by alpha)
		border = {}, -- smallID -> packed RGBA
		chunks = {},
		dirty = {}, -- tile -> true
		dirtyList = {},
		fullRedraw = true,
	}, TerritoryRenderer)

	local cols = math.ceil(W / MAX_TILE)
	local rows = math.ceil(H / MAX_TILE)
	local tileW = math.ceil(W / cols)
	local tileH = math.ceil(H / rows)
	self.cols, self.tileW, self.tileH = cols, tileW, tileH

	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local x0, y0 = c * tileW, r * tileH
			local w = math.min(tileW, W - x0)
			local h = math.min(tileH, H - y0)
			local image = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
			if not image then
				error(`CreateEditableImage failed for {w}x{h} tile (client memory budget?)`)
			end
			local label = Instance.new("ImageLabel")
			label.Name = `Tile_{c}_{r}`
			label.BackgroundTransparency = 1
			label.BorderSizePixel = 0
			label.ResampleMode = Enum.ResamplerMode.Pixelated
			label.ImageContent = Content.fromObject(image)
			camera:addTile(label, x0, y0, w, h)
			table.insert(self.chunks, {
				image = image,
				x0 = x0,
				y0 = y0,
				w = w,
				h = h,
				pixels = buffer.create(w * h * 4),
				-- dirty rect in chunk-local coords (inclusive), empty when minX > maxX
				minX = math.huge,
				minY = math.huge,
				maxX = -1,
				maxY = -1,
			})
		end
	end
	return self
end

-- Player colours: rgb / border as { r, g, b } in 0-255.
function TerritoryRenderer:setPlayerColor(smallID: number, rgb: { number }, border: { number })
	local r, g, b = rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
	-- Desaturate toward luma, as the territory shader does.
	local luma = r * 0.299 + g * 0.587 + b * 0.114
	r = luma + (r - luma) * TERRITORY_SATURATION
	g = luma + (g - luma) * TERRITORY_SATURATION
	b = luma + (b - luma) * TERRITORY_SATURATION
	self.fill[smallID] = { r * 255 * TERRITORY_ALPHA, g * 255 * TERRITORY_ALPHA, b * 255 * TERRITORY_ALPHA }
	self.border[smallID] = pack(border[1], border[2], border[3])
	self.fullRedraw = true
end

function TerritoryRenderer:ownerAt(tile: number): number
	return band(readu16(self.state, tile * 2), OWNER_MASK)
end

function TerritoryRenderer:_markDirty(tile: number)
	if not self.dirty[tile] then
		self.dirty[tile] = true
		table.insert(self.dirtyList, tile)
	end
end

-- Apply one tile's new simulation state.
function TerritoryRenderer:setState(tile: number, s: number)
	if readu16(self.state, tile * 2) == s then
		return
	end
	writeu16(self.state, tile * 2, s)
	if self.fullRedraw then
		return
	end
	local W = self.W
	local x = tile % W
	self:_markDirty(tile)
	if tile >= W then
		self:_markDirty(tile - W)
	end
	if tile < (self.H - 1) * W then
		self:_markDirty(tile + W)
	end
	if x ~= 0 then
		self:_markDirty(tile - 1)
	end
	if x ~= W - 1 then
		self:_markDirty(tile + 1)
	end
end

-- Replace the whole state (snapshot on join).
function TerritoryRenderer:loadState(stateBuf: buffer)
	buffer.copy(self.state, 0, stateBuf, 0, math.min(buffer.len(stateBuf), buffer.len(self.state)))
	self.fullRedraw = true
end

-- Packed RGBA for one tile.
function TerritoryRenderer:_pixel(tile: number): number
	local state = self.state
	local raw = readu16(state, tile * 2)
	if band(raw, FALLOUT_BIT) ~= 0 then
		-- Stale-nuke ground (territory.frag.glsl): opaque green with a per-tile
		-- hash noise (staleNukeR/G/B 0.05/0.55/0.07, variation 0.05).
		local W = self.W
		local x, y = tile % W, tile // W
		local h = math.sin(x * 12.9898 + y * 78.233) * 43758.5453
		local n = (h - math.floor(h)) * 0.05
		return pack(math.floor((0.05 + n) * 255 + 0.5), math.floor((0.55 + n) * 255 + 0.5), math.floor((0.07 + n) * 255 + 0.5))
	end
	local owner = band(raw, OWNER_MASK)
	if owner == 0 then
		return readu32(self.terrain, tile * 4)
	end
	local W = self.W
	local x = tile % W
	local isBorder = (tile >= W and band(readu16(state, (tile - W) * 2), OWNER_MASK) ~= owner)
		or (tile < (self.H - 1) * W and band(readu16(state, (tile + W) * 2), OWNER_MASK) ~= owner)
		or (x ~= 0 and band(readu16(state, (tile - 1) * 2), OWNER_MASK) ~= owner)
		or (x ~= W - 1 and band(readu16(state, (tile + 1) * 2), OWNER_MASK) ~= owner)
	if isBorder then
		return self.border[owner] or 0xff000000
	end
	local f = self.fill[owner]
	local t = readu32(self.terrain, tile * 4)
	if not f then
		return t
	end
	local k = 1 - TERRITORY_ALPHA
	local r = math.floor(band(t, 0xff) * k + f[1] + 0.5)
	local g = math.floor(band(bit32.rshift(t, 8), 0xff) * k + f[2] + 0.5)
	local b = math.floor(band(bit32.rshift(t, 16), 0xff) * k + f[3] + 0.5)
	return pack(r, g, b)
end

function TerritoryRenderer:_chunkFor(x: number, y: number)
	local c = x // self.tileW
	local r = y // self.tileH
	return self.chunks[r * self.cols + c + 1]
end

-- Recompute dirty pixels and upload changed rectangles.
function TerritoryRenderer:flush()
	if self.fullRedraw then
		self.fullRedraw = false
		table.clear(self.dirty)
		table.clear(self.dirtyList)
		for _, ch in self.chunks do
			local px = ch.pixels
			local o = 0
			for y = ch.y0, ch.y0 + ch.h - 1 do
				local row = y * self.W
				for x = ch.x0, ch.x0 + ch.w - 1 do
					writeu32(px, o, self:_pixel(row + x))
					o += 4
				end
			end
			ch.image:WritePixelsBuffer(Vector2.zero, Vector2.new(ch.w, ch.h), px)
			ch.minX, ch.minY, ch.maxX, ch.maxY = math.huge, math.huge, -1, -1
		end
		return
	end

	local list = self.dirtyList
	if #list == 0 then
		return
	end
	local W = self.W
	for _, tile in list do
		local x, y = tile % W, tile // W
		local ch = self:_chunkFor(x, y)
		local lx, ly = x - ch.x0, y - ch.y0
		writeu32(ch.pixels, (ly * ch.w + lx) * 4, self:_pixel(tile))
		if lx < ch.minX then
			ch.minX = lx
		end
		if lx > ch.maxX then
			ch.maxX = lx
		end
		if ly < ch.minY then
			ch.minY = ly
		end
		if ly > ch.maxY then
			ch.maxY = ly
		end
	end
	table.clear(self.dirty)
	table.clear(list)

	for _, ch in self.chunks do
		if ch.maxX < ch.minX then
			continue
		end
		local rw = ch.maxX - ch.minX + 1
		local rh = ch.maxY - ch.minY + 1
		if rw * rh * 2 >= ch.w * ch.h then
			-- Most of the image changed: upload it whole.
			ch.image:WritePixelsBuffer(Vector2.zero, Vector2.new(ch.w, ch.h), ch.pixels)
		else
			local region = buffer.create(rw * rh * 4)
			for row = 0, rh - 1 do
				buffer.copy(region, row * rw * 4, ch.pixels, ((ch.minY + row) * ch.w + ch.minX) * 4, rw * 4)
			end
			ch.image:WritePixelsBuffer(Vector2.new(ch.minX, ch.minY), Vector2.new(rw, rh), region)
		end
		ch.minX, ch.minY, ch.maxX, ch.maxY = math.huge, math.huge, -1, -1
	end
end

return TerritoryRenderer
