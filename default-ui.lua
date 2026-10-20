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

    button("Load Macro", function() return tds:LoadMacro(macroInput.Text) end)
    button("Start Recording", function() return tds:StartRecording(macroInput.Text) end)
    button("Stop Recording", function() return tds:StopRecording() end)
    button("Save Macro", function() return tds:SaveMacro(macroInput.Text) end)
    button("Play Once", function() return tds:Play() end)
    button("Start Auto Replay", function() return tds:SetAutoReplay(true) end)
    button("Stop Playback", function() return tds:Stop() end)
    button("Auto Equip Inventory", function() return tds:AutoEquipInventory() end)
    button("Restore Previous Loadout", function() return tds:RestorePreviousLoadout() end)
    button("Skip Wave", function() return tds:SkipWave() end)

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
    show("TDS Pro is ready.")
    return controller
end

return DefaultUI
