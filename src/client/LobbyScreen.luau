-- Pre-match lobby, modelled on upstream SinglePlayerModal / HostLobbyModal:
-- map grid (thumbnails), difficulty, bots, options, unit toggles, player
-- list and Start. Only the host can change settings; everyone sees them live
-- (Net.Lobby). Disappears when the server starts the match.

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MapCatalog = require(Shared:WaitForChild("Data"):WaitForChild("MapCatalog"))
local Format = require(Shared:WaitForChild("Format"))
local Icons = require(script.Parent.Icons)
local Style = require(script.Parent.Style)
local Lang = require(script.Parent.Lang)

local C, F = Style.color, Style.font

local DIFFICULTIES = { "Easy", "Medium", "Hard", "Impossible" }
local STARTING_GOLD = { 0, 1000000, 5000000, 25000000 }
local GOLD_MULTIPLIER = { 1, 2, 5 }
local UNITS = {
	{ unit = "City", icon = "city" },
	{ unit = "Factory", icon = "factory" },
	{ unit = "Port", icon = "port" },
	{ unit = "Defense Post", icon = "defensePost" },
	{ unit = "Missile Silo", icon = "missileSilo" },
	{ unit = "SAM Launcher", icon = "samLauncher" },
	{ unit = "Warship", icon = "warship" },
	{ unit = "Atom Bomb", icon = "atomBomb" },
	{ unit = "Hydrogen Bomb", icon = "hydrogenBomb" },
	{ unit = "MIRV", icon = "mirv" },
}
local NOT_PORTED: { [string]: boolean } = {} -- units shown as "(soon)"

local thumbCache = {}
local function thumbImage(entry)
	if thumbCache[entry.id] ~= nil then
		return thumbCache[entry.id]
	end
	local t = entry.thumb
	if not t then
		thumbCache[entry.id] = false
		return false
	end
	local z = EncodingService:Base64Decode(buffer.fromstring(t.data))
	local rgb = EncodingService:DecompressBuffer(z, Enum.CompressionAlgorithm.Zstd)
	local px = buffer.create(t.w * t.h * 4)
	for i = 0, t.w * t.h - 1 do
		buffer.writeu8(px, i * 4, buffer.readu8(rgb, i * 3))
		buffer.writeu8(px, i * 4 + 1, buffer.readu8(rgb, i * 3 + 1))
		buffer.writeu8(px, i * 4 + 2, buffer.readu8(rgb, i * 3 + 2))
		buffer.writeu8(px, i * 4 + 3, 255)
	end
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(t.w, t.h) })
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(t.w, t.h), px)
	thumbCache[entry.id] = img
	return img
end

local LobbyScreen = {}
LobbyScreen.__index = LobbyScreen

function LobbyScreen.new(gui: ScreenGui, net)
	local self = setmetatable({ net = net, state = nil, controls = {}, myVote = {} }, LobbyScreen)

	local shade = Style.frame(gui, "Lobby", Color3.new(0, 0, 0), 0.55)
	shade.Size = UDim2.fromScale(1, 1)
	shade.ZIndex = 80
	shade.Active = true
	shade.Visible = false
	self.shade = shade

	local modal = Style.frame(shade, "Modal", C.gray900, 1)
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.Position = UDim2.fromScale(0.5, 0.52)
	modal.Size = UDim2.new(1, -32, 1, -90)
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(980, 680)
	maxSize.Parent = modal
	Style.corner(modal, 12)
	Style.stroke(modal, C.gray700)
	modal.ZIndex = 81

	local title = Style.text(modal, "Title", "Game Settings", 22, F.bold)
	title.Position = UDim2.fromOffset(20, 14)
	title.ZIndex = 82
	self.title = title
	local sub = Style.text(modal, "Host", "", 14, F.medium, C.gray400)
	sub.Position = UDim2.fromOffset(20, 42)
	sub.ZIndex = 82
	self.hostLabel = sub

	-- Matchmaking actions, top right: public lobbies offer a private match and
	-- joining one by code; private matches show their code and invite friends.
	local actions = Style.frame(modal, "Actions")
	actions.AnchorPoint = Vector2.new(1, 0)
	actions.Position = UDim2.new(1, -16, 0, 14)
	actions.Size = UDim2.fromOffset(0, 32)
	actions.AutomaticSize = Enum.AutomaticSize.X
	actions.ZIndex = 82
	local al = Style.row(actions, 8)
	al.HorizontalAlignment = Enum.HorizontalAlignment.Right
	local function actionButton(name: string, text: string, order: number, onClick)
		local b = Style.button(actions, name, text, 14, F.semibold)
		b.AutomaticSize = Enum.AutomaticSize.X
		b.Size = UDim2.fromOffset(0, 32)
		b.BackgroundColor3 = C.gray700
		b.BackgroundTransparency = 0
		b.LayoutOrder = order
		b.ZIndex = 83
		Style.corner(b, 8)
		Style.padding(b, 12, 0)
		b.Activated:Connect(onClick)
		return b
	end
	local codeBox = Instance.new("TextBox")
	codeBox.Name = "CodeBox"
	codeBox.PlaceholderText = "Code"
	codeBox.Text = ""
	codeBox.ClearTextOnFocus = false
	codeBox.FontFace = F.semibold
	codeBox.TextSize = 14
	codeBox.TextColor3 = Color3.new(1, 1, 1)
	codeBox.BackgroundColor3 = C.gray800
	codeBox.Size = UDim2.fromOffset(90, 32)
	codeBox.LayoutOrder = 1
	codeBox.ZIndex = 83
	codeBox.Parent = actions
	Style.corner(codeBox, 8)
	self.codeBox = codeBox
	self.joinButton = actionButton("Join", "Join", 2, function()
		local code = string.upper((string.gsub(codeBox.Text, "%s", "")))
		if #code > 0 then
			net.Intent:FireServer({ type = "join_code", code = code })
			self.notice = "Joining…"
			self:_refresh()
		end
	end)
	self.privateButton = actionButton("Private", "Create private match", 3, function()
		net.Intent:FireServer({ type = "create_private" })
		self.notice = "Creating your private match…"
		self:_refresh()
	end)
	self.shopButton = actionButton("Shop", "Shop", 5, function()
		require(script.Parent.ShopScreen).open(gui, net)
	end)
	self.inviteButton = actionButton("Invite", "Invite friends", 4, function()
		pcall(function()
			game:GetService("SocialService"):PromptGameInvite(Players.LocalPlayer)
		end)
	end)
	net.Event.OnClientEvent:Connect(function(evt)
		if evt.type == "JoinCodeFailed" then
			self.notice = "No private match with that code."
			self:_refresh()
		end
	end)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Content"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(16, 70)
	scroll.Size = UDim2.new(1, -32, 1, -140)
	scroll.CanvasSize = UDim2.fromScale(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.ZIndex = 82
	scroll.Parent = modal
	Style.column(scroll, 14)
	self.scroll = scroll

	-- Footer: status + Start.
	local status = Style.text(modal, "Status", "", 15, F.medium, C.gray300)
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 20, 1, -22)
	status.ZIndex = 82
	self.status = status
	local start = Style.button(modal, "Start", "Start Game", 18, F.bold)
	start.AnchorPoint = Vector2.new(1, 1)
	start.Position = UDim2.new(1, -20, 1, -14)
	start.AutomaticSize = Enum.AutomaticSize.None
	start.Size = UDim2.fromOffset(180, 44)
	start.BackgroundColor3 = C.malibuBlue
	start.BackgroundTransparency = 0
	start.ZIndex = 83
	Style.corner(start, 8)
	start.Activated:Connect(function()
		if self:isHost() then
			self.net.Intent:FireServer({ type = "lobby_start" })
		end
	end)
	self.startButton = start

	-- Credits footer (AGPL section 7(b): the copyright notice stays visible).
	local GameInfo = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GameInfo"))
	local credits = Style.text(shade, "Credits", `{GameInfo.COPYRIGHT} · {GameInfo.LICENSE} · Source: {GameInfo.SOURCE_URL}`, 11, F.medium, C.gray400)
	credits.AnchorPoint = Vector2.new(0.5, 1)
	credits.Position = UDim2.new(0.5, 0, 1, -4)
	credits.ZIndex = 82
	credits.TextWrapped = true
	credits.AutomaticSize = Enum.AutomaticSize.Y
	credits.Size = UDim2.new(1, -20, 0, 0)
	credits.TextXAlignment = Enum.TextXAlignment.Center

	self:_build()
	net.Lobby.OnClientEvent:Connect(function(st)
		if st.starting then
			self.shade.Visible = false
			return
		end
		self.state = st
		self.shade.Visible = true
		self:_refresh()
	end)
	return self
end

function LobbyScreen:isHost(): boolean
	return self.state ~= nil and self.state.hostUserId == Players.LocalPlayer.UserId
end

function LobbyScreen:destroy()
	self.shade:Destroy()
end

function LobbyScreen:_set(key: string, value)
	if self.state and self.state.mode == "public" then
		-- Public lobby: a click is a vote (again on the same option withdraws it).
		if key == "map" or key == "mode" then
			self.myVote[key] = if self.myVote[key] == value then nil else value
			self.net.Intent:FireServer({ type = "lobby_vote", kind = key, value = value })
			self:_refresh()
		end
	elseif self:isHost() then
		self.net.Intent:FireServer({ type = "lobby_set", key = key, value = value })
	end
end

-- Vote count badge in a card's top-right corner.
local function voteBadge(parent: Instance)
	local b = Style.text(parent, "Votes", "", 12, F.bold, Color3.new(1, 1, 1))
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -4, 0, 4)
	b.BackgroundColor3 = C.malibuBlue
	b.BackgroundTransparency = 0
	b.ZIndex = 86
	b.Visible = false
	Style.corner(b, 8)
	Style.padding(b, 6, 1)
	return b
end
local function paintBadge(b: TextLabel, n: number?, mine: boolean)
	b.Visible = (n or 0) > 0
	b.Text = tostring(n or 0)
	b.BackgroundColor3 = if mine then Color3.fromRGB(34, 197, 94) else C.malibuBlue
end

-- Sections ------------------------------------------------------------------------

function LobbyScreen:_section(title: string, order: number): Frame
	local sec = Style.frame(self.scroll, title, nil)
	sec.LayoutOrder = order
	sec.Size = UDim2.new(1, -8, 0, 0)
	sec.AutomaticSize = Enum.AutomaticSize.Y
	Style.column(sec, 8)
	local h = Style.text(sec, "Header", title, 16, F.bold, C.gray200)
	h.LayoutOrder = 0
	h.ZIndex = 83
	return sec
end

-- Game modes: FFA, a fixed team count, team size, or humans vs nations.
local MODES = {
	{ label = "Free for all", value = "ffa" },
	{ label = "2 teams", value = 2 },
	{ label = "3 teams", value = 3 },
	{ label = "4 teams", value = 4 },
	{ label = "5 teams", value = 5 },
	{ label = "6 teams", value = 6 },
	{ label = "7 teams", value = 7 },
	{ label = "Duos", value = "Duos" },
	{ label = "Trios", value = "Trios" },
	{ label = "Quads", value = "Quads" },
	{ label = "Humans vs Nations", value = "Humans Vs Nations" },
}

local function chip(parent: Instance, text: string, order: number, onClick: () -> ())
	local b = Style.button(parent, text, text, 14, F.semibold)
	b.LayoutOrder = order
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.fromOffset(0, 34)
	b.BackgroundColor3 = C.gray800
	b.BackgroundTransparency = 0
	b.ZIndex = 83
	Style.corner(b, 8)
	Style.padding(b, 14, 0)
	local stroke = Style.stroke(b, C.gray600)
	b.Activated:Connect(onClick)
	return b, stroke
end

local function wrapRow(parent: Instance, name: string, order: number): Frame
	local row = Style.frame(parent, name, nil)
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.Wraps = true
	l.Padding = UDim.new(0, 8)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = row
	return row
end

function LobbyScreen:_build()
	local controls = self.controls

	-- Map grid.
	local maps = self:_section("Map", 1)
	local grid = wrapRow(maps, "Grid", 1)
	local sorted = table.clone(MapCatalog)
	table.sort(sorted, function(a, b)
		if a.frequency ~= b.frequency then
			return a.frequency > b.frequency
		end
		return a.name < b.name
	end)
	controls.maps = {}
	controls.mapVotes = {}
	for i, entry in sorted do
		local card = Instance.new("TextButton")
		card.Name = entry.id
		card.Text = ""
		card.AutoButtonColor = false
		card.LayoutOrder = i
		card.Size = UDim2.fromOffset(112, 88)
		card.BackgroundColor3 = C.gray800
		card.BorderSizePixel = 0
		card.ZIndex = 83
		Style.corner(card, 8)
		local stroke = Style.stroke(card, C.gray700, 2)
		local img = thumbImage(entry)
		if img then
			local th = Instance.new("ImageLabel")
			th.BackgroundTransparency = 1
			th.Position = UDim2.fromOffset(8, 6)
			th.Size = UDim2.new(1, -16, 0, 54)
			th.ScaleType = Enum.ScaleType.Fit
			th.ImageContent = Content.fromObject(img)
			th.ZIndex = 84
			th.Parent = card
		end
		local name = Style.text(card, "Name", entry.name, 12, F.semibold, C.gray200)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Position = UDim2.fromOffset(4, 62)
		name.Size = UDim2.new(1, -8, 0, 22)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 84
		card.Parent = grid
		card.Activated:Connect(function()
			self:_set("map", entry.id)
		end)
		controls.maps[entry.id] = stroke
		controls.mapVotes[entry.id] = voteBadge(card)
	end

	-- Game mode (upstream GameMode + team count).
	local modeSec = self:_section("Mode", 2)
	local mrow = wrapRow(modeSec, "Row", 1)
	controls.mode = {}
	controls.modeVotes = {}
	for i, m in MODES do
		local button, stroke = chip(mrow, m.label, i, function()
			self:_set("mode", m.value)
		end)
		controls.mode[tostring(m.value)] = stroke
		controls.modeVotes[tostring(m.value)] = voteBadge(button)
	end

	-- Difficulty.
	local diff = self:_section("Difficulty", 3)
	local drow = wrapRow(diff, "Row", 1)
	controls.difficulty = {}
	for i, d in DIFFICULTIES do
		local _, stroke = chip(drow, d, i, function()
			self:_set("difficulty", d)
		end)
		controls.difficulty[d] = stroke
	end
	local note = Style.text(diff, "Note", "Difficulty sets how strong the nations are.", 12, F.medium, C.gray400)
	note.LayoutOrder = 2
	note.ZIndex = 83

	-- Bots and nations sliders (0..400, like upstream; 0 = disabled).
	controls.sliders = {}
	self.pending = {}
	self:_slider("bots", self:_section("Bots", 4), 10)
	self:_slider("nations", self:_section("Nations", 5), 1)

	-- Options.
	local opts = self:_section("Options", 6)
	local orow = wrapRow(opts, "Row", 1)
	controls.toggles = {}
	for i, spec in {
		{ key = "randomSpawn", label = "Random spawn" },
		{ key = "instantBuild", label = "Instant build" },
		{ key = "infiniteGold", label = "Infinite gold" },
		{ key = "infiniteTroops", label = "Infinite troops" },
	} do
		local b, stroke = chip(orow, spec.label, i, function()
			if not spec.locked and self.state then
				self:_set(spec.key, not self.state.settings[spec.key])
			end
		end)
		controls.toggles[spec.key] = { button = b, stroke = stroke, locked = spec.locked }
	end

	local gold = self:_section("Starting gold", 7)
	local grow = wrapRow(gold, "Row", 1)
	controls.startingGold = {}
	for i, v in STARTING_GOLD do
		local _, stroke = chip(grow, if v == 0 then "None" else Format.renderNumber(v), i, function()
			self:_set("startingGold", v)
		end)
		controls.startingGold[v] = stroke
	end

	local mult = self:_section("Gold multiplier", 8)
	local mrow = wrapRow(mult, "Row", 1)
	controls.goldMultiplier = {}
	for i, v in GOLD_MULTIPLIER do
		local _, stroke = chip(mrow, `x{v}`, i, function()
			self:_set("goldMultiplier", v)
		end)
		controls.goldMultiplier[v] = stroke
	end

	-- Units.
	local units = self:_section("Enabled units", 9)
	local urow = wrapRow(units, "Row", 1)
	controls.units = {}
	for i, def in UNITS do
		local b = Instance.new("TextButton")
		b.Name = def.unit
		b.Text = ""
		b.AutoButtonColor = false
		b.LayoutOrder = i
		b.Size = UDim2.fromOffset(150, 36)
		b.BackgroundColor3 = C.gray800
		b.BorderSizePixel = 0
		b.ZIndex = 83
		Style.corner(b, 8)
		local stroke = Style.stroke(b, C.gray600)
		local icon = Icons.label(b, def.icon, 20, { white = true })
		icon.Position = UDim2.fromOffset(8, 8)
		icon.ZIndex = 84
		local label = Style.text(b, "Label", def.unit, 13, F.semibold, C.gray200)
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.Position = UDim2.new(0, 34, 0.5, 0)
		label.ZIndex = 84
		b.Parent = urow
		b.Activated:Connect(function()
			if self.state and not NOT_PORTED[def.unit] then
				local disabled = table.find(self.state.settings.disabledUnits, def.unit) ~= nil
				self:_set("unit", { def.unit, disabled })
			end
		end)
		controls.units[def.unit] = { button = b, stroke = stroke, icon = icon, label = label }
	end

	-- Players.
	local ps = self:_section("Players", 10)
	local plist = Style.text(ps, "List", "", 14, F.medium, C.gray300)
	plist.LayoutOrder = 1
	plist.ZIndex = 83
	plist.TextWrapped = true
	plist.AutomaticSize = Enum.AutomaticSize.Y
	plist.Size = UDim2.new(1, 0, 0, 0)
	plist.TextXAlignment = Enum.TextXAlignment.Left
	controls.players = plist
end

local SLIDER_MAX = 400

-- A 0..SLIDER_MAX slider row for setting `key`, snapped to `step`.
function LobbyScreen:_slider(key: string, section: Frame, step: number)
	local row = Style.frame(section, "Row", nil)
	row.LayoutOrder = 1
	row.Size = UDim2.new(1, 0, 0, 30)
	local label = Style.text(row, "Value", "0", 15, F.bold)
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0, 0.5)
	label.ZIndex = 83
	local track = Style.frame(row, "Track", C.gray700, 1)
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 80, 0.5, 0)
	track.Size = UDim2.new(1, -90, 0, 6)
	track.Active = true
	track.ZIndex = 83
	Style.corner(track, 3)
	local fill = Style.frame(track, "Fill", C.aquarius, 1)
	fill.ZIndex = 84
	Style.corner(fill, 3)
	local knob = Style.frame(track, "Knob", C.aquarius, 1)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(16, 16)
	knob.ZIndex = 85
	Style.corner(knob, 8)
	self.controls.sliders[key] = { label = label, fill = fill, knob = knob }

	local dragging = false
	local UIS = game:GetService("UserInputService")
	local function setFromX(x)
		local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		local v = math.floor(rel * SLIDER_MAX / step + 0.5) * step
		self.pending[key] = v
		self:_paintSlider(key, v)
	end
	track.InputBegan:Connect(function(input)
		if self:isHost() and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UIS.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if self.pending[key] then
				self:_set(key, self.pending[key])
			end
		end
	end)
end

function LobbyScreen:_paintSlider(key: string, v: number)
	local c = self.controls.sliders[key]
	c.label.Text = if v == 0 then "Disabled" else tostring(v)
	c.fill.Size = UDim2.fromScale(v / SLIDER_MAX, 1)
	c.knob.Position = UDim2.fromScale(v / SLIDER_MAX, 0.5)
end

local function mark(stroke: UIStroke, on: boolean)
	stroke.Color = if on then C.aquarius else C.gray600
	stroke.Thickness = if on then 2 else 1
end

function LobbyScreen:_refresh()
	local st = self.state
	if not st then
		return
	end
	local s, c = st.settings, self.controls
	local host = self:isHost()
	for id, stroke in c.maps do
		mark(stroke, id == s.map)
	end
	for v, stroke in c.mode do
		mark(stroke, v == tostring(s.mode or "ffa"))
	end
	local votes = st.votes or { map = {}, mode = {} }
	for id, b in c.mapVotes do
		paintBadge(b, votes.map[id], self.myVote.map == id)
	end
	for v, b in c.modeVotes do
		paintBadge(b, votes.mode[v], self.myVote.mode ~= nil and tostring(self.myVote.mode) == v)
	end
	for d, stroke in c.difficulty do
		mark(stroke, d == s.difficulty)
	end
	for key in c.sliders do
		self.pending[key] = nil
		self:_paintSlider(key, s[key])
	end
	for key, t in c.toggles do
		mark(t.stroke, s[key] == true)
		t.button.TextTransparency = if t.locked then 0.5 else 0
	end
	for v, stroke in c.startingGold do
		mark(stroke, v == s.startingGold)
	end
	for v, stroke in c.goldMultiplier do
		mark(stroke, v == s.goldMultiplier)
	end
	for unit, u in c.units do
		local enabled = table.find(s.disabledUnits, unit) == nil
		mark(u.stroke, enabled)
		u.icon.ImageTransparency = if enabled then 0 else 0.6
		u.label.TextTransparency = if enabled then 0 else 0.5
		u.label.Text = if NOT_PORTED[unit] then Lang.t("{unit} (soon)", { unit = Lang.t(unit) }) else unit
	end
	c.players.Text = table.concat(st.players or {}, ", ")
	local hostName = "?"
	local hp = st.hostUserId and Players:GetPlayerByUserId(st.hostUserId)
	if hp then
		hostName = hp.DisplayName
	end
	local public = st.mode == "public"
	self.title.Text = if public then "Next match" else "Game Settings"
	if public then
		local name = s.map
		for _, m in MapCatalog do
			if m.id == s.map then
				name = m.name
			end
		end
		self.hostLabel.Text = Lang.t("Vote for the map and mode by clicking them — the most votes win. Leading: {map}.", { map = Lang.t(name) })
	elseif st.joinCode then
		self.hostLabel.Text = (if host then Lang.t("You are the host. ") else Lang.t("Host: {hostName}. ", { hostName = hostName })) .. Lang.t("Friends join with code {code}.", { code = st.joinCode })
	else
		self.hostLabel.Text = if host then "You are the host — choose the settings and start the game." else Lang.t("Host: {hostName} — waiting for the host to start.", { hostName = hostName })
	end
	self.startButton.Visible = host
	local status = if st.secondsLeft then Lang.t("Starting in {seconds} s", { seconds = st.secondsLeft }) else (if host then "" else "Waiting for the host…")
	self.status.Text = if self.notice then self.notice .. "   " .. status else status
	local mm = st.canMatchmake == true
	self.codeBox.Visible = mm and public
	self.joinButton.Visible = mm and public
	self.privateButton.Visible = mm and public
	self.inviteButton.Visible = not public
end

return LobbyScreen
