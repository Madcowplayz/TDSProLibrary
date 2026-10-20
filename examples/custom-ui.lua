local Players = game:GetService("Players")
local LIBRARY_URL = "https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/main/TDSPro.lua"
local source = game:HttpGet(LIBRARY_URL .. "?cache=" .. tostring(os.time()))
local chunk, compileError = loadstring(source)
assert(chunk, compileError)
local executed, result = pcall(chunk)
assert(executed, "TDS Pro failed while loading: " .. tostring(result))
local environment = type(getgenv) == "function" and getgenv() or _G
local TDSPro = result
if type(TDSPro) ~= "table" or type(TDSPro.new) ~= "function" then
    TDSPro = environment and environment.TDSProLibrary
end
assert(
    type(TDSPro) == "table" and type(TDSPro.new) == "function",
    "Invalid TDS Pro library. Received " .. type(result) .. " from " .. tostring(#source) .. " source bytes."
)
local tds = TDSPro.new({MacroFolder = "TDSProMacros"})

local connections = {}
local closed = false
local busy = true

local gui = Instance.new("ScreenGui")
gui.Name = "MyTDSInterface"
gui.ResetOnSpawn = false

local panel = Instance.new("ScrollingFrame")
panel.Position = UDim2.fromOffset(20, 20)
panel.Size = UDim2.new(0.9, 0, 0.85, 0)
panel.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
panel.BorderSizePixel = 0
panel.ScrollBarThickness = 5
panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
panel.CanvasSize = UDim2.new()
panel.Parent = gui

local sizeLimit = Instance.new("UISizeConstraint")
sizeLimit.MaxSize = Vector2.new(420, 640)
sizeLimit.Parent = panel

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 12)
padding.PaddingBottom = UDim.new(0, 12)
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local order = 0
local function textControl(className, text, height)
    order += 1
    local control = Instance.new(className)
    control.Size = UDim2.new(1, -8, 0, height or 34)
    control.LayoutOrder = order
    control.BackgroundColor3 = Color3.fromRGB(47, 53, 69)
    control.BorderSizePixel = 0
    control.TextColor3 = Color3.fromRGB(239, 242, 250)
    control.Font = Enum.Font.Gotham
    control.TextSize = 14
    control.TextWrapped = true
    control.Text = text
    control.Parent = panel
    return control
end

textControl("TextLabel", "My TDS controls", 30)
local stateLabel = textControl("TextLabel", "Starting...", 42)
local notificationLabel = textControl("TextLabel", "Load a macro or start a new recording.", 56)
local macroName = textControl("TextBox", "my_macro", 34)
macroName.PlaceholderText = "Macro name"
macroName.ClearTextOnFocus = false

local function showMessage(message)
    if not closed then notificationLabel.Text = tostring(message) end
end

local function renderState(state)
    if closed then return end
    stateLabel.Text = string.format("%s | %d events\nRecording: %s | Playing: %s",
        state.SelectedMacro or state.MacroName or "No macro",
        state.EventCount,
        state.Recording and "on" or "off",
        (state.Playing or state.AutoReplay) and "on" or "off")
end



local function addCommand(label, callback)
    local button = textControl("TextButton", label)
    table.insert(connections, button.Activated:Connect(function()
        if closed then return end
        if busy then showMessage("Wait for the current operation to finish."); return end
        busy = true
        task.spawn(function()
            local called, ok, result = pcall(callback)
            busy = false
            if closed then return end
            if not called then
                showMessage("Error: " .. tostring(ok))
            elseif not ok then
                showMessage("Error: " .. tostring(result))
            else
                showMessage(label .. ": accepted")
            end
            renderState(tds:GetState())
        end)
    end))
end

addCommand("Load macro", function() return tds:LoadMacro(macroName.Text) end)

addCommand("Start new recording", function() return tds:StartRecording(macroName.Text) end)
addCommand("Stop recording", function()
    local ok, result = tds:StopRecording()
    if ok and not result.Drained then
        return false, string.format("Stopped with %d unresolved action(s); review the timeline before saving.", result.Unresolved)
    end
    return ok, result
end)
addCommand("Save recording", function() return tds:SaveMacro(macroName.Text) end)
addCommand("Play once", function() return tds:Play() end)
addCommand("Start auto replay", function() return tds:SetAutoReplay(true) end)
addCommand("Stop playback / auto replay", function() return tds:Stop() end)

local function cleanup()
    if closed then return end
    closed = true
    tds:Destroy()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
end

local closeButton = textControl("TextButton", "Close and stop library")
table.insert(connections, closeButton.Activated:Connect(function()
    cleanup()
    gui:Destroy()
end))
table.insert(connections, gui.Destroying:Connect(cleanup))
table.insert(connections, script.Destroying:Connect(function()
    cleanup()
    gui:Destroy()
end))


table.insert(connections, tds:On("Notification", function(message)
    showMessage(tostring(message.Title) .. ": " .. tostring(message.Content))
end))
table.insert(connections, tds:On("StatusChanged", showMessage))
table.insert(connections, tds:On("StateChanged", renderState))
table.insert(connections, tds:On("TimelineChanged", function()
    renderState(tds:GetState())
end))
table.insert(connections, tds:On("Error", function(problem)
    showMessage("Runtime error: " .. tostring(problem.Message))
end))

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local ok, result = tds:Start()
busy = false
if not ok then
    showMessage("Startup failed: " .. tostring(result))
    busy = true
    tds:Destroy()
else
    renderState(result)
end
