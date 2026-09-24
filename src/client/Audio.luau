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

-- Plays a cue; `minGap` (seconds) drops repeats that come too quickly (the
-- MIRV and nuke-warning intervals in SoundEffectController).
function Audio.play(name: string, minGap: number?)
	local id = EFFECTS[name]
	if id == nil or muted then
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
	group.Volume = if value then 0 else EFFECT_VOLUME
	musicGroup.Volume = if value then 0 else MUSIC_VOLUME
end

-- Speaker toggle button (top right, left of the leaderboard).
function Audio.button(parent: Instance, topInset: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = "AudioToggle"
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -12 - 260 - 8, 0, topInset)
	b.Size = UDim2.fromOffset(40, 40)
	b.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
	b.BackgroundTransparency = 0.25
	b.AutoButtonColor = true
	b.TextSize = 20
	b.Font = Enum.Font.GothamBold
	b.TextColor3 = Color3.new(1, 1, 1)
	b.ZIndex = 50
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = b
	local function paint()
		b.Text = if muted then "🔇" else "🔊"
	end
	paint()
	b.Activated:Connect(function()
		Audio.setMuted(not muted)
		paint()
	end)
	b.Parent = parent
	return b
end

return Audio
