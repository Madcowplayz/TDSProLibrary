local DefaultUI = {}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local function create(className, properties)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do
        object[key] = value
    end
    return object
end

function DefaultUI.mount(tds, options)
    options = type(options) == "table" and options or {}
    if type(tds) ~= "table" or type(tds.Start) ~= "function" then
        return nil, "DefaultUI.mount expects a TDSPro instance."
    end

    local player = Players.LocalPlayer
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return nil, "PlayerGui is unavailable."
    end

    local existing = playerGui:FindFirstChild("TDSProDefaultUI")
    if existing then existing:Destroy() end

    local connections = {}
    local closed = false
    local busy = false
    local controller = {}

    local gui = create("ScreenGui", {
        Name = "TDSProDefaultUI",
        ResetOnSpawn = false,
        IgnoreGuiInset = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = playerGui,
    })

    local panel = create("Frame", {
        Name = "Panel",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(410, 560),
        BackgroundColor3 = Color3.fromRGB(18, 21, 29),
        BorderSizePixel = 0,
        Parent = gui,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 12), Parent = panel})
    create("UIStroke", {Color = Color3.fromRGB(58, 68, 91), Thickness = 1, Parent = panel})

    local header = create("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundColor3 = Color3.fromRGB(26, 31, 43),
        BorderSizePixel = 0,
        Parent = panel,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 12), Parent = header})
    create("Frame", {
        Position = UDim2.new(0, 0, 1, -12),
        Size = UDim2.new(1, 0, 0, 12),
        BackgroundColor3 = header.BackgroundColor3,
        BorderSizePixel = 0,
        Parent = header,
    })

    create("TextLabel", {
        Position = UDim2.fromOffset(18, 0),
        Size = UDim2.new(1, -78, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = tostring(options.Title or "TDS Pro"),
        TextColor3 = Color3.fromRGB(244, 247, 255),
        TextSize = 18,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = header,
    })

    local closeButton = create("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(34, 34),
        BackgroundColor3 = Color3.fromRGB(52, 59, 77),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "×",
        TextColor3 = Color3.fromRGB(235, 239, 249),
        TextSize = 22,
        Parent = header,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = closeButton})

    local content = create("ScrollingFrame", {
        Position = UDim2.fromOffset(12, 66),
        Size = UDim2.new(1, -24, 1, -78),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(104, 125, 180),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(),
        Parent = panel,
    })
    create("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = content,
    })

    local order = 0
    local function nextOrder()
        order += 1
        return order
    end

    local function label(text, height)
        return create("TextLabel", {
            LayoutOrder = nextOrder(),
            Size = UDim2.new(1, -4, 0, height or 38),
            BackgroundColor3 = Color3.fromRGB(27, 32, 44),
            BorderSizePixel = 0,
            Font = Enum.Font.Gotham,
            Text = text,
            TextColor3 = Color3.fromRGB(218, 224, 239),
            TextSize = 13,
            TextWrapped = true,
            Parent = content,
        })
    end

    local stateLabel = label("Starting…", 52)
    local messageLabel = label("Ready", 52)

    local macroInput = create("TextBox", {
        LayoutOrder = nextOrder(),
        Size = UDim2.new(1, -4, 0, 38),
        BackgroundColor3 = Color3.fromRGB(35, 42, 58),
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Font = Enum.Font.Gotham,
        PlaceholderText = "Macro name",
        Text = tostring(options.MacroName or "default_macro"),
        TextColor3 = Color3.fromRGB(244, 247, 255),
        PlaceholderColor3 = Color3.fromRGB(136, 146, 170),
        TextSize = 14,
        Parent = content,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = macroInput})

    local function show(message)
        if not closed then messageLabel.Text = tostring(message) end
    end

    local function render(state)
        if closed then return end
        state = state or tds:GetState()
        local name = state.SelectedMacro or state.MacroName or "No macro"
        stateLabel.Text = string.format(
            "%s  •  %d events\nRecording: %s    Playing: %s    Auto replay: %s",
            tostring(name),
            tonumber(state.EventCount) or 0,
            state.Recording and "ON" or "OFF",
            state.Playing and "ON" or "OFF",
            state.AutoReplay and "ON" or "OFF"
        )
    end

    local function run(name, callback)
        if closed then return end
        if busy then show("Wait for the current operation to finish."); return end
        busy = true
        show(name .. "…")
        task.spawn(function()
            local called, ok, result = pcall(callback)
            busy = false
            if closed then return end
            if not called then
                show("Error: " .. tostring(ok))
            elseif not ok then
                show("Error: " .. tostring(result))
            else
                show(name .. " completed.")
            end
            render()
            for _, refresh in ipairs(refreshControls) do pcall(refresh) end
        end)
    end

    local function button(text, callback)
        local control = create("TextButton", {
            LayoutOrder = nextOrder(),
            Size = UDim2.new(1, -4, 0, 38),
            BackgroundColor3 = Color3.fromRGB(58, 78, 128),
            BorderSizePixel = 0,
            Font = Enum.Font.GothamSemibold,
            Text = text,
            TextColor3 = Color3.fromRGB(248, 250, 255),
            TextSize = 14,
            AutoButtonColor = true,
            Parent = content,
        })
        create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = control})
        table.insert(connections, control.Activated:Connect(function()
            run(text, callback)
        end))
        return control
    end

    local function section(text)
        local control = label(text, 30)
        control.BackgroundTransparency = 1
        control.Font = Enum.Font.GothamBold
        control.TextColor3 = Color3.fromRGB(121, 156, 239)
        control.TextXAlignment = Enum.TextXAlignment.Left
        return control
    end

    local function textInput(placeholder, initial)
        local control = create("TextBox", {
            LayoutOrder = nextOrder(),
            Size = UDim2.new(1, -4, 0, 38),
            BackgroundColor3 = Color3.fromRGB(35, 42, 58),
            BorderSizePixel = 0,
            ClearTextOnFocus = false,
            Font = Enum.Font.Gotham,
            PlaceholderText = placeholder,
            Text = tostring(initial or ""),
            TextColor3 = Color3.fromRGB(244, 247, 255),
            PlaceholderColor3 = Color3.fromRGB(136, 146, 170),
            TextSize = 13,
            Parent = content,
        })
        create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = control})
        return control
    end

    local refreshControls = {}
    local function toggle(text, getter, setter)
        local control = create("TextButton", {
            LayoutOrder = nextOrder(),
            Size = UDim2.new(1, -4, 0, 38),
            BackgroundColor3 = Color3.fromRGB(35, 42, 58),
            BorderSizePixel = 0,
            Font = Enum.Font.GothamSemibold,
            TextColor3 = Color3.fromRGB(248, 250, 255),
            TextSize = 13,
            Parent = content,
        })
        create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = control})
        local function refresh()
            local enabled = getter() == true
            control.Text = text .. ": " .. (enabled and "ON" or "OFF")
            control.BackgroundColor3 = enabled and Color3.fromRGB(55, 137, 96) or Color3.fromRGB(35, 42, 58)
        end
        table.insert(refreshControls, refresh)
        table.insert(connections, control.Activated:Connect(function()
            run(text, function()
                local ok, result = setter(not getter())
                refresh()
                return ok, result
            end)
        end))
        refresh()
        return control
    end

    local function configToggle(text, key)
        return toggle(text, function()
            return tds:GetConfig()[key]
        end, function(value)
            return tds:Configure({[key] = value})
        end)
    end

    local function choice(text, values, getter, setter)
        local control
        control = button(text, function()
            local current = getter()
            local index = table.find(values, current) or 0
            local value = values[(index % #values) + 1]
            local ok, result = setter(value)
            control.Text = text .. ": " .. tostring(getter())
            return ok, result
        end)
        control.BackgroundColor3 = Color3.fromRGB(35, 42, 58)
        control.Text = text .. ": " .. tostring(getter())
        return control
    end

    section("Macros and Playback")

    button("Load Macro", function() return tds:LoadMacro(macroInput.Text) end)
    local selectedMacro
    local savedMacros = {}
    local savedMacroIndex = 0
    local savedMacroButton
    button("Refresh Saved Macros", function()
        local names, errorMessage = tds:ListMacros()
        savedMacros = names or {}
        savedMacroIndex = 0
        selectedMacro = nil
        savedMacroButton.Text = "Select Saved Macro: " .. (#savedMacros > 0 and "Click to cycle" or "None")
        return errorMessage == nil, errorMessage
    end)
    savedMacroButton = button("Select Saved Macro: None", function()
        if #savedMacros == 0 then return false, "Refresh the macro list first." end
        savedMacroIndex = (savedMacroIndex % #savedMacros) + 1
        selectedMacro = savedMacros[savedMacroIndex]
        macroInput.Text = selectedMacro
        savedMacroButton.Text = "Select Saved Macro: " .. selectedMacro
        return true
    end)
    savedMacroButton.BackgroundColor3 = Color3.fromRGB(35, 42, 58)
    button("Start Recording", function() return tds:StartRecording(macroInput.Text) end)
    button("Stop Recording", function() return tds:StopRecording() end)
    button("Clear Recording", function() return tds:ClearRecording() end)
    button("Save Macro", function() return tds:SaveMacro(macroInput.Text) end)
    button("Play Once", function() return tds:Play() end)
    toggle("Auto Replay", function() return tds:GetState().AutoReplay end, function(value) return tds:SetAutoReplay(value) end)
    button("Stop Playback", function() return tds:Stop() end)
    button("Start Matchmaking", function() return tds:StartMatchmaking() end)

    section("Replay Settings")
    configToggle("VIP Override", "VIPOverride")
    configToggle("Map Reroll", "MapReroll")
    configToggle("Loading Stall Recovery", "LoadingStallRecovery")
    configToggle("Use 2x Time Scale", "TimeScale2x")
    configToggle("Early Economy Actions", "EarlyEconomyActions")
    local loadingTimeout = textInput("Loading timeout in seconds", tds:GetConfig().LoadingStallTimeout)
    button("Apply Loading Timeout", function()
        return tds:Configure({LoadingStallTimeout = tonumber(loadingTimeout.Text)})
    end)
    button("Use Time Scale Ticket Now", function() return tds:UseTimeScaleTicket() end)

    section("Gameplay")
    configToggle("Anti AFK", "AntiAFK")
    configToggle("Auto Skip", "AutoSkip")
    configToggle("Simplify Map Visuals", "SimplifyMapVisuals")
    button("Auto Equip Inventory", function() return tds:AutoEquipInventory() end)
    button("Restore Previous Loadout", function() return tds:RestorePreviousLoadout() end)
    button("Skip Wave", function() return tds:SkipWave() end)

    section("Multiplayer")
    configToggle("Multiplayer Mode", "Multiplayer")
    configToggle("Party Host", "IsHost")
    choice("Player Count", {2, 3, 4}, function() return tds:GetConfig().PlayerCount end, function(value)
        return tds:Configure({PlayerCount = value})
    end)
    local hostDelay = textInput("Host delay in seconds", tds:GetConfig().HostDelay)
    button("Apply Host Delay", function() return tds:Configure({HostDelay = tonumber(hostDelay.Text)}) end)

    section("Modifiers")
    configToggle("Enable Modifier Voting", "ModifierVoting")
    for _, modifierName in ipairs(tds:GetModifiers()) do
        toggle(modifierName, function()
            return table.find(tds:GetConfig().Modifiers, modifierName) ~= nil
        end, function(enabled)
            local configured = tds:GetConfig().Modifiers
            local nextModifiers = {}
            for _, name in ipairs(configured) do
                if name ~= modifierName then table.insert(nextModifiers, name) end
            end
            if enabled then table.insert(nextModifiers, modifierName) end
            return tds:Configure({Modifiers = nextModifiers})
        end)
    end
    button("Vote Configured Modifiers", function() return tds:VoteModifiers() end)

    section("Timeline")
    local timelineLabel = label("No timeline loaded.", 140)
    timelineLabel.TextXAlignment = Enum.TextXAlignment.Left
    timelineLabel.TextYAlignment = Enum.TextYAlignment.Top
    local eventIndexInput = textInput("Timeline event index", "1")
    local eventTimeInput = textInput("New event time in seconds", "0")
    button("Refresh Timeline", function()
        local events = tds:GetTimeline()
        local lines = {}
        for index = 1, math.min(#events, 8) do
            local event = events[index]
            local time = tonumber(event.WaveElapsed or event.WaveTimer or event.Timestamp) or 0
            table.insert(lines, string.format("%d. %s | Wave %s | %.2fs", index, tostring(event.Action), tostring(event.Wave or "-"), time))
        end
        timelineLabel.Text = #lines > 0 and table.concat(lines, "\n") or "No timeline loaded."
        return true
    end)
    button("Set Timeline Event Time", function()
        return tds:SetEventTime(tonumber(eventIndexInput.Text), tonumber(eventTimeInput.Text))
    end)
    local macroJsonInput = textInput("Macro JSON for import or export", "")
    button("Import Macro JSON", function()
        return tds:ImportMacro(macroJsonInput.Text, macroInput.Text)
    end)
    button("Export Macro JSON", function()
        local json, errorMessage = tds:ExportMacro(true)
        if not json then return false, errorMessage end
        macroJsonInput.Text = json
        local clipboard = type(setclipboard) == "function" and setclipboard or type(toclipboard) == "function" and toclipboard
        if clipboard then pcall(clipboard, json) end
        return true
    end)

    section("Game and Recording Information")
    local gameInfoLabel = label("Game information unavailable.", 90)
    gameInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
    local recordingLogLabel = label("No recording log.", 140)
    recordingLogLabel.TextXAlignment = Enum.TextXAlignment.Left
    recordingLogLabel.TextYAlignment = Enum.TextYAlignment.Top
    button("Refresh Game Information", function()
        local info = tds:GetGameInfo()
        gameInfoLabel.Text = string.format(
            "Map: %s\nMode: %s\nDifficulty: %s\nWave: %s\nTimer: %s",
            tostring(info.Map), tostring(info.Mode), tostring(info.Difficulty),
            tostring(info.Wave), tostring(info.WaveTime)
        )
        return true
    end)
    button("Refresh Recording Log", function()
        local logs = tds:GetRecordingLog()
        recordingLogLabel.Text = #logs > 0 and table.concat(logs, "\n") or "No recording log."
        return true
    end)

    section("Statistics")
    local statsLabel = label("No statistics loaded.", 170)
    statsLabel.TextXAlignment = Enum.TextXAlignment.Left
    statsLabel.TextYAlignment = Enum.TextYAlignment.Top
    local function refreshStats()
        local data = tds:GetStats()
        local rates = data.Rates or {}
        statsLabel.Text = string.format(
            "Rounds: %s\nCoins gained: %s\nGems gained: %s\nPlay seconds: %s\nCoins/hour: %.1f\nGems/hour: %.1f\nRetried: %s\nSkipped: %s\nMap rerolls: %s",
            tostring(data.Rounds or 0), tostring(data.CoinsGained or 0), tostring(data.GemsGained or 0),
            tostring(data.PlaySeconds or 0), tonumber(rates.CoinsPerHour) or 0, tonumber(rates.GemsPerHour) or 0,
            tostring(data.ActionsRetried or 0), tostring(data.ActionsSkipped or 0), tostring(data.MapRerolls or 0)
        )
    end
    button("Refresh Statistics", function()
        local ok, result = tds:RefreshStats()
        refreshStats()
        return ok, result
    end)
    button("Reconcile Pending Round", function() return tds:ReconcilePendingRound(15) end)
    button("Reset Statistics", function()
        local ok, result = tds:ResetStats()
        refreshStats()
        return ok, result
    end)

    section("Webhooks")
    local webhookInput = textInput("Discord webhook URL", tds:GetConfig().WebhookURL)
    button("Apply Webhook URL", function() return tds:Configure({WebhookURL = webhookInput.Text}) end)
    local webhookLogoInput = textInput("Webhook logo URL", tds:GetConfig().WebhookLogoURL)
    button("Apply Webhook Logo", function() return tds:Configure({WebhookLogoURL = webhookLogoInput.Text}) end)
    configToggle("Enable Webhooks", "WebhookEnabled")
    local webhookRateInput = textInput("Webhook rate limit", tds:GetConfig().WebhookRateLimit)
    button("Apply Webhook Rate Limit", function() return tds:Configure({WebhookRateLimit = tonumber(webhookRateInput.Text)}) end)
    for _, eventName in ipairs({"Disconnect", "MatchResult", "LoadingScreenBroke", "LoadingRejoinFailed"}) do
        toggle("Webhook " .. eventName, function()
            return tds:GetConfig().WebhookEvents[eventName]
        end, function(enabled)
            return tds:Configure({WebhookEvents = {[eventName] = enabled}})
        end)
    end
    button("Send Test Webhook", function() return tds:SendTestWebhook() end)

    section("Settings and Diagnostics")
    button("Save Settings", function() return tds:SaveSettings() end)
    button("Load Settings", function()
        local ok, result = tds:LoadSettings()
        for _, refresh in ipairs(refreshControls) do refresh() end
        return ok, result
    end)
    local telemetryLabel = label("No telemetry collected.", 90)
    telemetryLabel.TextXAlignment = Enum.TextXAlignment.Left
    button("Refresh Telemetry", function()
        local data = tds:GetTelemetry()
        telemetryLabel.Text = string.format(
            "Actions: %s\nRetried: %s\nSkipped: %s\nFatal error: %s",
            tostring(data.TotalActions or 0), tostring(data.Retried or 0),
            tostring(data.Skipped or 0), tostring(data.FatalError or "None")
        )
        return true
    end)

    local dragging = false
    local dragStart
    local startPosition
    table.insert(connections, header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = panel.Position
        end
    end))
    table.insert(connections, header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            panel.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end))

    table.insert(connections, tds:On("Notification", function(message)
        show(tostring(message.Title) .. ": " .. tostring(message.Content))
    end))
    table.insert(connections, tds:On("StatusChanged", show))
    table.insert(connections, tds:On("StateChanged", render))
    table.insert(connections, tds:On("TimelineChanged", function() render() end))
    table.insert(connections, tds:On("RecordingLog", function(logs)
        recordingLogLabel.Text = #logs > 0 and table.concat(logs, "\n") or "No recording log."
    end))
    table.insert(connections, tds:On("StatsChanged", function()
        refreshStats()
    end))
    table.insert(connections, tds:On("ConfigChanged", function()
        for _, refresh in ipairs(refreshControls) do pcall(refresh) end
    end))
    table.insert(connections, tds:On("Error", function(problem)
        show("Runtime error: " .. tostring(problem.Message))
    end))

    function controller:Destroy(destroyLibrary)
        if closed then return end
        closed = true
        if destroyLibrary ~= false and options.DestroyLibraryOnClose ~= false then
            tds:Destroy()
        end
        for _, connection in ipairs(connections) do
            pcall(function() connection:Disconnect() end)
        end
        table.clear(connections)
        if gui.Parent then gui:Destroy() end
    end

    function controller:SetVisible(visible)
        if not closed then gui.Enabled = visible == true end
    end

    function controller:GetGui()
        return gui
    end

    table.insert(connections, closeButton.Activated:Connect(function()
        controller:Destroy(true)
    end))
    table.insert(connections, gui.Destroying:Connect(function()
        if not closed then controller:Destroy(true) end
    end))

    local started, startResult = tds:Start()
    if not started then
        controller:Destroy(true)
        return nil, startResult
    end
    render(startResult)
    refreshStats()
    for _, refresh in ipairs(refreshControls) do pcall(refresh) end
    show("TDS Pro is ready.")
    return controller
end

return DefaultUI
