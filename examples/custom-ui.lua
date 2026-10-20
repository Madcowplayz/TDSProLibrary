local LIBRARY_URL = "https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/main/TDSPro.lua"
local source = game:HttpGet(LIBRARY_URL .. "?cache=" .. tostring(os.time()))
local chunk, compileError = loadstring(source)
assert(chunk, compileError)
local executed, result = pcall(chunk)
assert(executed, "TDS Pro failed while loading: " .. tostring(result))
local environment = type(getgenv) == "function" and getgenv() or _G
local TDSPro = result
if type(TDSPro) ~= "table" or type(TDSPro.new) ~= "function" then TDSPro = environment and environment.TDSProLibrary end
assert(type(TDSPro) == "table" and type(TDSPro.new) == "function", "Invalid TDS Pro library")

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name = "TDS Pro Library Example",
    LoadingTitle = "TDS Pro",
    LoadingSubtitle = "Rayfield integration",
    ConfigurationSaving = {Enabled = false},
    Discord = {Enabled = false},
    KeySystem = false,
})

local tds = TDSPro.new({MacroFolder = "TDSProMacros"})
local connections = {}
local macroName = "default_macro"

local function notify(title, content)
    Rayfield:Notify({Title = tostring(title), Content = tostring(content), Duration = 4})
end

local function execute(name, callback)
    task.spawn(function()
        local called, ok, value = pcall(callback)
        if not called then notify(name, "Error: " .. tostring(ok))
        elseif not ok then notify(name, tostring(value))
        else notify(name, "Completed") end
    end)
end

local Main = Window:CreateTab("Main", "home")
local Recorder = Window:CreateTab("Recorder", "circle-dot")
local Gameplay = Window:CreateTab("Gameplay", "gamepad-2")
local Settings = Window:CreateTab("Settings", "settings")
local Status = Main:CreateParagraph({Title = "Library Status", Content = "Starting..."})

Main:CreateInput({
    Name = "Macro Name",
    PlaceholderText = "default_macro",
    RemoveTextAfterFocusLost = false,
    Callback = function(text) if tostring(text) ~= "" then macroName = tostring(text) end end,
})
Main:CreateButton({Name = "Load Macro", Callback = function() execute("Load Macro", function() return tds:LoadMacro(macroName) end) end})
Main:CreateButton({Name = "Play Once", Callback = function() execute("Play Once", function() return tds:Play() end) end})
Main:CreateToggle({
    Name = "Auto Replay",
    CurrentValue = false,
    Flag = "TDSProAutoReplay",
    Callback = function(value) execute("Auto Replay", function() return tds:SetAutoReplay(value) end) end,
})
Main:CreateButton({Name = "Stop Playback", Callback = function() execute("Stop Playback", function() return tds:Stop() end) end})
Main:CreateButton({Name = "Auto Equip Inventory", Callback = function() execute("Auto Equip", function() return tds:AutoEquipInventory() end) end})
Main:CreateButton({Name = "Restore Previous Loadout", Callback = function() execute("Restore Loadout", function() return tds:RestorePreviousLoadout() end) end})

Recorder:CreateButton({Name = "Start Recording", Callback = function() execute("Start Recording", function() return tds:StartRecording(macroName) end) end})
Recorder:CreateButton({Name = "Stop Recording", Callback = function() execute("Stop Recording", function() return tds:StopRecording() end) end})
Recorder:CreateButton({Name = "Save Recording", Callback = function() execute("Save Recording", function() return tds:SaveMacro(macroName) end) end})
Recorder:CreateButton({Name = "Clear Recording", Callback = function() execute("Clear Recording", function() return tds:ClearRecording() end) end})

local function configToggle(tab, name, key)
    tab:CreateToggle({
        Name = name,
        CurrentValue = tds:GetConfig()[key],
        Flag = "TDSPro" .. key,
        Callback = function(value) execute(name, function() return tds:Configure({[key] = value}) end) end,
    })
end

configToggle(Gameplay, "Anti AFK", "AntiAFK")
configToggle(Gameplay, "Auto Skip", "AutoSkip")
configToggle(Gameplay, "Simplify Map Visuals", "SimplifyMapVisuals")
configToggle(Gameplay, "VIP Override", "VIPOverride")
configToggle(Gameplay, "Map Reroll", "MapReroll")
configToggle(Gameplay, "Loading Stall Recovery", "LoadingStallRecovery")
configToggle(Gameplay, "Use 2x Time Scale", "TimeScale2x")
configToggle(Gameplay, "Early Economy Actions", "EarlyEconomyActions")
configToggle(Gameplay, "Multiplayer Mode", "Multiplayer")
configToggle(Gameplay, "Party Host", "IsHost")
configToggle(Gameplay, "Modifier Voting", "ModifierVoting")

Gameplay:CreateDropdown({
    Name = "Player Count",
    Options = {"2 Players", "3 Players", "4 Players"},
    CurrentOption = {"2 Players"},
    MultipleOptions = false,
    Flag = "TDSProPlayerCount",
    Callback = function(option)
        local selected = type(option) == "table" and option[1] or option
        local count = tonumber(tostring(selected):match("%d+"))
        if count then execute("Player Count", function() return tds:Configure({PlayerCount = count}) end) end
    end,
})
Gameplay:CreateDropdown({
    Name = "Modifiers",
    Options = tds:GetModifiers(),
    CurrentOption = {},
    MultipleOptions = true,
    Flag = "TDSProModifiers",
    Callback = function(options) execute("Modifiers", function() return tds:Configure({Modifiers = options}) end) end,
})
Gameplay:CreateButton({Name = "Vote Configured Modifiers", Callback = function() execute("Vote Modifiers", function() return tds:VoteModifiers() end) end})
Gameplay:CreateButton({Name = "Skip Wave", Callback = function() execute("Skip Wave", function() return tds:SkipWave() end) end})

Settings:CreateButton({Name = "Save Library Settings", Callback = function() execute("Save Settings", function() return tds:SaveSettings() end) end})
Settings:CreateButton({Name = "Load Library Settings", Callback = function() execute("Load Settings", function() return tds:LoadSettings() end) end})
Settings:CreateButton({
    Name = "Close and Stop",
    Callback = function()
        tds:Destroy()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        table.clear(connections)
        Rayfield:Destroy()
    end,
})

table.insert(connections, tds:On("Notification", function(message) notify(message.Title, message.Content) end))
table.insert(connections, tds:On("StatusChanged", function(message) Status:Set({Title = "Library Status", Content = tostring(message)}) end))
table.insert(connections, tds:On("StateChanged", function(state)
    Status:Set({
        Title = tostring(state.SelectedMacro or state.MacroName or "TDS Pro"),
        Content = string.format(
            "%d events | Recording: %s | Playing: %s | Auto Replay: %s",
            tonumber(state.EventCount) or 0,
            state.Recording and "ON" or "OFF",
            state.Playing and "ON" or "OFF",
            state.AutoReplay and "ON" or "OFF"
        ),
    })
end))
table.insert(connections, tds:On("Error", function(problem) notify("TDS Pro Error", problem.Message) end))

local started, startResult = tds:Start()
if not started then
    notify("Startup Failed", startResult)
    tds:Destroy()
else
    Status:Set({Title = "TDS Pro", Content = "Ready"})
end
