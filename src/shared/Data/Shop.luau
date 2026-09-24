-- Cosmetics shop catalogue (our own designs; upstream's premium patterns are
-- proprietary and not used).
--
-- productId: the Roblox developer product sold for the item. 0 = not set up
-- yet (the shop shows it as unavailable). Create the products in the
-- Creator Dashboard (Monetization > Developer products) with the prices
-- below and paste their IDs here.
--
-- Patterns work like upstream's (PatternDecoder): the territory fill uses
-- the player's colour on primary cells and their border colour on the
-- others. rows: "#" = secondary cell; each cell covers 2^scale tiles.

local Shop = {}

Shop.SUPPORTER_PASS_ID = 0 -- game pass: supporter badge + gold name
Shop.SUPPORTER_PRICE = 199

Shop.items = {
	{ id = "pattern_stripes", kind = "pattern", name = "Stripes", price = 49, productId = 0, scale = 1,
		rows = { "########", "        ", "        ", "        ", "########", "        ", "        ", "        " } },
	{ id = "pattern_checker", kind = "pattern", name = "Checker", price = 49, productId = 0, scale = 1,
		rows = { "####    ", "####    ", "####    ", "####    ", "    ####", "    ####", "    ####", "    ####" } },
	{ id = "pattern_dots", kind = "pattern", name = "Dots", price = 49, productId = 0, scale = 1,
		rows = { "        ", " ##     ", " ##     ", "        ", "        ", "     ## ", "     ## ", "        " } },
	{ id = "pattern_diagonal", kind = "pattern", name = "Diagonal", price = 79, productId = 0, scale = 1,
		rows = { "##      ", " ##     ", "  ##    ", "   ##   ", "    ##  ", "     ## ", "      ##", "#      #" } },
	{ id = "pattern_bricks", kind = "pattern", name = "Bricks", price = 79, productId = 0, scale = 1,
		rows = { "########", "   #    ", "   #    ", "   #    ", "########", "#       ", "#       ", "#       " } },
	{ id = "pattern_waves", kind = "pattern", name = "Waves", price = 99, productId = 0, scale = 1,
		rows = { "        ", "##    ##", "  #  #  ", "   ##   ", "        ", "##    ##", "  #  #  ", "   ##   " } },
	{ id = "pattern_diamonds", kind = "pattern", name = "Diamonds", price = 99, productId = 0, scale = 1,
		rows = { "   #    ", "  # #   ", " #   #  ", "#     # ", " #   #  ", "  # #   ", "   #    ", "        " } },
	{ id = "pattern_crosses", kind = "pattern", name = "Crosses", price = 99, productId = 0, scale = 1,
		rows = { "        ", "   #    ", "   #    ", " #####  ", "   #    ", "   #    ", "        ", "        " } },
	{ id = "name_gold", kind = "nameColor", name = "Gold name", price = 99, productId = 0, color = { 255, 214, 90 } },
	{ id = "name_cyan", kind = "nameColor", name = "Cyan name", price = 99, productId = 0, color = { 94, 234, 212 } },
	{ id = "name_pink", kind = "nameColor", name = "Pink name", price = 99, productId = 0, color = { 244, 114, 182 } },
}

Shop.byId = {}
Shop.byProduct = {}
for _, item in Shop.items do
	Shop.byId[item.id] = item
	if item.productId ~= 0 then
		Shop.byProduct[item.productId] = item
	end
end

-- Equip slot per item kind.
Shop.SLOTS = { pattern = "pattern", nameColor = "nameColor" }

return Shop
