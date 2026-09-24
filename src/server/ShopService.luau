-- Cosmetics shop, server side: grants developer-product purchases into the
-- player's profile (idempotent by PurchaseId), checks the supporter game
-- pass, and validates equip requests. Nothing here affects the simulation.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Shop = require(Shared.Data.Shop)
local Profiles = require(script.Parent.Profiles)

local ShopService = {}

local supporters = {} -- userId -> true
local changed = Instance.new("BindableEvent") -- (userId) cosmetics changed
ShopService.Changed = changed.Event

local function processReceipt(receipt)
	local item = Shop.byProduct[receipt.ProductId]
	if item == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data = Profiles.get(receipt.PlayerId, 15)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- not loaded; Roblox retries
	end
	if Profiles.hasReceipt(data, receipt.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	data.owned[item.id] = true
	-- Equip on purchase.
	local slot = Shop.SLOTS[item.kind]
	if slot then
		data.equipped[slot] = item.id
	end
	Profiles.addReceipt(data, receipt.PurchaseId)
	if not Profiles.saveNow(receipt.PlayerId) then
		-- Roll back so a retry grants it again cleanly.
		data.owned[item.id] = nil
		table.remove(data.receipts, table.find(data.receipts, receipt.PurchaseId) :: number)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	changed:Fire(receipt.PlayerId)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local started = false
function ShopService.start()
	if started then
		return
	end
	started = true
	MarketplaceService.ProcessReceipt = processReceipt
	Profiles.onLoaded(function(userId)
		changed:Fire(userId)
	end)
	local function checkPass(player: Player)
		if Shop.SUPPORTER_PASS_ID == 0 then
			return
		end
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, Shop.SUPPORTER_PASS_ID)
		end)
		if ok and owns then
			supporters[player.UserId] = true
			changed:Fire(player.UserId)
		end
	end
	Players.PlayerAdded:Connect(checkPass)
	for _, p in Players:GetPlayers() do
		task.spawn(checkPass, p)
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if purchased and passId == Shop.SUPPORTER_PASS_ID then
			supporters[player.UserId] = true
			changed:Fire(player.UserId)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		supporters[player.UserId] = nil
	end)
end

function ShopService.isSupporter(userId: number): boolean
	return supporters[userId] == true
end

-- What a player shows in the game: { pattern = itemId?, nameColor = {r,g,b}?, supporter = bool }.
function ShopService.cosmetics(userId: number)
	local data = Profiles.get(userId)
	local out = { supporter = supporters[userId] == true }
	if data then
		local pattern = data.equipped.pattern
		if pattern and data.owned[pattern] and Shop.byId[pattern] then
			out.pattern = pattern
		end
		local nameColor = data.equipped.nameColor
		if nameColor and data.owned[nameColor] and Shop.byId[nameColor] then
			out.nameColor = Shop.byId[nameColor].color
		end
	end
	if out.nameColor == nil and out.supporter then
		out.nameColor = Shop.byId.name_gold.color
	end
	return out
end

-- Shop screen state for a player.
function ShopService.state(userId: number)
	local data = Profiles.get(userId, 5)
	return {
		owned = if data then data.owned else {},
		equipped = if data then data.equipped else {},
		supporter = supporters[userId] == true,
		loaded = data ~= nil,
	}
end

-- Equip (or unequip with itemId nil) an owned item.
function ShopService.equip(userId: number, slot: string, itemId: string?): boolean
	local data = Profiles.get(userId)
	if data == nil or (slot ~= "pattern" and slot ~= "nameColor") then
		return false
	end
	if itemId ~= nil then
		local item = Shop.byId[itemId]
		if item == nil or Shop.SLOTS[item.kind] ~= slot or not data.owned[itemId] then
			return false
		end
	end
	data.equipped[slot] = itemId
	Profiles.markDirty(userId)
	changed:Fire(userId)
	return true
end

return ShopService
