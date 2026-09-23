-- Upstream HUD icons (tools/pack-icons.mjs) as EditableImages. Each icon is
-- decoded once; the "white" variant copies it with RGB forced to white, the
-- equivalent of upstream's `brightness(0) invert(1)` filter, and is what
-- tinted icons use (ImageColor3 multiplies white into any colour).

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")

local Data = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Icons"))

local Icons = {}

local cache = {} -- name .. variant -> EditableImage

local function decode(name: string): (buffer, number)
	local icon = Data[name]
	assert(icon, `unknown icon {name}`)
	return EncodingService:Base64Decode(buffer.fromstring(icon.rgba)), icon.size
end

local function editable(name: string, white: boolean)
	local key = name .. (if white then ":white" else "")
	local img = cache[key]
	if img then
		return img
	end
	local px, size = decode(name)
	if white then
		for i = 0, buffer.len(px) - 1, 4 do
			buffer.writeu8(px, i, 255)
			buffer.writeu8(px, i + 1, 255)
			buffer.writeu8(px, i + 2, 255)
		end
	end
	img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), px)
	cache[key] = img
	return img
end

-- An ImageLabel showing icon `name` at `px` pixels. opts.white forces the
-- white variant; opts.color tints it (implies white).
function Icons.label(parent: Instance?, name: string, px: number, opts: { white: boolean?, color: Color3? }?): ImageLabel
	local white = opts ~= nil and (opts.white == true or opts.color ~= nil)
	local l = Instance.new("ImageLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromOffset(px, px)
	l.ImageContent = Content.fromObject(editable(name, white))
	l.ScaleType = Enum.ScaleType.Fit
	if opts and opts.color then
		l.ImageColor3 = opts.color
	end
	l.Parent = parent
	return l
end

return Icons
