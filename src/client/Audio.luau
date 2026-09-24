-- Sound effects and music (upstream client/sound: SoundManager + Sounds.ts).
-- Effects are OpenFront's resources/sounds (CC BY-SA 4.0, see NOTICE.md),
-- uploaded as Roblox audio. The upstream music is proprietary, so the game
-- plays tracks from Roblox's licensed APM library instead.

local SoundService = game:GetService("SoundService")

local EFFECTS = {
	["atom-hit"] = 111357603453749,
	["atom-launch"] = 70906591686033,
	["hydrogen-hit"] = 132906084766770,
	["hydrogen-launch"] = 75770401970749,
	["mirv-launch"] = 88683012378902,
	["nuke-warning"] = 83946660698324,
	["alliance-suggested"] = 84733096525071,
	["alliance-accepted"] = 115565492993142,
	["alliance-declined"] = 100923373313015,
	["alliance-broken"] = 81242145593159,
	["build-city"] = 107227795928961,
	["build-defense-post"] = 93614265685531,
	["build-factory"] = 82846152601128,
	["build-port"] = 97257055971352,
	["build-train-station"] = 95368752802087,
	["build-warship"] = 121410594696851,
	["sam-built"] = 99698990208079,
	["silo-built"] = 106431698254735,
	["transport-ship"] = 93930577419411,
	click = 134797132081235,
	conquered = 129710171983048,
	["ka-ching"] = 103105391582610,
	spawn = 96024714965177,
	["game-start"] = 91013627494238,
	victory = 72609868292810,
	defeat = 99248911988769,
}
-- Same morse-code cue as the alliance request (Sounds.ts "message").
EFFECTS.message = EFFECTS["alliance-suggested"]

-- APM library (APMOfficial), free for use in Roblox experiences.
local MUSIC = {
	1842642981, -- Fantastic Journey
	1843329501, -- The Monument
	1848128571, -- Right Man For The Job C
	1843329235, -- Hypercharged
	1847838831, -- Take Action C
}

local EFFECT_VOLUME = 0.6
local MUSIC_VOLUME = 0.22
-- Upstream AudioMixer budget: at most this many copies of one cue at once.
local MAX_PER_CUE = 3

local Audio = {}

local group = Instance.new("SoundGroup")
group.Name = "Effects"
group.Volume = EFFECT_VOLUME
group.Parent = SoundService
local musicGroup = Instance.new("SoundGroup")
musicGroup.Name = "Music"
musicGroup.Volume = MUSIC_VOLUME
musicGroup.Parent = SoundService

local playing: { [string]: number } = {}
local lastPlayed: { [string]: number } = {}
local muted = false
-- Player volume (0..1) per channel, saved in the profile ("audio" setting).
local volume = { music = 1, effects = 1 }
local onChange: ((music: number, effects: number) -> ())? = nil

local function applyVolume()
	group.Volume = if muted then 0 else EFFECT_VOLUME * volume.effects
	musicGroup.Volume = if muted then 0 else MUSIC_VOLUME * volume.music
end

-- Plays a cue; `minGap` (seconds) drops repeats that come too quickly (the
-- MIRV and nuke-warning intervals in SoundEffectController).
function Audio.play(name: string, minGap: number?)
	local id = EFFECTS[name]
	if id == nil or muted or volume.effects <= 0 then
		return
	end
	local now = os.clock()
	if minGap and lastPlayed[name] and now - lastPlayed[name] < minGap then
		return
	end
	if (playing[name] or 0) >= MAX_PER_CUE then
		return
	end
	lastPlayed[name] = now
	playing[name] = (playing[name] or 0) + 1
	local s = Instance.new("Sound")
	s.SoundId = `rbxassetid://{id}`
	s.SoundGroup = group
	s.Parent = SoundService
	s.Ended:Once(function()
		playing[name] -= 1
		s:Destroy()
	end)
	s:Play()
	-- A cue that never loads must not hold its budget slot forever.
	task.delay(25, function()
		if s.Parent then
			playing[name] -= 1
			s:Destroy()
		end
	end)
end

-- Looping playlist; started once per client (Main is re-cloned every match,
-- this module is not).
local musicStarted = false
function Audio.startMusic()
	if musicStarted then
		return
	end
	musicStarted = true
	local track = Instance.new("Sound")
	track.Name = "Music"
	track.SoundGroup = musicGroup
	track.Parent = SoundService
	local i = math.random(#MUSIC)
	local function nextTrack()
		track.SoundId = `rbxassetid://{MUSIC[i]}`
		i = i % #MUSIC + 1
		track:Play()
	end
	track.Ended:Connect(nextTrack)
	nextTrack()
end

function Audio.isMuted(): boolean
	return muted
end

function Audio.setMuted(value: boolean)
	muted = value
	applyVolume()
end

-- Saved volumes from the profile ({ music, effects } or nil).
function Audio.load(saved)
	if type(saved) == "table" then
		volume.music = math.clamp(tonumber(saved.music) or 1, 0, 1)
		volume.effects = math.clamp(tonumber(saved.effects) or 1, 0, 1)
		applyVolume()
		if Audio.repaint then
			Audio.repaint()
		end
	end
end

-- Called with (music, effects) whenever the player changes a volume.
function Audio.onChange(fn)
	onChange = fn
end

local function mkButton(parent: Instance, name: string, text: string, size: Vector2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.fromOffset(size.X, size.Y)
	b.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
	b.BackgroundTransparency = 0.25
	b.AutoButtonColor = true
	b.TextSize = 18
	b.Font = Enum.Font.GothamBold
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.ZIndex = 50
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = b
	b.Parent = parent
	return b
end

-- Speaker button left of the leaderboard (follows it as it opens / closes);
-- it opens a small panel: music and effects volume in 10 % steps.
function Audio.button(parent: Instance, board: GuiObject): TextButton
	local b = mkButton(parent, "AudioToggle", "🔊", Vector2.new(40, 40))
	b.AnchorPoint = Vector2.new(1, 0)
	local panel = Instance.new("Frame")
	panel.Name = "AudioPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Size = UDim2.fromOffset(230, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.ZIndex = 50
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 8)
	pc.Parent = panel
	local pad = Instance.new("UIPadding")
	for _, k in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		pad[k] = UDim.new(0, 8)
	end
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = panel
	panel.Parent = parent

	local rows = {}
	local function row(key: string, label: string, order: number)
		local r = Instance.new("Frame")
		r.Name = key
		r.BackgroundTransparency = 1
		r.Size = UDim2.new(1, 0, 0, 32)
		r.LayoutOrder = order
		r.ZIndex = 51
		r.Parent = panel
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(0, 80, 1, 0)
		t.Font = Enum.Font.GothamMedium
		t.TextSize = 15
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Text = label
		t.ZIndex = 51
		t.Parent = r
		local minus = mkButton(r, "Minus", "−", Vector2.new(32, 32))
		minus.Position = UDim2.fromOffset(84, 0)
		local value = Instance.new("TextLabel")
		value.BackgroundTransparency = 1
		value.Position = UDim2.fromOffset(118, 0)
		value.Size = UDim2.fromOffset(60, 32)
		value.Font = Enum.Font.GothamBold
		value.TextSize = 15
		value.TextColor3 = Color3.new(1, 1, 1)
		value.ZIndex = 51
		value.Parent = r
		local plus = mkButton(r, "Plus", "+", Vector2.new(32, 32))
		plus.Position = UDim2.fromOffset(180, 0)
		local function step(d: number)
			volume[key] = math.clamp(math.round((volume[key] + d) * 10) / 10, 0, 1)
			applyVolume()
			Audio.repaint()
			if onChange then
				onChange(volume.music, volume.effects)
			end
		end
		minus.Activated:Connect(function()
			step(-0.1)
		end)
		plus.Activated:Connect(function()
			step(0.1)
		end)
		rows[key] = value
	end
	row("music", "Music", 1)
	row("effects", "Effects", 2)
	local mute = mkButton(panel, "Mute", "", Vector2.new(214, 32))
	mute.LayoutOrder = 3
	mute.TextSize = 15
	mute.Activated:Connect(function()
		Audio.setMuted(not muted)
		Audio.repaint()
	end)

	function Audio.repaint()
		b.Text = if muted or (volume.music <= 0 and volume.effects <= 0) then "🔇" else "🔊"
		rows.music.Text = tostring(math.round(volume.music * 100)) .. "%"
		rows.effects.Text = tostring(math.round(volume.effects * 100)) .. "%"
		mute.Text = if muted then "Unmute" else "Mute all"
	end
	Audio.repaint()
	b.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	local function follow()
		-- Offsets relative to the parent (AbsolutePosition ignores IgnoreGuiInset).
		local origin = (parent :: any).AbsolutePosition
		local x = board.AbsolutePosition.X - origin.X - 8
		local y = board.AbsolutePosition.Y - origin.Y
		b.Position = UDim2.fromOffset(x, y)
		panel.Position = UDim2.fromOffset(x, y + 46)
	end
	board:GetPropertyChangedSignal("AbsolutePosition"):Connect(follow)
	board:GetPropertyChangedSignal("AbsoluteSize"):Connect(follow)
	follow()
	return b
end

return Audio
