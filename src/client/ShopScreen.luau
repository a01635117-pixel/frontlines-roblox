-- Cosmetics shop (Roblox monetisation; upstream's store sells its own
-- proprietary skins). Sections: subscription, daily deal, free trial for a
-- rewarded ad, passes (supporter, custom colour, host, flag), bundles, then
-- the items by kind. Everything is cosmetic or a lobby convenience.

local AdService = game:GetService("AdService")
local AssetService = game:GetService("AssetService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Shop = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)
local Lang = require(script.Parent.Lang)
local FlagAtlas = require(script.Parent.FlagAtlas)

local F = Style.font
local Z = Modal.zinc
local ACCENT = Color3.fromHex("#4f46e5")
local GOLD = Color3.fromRGB(255, 214, 90)
local GREEN = Color3.fromRGB(34, 197, 94)

local ShopScreen = {}

-- 48x48 swatch of a pattern in a sample blue (primary) / dark blue (secondary).
local swatchCache = {}
local function patternSwatch(item)
	local img = swatchCache[item.id]
	if img then
		return img
	end
	local size = 48
	img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	local px = buffer.create(size * size * 4)
	local cell = 3
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local cx, cy = (x // cell) % #item.rows[1], (y // cell) % #item.rows
			local secondary = string.sub(item.rows[cy + 1], cx + 1, cx + 1) == "#"
			local o = (y * size + x) * 4
			buffer.writeu8(px, o, if secondary then 30 else 96)
			buffer.writeu8(px, o + 1, if secondary then 64 else 165)
			buffer.writeu8(px, o + 2, if secondary then 175 else 250)
			buffer.writeu8(px, o + 3, 255)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), px)
	swatchCache[item.id] = img
	return img
end

local function rgb(c): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function hours(seconds: number): string
	return `{math.max(1, math.ceil(seconds / 3600))} h`
end

function ShopScreen.open(gui: Instance, net)
	local _, card, close = Modal.open(gui, "Shop", 600, 110)
	local title = Style.text(card, "Title", "Shop — cosmetics only, no pay-to-win", 18, F.bold, Z.z50)
	title.LayoutOrder = 1
	title.ZIndex = card.ZIndex + 1
	local status = Style.text(card, "Status", "Loading…", 13, F.medium, Z.z400)
	status.LayoutOrder = 2
	status.ZIndex = card.ZIndex + 1

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Items"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.LayoutOrder = 3
	scroll.Size = UDim2.new(1, 0, 0, math.min(420, gui.AbsoluteSize.Y - 150))
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.ScrollBarThickness = 4
	scroll.ZIndex = card.ZIndex + 1
	scroll.Parent = card
	local list = Style.column(scroll, 12)
	list.SortOrder = Enum.SortOrder.LayoutOrder

	local closed = false
	local render
	local adReady = false

	local function refresh(delay: number?)
		task.delay(delay or 0.3, function()
			if not closed then
				local ok, st = pcall(function()
					return net.Query:InvokeServer({ kind = "shop" })
				end)
				if ok and st and not closed then
					render(st)
				end
			end
		end)
	end
	local function equip(slot: string, value)
		net.Intent:FireServer({ type = "equip", slot = slot, value = value })
		refresh()
	end

	local function section(name: string, order: number, height: number)
		local sec = Style.frame(scroll, name, nil)
		sec.LayoutOrder = order
		sec.Size = UDim2.new(1, -8, 0, 0)
		sec.AutomaticSize = Enum.AutomaticSize.Y
		sec.ZIndex = scroll.ZIndex
		Style.column(sec, 6)
		local h = Style.text(sec, "Header", name, 15, F.bold, Z.z200)
		h.LayoutOrder = 0
		h.ZIndex = scroll.ZIndex + 1
		local grid = Style.frame(sec, "Grid", nil)
		grid.LayoutOrder = 1
		grid.Size = UDim2.new(1, 0, 0, 0)
		grid.AutomaticSize = Enum.AutomaticSize.Y
		grid.ZIndex = scroll.ZIndex
		local g = Instance.new("UIGridLayout")
		g.CellPadding = UDim2.fromOffset(8, 8)
		g.CellSize = UDim2.new(0.25, -8, 0, height)
		g.SortOrder = Enum.SortOrder.LayoutOrder
		g.Parent = grid
		return grid, g
	end
	local function tile(parent: Instance, order: number, highlight: Color3?)
		local f = Style.frame(parent, "Item", Z.z800, 1)
		f.LayoutOrder = order
		f.ZIndex = scroll.ZIndex + 1
		Style.corner(f, 10)
		if highlight then
			Style.stroke(f, highlight, 2)
		end
		return f
	end
	local function label(parent: Instance, text: string, y: number, size: number, color: Color3, font: Font?)
		local t = Style.text(parent, "Label", text, size, font or F.semibold, color)
		t.AnchorPoint = Vector2.new(0.5, 0)
		t.Position = UDim2.new(0.5, 0, 0, y)
		t.Size = UDim2.new(1, -12, 0, 0)
		t.AutomaticSize = Enum.AutomaticSize.Y
		t.TextWrapped = true
		t.ZIndex = parent.ZIndex + 1
		return t
	end
	local function button(parent, text: string, enabled: boolean, onClick, color: Color3?)
		local b = Style.button(parent, "Buy", text, 13, F.semibold)
		b.AutomaticSize = Enum.AutomaticSize.None
		b.AnchorPoint = Vector2.new(0.5, 1)
		b.Position = UDim2.new(0.5, 0, 1, -8)
		b.Size = UDim2.new(1, -16, 0, 28)
		b.BackgroundColor3 = if enabled then (color or ACCENT) else Z.z700
		b.BackgroundTransparency = 0
		b.TextTransparency = if enabled then 0 else 0.4
		b.ZIndex = parent.ZIndex + 2
		Style.corner(b, 6)
		if enabled then
			b.Activated:Connect(onClick)
		end
		return b
	end
	local function preview(parent, item)
		if item.kind == "pattern" then
			local img = Instance.new("ImageLabel")
			img.BackgroundTransparency = 1
			img.Size = UDim2.fromOffset(44, 44)
			img.AnchorPoint = Vector2.new(0.5, 0)
			img.Position = UDim2.new(0.5, 0, 0, 10)
			img.ImageContent = Content.fromObject(patternSwatch(item))
			img.ZIndex = parent.ZIndex + 1
			img.Parent = parent
			Style.corner(img, 6)
		elseif item.kind == "explosion" then
			local ring = Style.frame(parent, "Blast", rgb(item.flash), 0.1)
			ring.AnchorPoint = Vector2.new(0.5, 0)
			ring.Position = UDim2.new(0.5, 0, 0, 10)
			ring.Size = UDim2.fromOffset(44, 44)
			ring.ZIndex = parent.ZIndex + 1
			Style.corner(ring, 22)
			Style.stroke(ring, rgb(item.ring), 4)
		else
			label(parent, Players.LocalPlayer.DisplayName, 20, 16, rgb(item.color), F.bold)
		end
	end
	local function productButton(parent, productId: number, price: number)
		if productId ~= 0 then
			return button(parent, `R$ {price}`, true, function()
				MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
			end)
		end
		return button(parent, Lang.t("Soon"), false)
	end
	local function passButton(parent, pass)
		if pass.id ~= 0 then
			return button(parent, `R$ {pass.price}`, true, function()
				MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, pass.id)
			end)
		end
		return button(parent, Lang.t("Soon"), false)
	end

	-- Pickers (custom colour, flag) ---------------------------------------------------
	local function picker(titleText: string, cells: number, build: (Frame, () -> ()) -> ())
		local _, pcard, pclose = Modal.open(gui, "Picker", 520, 130)
		local t = Style.text(pcard, "Title", titleText, 17, F.bold, Z.z50)
		t.LayoutOrder = 1
		t.ZIndex = pcard.ZIndex + 1
		local s = Instance.new("ScrollingFrame")
		s.BackgroundTransparency = 1
		s.BorderSizePixel = 0
		s.LayoutOrder = 2
		s.Size = UDim2.new(1, 0, 0, math.min(360, gui.AbsoluteSize.Y - 160))
		s.AutomaticCanvasSize = Enum.AutomaticSize.Y
		s.CanvasSize = UDim2.fromOffset(0, 0)
		s.ScrollBarThickness = 4
		s.ZIndex = pcard.ZIndex + 1
		s.Parent = pcard
		local g = Instance.new("UIGridLayout")
		g.CellPadding = UDim2.fromOffset(6, 6)
		g.CellSize = UDim2.fromOffset(cells, math.floor(cells * 0.72))
		g.SortOrder = Enum.SortOrder.LayoutOrder
		g.Parent = s
		build(s, pclose)
	end
	local function colorPicker(current: number?)
		picker(Lang.t("Pick your territory colour"), 52, function(s, pclose)
			for i, c in Shop.COLORS do
				local b = Instance.new("TextButton")
				b.Text = ""
				b.AutoButtonColor = true
				b.BackgroundColor3 = rgb(c)
				b.LayoutOrder = i
				b.ZIndex = s.ZIndex + 1
				b.Parent = s
				Style.corner(b, 6)
				Style.stroke(b, if i == current then Color3.new(1, 1, 1) else Z.z700, if i == current then 3 else 1)
				b.Activated:Connect(function()
					equip("color", i)
					pclose()
				end)
			end
		end)
	end
	local function flagPicker(current: string?)
		picker(Lang.t("Pick your flag"), 44, function(s, pclose)
			for i, code in FlagAtlas.codes do
				local b = Instance.new("ImageButton")
				b.BackgroundColor3 = Z.z800
				b.LayoutOrder = i
				b.ZIndex = s.ZIndex + 1
				b.Parent = s
				FlagAtlas.apply(b :: any, code)
				Style.stroke(b, if code == current then Color3.new(1, 1, 1) else Z.z700, if code == current then 3 else 1)
				b.Activated:Connect(function()
					equip("flag", code)
					pclose()
				end)
			end
		end)
	end

	-- Render ---------------------------------------------------------------------------
	function render(state)
		for _, c in scroll:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local perks = state.perks or {}
		local trials = state.trials or {}
		status.Text = if state.loaded then "Bought items are saved to your account and apply from the next match." else "Your profile is still loading…"
		local order = 0
		local function nextOrder()
			order += 1
			return order
		end

		-- Subscription.
		if Shop.SUBSCRIPTION_ID ~= "" then
			local grid, g = section(Lang.t("Frontlines Plus"), nextOrder(), 96)
			g.CellSize = UDim2.new(1, -8, 0, 96)
			local f = tile(grid, 1, GOLD)
			local d = label(f, Lang.t("Every cosmetic, custom colour, flags and Host Pass perks while subscribed."), 10, 14, Z.z100)
			d.Size = UDim2.new(1, -200, 0, 0)
			d.AnchorPoint = Vector2.new(0, 0)
			d.Position = UDim2.fromOffset(12, 12)
			d.TextXAlignment = Enum.TextXAlignment.Left
			local b
			if perks.plus then
				b = button(f, Lang.t("Active"), false)
			else
				b = button(f, Lang.t("Subscribe {price}/month", { price = Shop.SUBSCRIPTION_PRICE }), true, function()
					MarketplaceService:PromptSubscriptionPurchase(Players.LocalPlayer, Shop.SUBSCRIPTION_ID)
				end, Color3.fromRGB(202, 138, 4))
			end
			b.AnchorPoint = Vector2.new(1, 0.5)
			b.Position = UDim2.new(1, -12, 0.5, 0)
			b.Size = UDim2.fromOffset(180, 34)
		end

		-- Daily deal + free trial.
		local specials, _ = section(Lang.t("Specials"), nextOrder(), 150)
		local deal = state.daily and Shop.byId[state.daily]
		if deal and Shop.DAILY_DEAL.productId ~= 0 then
			local f = tile(specials, 1, GOLD)
			preview(f, deal)
			label(f, Lang.t("Deal of the day"), 58, 12, GOLD, F.bold)
			label(f, `{Lang.t(deal.name)} · R$ {deal.price}`, 74, 12, Z.z300)
			label(f, Lang.t("{hours} left", { hours = hours(state.dailySecondsLeft or 0) }), 90, 11, Z.z400)
			productButton(f, Shop.DAILY_DEAL.productId, Shop.DAILY_DEAL.price)
		end
		if Shop.AD_REWARD.productId ~= 0 and adReady then
			local f = tile(specials, 2, GREEN)
			label(f, Lang.t("Free trial"), 10, 14, GREEN, F.bold)
			label(f, Lang.t("Watch a short ad and try a random cosmetic for 24 h."), 32, 12, Z.z300)
			local b = button(f, Lang.t("Watch ad"), true, function()
				adReady = false
				net.Intent:FireServer({ type = "watch_ad" })
				refresh(8)
			end, GREEN)
			pcall(function()
				AdService:RegisterAdOpportunityAsync(b)
			end)
		end

		-- Passes.
		local passGrid = section(Lang.t("Passes"), nextOrder(), 150)
		local passOrder = { "supporter", "color", "host", "flag" }
		for i, key in passOrder do
			local pass = Shop.PASSES[key]
			local f = tile(passGrid, i, if key == "supporter" then GOLD else nil)
			label(f, Lang.t(pass.name), 10, 15, if key == "supporter" then GOLD else Z.z50, F.bold)
			label(f, Lang.t(pass.desc), 34, 12, Z.z300)
			local has = perks[key]
			if has and key == "color" then
				local cur = state.equipped and state.equipped.color
				if cur and Shop.COLORS[cur] then
					local sw = Style.frame(f, "Current", rgb(Shop.COLORS[cur]), 0)
					sw.AnchorPoint = Vector2.new(0.5, 1)
					sw.Position = UDim2.new(0.5, 0, 1, -42)
					sw.Size = UDim2.fromOffset(36, 14)
					sw.ZIndex = f.ZIndex + 1
					Style.corner(sw, 4)
				end
				button(f, Lang.t("Pick colour"), true, function()
					colorPicker(cur)
				end, GREEN)
			elseif has and key == "flag" then
				local cur = state.equipped and state.equipped.flag
				button(f, Lang.t("Pick flag"), true, function()
					flagPicker(cur)
				end, GREEN)
			elseif has then
				button(f, Lang.t("Active"), false)
			else
				passButton(f, pass)
			end
		end

		-- Bundles.
		local bundleGrid = section(Lang.t("Bundles"), nextOrder(), 130)
		for i, b in Shop.bundles do
			local f = tile(bundleGrid, i, ACCENT)
			label(f, Lang.t(b.name), 10, 15, Z.z50, F.bold)
			local count, worth = 0, 0
			for _, it in Shop.items do
				if b.kinds[it.kind] then
					count += 1
					worth += it.price
				end
			end
			label(f, Lang.t("{count} items (worth R$ {worth})", { count = count, worth = worth }), 34, 12, Z.z300)
			productButton(f, b.productId, b.price)
		end

		-- Items by kind.
		for _, kind in { { "pattern", "Patterns" }, { "nameColor", "Name colours" }, { "explosion", "Nuke blasts" } } do
			local grid = section(Lang.t(kind[2]), nextOrder(), 128)
			local i = 0
			for _, item in Shop.items do
				if item.kind ~= kind[1] then
					continue
				end
				i += 1
				local f = tile(grid, i)
				preview(f, item)
				local name = label(f, Lang.t(item.name), 62, 13, Z.z100)
				local slot = Shop.SLOTS[item.kind]
				local owned = state.owned[item.id] or perks.plus
				local trial = trials[item.id]
				if trial and not owned then
					name.Text = `{Lang.t(item.name)} · {Lang.t("trial")} {hours(trial)}`
				end
				if owned or trial then
					local equipped = state.equipped[slot] == item.id
					button(f, if equipped then Lang.t("Equipped") else Lang.t("Equip"), true, function()
						equip(slot, if equipped then nil else item.id)
					end)
				else
					productButton(f, item.productId, item.price)
				end
			end
		end
	end

	local conns = {
		MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, _, purchased)
			if purchased then
				refresh(2) -- the server grants it in ProcessReceipt
			end
		end),
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_, _, purchased)
			if purchased then
				refresh(1)
			end
		end),
	}
	pcall(function()
		table.insert(conns, MarketplaceService.PromptSubscriptionPurchaseFinished:Connect(function()
			refresh(2)
		end))
	end)
	card.Destroying:Connect(function()
		closed = true
		for _, c in conns do
			c:Disconnect()
		end
	end)
	refresh(0)
	if Shop.AD_REWARD.productId ~= 0 then
		task.spawn(function()
			-- Ask for an ad only when the shop opens (AdService guidance).
			local ok, result = pcall(function()
				return AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
			end)
			if ok and result and result.AdAvailabilityResult == Enum.AdAvailabilityResult.IsAvailable then
				adReady = true
				refresh(0)
			end
		end)
	end
	return close
end

return ShopScreen
