local TDSPro = require("../TDSPRO")
assert(type(TDSPro) == "table" and type(TDSPro.new) == "function", "module must return a factory")

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local activity = {connections = 0, disconnected = 0, tasks = 0, cancelled = 0, ui = 0, http = 0, remote = 0, writes = 0}
local signals = {}
local pending = {}
local files, folders, encoded = {}, {}, {}
local warnings = {}

local function signal()
    local value = {listeners = {}}
    function value:Connect(callback)
        activity.connections += 1
        local connection = {Connected = true}
        function connection:Disconnect()
            if self.Connected then
                self.Connected = false
                activity.disconnected += 1
            end
        end
        self.listeners[connection] = callback
        return connection
    end
    function value:Fire(...)
        for connection, callback in pairs(self.listeners) do
            if connection.Connected then callback(...) end
        end
    end
    table.insert(signals, value)
    return value
end

local function instance(name, className)
    local value = {Name = name, ClassName = className or "Folder", __type = "Instance", children = {}, attributes = {}}
    value.ChildAdded = signal()
    value.DescendantAdded = signal()
    function value:IsA(kind) return self.ClassName == kind or kind == "Instance" end
    function value:FindFirstChild(key, recursive)
        local child = self.children[key]
        if child or not recursive then return child end
        for _, descendant in pairs(self.children) do
            local found = descendant:FindFirstChild(key, true)
            if found then return found end
        end
        return nil
    end
    function value:FindFirstChildOfClass(kind)
        for _, child in pairs(self.children) do if child.ClassName == kind then return child end end
        return nil
    end
    function value:GetChildren()
        local result = {}
        for _, child in pairs(self.children) do table.insert(result, child) end
        return result
    end
    function value:GetDescendants()
        local result = {}
        for _, child in pairs(self.children) do
            table.insert(result, child)
            for _, descendant in ipairs(child:GetDescendants()) do table.insert(result, descendant) end
        end
        return result
    end
    function value:GetAttribute(key) return self.attributes[key] end
    function value:WaitForChild(key) return self:FindFirstChild(key) end
    function value:GetPropertyChangedSignal() return signal() end
    function value:GetFullName() return self.Name end
    function value:IsDescendantOf(ancestor)
        local current = self.Parent
        while current do
            if current == ancestor then return true end
            current = current.Parent
        end
        return false
    end
    return value
end

local function attach(parent, child)
    child.Parent = parent
    parent.children[child.Name] = child
    parent[child.Name] = child
    return child
end

local player = instance("TestPlayer", "Player")
player.DisplayName, player.UserId = "Test Player", 123
player.Idled, player.OnTeleport = signal(), signal()
local playerGui = attach(player, instance("PlayerGui", "PlayerGui"))
local gameGui = attach(playerGui, instance("GameGui", "ScreenGui"))
gameGui.Enabled = true
local players = instance("Players", "Players")
players.LocalPlayer, players.PlayerRemoving = player, signal()
function players:GetPlayers() return {player} end
local world = instance("Workspace", "Workspace")
world.CurrentCamera = {ViewportSize = {X = 1280, Y = 720}}
local replicated = instance("ReplicatedStorage", "ReplicatedStorage")
local remoteFunction = attach(replicated, instance("RemoteFunction", "RemoteFunction"))
function remoteFunction:InvokeServer(...) activity.remote += 1 return true end
local remoteEvent = attach(replicated, instance("RemoteEvent", "RemoteEvent"))
function remoteEvent:FireServer(...) activity.remote += 1 end
local guiService = {ErrorMessageChanged = signal()}
local httpService = {}
function httpService:JSONEncode(value)
    local token = "mock-json:" .. tostring(#encoded + 1)
    table.insert(encoded, copy(value))
    return token
end
function httpService:JSONDecode(value)
    local index = tonumber(tostring(value):match("^mock%-json:(%d+)$"))
    assert(index and encoded[index], "invalid mock JSON")
    return copy(encoded[index])
end
local services = {
    Players = players,
    UserInputService = {InputChanged = signal()},
    VirtualUser = {Button2Down = function() end, Button2Up = function() end, CaptureController = function() end, ClickButton2 = function() end},
    ReplicatedStorage = replicated,
    HttpService = httpService,
    TeleportService = {Teleport = function() activity.remote += 1 end},
    GuiService = guiService,
}
local mockGame = instance("game", "DataModel")
mockGame.PlaceId, mockGame.JobId = 1, "test-job"
function mockGame:GetService(name)
    assert(services[name], "unexpected service: " .. tostring(name))
    return services[name]
end
function mockGame:IsLoaded() return true end
function mockGame:HttpGet() activity.http += 1 error("unexpected network call") end

local mockTask = {}
function mockTask.spawn(callback, ...)
    local thread = type(callback) == "thread" and callback or coroutine.create(callback)
    activity.tasks += 1
    pending[thread] = {args = table.pack(...)}
    return thread
end
mockTask.defer = mockTask.spawn
function mockTask.delay(_, callback, ...) return mockTask.spawn(callback, ...) end
function mockTask.wait(seconds) return coroutine.yield(seconds or 0) end
function mockTask.cancel(thread)
    if pending[thread] then
        activity.cancelled += 1
        pending[thread] = nil
    end
    if coroutine.status(thread) ~= "dead" then coroutine.close(thread) end
end
local function stepTasks()
    local scheduled = {}
    for thread, info in pairs(pending) do scheduled[thread] = info end
    for thread, info in pairs(scheduled) do
        if pending[thread] then
            local ok, err = coroutine.resume(thread, table.unpack(info.args, 1, info.args.n))
            info.args = table.pack()
            assert(ok, tostring(err))
            if coroutine.status(thread) == "dead" then pending[thread] = nil end
        end
    end
end

local baseEnvironment = getfenv(0)
local environment = setmetatable({
    game = mockGame,
    workspace = world,
    task = mockTask,
    typeof = function(value) return type(value) == "table" and value.__type or type(value) end,
    warn = function(...) table.insert(warnings, table.pack(...)) end,
    print = function() end,
    _G = {},
    Instance = {new = function() activity.ui += 1 error("library must not create UI") end},
    Color3 = {fromRGB = function(r, g, b) return {R = r / 255, G = g / 255, B = b / 255} end},
    Vector2 = {new = function(x, y) return {X = x, Y = y} end},
    Vector3 = {new = function(x, y, z) return {X = x, Y = y, Z = z, __type = "Vector3"} end},
    Enum = {TeleportState = {Started = "Started", Failed = "Failed", InProgress = "InProgress"}},
    request = function() activity.http += 1 error("unexpected network call") end,
    isfile = function(path) return files[path] ~= nil end,
    isfolder = function(path) return folders[path] == true end,
    makefolder = function(path) folders[path] = true end,
    readfile = function(path) assert(files[path], "file not found") return files[path] end,
    writefile = function(path, value) activity.writes += 1 files[path] = value end,
    listfiles = function(path)
        local result = {}
        for filename in pairs(files) do
            if filename:sub(1, #path + 1) == path .. "/" then table.insert(result, filename) end
        end
        return result
    end,
}, {__index = baseEnvironment})
setfenv(TDSPro.new, environment)

local tests, passed = {}, 0
local function test(name, callback) table.insert(tests, {name, callback}) end
local function succeeds(ok, result) assert(ok == true, tostring(result)) return result end
local function rejects(ok, result) assert(ok == false and type(result) == "string", "expected false,error") end
local api

test("factory is headless and idle", function()
    api = TDSPro.new()
    assert(type(api) == "table", "new() must return an API table")
    assert(activity.connections == 0 and activity.tasks == 0, "factory started background work")
    assert(activity.ui == 0 and activity.http == 0 and activity.remote == 0 and activity.writes == 0, "factory performed external work")
end)

test("configuration validates atomically and copies tables", function()
    local settings = {HostDelay = 9, Modifiers = {"Fog"}, WebhookEvents = {Disconnect = false}}
    succeeds(api:Configure(settings))
    settings.Modifiers[1] = "Glass"
    settings.WebhookEvents.Disconnect = true
    local config = api:GetConfig()
    assert(config.HostDelay == 9 and config.Modifiers[1] == "Fog" and config.WebhookEvents.Disconnect == false)
    config.Modifiers[1] = "Glass"
    config.WebhookEvents.Disconnect = true
    assert(api:GetConfig().Modifiers[1] == "Fog" and api:GetConfig().WebhookEvents.Disconnect == false)
    rejects(api:Configure({HostDelay = 4, NotAnOption = true}))
    assert(api:GetConfig().HostDelay == 9, "invalid configure was partially applied")
    for _, settingsToReject in ipairs({
        {HostDelay = -1}, {HostDelay = math.huge}, {PlayerCount = 2.5}, {PlayerCount = 5},
        {LoadingStallTimeout = 20}, {AntiAFK = "yes"}, {Modifiers = {"missing"}},
        {MacroFolder = "../outside"}, {WebhookURL = "http://example.com"},
        {VIPOverride = true, MapReroll = true},
    }) do rejects(api:Configure(settingsToReject)) end
    succeeds(api:Configure({VIPOverride = true}))
    succeeds(api:Configure({MapReroll = true}))
    assert(api:GetConfig().MapReroll and not api:GetConfig().VIPOverride)
    succeeds(api:Configure({MapReroll = false}))
    assert(activity.tasks == 0 and activity.connections == 0, "configuration started runtime before Start")
end)

test("subscriptions copy payloads and disconnect", function()
    local received = 0
    local subscription = assert(api:On("ConfigChanged", function(config)
        received += 1
        config.Modifiers[1] = "mutated callback"
        config.HostDelay = -99
    end))
    succeeds(api:Configure({HostDelay = 8}))
    assert(received == 1 and api:GetConfig().HostDelay == 8 and api:GetConfig().Modifiers[1] == "Fog")
    subscription:Disconnect()
    succeeds(api:Configure({HostDelay = 7}))
    assert(received == 1 and not subscription.Connected)
    local invalid, message = api:On("", function() end)
    assert(invalid == nil and type(message) == "string")
end)

test("runtime operations require Start", function()
    rejects(api:Play())
    rejects(api:StartRecording())
    rejects(api:SetAutoReplay(true))
    rejects(api:SkipWave())
    rejects(api:AutoEquipInventory())
    rejects(api:RestorePreviousLoadout())
    rejects(api:SendTestWebhook())
    assert(activity.remote == 0 and activity.http == 0 and activity.tasks == 0)
end)

local nativeDocument = {
    Meta = {Map = "Test Map", Difficulty = "Molten", Towers = {{Name = "Scout"}}},
    Timeline = {{Order = 1, Timestamp = 0, Action = "Custom", Details = {Flag = "autoskip", Bool = false}}},
}
test("native macro import and getters isolate mutable state", function()
    local source = copy(nativeDocument)
    succeeds(api:ImportMacro(source, "sample"))
    source.Meta.Map = "mutated input"
    source.Timeline[1].Details.Flag = "mutated input"
    assert(api:GetState().MacroName == "sample" and api:GetState().EventCount == 1)
    assert(api:GetState().Metadata.Map == "Test Map")
    local timeline = api:GetTimeline()
    timeline[1].Details.Flag = "mutated output"
    assert(api:GetTimeline()[1].Details.Flag == "autoskip")
    local exported = api:ExportMacro()
    exported.Meta.Towers[1].Name = "mutated export"
    assert(api:ExportMacro().Meta.Towers[1].Name == "Scout")
    local state = api:GetState()
    state.Metadata.Map = "mutated state"
    assert(api:GetState().Metadata.Map == "Test Map")
end)

test("invalid imports preserve the previous macro", function()
    for _, document in ipairs({
        {anything = true},
        {Timeline = {{Action = "Skip", Timestamp = math.huge}}},
        {Timeline = {{Action = "Skip", Details = "invalid"}}},
        {Timeline = {{Timestamp = 0}}},
        {Timeline = {[2] = {Action = "Skip"}}},
    }) do
        rejects(api:ImportMacro(document))
        assert(api:GetState().EventCount == 1 and api:GetTimeline()[1].Action == "Custom")
    end
    rejects(api:ImportMacro("invalid JSON"))
end)

test("AutoTDS documents normalize timing and action types", function()
    succeeds(api:ImportMacro({
        {type = "custom", typeInfo = {currentWave = 1, time = 60, Flag = "autoskip", Bool = false}},
        {type = "wave", typeInfo = {currentWave = 1, time = 45}},
        {type = "game over", typeInfo = {mapData = {currentMap = "Crossroads", currentDifficulty = "Molten"}}},
    }, "AutoTDS import"))
    local state, timeline = api:GetState(), api:GetTimeline()
    assert(state.SourceFormat == "AutoTDS" and state.Metadata.Map == "Crossroads" and #timeline == 2)
    assert(timeline[1].Action == "Custom" and timeline[2].Action == "Skip")
    assert(timeline[2].WaveTime == 45 and timeline[2].TimingMode == "WaveTimerCountdown")
    succeeds(api:ImportMacro(nativeDocument, "sample"))
end)

test("timeline edits, JSON roundtrip, and macro storage", function()
    succeeds(api:SetEventTime(1, 2.5))
    assert(api:GetTimeline()[1].Timestamp == 2.5)
    rejects(api:SetEventTime(1, -1))
    rejects(api:SetEventTime(10, 1))
    rejects(api:SetEventTime(1, 0/0))
    local json = api:ExportMacro(true)
    assert(type(json) == "string")
    succeeds(api:ImportMacro(json, "roundtrip"))
    assert(api:GetTimeline()[1].Timestamp == 2.5)
    local path = succeeds(api:SaveMacro("roundtrip"))
    assert(path:match("roundtrip%.txt$"))
    local names = api:ListMacros()
    assert(table.find(names, "roundtrip"), "saved macro missing from listing")
    succeeds(api:ClearRecording())
    assert(api:GetState().EventCount == 0)
    succeeds(api:LoadMacro("roundtrip"))
    assert(api:GetState().EventCount == 1)
    succeeds(api:SetEventTime(1, 0))
end)

test("settings save and load use the public configuration", function()
    local before = api:GetConfig()
    succeeds(api:SaveSettings())
    succeeds(api:Configure({HostDelay = 3}))
    succeeds(api:LoadSettings())
    assert(api:GetConfig().HostDelay == before.HostDelay)
end)

test("Start is idempotent and workers stay headless", function()
    local errors = {}
    assert(api:On("Error", function(payload) table.insert(errors, payload.Message) end))
    succeeds(api:Start())
    assert(api:GetState().Started and activity.connections > 0 and activity.tasks > 0)
    local connections, tasks = activity.connections, activity.tasks
    succeeds(api:Start())
    assert(activity.connections == connections and activity.tasks == tasks, "Start duplicated runtime work")
    stepTasks()
    assert(#errors == 0, table.concat(errors, "\n"))
    assert(activity.ui == 0 and activity.http == 0 and activity.remote == 0)
    rejects(api:Configure({MacroFolder = "AnotherFolder"}))
    rejects(api:StartRecording())
    assert(not api:GetState().Recording, "failed recorder start changed state")
end)

test("playback finishes without matchmaking and respects busy state", function()
    succeeds(api:Play())
    assert(api:GetState().Playing and api:GetState().PlaybackBusy)
    rejects(api:ImportMacro(nativeDocument))
    rejects(api:Play())
    stepTasks()
    assert(not api:GetState().Playing and not api:GetState().PlaybackBusy, "one-shot playback did not finish")
    assert(activity.remote == 0, "one-shot playback unexpectedly requested matchmaking")
    local telemetry = api:GetTelemetry()
    assert(telemetry.Played == 1 and #telemetry.Actions == 1, "playback did not report completed action")
    telemetry.Actions[1].Status = "mutated telemetry"
    assert(api:GetTelemetry().Actions[1].Status ~= "mutated telemetry")
end)

test("stopped playback settles before allowing macro edits", function()
    succeeds(api:Play())
    succeeds(api:Stop())
    assert(not api:GetState().Playing)
    rejects(api:ImportMacro(nativeDocument))
    stepTasks()
    assert(not api:GetState().PlaybackBusy)
    succeeds(api:ImportMacro(nativeDocument))
end)

test("instances isolate configuration and macro state", function()
    local second = TDSPro.new({HostDelay = 2})
    assert(second:GetConfig().HostDelay == 2 and api:GetConfig().HostDelay == 7)
    assert(second:GetState().EventCount == 0 and api:GetState().EventCount == 1)
    succeeds(second:Destroy())
    assert(not api:GetState().Destroyed)
end)

test("Destroy cancels workers, disconnects signals, and guards commands", function()
    local destroyedCount = 0
    local listener = assert(api:On("Destroyed", function(state)
        destroyedCount += 1
        assert(state.Destroyed and not state.Started)
    end))
    succeeds(api:Destroy())
    succeeds(api:Destroy())
    assert(destroyedCount == 1 and not listener.Connected)
    assert(api:GetState().Destroyed and not api:GetState().Started)
    assert(activity.connections == activity.disconnected, "runtime leaked signal connections")
    assert(next(pending) == nil, "runtime leaked background threads")
    rejects(api:Start())
    rejects(api:Configure({AntiAFK = true}))
    rejects(api:ImportMacro(nativeDocument))
    rejects(api:Play())
    rejects(api:Stop())
    rejects(api:SkipWave())
    local invalid, message = api:On("StateChanged", function() end)
    assert(invalid == nil and type(message) == "string")
    assert(activity.ui == 0 and activity.http == 0 and activity.remote == 0)
end)

for _, entry in ipairs(tests) do
    local ok, err = pcall(entry[2])
    if not ok then error("FAIL " .. entry[1] .. ": " .. tostring(err), 0) end
    passed += 1
    print("PASS " .. entry[1])
end
print("Passed " .. tostring(passed) .. " TDSPro library tests")
