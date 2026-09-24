-- Cosmetics shop (Roblox monetisation; upstream's store sells its own
-- proprietary skins). Territory patterns and name colours bought with Robux
-- developer products, plus the supporter game pass. Purely cosmetic.

local AssetService = game:GetService("AssetService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Shop = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)

local F = Style.font
local Z = Modal.zinc
local ACCENT = Color3.fromHex("#4f46e5")

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
	local cell = 3 -- pixels per pattern cell in the preview
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

function ShopScreen.open(gui: Instance, net)
	local _, card, close = Modal.open(gui, "Shop", 560, 110)
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
	scroll.Size = UDim2.new(1, 0, 0, math.min(380, gui.AbsoluteSize.Y - 150))
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.ScrollBarThickness = 4
	scroll.ZIndex = card.ZIndex + 1
	scroll.Parent = card
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.CellSize = UDim2.new(0.25, -8, 0, 128)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll

	local closed = false
	local render

	local function tile(order: number)
		local f = Style.frame(scroll, "Item", Z.z800, 1)
		f.LayoutOrder = order
		f.ZIndex = scroll.ZIndex + 1
		Style.corner(f, 10)
		return f
	end
	local function button(parent, text: string, enabled: boolean, onClick)
		local b = Style.button(parent, "Buy", text, 13, F.semibold)
		b.AutomaticSize = Enum.AutomaticSize.None
		b.AnchorPoint = Vector2.new(0.5, 1)
		b.Position = UDim2.new(0.5, 0, 1, -8)
		b.Size = UDim2.new(1, -16, 0, 28)
		b.BackgroundColor3 = if enabled then ACCENT else Z.z700
		b.BackgroundTransparency = 0
		b.TextTransparency = if enabled then 0 else 0.4
		b.ZIndex = parent.ZIndex + 2
		Style.corner(b, 6)
		if enabled then
			b.Activated:Connect(onClick)
		end
		return b
	end

	function render(state)
		for _, c in scroll:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		status.Text = if state.loaded then "Bought items are saved to your account and apply from the next match." else "Your profile is still loading…"

		-- Supporter pass.
		local sup = tile(0)
		local st = Style.text(sup, "Name", "Supporter", 15, F.bold, Color3.fromRGB(255, 214, 90))
		st.Position = UDim2.fromOffset(10, 10)
		st.ZIndex = sup.ZIndex + 1
		local sd = Style.text(sup, "Desc", "Gold name and a thank-you from us", 12, F.medium, Z.z300)
		sd.Position = UDim2.fromOffset(10, 34)
		sd.Size = UDim2.new(1, -20, 0, 40)
		sd.AutomaticSize = Enum.AutomaticSize.None
		sd.TextWrapped = true
		sd.ZIndex = sup.ZIndex + 1
		if state.supporter then
			button(sup, "Active", false)
		elseif Shop.SUPPORTER_PASS_ID ~= 0 then
			button(sup, `R$ {Shop.SUPPORTER_PRICE}`, true, function()
				MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, Shop.SUPPORTER_PASS_ID)
			end)
		else
			button(sup, "Soon", false)
		end

		for i, item in Shop.items do
			local f = tile(i)
			if item.kind == "pattern" then
				local img = Instance.new("ImageLabel")
				img.BackgroundTransparency = 1
				img.Size = UDim2.fromOffset(48, 48)
				img.AnchorPoint = Vector2.new(0.5, 0)
				img.Position = UDim2.new(0.5, 0, 0, 10)
				img.ImageContent = Content.fromObject(patternSwatch(item))
				img.ZIndex = f.ZIndex + 1
				img.Parent = f
				Style.corner(img, 6)
			else
				local c = item.color
				local sample = Style.text(f, "Sample", Players.LocalPlayer.DisplayName, 16, F.bold, Color3.fromRGB(c[1], c[2], c[3]))
				sample.AnchorPoint = Vector2.new(0.5, 0)
				sample.Position = UDim2.new(0.5, 0, 0, 22)
				sample.ZIndex = f.ZIndex + 1
			end
			local name = Style.text(f, "Name", item.name, 13, F.semibold, Z.z100)
			name.AnchorPoint = Vector2.new(0.5, 0)
			name.Position = UDim2.new(0.5, 0, 0, 64)
			name.ZIndex = f.ZIndex + 1
			local slot = Shop.SLOTS[item.kind]
			if state.owned[item.id] then
				local equipped = state.equipped[slot] == item.id
				button(f, if equipped then "Equipped" else "Equip", true, function()
					net.Intent:FireServer({ type = "equip", slot = slot, itemId = if equipped then nil else item.id })
					task.delay(0.3, function()
						if not closed then
							render(net.Query:InvokeServer({ kind = "shop" }))
						end
					end)
				end)
			elseif item.productId ~= 0 then
				button(f, `R$ {item.price}`, true, function()
					MarketplaceService:PromptProductPurchase(Players.LocalPlayer, item.productId)
				end)
			else
				button(f, "Soon", false)
			end
		end
	end

	local conns = {
		MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, _, purchased)
			if purchased then
				task.wait(2) -- the server grants it in ProcessReceipt
				if not closed then
					render(net.Query:InvokeServer({ kind = "shop" }))
				end
			end
		end),
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_, _, purchased)
			if purchased and not closed then
				task.wait(1)
				render(net.Query:InvokeServer({ kind = "shop" }))
			end
		end),
	}
	card.Destroying:Connect(function()
		closed = true
		for _, c in conns do
			c:Disconnect()
		end
	end)
	task.spawn(function()
		local state = net.Query:InvokeServer({ kind = "shop" })
		if not closed and state then
			render(state)
		end
	end)
	return close
end

return ShopScreen
