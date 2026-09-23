-- Event feed, ported from upstream hud/layers/EventsDisplay.ts (bottom
-- right, w-96): server messages (DisplayEvent / UnitIncoming) for us.
--   * tier 1 (nukes inbound / detonated, naval invasion, conquests, …):
--     bg-gray-800 panel with a red left border, text-lg
--   * tier 2 (everything else): bg-gray-800/92, text-sm, last 4 only
--   * events expire after 80 ticks; inbound warnings also when the unit is gone
--   * clicking a row focuses the player / unit
-- Colours: getMessageTypeClasses (severityColors).

local Style = require(script.Parent.Style)

local C, F = Style.color, Style.font

-- GameTypes.MessageType values.
local MT = {
	ATTACK_FAILED = 0,
	ATTACK_CANCELLED = 1,
	ATTACK_REQUEST = 2,
	CONQUERED_PLAYER = 3,
	MIRV_INBOUND = 4,
	NUKE_INBOUND = 5,
	NUKE_DETONATED = 6,
	HYDROGEN_BOMB_INBOUND = 7,
	NAVAL_INVASION_INBOUND = 8,
	SAM_MISS = 9,
	SAM_HIT = 10,
	CAPTURED_ENEMY_UNIT = 11,
	UNIT_DESTROYED = 12,
	ALLIANCE_ACCEPTED = 13,
	ALLIANCE_REJECTED = 14,
	ALLIANCE_REQUEST = 15,
	ALLIANCE_BROKEN = 16,
	ALLIANCE_EXPIRED = 17,
	DONATION_SENT = 18,
	DONATION_RECEIVED = 19,
	CHAT = 20,
	RENEW_ALLIANCE = 21,
}

local TIER_1 = {
	[MT.NUKE_INBOUND] = true,
	[MT.HYDROGEN_BOMB_INBOUND] = true,
	[MT.MIRV_INBOUND] = true,
	[MT.NUKE_DETONATED] = true,
	[MT.NAVAL_INVASION_INBOUND] = true,
	[MT.ATTACK_REQUEST] = true,
	[MT.ALLIANCE_ACCEPTED] = true,
	[MT.ALLIANCE_REJECTED] = true,
	[MT.ALLIANCE_BROKEN] = true,
	[MT.RENEW_ALLIANCE] = true,
	[MT.CONQUERED_PLAYER] = true,
	[MT.CHAT] = true,
	[MT.DONATION_RECEIVED] = true,
}

local INBOUND = {
	[MT.NUKE_INBOUND] = true,
	[MT.HYDROGEN_BOMB_INBOUND] = true,
	[MT.MIRV_INBOUND] = true,
	[MT.NAVAL_INVASION_INBOUND] = true,
}

local RED, YELLOW, GREEN, GRAY, BLUE = Color3.fromHex("#f87171"), C.yellow400, C.green400, C.gray200, C.blue400
local function severity(t: number): Color3
	if t == MT.SAM_HIT or t == MT.CAPTURED_ENEMY_UNIT or t == MT.CONQUERED_PLAYER or t == MT.ALLIANCE_ACCEPTED then
		return GREEN
	elseif t == MT.ATTACK_FAILED or t == MT.ALLIANCE_REJECTED or t == MT.ALLIANCE_BROKEN or t == MT.UNIT_DESTROYED or t == MT.NUKE_DETONATED then
		return RED
	elseif t == MT.ATTACK_CANCELLED or t == MT.ATTACK_REQUEST or t == MT.DONATION_SENT or t == MT.DONATION_RECEIVED then
		return BLUE
	elseif INBOUND[t] or t == MT.SAM_MISS or t == MT.ALLIANCE_EXPIRED or t == MT.RENEW_ALLIANCE then
		return YELLOW
	elseif t == MT.CHAT or t == MT.ALLIANCE_REQUEST then
		return GRAY
	end
	return C.white
end

-- en.json "events_display" / "unit_type" (the keys the simulation emits).
local TEXTS = {
	["events_display.atom_bomb_detonated"] = "{name} - atom bomb detonated",
	["events_display.hydrogen_bomb_detonated"] = "{name} - hydrogen bomb detonated",
	["events_display.attack_cancelled_retreat"] = "Attack cancelled, {troops} soldiers killed during retreat",
	["events_display.conquered_no_gold"] = "Conquered {name} (didn't play, no gold awarded)",
	["events_display.missile_intercepted"] = "SAM intercepted {unit}",
	["events_display.no_boats_available"] = "No boats available, max {max}",
	["events_display.received_gold_from_conquest"] = "Conquered {name}, received {gold} gold",
	["events_display.received_gold_from_player"] = "Received {gold} gold from {name}",
	["events_display.received_troops_from_player"] = "Received {troops} troops from {name}",
	["events_display.trade_ship_captured"] = "Your trade ship was captured by {name}",
	["events_display.unit_destroyed"] = "Your {unit} was destroyed",
	["events_display.unit_voluntarily_deleted"] = "Unit voluntarily deleted",
	["events_display.betrayed_you"] = "{name} broke their alliance with you",
}
local UNIT_NAMES = {
	["unit_type.atom_bomb"] = "Atom Bomb",
	["unit_type.boat"] = "Boat",
	["unit_type.city"] = "City",
	["unit_type.defense_post"] = "Defense Post",
	["unit_type.factory"] = "Factory",
	["unit_type.hydrogen_bomb"] = "Hydrogen Bomb",
	["unit_type.mirv"] = "MIRV",
	["unit_type.missile_silo"] = "Missile Silo",
	["unit_type.port"] = "Port",
	["unit_type.sam_launcher"] = "SAM Launcher",
	["unit_type.warship"] = "Warship",
}

local function translate(message: string, params): string
	local text = TEXTS[message] or message
	return (string.gsub(text, "{(%w+)}", function(k)
		local v = params and params[k]
		if type(v) == "string" and UNIT_NAMES[v] then
			return UNIT_NAMES[v]
		end
		return if v ~= nil then tostring(v) else "{" .. k .. "}"
	end))
end

local EventsDisplay = {}
EventsDisplay.__index = EventsDisplay

-- deps: { gui, tickNow() -> number, unitActive(id) -> boolean,
--         playerName(smallID) -> string?, focusPlayer(smallID), focusUnit(id), visible() -> boolean }
function EventsDisplay.new(deps)
	local self = setmetatable({ deps = deps, events = {}, dirty = true }, EventsDisplay)
	local column = Style.frame(deps.gui, "EventsDisplay")
	column.AnchorPoint = Vector2.new(1, 1)
	column.Position = UDim2.new(1, -8, 1, -8)
	column.Size = UDim2.fromOffset(384, 0) -- min-[1200px]:w-96
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.ZIndex = 20
	local layout = Style.column(column, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	self.column = column

	local function panel(name: string, order: number, alpha: number, borderLeft: boolean)
		local p = Style.frame(column, name, C.gray800, alpha)
		p.LayoutOrder = order
		p.Size = UDim2.fromScale(1, 0)
		p.AutomaticSize = Enum.AutomaticSize.Y
		p.Active = true
		p.Visible = false
		Style.corner(p, 8)
		Style.padding(p, if borderLeft then 10 else 6, 2)
		Style.column(p, 0)
		if borderLeft then
			local bar = Style.frame(p, "Border", Color3.fromHex("#ef4444"), 1)
			bar.Size = UDim2.new(0, 4, 1, 0)
			bar.Position = UDim2.fromOffset(-10, 0)
			local ignore = Instance.new("UIFlexItem")
			ignore.Parent = bar
		end
		return p
	end
	self.tier2 = panel("Tier2", 1, 0.92 * 0.9, false)
	self.tier1 = panel("Tier1", 2, 1, true)

	task.spawn(function()
		while column.Parent do
			self:_expire()
			if self.dirty then
				self:_render()
			end
			task.wait(0.1)
		end
	end)
	return self
end

function EventsDisplay:add(evt)
	-- Captured trade-ship gold is the gold pip in the control panel instead.
	if evt.message == "events_display.received_gold_from_captured_ship" then
		return
	end
	local params = evt.params or {}
	if evt.focusPlayerID and params.name ~= nil then
		params = table.clone(params)
		params.name = self.deps.playerName(evt.focusPlayerID) or params.name
	end
	table.insert(self.events, {
		description = if evt.type == "Incoming" then evt.message else translate(evt.message, params),
		type = evt.messageType,
		createdAt = self.deps.tickNow(),
		focusID = evt.focusPlayerID,
		unitID = evt.unitID,
	})
	if #self.events > 30 then
		table.remove(self.events, 1)
	end
	self.dirty = true
end

function EventsDisplay:_expire()
	local now = self.deps.tickNow()
	local keep = {}
	for _, e in self.events do
		local expired = now - e.createdAt >= 80
		local unitGone = INBOUND[e.type] and e.unitID ~= nil and not self.deps.unitActive(e.unitID)
		if not expired and not unitGone then
			table.insert(keep, e)
		end
	end
	if #keep ~= #self.events then
		self.events = keep
		self.dirty = true
	end
end

function EventsDisplay:_row(parent: Frame, e, order: number, big: boolean)
	local b = Style.button(parent, "Row", e.description, if big then 18 else 14, if big then F.medium else F.medium, severity(e.type))
	b.LayoutOrder = order
	b.AutomaticSize = Enum.AutomaticSize.Y
	b.Size = UDim2.fromScale(1, 0)
	b.TextWrapped = true
	b.TextXAlignment = Enum.TextXAlignment.Left
	Style.padding(b, 4, 4)
	b.Activated:Connect(function()
		if e.focusID then
			self.deps.focusPlayer(e.focusID)
		elseif e.unitID then
			self.deps.focusUnit(e.unitID)
		end
	end)
end

function EventsDisplay:_render()
	self.dirty = false
	for _, p in { self.tier1, self.tier2 } do
		for _, c in p:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
	end
	local visible = self.deps.visible()
	local t1, t2 = {}, {}
	for _, e in self.events do
		table.insert(if TIER_1[e.type] then t1 else t2, e)
	end
	while #t2 > 4 do
		table.remove(t2, 1)
	end
	for i, e in t1 do
		self:_row(self.tier1, e, i, true)
	end
	for i, e in t2 do
		self:_row(self.tier2, e, i, false)
	end
	self.tier1.Visible = visible and #t1 > 0
	self.tier2.Visible = visible and #t2 > 0
end

function EventsDisplay:refresh()
	self.dirty = true
end

return EventsDisplay
