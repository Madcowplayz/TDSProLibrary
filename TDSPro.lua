local TDSPro = { Version = "4.0.0" }

function TDSPro.new(options)
   local api = {}
   local internal = {}
   local lifecycle = {
      Started = false, Destroyed = false, Status = "Idle",
      Connections = {}, Threads = {}, Listeners = {}, RawTask = task,
   }

   local function libraryCopy(value, seen)
      if type(value) ~= "table" then return value end
      seen = seen or {}
      if seen[value] then return seen[value] end
      local copy = {}
      seen[value] = copy
      for key, item in pairs(value) do copy[libraryCopy(key, seen)] = libraryCopy(item, seen) end
      return copy
   end

   local function libraryEmit(eventName, payload)
      local listeners = lifecycle.Listeners[eventName]
      if not listeners then return end
      local snapshot = {}
      for connection in pairs(listeners) do table.insert(snapshot, connection) end
      for _, connection in ipairs(snapshot) do
         if connection.Connected then
            local ok, err = pcall(connection.Callback, libraryCopy(payload))
            if not ok then warn("[TDSPro] " .. eventName .. " listener failed: " .. tostring(err)) end
         end
      end
   end

   local function libraryCheckStarted()
      if lifecycle.Destroyed then return false, "This TDSPro instance has been destroyed." end
      if not lifecycle.Started then return false, "Call Start() before this operation." end
      return true
   end

   local function libraryConnect(signal, callback)
      local connection = signal:Connect(function(...)
         if not lifecycle.Destroyed then callback(...) end
      end)
      table.insert(lifecycle.Connections, connection)
      return connection
   end

   local function librarySchedule(mode, delaySeconds, callback, ...)
      if lifecycle.Destroyed then return nil end
      local arguments = table.pack(...)
      local thread = coroutine.create(function()
         local current = coroutine.running()
         local ok, err = xpcall(function()
            callback(table.unpack(arguments, 1, arguments.n))
         end, function(message) return debug.traceback(tostring(message), 2) end)
         lifecycle.Threads[current] = nil
         if not ok and not lifecycle.Destroyed then
            warn("[TDSPro] Background task failed: " .. tostring(err))
            libraryEmit("Error", {Message = tostring(err)})
         end
      end)
      lifecycle.Threads[thread] = true
      if mode == "delay" then
         lifecycle.RawTask.delay(delaySeconds, thread)
      else
         lifecycle.RawTask[mode](thread)
      end
      return thread
   end

   local task = {
      wait = lifecycle.RawTask.wait,
      cancel = lifecycle.RawTask.cancel,
      spawn = function(callback, ...) return librarySchedule("spawn", 0, callback, ...) end,
      defer = function(callback, ...) return librarySchedule("defer", 0, callback, ...) end,
      delay = function(seconds, callback, ...) return librarySchedule("delay", seconds, callback, ...) end,
   }

   local Players = game:GetService("Players")
   local UserInputService = game:GetService("UserInputService")
   local VirtualUser = game:GetService("VirtualUser")
   local ReplicatedStorage = game:GetService("ReplicatedStorage")
   local HttpService = game:GetService("HttpService")
   local TeleportService = game:GetService("TeleportService")
   local TDS_PUBLIC_START_PLACE_ID = 3260590327

   local LocalPlayer = Players.LocalPlayer
   local tableUnpack = table.unpack or unpack
   local traceback = (debug and debug.traceback) or function(err) return tostring(err) end

   function internal.packValues(...)
      return { n = select("#", ...), ... }
   end

   function internal.unpackValues(values)
      return tableUnpack(values, 1, values.n or #values)
   end

   function internal.clearTable(target)
      if type(target) ~= "table" then return end
      if table.clear then
         table.clear(target)
         return
      end
      for key in pairs(target) do
         target[key] = nil
      end
   end

   function internal.safeReadValue(obj, defaultValue)
      if typeof(obj) ~= "Instance" then return defaultValue end
      local success, value = pcall(function() return obj.Value end)
      if success and value ~= nil then return value end
      return defaultValue
   end

   function internal.coerceNumber(value)
      if type(value) == "number" then return value end
      if type(value) == "string" then
         local text = tostring(value)
         local direct = tonumber(text)
         if direct then return direct end
         local minutes, seconds = string.match(text, "^%s*(%d+):(%d+%.?%d*)")
         if minutes and seconds then
            return (tonumber(minutes) * 60) + tonumber(seconds)
         end
         local normalized = text:gsub("[,%s]", "")
         local matched, suffix = string.match(normalized, "(%-?%d+%.?%d*)([kKmMbB]?)")
         if matched then
            local numeric = tonumber(matched)
            if not numeric then return nil end
            suffix = string.lower(suffix or "")
            if suffix == "k" then return numeric * 1000 end
            if suffix == "m" then return numeric * 1000000 end
            if suffix == "b" then return numeric * 1000000000 end
            return numeric
         end
      end
      return nil
   end

   function internal.readInstanceNumber(obj, names)
      if typeof(obj) ~= "Instance" then return nil end

      local fallback = nil
      local value = internal.coerceNumber(internal.safeReadValue(obj, nil))
      if value ~= nil and value ~= 0 then return value end
      if value ~= nil then fallback = value end

      local success, text = pcall(function() return obj.Text end)
      value = success and internal.coerceNumber(text) or nil
      if value ~= nil and value ~= 0 then return value end
      if value ~= nil and fallback == nil then fallback = value end

      if type(names) == "table" then
         for _, name in ipairs(names) do
            local attrSuccess, attrValue = pcall(function() return obj:GetAttribute(name) end)
            value = attrSuccess and internal.coerceNumber(attrValue) or nil
            if value ~= nil and value ~= 0 then return value end
            if value ~= nil and fallback == nil then fallback = value end
         end

         for _, name in ipairs(names) do
            local child = obj:FindFirstChild(name)
            if child then
               value = internal.coerceNumber(internal.safeReadValue(child, nil))
               if value ~= nil and value ~= 0 then return value end
               if value ~= nil and fallback == nil then fallback = value end
               local childTextSuccess, childText = pcall(function() return child.Text end)
               value = childTextSuccess and internal.coerceNumber(childText) or nil
               if value ~= nil and value ~= 0 then return value end
               if value ~= nil and fallback == nil then fallback = value end
            end
         end
      end

      return fallback
   end

   function internal.safeWaitForChild(parent, childName, timeout)
      if typeof(parent) ~= "Instance" then return nil end
      local success, child = pcall(function()
         return parent:WaitForChild(childName, timeout or 5)
      end)
      if success then return child end
      return nil
   end

   function internal.refreshLocalPlayer()
      LocalPlayer = Players.LocalPlayer or LocalPlayer
      return LocalPlayer
   end

   function internal.hasGameGui(playerGui)
      if typeof(playerGui) ~= "Instance" then return false end
      for _, child in ipairs(playerGui:GetChildren()) do
         if child:IsA("ScreenGui") and child.Name ~= "TDSProStatsHUD" then
            return true
         end
      end
      return false
   end

   function internal.waitForTDSClientReady(timeout)
      local deadline = os.clock() + (timeout or 35)

      while not game:IsLoaded() and os.clock() < deadline do
         task.wait(0.1)
      end

      local player = internal.refreshLocalPlayer()
      while not player and os.clock() < deadline do
         task.wait(0.1)
         player = internal.refreshLocalPlayer()
      end

      local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
      while player and not playerGui and os.clock() < deadline do
         task.wait(0.1)
         playerGui = player:FindFirstChildOfClass("PlayerGui")
      end

      local guiSeenAt = nil
      while playerGui and os.clock() < deadline do
         if internal.hasGameGui(playerGui) then
            guiSeenAt = guiSeenAt or os.clock()

            if os.clock() - guiSeenAt >= 3 then
               break
            end
         else
            guiSeenAt = nil
         end
         task.wait(0.1)
      end

      local remaining = deadline - os.clock()
      if remaining > 0 and not ReplicatedStorage:FindFirstChild("RemoteEvent") then
         internal.safeWaitForChild(ReplicatedStorage, "RemoteEvent", math.min(5, remaining))
      end

      remaining = deadline - os.clock()
      if remaining > 0 and not ReplicatedStorage:FindFirstChild("RemoteFunction") then
         internal.safeWaitForChild(ReplicatedStorage, "RemoteFunction", math.min(5, remaining))
      end

      return player, playerGui
   end

   function internal.safeIndex(root, ...)
      local current = root
      for index = 1, select("#", ...) do
         if current == nil then return nil end
         local key = select(index, ...)
         local success, value = pcall(function() return current[key] end)
         if not success then return nil end
         current = value
      end
      return current
   end

   function internal.safeSetParagraph(paragraph, data)
      if paragraph and type(paragraph.Set) == "function" then
         pcall(function() paragraph:Set(data) end)
      end
   end

   function internal.toBooleanFlag(value, defaultValue)
      if type(value) == "boolean" then return value end
      if type(value) == "number" then return value ~= 0 end
      if type(value) == "string" then
         local text = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
         if text == "true" or text == "on" or text == "yes" or text == "1" then return true end
         if text == "false" or text == "off" or text == "no" or text == "0" or text == "" then return false end
      end
      return defaultValue == true
   end

   function internal.safeToggleCallback(name, callback)
      local success, err = xpcall(callback, traceback)
      if not success then
         warn("[TDSPro] " .. tostring(name) .. " callback failed: " .. tostring(err))
      end
   end

   function internal.tryGetPlayerStatValue(statName)
      local player = LocalPlayer or Players.LocalPlayer
      if not player then return nil, false end
      local statObj = player:FindFirstChild(statName)
      if not statObj then
         local leaderstats = player:FindFirstChild("leaderstats")
         if leaderstats then
            statObj = leaderstats:FindFirstChild(statName)
         end
      end
      if not statObj then return nil, false end

      local value = tonumber(internal.safeReadValue(statObj, nil))
      if value == nil then return nil, false end
      return value, true
   end

   function internal.getPlayerStatValue(statName)
      local value = internal.tryGetPlayerStatValue(statName)
      return tonumber(value) or 0
   end

   function internal.getPlayerExperienceValue()
      for _, statName in ipairs({"EXP", "XP", "Experience", "Exp"}) do
         local value, available = internal.tryGetPlayerStatValue(statName)
         if available then return math.max(0, tonumber(value) or 0), true end
      end
      return 0, false
   end

   local antiAFKEnabled = false

   local currentMacroName = "default_macro"
   local isRecording = false
   local isPlayingMacro = false
   local recordingArmedAt = 0
   local recordingTimerStarted = false
   local recordedTimeline = {}
   local recordedEventCounter = 0
   local recordedTroopCounter = 0
   local recordedTowerIdsByInstance = {}
   local recordedPlaceDetailsByTroopId = {}
   local recordedUpgradeStateByTower = {}
   local recordingRuntime = {
      NextSessionId = 0,
      ActiveSession = nil,
   }
   local playbackTowerIdsByMacroId = {}
   local recordingWatch = {
      Token = nil,
      LastWave = 0,
      LastTimer = nil,
      AnchorAt = nil,
      AnchorSource = nil,
      ReadyPromptSeen = false,
      DebugEnabled = false,
      LastDebugAt = 0,
      WaveStartTimes = {}
   }
   local macroFolderName = "TDSProMacros"
   local macroFileExtension = ".txt"
   local selectedMacroName = nil
   local macroPathsByName = {}
   local macroDirectoryError = nil
   local MacroDropdown = nil
   local AutoReplayToggle = nil
   local skipCurrentWave = nil
   local macroRuntime = {
      SourceFormat = "TDSPro",
      SourceLabel = nil,
      CustomFlags = {},
      AutoSkipToken = 0,
      SyncingDropdown = false,
      LastUpgradeAttemptAt = 0,
      PlaybackTaskActive = false,
   }

   local UPGRADE_MIN_ATTEMPT_GAP = 0.3
   local UPGRADE_CONFIRM_TIMEOUT = 1
   local ECONOMY_RETRY_INTERVAL = 0.5
   local ECONOMY_RETRY_TIMEOUT = 45
   local RECORDING_CONFIRM_TIMEOUT = 5
   local RECORDING_UPGRADE_SETTLE_TIMEOUT = 0.75
   local RECORDING_UPGRADE_LANE_TIMEOUT = 10
   local RECORDING_RESPONSE_TIMEOUT = 8
   local RECORDING_STOP_DRAIN_TIMEOUT = 10
   local RECORDING_PLACE_MATCH_DISTANCE = 2

   local detectedGameInfo = {}
   local loadedMacroMeta = {}

   local recordingLogLines = {}
   local MAX_LOG_LINES = 12
   local RecordingLogParagraph = nil
   local GameInfoParagraph = nil
   local TimelineUI = {
      Events = {},
   }

   local PendingLogs = {}
   local PendingLogRefresh = false

   local autoReplayEnabled = false
   local autoReplayRunning = false
   local autoReplayRuns = 0
   local ReplayStatusParagraph = nil
   local updateReplayStatus = nil
   local isVotingLobbyReady = nil
   local VIPOverrideEnabled = false
   local MapRerollEnabled = false
   local loadingStallRecoveryEnabled = true
   local loadingStallTimeout = 90
   local timeScaleEnabled = false
   local timeScaleActiveForRun = false
   local earlyEconomyActionsEnabled = false
   local modifierVotingEnabled = false
   local standaloneAutoSkipEnabled = false
   local standaloneAutoSkipToken = 0
   local selectedModifierOptions = {}
   local modifierOptionFlags = {
      ["Exploding Enemies"] = "ExplodingEnemies",
      ["Limitation"] = "Limitation",
      ["Hidden Enemies"] = "HiddenEnemies",
      ["Glass"] = "Glass",
      ["Jailed"] = "Jailed",
      ["Committed"] = "Committed",
      ["Healthy Enemies"] = "HealthyEnemies",
      ["Speedy Enemies"] = "SpeedyEnemies",
      ["Fog"] = "Fog",
      ["Flying Enemies"] =  "FlyingEnemies",
      ["Broke"] = "Broke",
      ["Quarantine"] = "Quarantine",
      ["Inflation"] = "Inflation",
      ["Weekend"] = "Weekend",
      ["Sandbox Unlocks"] = "SandboxUnlocks"
   }
   local skipSync = {
      StartSkipAt = nil
   }
   local multiplayerEnabled = false
   local playerCount = 2
   local isHost = true
   local hostDelayVal = 5
   local webhookUrl = ""
   local webhookLogoUrl = ""
   local webhookEnabled = false
   recordingRuntime.WebhookConfig = {
      RateLimit = 2,
      Events = {
         Disconnect = true,
         MatchResult = true,
         LoadingScreenBroke = true,
         LoadingRejoinFailed = true,
      },
   }
   recordingRuntime.IntentionalTransitionUntil = 0
   recordingRuntime.IntentionalTransitionReason = nil
   local initialCoins = 0
   local initialGems = 0
   local statsFileName = macroFolderName .. "/stats.json"
   local currentMatchStartClock = nil
   local currentMatchStartedAt = nil
   local matchStatsBaselineCaptured = false
   local minimumValidMatchSeconds = 10
   local maximumValidMatchSeconds = 6 * 60 * 60
   local savedStats = {
      SchemaVersion = 7,
      StartedAt = os.time(),
      Rounds = 0,
      CoinsGained = 0,
      GemsGained = 0,
      PlaySeconds = 0,
      ActionsRetried = 0,
      ActionsSkipped = 0,
      MapRerolls = 0,
      DeliveryQueue = {},
      LastKnownBalances = {
         Coins = 0,
         Gems = 0,
         HasCoins = false,
         HasGems = false,
         UpdatedAt = 0,
      },
   }
   local statsLoaded = false


   function internal.safeUINotify(title, content, duration, image)
      libraryEmit("Notification", {Title = title, Content = content, Duration = duration or 3, Image = image})
   end

   function internal.notifyMacro(content, duration)
      internal.safeUINotify("TDSPro Macro", content, duration or 3, 4483362458)
   end

   function internal.trimMacroName(name)
      local text = tostring(name or "")
      text = text:gsub("^%s+", ""):gsub("%s+$", "")
      return text
   end

   function internal.sanitizeMacroFilename(name)
      local text = internal.trimMacroName(name)
      text = text:gsub("%.[Tt][Xx][Tt]$", "")
      text = text:gsub("%.[Jj][Ss][Oo][Nn]$", "")
      text = text:gsub("[\\/:*?\"<>|]", "_")
      text = text:gsub("%.%.", "_")
      text = text:gsub("^%.+", "")
      if text == "" then text = "default_macro" end
      return text
   end

   function internal.ensureMacroFolder()
      if type(isfolder) == "function" then
         local existsSuccess, exists = pcall(function() return isfolder(macroFolderName) end)
         if existsSuccess and exists then return true end
      end
      if type(makefolder) ~= "function" then
         return false, "Your executor does not support folder creation."
      end
      local createSuccess, createError = pcall(function() makefolder(macroFolderName) end)
      if createSuccess then return true end
      if type(isfolder) == "function" then
         local existsSuccess, exists = pcall(function() return isfolder(macroFolderName) end)
         if existsSuccess and exists then return true end
      end
      return false, tostring(createError)
   end

   function internal.getMacroPath(macroName)
      return macroFolderName .. "/" .. internal.sanitizeMacroFilename(macroName) .. macroFileExtension
   end

   function internal.getFileNameFromPath(path)
      local normalizedPath = tostring(path):gsub("\\", "/")
      return normalizedPath:match("[^/]+$") or normalizedPath
   end

   function internal.getSavedMacroNames()
      internal.clearTable(macroPathsByName)
      macroDirectoryError = nil
      local macros = {}
      local folderReady, folderError = internal.ensureMacroFolder()
      if not folderReady then
         macroDirectoryError = "Could not open " .. macroFolderName .. ": " .. tostring(folderError)
         return macros
      end
      if type(listfiles) ~= "function" then
         macroDirectoryError = "Your executor does not support listfiles()."
         return macros
      end
      local folders = { macroFolderName, "AutoTDS" }
      for folderIndex, folderName in ipairs(folders) do
         local listSuccess, files = pcall(function() return listfiles(folderName) end)
         if folderIndex == 1 and (not listSuccess or type(files) ~= "table") then
            macroDirectoryError = "Could not list files in " .. macroFolderName .. "."
            return macros
         end
         if listSuccess and type(files) == "table" then
            for _, filePath in ipairs(files) do
               local fileName = internal.getFileNameFromPath(filePath)
               local macroName = fileName:match("(.+)%.[Tt][Xx][Tt]$") or fileName:match("(.+)%.[Jj][Ss][Oo][Nn]$")
               if macroName and not (folderIndex == 1 and (string.lower(fileName) == "stats.json" or string.lower(fileName) == "settings.json")) then
                  local displayName = folderIndex == 1 and macroName or (folderName .. "/" .. macroName)
                  table.insert(macros, displayName)
                  macroPathsByName[displayName] = filePath
               end
            end
         end
      end
      table.sort(macros, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
      return macros
   end

   function internal.refreshMacroDropdown(showNotification)
      local macros = internal.getSavedMacroNames()
      if MacroDropdown and type(MacroDropdown.Refresh) == "function" then
         pcall(function() MacroDropdown:Refresh(macros) end)
      end
      local selectedStillExists = false
      for _, macroName in ipairs(macros) do
         if macroName == selectedMacroName then
            selectedStillExists = true
            break
         end
      end
      if not selectedStillExists and not macroDirectoryError then
         selectedMacroName = macros[1]
      end
      if selectedMacroName and MacroDropdown and type(MacroDropdown.Set) == "function" then
         macroRuntime.SyncingDropdown = true
         pcall(function() MacroDropdown:Set({ selectedMacroName }) end)
         macroRuntime.SyncingDropdown = false
      end
      if showNotification then
         if macroDirectoryError then
            internal.notifyMacro(macroDirectoryError, 3)
         elseif #macros > 0 then
            internal.notifyMacro("Found " .. #macros .. " macro(s) across " .. macroFolderName .. " and AutoTDS.", 3)
         else
            internal.notifyMacro("No macros found in " .. macroFolderName .. " or AutoTDS yet.", 3)
         end
      end
      return macros
   end

   function internal.getInstancePath(instance)
      if typeof(instance) ~= "Instance" then return nil end
      local path = {}
      local current = instance
      while current and current ~= game do
         table.insert(path, 1, current.Name)
         current = current.Parent
      end
      return path
   end

   function internal.resolveInstancePath(path)
      if type(path) ~= "table" or #path == 0 then return nil end
      local current
      local serviceSuccess, service = pcall(function() return game:GetService(path[1]) end)
      if serviceSuccess and service then
         current = service
      else
         current = game:FindFirstChild(path[1])
      end
      for index = 2, #path do
         if not current then return nil end
         current = current:FindFirstChild(path[index])
      end
      return current
   end

   function internal.encodeValue(value, depth)
      depth = depth or 0
      if depth > 8 then
         return { Type = "Unsupported", ValueType = typeof(value), Value = "Max depth reached" }
      end
      local valueType = typeof(value)
      if valueType == "nil" then
         return { Type = "nil" }
      elseif valueType == "string" or valueType == "number" or valueType == "boolean" then
         return { Type = valueType, Value = value }
      elseif valueType == "Vector2" then
         return { Type = "Vector2", Value = { X = value.X, Y = value.Y } }
      elseif valueType == "Vector3" then
         return { Type = "Vector3", Value = { X = value.X, Y = value.Y, Z = value.Z } }
      elseif valueType == "CFrame" then
         return { Type = "CFrame", Value = { value:GetComponents() } }
      elseif valueType == "Color3" then
         return { Type = "Color3", Value = { R = value.R, G = value.G, B = value.B } }
      elseif valueType == "EnumItem" then
         return { Type = "EnumItem", EnumType = tostring(value.EnumType):gsub("^Enum%.", ""), Name = value.Name }
      elseif valueType == "Instance" then
         return { Type = "Instance", Path = internal.getInstancePath(value), Name = value.Name }
      elseif valueType == "table" then
         local entries = {}
         for key, childValue in pairs(value) do
            table.insert(entries, { Key = internal.encodeValue(key, depth + 1), Value = internal.encodeValue(childValue, depth + 1) })
         end
         return { Type = "table", Value = entries }
      end
      return { Type = "Unsupported", ValueType = valueType, Value = tostring(value) }
   end

   function internal.decodeValue(encoded)
      if type(encoded) ~= "table" or not encoded.Type then return encoded end
      local valueType = encoded.Type
      if valueType == "nil" then
         return nil
      elseif valueType == "string" or valueType == "number" or valueType == "boolean" then
         return encoded.Value
      elseif valueType == "Vector2" and type(encoded.Value) == "table" then
         local success, value = pcall(function()
            return Vector2.new(tonumber(encoded.Value.X) or 0, tonumber(encoded.Value.Y) or 0)
         end)
         if success then return value end
      elseif valueType == "Vector3" and type(encoded.Value) == "table" then
         local success, value = pcall(function()
            return Vector3.new(tonumber(encoded.Value.X) or 0, tonumber(encoded.Value.Y) or 0, tonumber(encoded.Value.Z) or 0)
         end)
         if success then return value end
      elseif valueType == "CFrame" and type(encoded.Value) == "table" then
         local success, value = pcall(function() return CFrame.new(tableUnpack(encoded.Value)) end)
         if success then return value end
         return CFrame.new(0, 0, 0)
      elseif valueType == "Color3" and type(encoded.Value) == "table" then
         local success, value = pcall(function()
            return Color3.new(tonumber(encoded.Value.R) or 0, tonumber(encoded.Value.G) or 0, tonumber(encoded.Value.B) or 0)
         end)
         if success then return value end
      elseif valueType == "EnumItem" then
         local enumType = nil
         if encoded.EnumType then
            local s, r = pcall(function() return Enum[encoded.EnumType] end)
            if s then enumType = r end
         end
         if enumType then
            local s, r = pcall(function() return enumType[encoded.Name] end)
            if s then return r end
         end
      elseif valueType == "Instance" then
         return internal.resolveInstancePath(encoded.Path)
      elseif valueType == "table" and type(encoded.Value) == "table" then
         local decodedTable = {}
         for _, entry in ipairs(encoded.Value) do
            local key = internal.decodeValue(entry.Key)
            if key ~= nil then decodedTable[key] = internal.decodeValue(entry.Value) end
         end
         return decodedTable
      end
      return nil
   end

   function internal.encodeRemoteCall(method, remote, args)
      local count = type(args) == "table" and (tonumber(args.n) or #args) or 0
      local encodedArgs = {n = count}
      for index = 1, count do
         encodedArgs[index] = internal.encodeValue(args[index], 0)
      end
      return { Method = method, Path = internal.getInstancePath(remote), Args = encodedArgs }
   end

   function internal.decodeRemoteArgs(encodedArgs)
      local args = {n = 0}
      if type(encodedArgs) ~= "table" then return args end
      local count = tonumber(encodedArgs.n) or #encodedArgs
      args.n = count
      for index = 1, count do
         args[index] = internal.decodeValue(encodedArgs[index])
      end
      return args
   end

   function internal.makeVector3Value(x, y, z)
      if vector and type(vector.create) == "function" then
         local success, value = pcall(function()
            return vector.create(x, y, z)
         end)
         if success and value then return value end
      end
      return Vector3.new(x, y, z)
   end

   function internal.getVector3Components(value)
      if not value then return nil end
      local success, x, y, z = pcall(function()
         local vt = typeof(value)
         if vt == "Vector3" then return value.X, value.Y, value.Z
         elseif vt == "Vector2" then return value.X, value.Y, 0 end
         local gx, gy, gz = value.X, value.Y, value.Z
         if gx and gy and gz then return gx, gy, gz end
      end)
      if success and x ~= nil and y ~= nil and z ~= nil then
         local nx, ny, nz = tonumber(x), tonumber(y), tonumber(z)
         if nx and ny and nz then return nx, ny, nz end
      end
      if type(value) == "table" then
         x = value.X or value.x or value[1]
         y = value.Y or value.y or value[2]
         z = value.Z or value.z or value[3]
         if x and y and z then return tonumber(x), tonumber(y), tonumber(z) end
      end
      return nil
   end

   function internal.getVectorDistance(a, b)
      local ax, ay, az = internal.getVector3Components(a)
      local bx, by, bz = internal.getVector3Components(b)
      if not ax or not bx then return nil end
      local dx = ax - bx
      local dy = ay - by
      local dz = az - bz
      return math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
   end

   function internal.serializeVector3Value(value)
      local x, y, z = internal.getVector3Components(value)
      if not x then return nil end
      return { x, y, z }
   end

   function internal.deserializeVector3Value(value)
      local x, y, z = internal.getVector3Components(value)
      if not x then return nil end
      return internal.makeVector3Value(x, y, z)
   end

   function internal.serializeCFrameValue(value)
      if typeof(value) == "CFrame" then return { value:GetComponents() } end
      if type(value) == "table" then return value end
      return nil
   end

   function internal.deserializeCFrameValue(value)
      if typeof(value) == "CFrame" then return value end
      if type(value) == "number" then
         local success, cframe = pcall(function() return CFrame.Angles(0, value, 0) end)
         if success then return cframe end
      end
      if type(value) == "table" and tonumber(value.Yaw or value.yaw) then
         local success, cframe = pcall(function() return CFrame.Angles(0, tonumber(value.Yaw or value.yaw), 0) end)
         if success then return cframe end
      end
      if type(value) == "table" and #value >= 12 then
         local success, cframe = pcall(function() return CFrame.new(tableUnpack(value)) end)
         if success then return cframe end
      end
      return CFrame.new(0, 0, 0)
   end

   function internal.getTDSRemoteFunction()
      return ReplicatedStorage:WaitForChild("RemoteFunction", 5)
   end

   function internal.getTDSRemoteEvent()
      return ReplicatedStorage:WaitForChild("RemoteEvent", 5)
   end

   function internal.invokeTDSRemoteFunction(...)
      local remote = internal.getTDSRemoteFunction()
      if not remote then return false, "RemoteFunction was not found." end
      local args = { ... }
      local success, results = pcall(function()
         return internal.packValues(remote:InvokeServer(tableUnpack(args)))
      end)
      if not success then return false, tostring(results), nil end
      return true, results[1], results
   end

   function internal.classifyRemoteActionResult(result, packedResults)
      local resultType = type(result)
      local reason = nil
      local accepted = nil
      local reasonIsDiagnostic = false
      if result == false then
         accepted = false
      elseif result == true then
         accepted = true
      end

      if resultType == "table" then
         for _, key in ipairs({"Success", "success", "Accepted", "accepted", "Ok", "ok"}) do
            if type(result[key]) == "boolean" then
               accepted = result[key]
               break
            end
         end
         for _, key in ipairs({"Reason", "reason", "Error", "error", "Message", "message"}) do
            local fieldValue = result[key]
            if fieldValue ~= nil and fieldValue ~= false and tostring(fieldValue) ~= "" then
               reason = tostring(fieldValue)
               reasonIsDiagnostic = true
               break
            end
         end
      elseif resultType == "string" then
         reason = result
         reasonIsDiagnostic = result ~= ""
      elseif result ~= nil and resultType ~= "boolean" then
         return true, false, nil
      end

      if type(packedResults) == "table" then
         local resultCount = tonumber(packedResults.n) or #packedResults
         for index = 2, resultCount do
            local extra = packedResults[index]
            if extra == false then accepted = false end
            if reason == nil and type(extra) == "string" and extra ~= "" then
               reason = extra
               reasonIsDiagnostic = true
            elseif reason == nil and type(extra) == "table" then
               for _, key in ipairs({"Success", "success", "Accepted", "accepted", "Ok", "ok"}) do
                  if type(extra[key]) == "boolean" then
                     if extra[key] == false or accepted == nil then accepted = extra[key] end
                     break
                  end
               end
               for _, key in ipairs({"Reason", "reason", "Error", "error", "Message", "message"}) do
                  local fieldValue = extra[key]
                  if fieldValue ~= nil and fieldValue ~= false and tostring(fieldValue) ~= "" then
                     reason = tostring(fieldValue)
                     reasonIsDiagnostic = true
                     break
                  end
               end
            end
         end
      end

      if accepted == true then return true, false, nil end
      if result == nil and reason == nil then


         return true, false, nil
      end

      local normalizedReason = string.lower(tostring(reason or "")):gsub("^%s+", ""):gsub("%s+$", "")
      local economyRetryPatterns = {
         "money", "cash", "currency", "fund", "afford", "insufficient",
         "not enough", "cost", "price", "requires", "need ", "cooldown",
         "try again", "retry",
      }
      for _, pattern in ipairs(economyRetryPatterns) do
         if string.find(normalizedReason, pattern, 1, true) then
            return false, true, reason
         end
      end

      local terminalPatterns = {
         "invalid", "max level", "maximum level", "already max", "maxed",
         "fully upgraded", "not found", "does not exist", "not owned",
         "wrong owner", "wrong path", "invalid path", "invalid tower",
         "cannot upgrade", "can't upgrade",
      }
      for _, pattern in ipairs(terminalPatterns) do
         if string.find(normalizedReason, pattern, 1, true) then
            return false, false, reason ~= nil and reason or "the request is invalid"
         end
      end

      local retryablePatterns = {
         "rejected", "failed", "false",
      }
      for _, pattern in ipairs(retryablePatterns) do
         if string.find(normalizedReason, pattern, 1, true) then
            return false, true, reason
         end
      end

      if accepted == false then
         return false, true, reason ~= nil and reason or "the server rejected the request"
      end
      local acceptedMessages = {
         ["ok"] = true,
         ["true"] = true,
         ["success"] = true,
         ["successful"] = true,
         ["accepted"] = true,
         ["upgraded"] = true,
         ["placed"] = true,
         ["complete"] = true,
         ["completed"] = true,
         ["upgrade successful"] = true,
         ["place successful"] = true,
         ["placement successful"] = true,
         ["successfully upgraded"] = true,
         ["successfully placed"] = true,
         ["upgrade complete"] = true,
         ["upgrade completed"] = true,
         ["placement complete"] = true,
         ["placement completed"] = true,
      }
      if acceptedMessages[normalizedReason] then return true, false, nil end
      if reasonIsDiagnostic then
         return false, false, reason
      end
      return true, false, nil
   end

   function internal.fireTDSRemoteEvent(...)
      local remote = internal.getTDSRemoteEvent()
      if not remote then return false, "RemoteEvent was not found." end
      local args = { ... }
      local success, result = pcall(function() remote:FireServer(tableUnpack(args)) end)
      if not success then return false, tostring(result) end
      return true
   end

   function internal.getMacroPlaybackSpeed()
      return timeScaleActiveForRun and 2 or 1
   end

   function internal.adjustMacroPlaybackSeconds(seconds)
      return (tonumber(seconds) or 0) / internal.getMacroPlaybackSpeed()
   end

   function internal.unlockAndSetTimeScale2x()
      timeScaleActiveForRun = false

      local unlockSuccess, unlockResult = internal.invokeTDSRemoteFunction("TicketsManager", "UnlockTimeScale")
      if not unlockSuccess then
         return false, unlockResult
      end
      if unlockResult == false then
         return false, "The server rejected the time-scale ticket."
      end

      task.wait(0.15)
      for cycleIndex = 1, 2 do
         local cycleSuccess, cycleError = internal.fireTDSRemoteEvent("TicketsManager", "CycleTimeScale")
         if not cycleSuccess then
            return false, "Cycle " .. tostring(cycleIndex) .. " failed: " .. tostring(cycleError)
         end
         if cycleIndex < 2 then task.wait(0.15) end
      end

      timeScaleActiveForRun = true
      return true
   end

   function internal.invokeBulkVoteModifiers(args)
      local network = internal.safeWaitForChild(ReplicatedStorage, "Network", 5)
      if not network then return false, "Network folder was not found." end

      local modifiers = internal.safeWaitForChild(network, "Modifiers", 5)
      if not modifiers then return false, "Modifiers folder was not found." end

      local remote = internal.safeWaitForChild(modifiers, "RF:BulkVoteModifiers", 5)
      if not remote then return false, "RF:BulkVoteModifiers was not found." end

      local remoteArgs = type(args) == "table" and args or {}
      local success, result = pcall(function()
         return remote:InvokeServer(tableUnpack(remoteArgs))
      end)
      if not success then return false, tostring(result) end
      return true, result
   end

   function internal.getTowersFolder()
      return workspace:FindFirstChild("Towers") or workspace:FindFirstChild("PlacedTowers")
   end

   function internal.normalizeTowerInstance(instance)
      if typeof(instance) ~= "Instance" then return nil end
      local folder = internal.getTowersFolder()
      if not folder then return instance end
      local current = instance
      while current and current ~= workspace do
         if current.Parent == folder then return current end
         current = current.Parent
      end
      return instance
   end

   function internal.getTowerPosition(tower)
      local t = internal.normalizeTowerInstance(tower)
      if not t then return nil end
      if t:IsA("BasePart") then return t.Position end
      if t:IsA("Model") then


         local root = t.PrimaryPart or t:FindFirstChild("HumanoidRootPart", true) or
            t:FindFirstChildWhichIsA("BasePart", true)
         if root then return root.Position end
      end
      local part = t:FindFirstChildWhichIsA("BasePart", true)
      if part then return part.Position end
      return nil
   end

   function internal.getTowerSnapshot()
      local snapshot = {}
      local folder = internal.getTowersFolder()
      if not folder then return snapshot end
      for _, tower in ipairs(folder:GetChildren()) do
         snapshot[tower] = true
      end
      return snapshot
   end

   function internal.rememberTowerId(map, tower, troopId)
      local t = internal.normalizeTowerInstance(tower)
      if t and troopId then
         map[t] = troopId
         map[tower] = troopId
      end
      return t
   end

   function internal.getRememberedTowerId(map, tower)
      local t = internal.normalizeTowerInstance(tower)
      if not t then return nil end
      return map[t] or map[tower]
   end

   function internal.findNearestTowerToPosition(position, ignoredMap, beforeSnapshot)
      if not position then return nil end
      local folder = internal.getTowersFolder()
      if not folder then return nil end
      local bestTower, bestDistance = nil, nil
      for _, tower in ipairs(folder:GetChildren()) do
         if not (ignoredMap and ignoredMap[tower]) and not (beforeSnapshot and beforeSnapshot[tower]) then
            local tp = internal.getTowerPosition(tower)
            if tp then
               local distance = internal.getVectorDistance(tp, position)
               if distance and (not bestDistance or distance < bestDistance) then
                  bestTower = tower
                  bestDistance = distance
               end
            end
         end
      end
      if bestTower and (not bestDistance or bestDistance <= 12) then return bestTower end
      return nil
   end

   function internal.waitForPlacedTower(position, beforeSnapshot, returnedInstance)
      local returnedTower = internal.normalizeTowerInstance(returnedInstance)
      if returnedTower and typeof(returnedTower) == "Instance" and not (beforeSnapshot and beforeSnapshot[returnedTower]) then
         return returnedTower
      end
      for _ = 1, 20 do
         local tower = internal.findNearestTowerToPosition(position, nil, beforeSnapshot)
         if tower then return tower end
         task.wait(0.1)
      end
      return nil
   end

   function internal.createPlaceDetails(placementData, troopName, troopId, remoteData)
      local position, rotation = nil, nil
      if type(placementData) == "table" then
         position = internal.serializeVector3Value(placementData.Position)
         rotation = internal.serializeCFrameValue(placementData.Rotation)
      end
      local details = {
         Troop = tostring(troopName or ""),
         TroopId = troopId,
         Position = position,
         Rotation = rotation,
         Remote = remoteData
      }
      return details
   end

   function internal.getRecordedTroopName(troopId, fallbackName)
      if troopId and recordedPlaceDetailsByTroopId[troopId] and recordedPlaceDetailsByTroopId[troopId].Troop then
         local recordedName = tostring(recordedPlaceDetailsByTroopId[troopId].Troop)
         if recordedName ~= "" then return recordedName end
      end
      return fallbackName
   end

   function internal.formatTowerLabel(details)
      if type(details) ~= "table" then return "Tower" end
      local name = details.Troop or details.TowerName or "Tower"
      if details.TroopId then
         return tostring(name) .. " #" .. tostring(details.TroopId)
      end
      return tostring(name)
   end

   function internal.findRecordedTroopIdByPosition(position)
      if not position then return nil end
      local bestTroopId, bestDistance, matchCount = nil, nil, 0
      for troopId, placeDetails in pairs(recordedPlaceDetailsByTroopId) do
         local pp = internal.deserializeVector3Value(placeDetails.Position)
         if pp then
            local distance = internal.getVectorDistance(pp, position)
            if distance and distance <= 2 then
               matchCount = matchCount + 1
               if not bestDistance or distance < bestDistance then
                  bestTroopId = troopId
                  bestDistance = distance
               end
            end
         end
      end
      if matchCount == 1 then return bestTroopId end
      return nil
   end

   function internal.createUpgradeDetails(upgradeMode, upgradeData, remoteData)
      local tower, path = nil, nil
      if type(upgradeData) == "table" then
         tower = upgradeData.Troop
         path = upgradeData.Path
      end
      local towerPosition = internal.getTowerPosition(tower)
      local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, tower)
      local towerName = internal.getRecordedTroopName(troopId, typeof(tower) == "Instance" and tower.Name or nil)
      return {
         Mode = tostring(upgradeMode or "Set"),
         TroopId = troopId,
         Troop = towerName,
         TowerName = towerName,
         InstanceName = typeof(tower) == "Instance" and tower.Name or nil,
         TowerPosition = internal.serializeVector3Value(towerPosition),
         Path = path or 1,
         Remote = remoteData
      }
   end

   function internal.createSellDetails(sellData, remoteData)
      local tower = nil
      if type(sellData) == "table" then
         tower = sellData.Troop
      end
      local towerPosition = internal.getTowerPosition(tower)
      local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, tower)
      if not troopId then
         troopId = internal.findRecordedTroopIdByPosition(towerPosition)
         if troopId and tower then internal.rememberTowerId(recordedTowerIdsByInstance, tower, troopId) end
      end
      if not towerPosition and troopId and recordedPlaceDetailsByTroopId[troopId] then
         towerPosition = internal.deserializeVector3Value(recordedPlaceDetailsByTroopId[troopId].Position)
      end
      local towerName = internal.getRecordedTroopName(troopId, typeof(tower) == "Instance" and tower.Name or nil)
      return {
         Mode = tostring("Set"),
         TroopId = troopId,
         Troop = towerName,
         TowerName = towerName,
         InstanceName = typeof(tower) == "Instance" and tower.Name or nil,
         TowerPosition = internal.serializeVector3Value(towerPosition),
         Path = 1,
         Remote = remoteData
      }
   end

   function internal.createAbilityDetails(abilityMode, abilityData, remoteData)
      local tower, abilityName, data = nil, nil, {}
      if type(abilityData) == "table" then
         tower = abilityData.Troop
         abilityName = abilityData.Name
         data = abilityData.Data or {}
      end
      local towerPosition = internal.getTowerPosition(tower)
      local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, tower)
      if not troopId then
         troopId = internal.findRecordedTroopIdByPosition(towerPosition)
         if troopId and tower then internal.rememberTowerId(recordedTowerIdsByInstance, tower, troopId) end
      end
      if not towerPosition and troopId and recordedPlaceDetailsByTroopId[troopId] then
         towerPosition = internal.deserializeVector3Value(recordedPlaceDetailsByTroopId[troopId].Position)
      end
      local towerName = internal.getRecordedTroopName(troopId, typeof(tower) == "Instance" and tower.Name or nil)
      return {
         Mode = tostring(abilityMode or "Activate"),
         Name = tostring(abilityName or ""),
         TroopId = troopId,
         Troop = towerName,
         TowerName = towerName,
         InstanceName = typeof(tower) == "Instance" and tower.Name or nil,
         TowerPosition = internal.serializeVector3Value(towerPosition),
         Data = internal.encodeValue(data, 0),
         Remote = remoteData
      }
   end

   function internal.createOptionDetails(optionMode, optionData, remoteData)
      local tower, optionName, optionValue = nil, nil, nil
      if type(optionData) == "table" then
         tower = optionData.Troop
         optionName = optionData.Name
         optionValue = optionData.Value
      end
      local towerPosition = internal.getTowerPosition(tower)
      local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, tower)
      if not troopId then
         troopId = internal.findRecordedTroopIdByPosition(towerPosition)
         if troopId and tower then internal.rememberTowerId(recordedTowerIdsByInstance, tower, troopId) end
      end
      if not towerPosition and troopId and recordedPlaceDetailsByTroopId[troopId] then
         towerPosition = internal.deserializeVector3Value(recordedPlaceDetailsByTroopId[troopId].Position)
      end
      local towerName = internal.getRecordedTroopName(troopId, typeof(tower) == "Instance" and tower.Name or nil)
      return {
         Mode = tostring(optionMode or "Set"),
         Name = tostring(optionName or ""),
         Value = optionValue,
         TroopId = troopId,
         Troop = towerName,
         TowerName = towerName,
         InstanceName = typeof(tower) == "Instance" and tower.Name or nil,
         TowerPosition = internal.serializeVector3Value(towerPosition),
         Remote = remoteData
      }
   end

   function macroRuntime.NormalizeDocument(decodedData)
      if type(decodedData) ~= "table" then
         return nil, nil, nil, "Macro JSON must contain an object or array."
      end

      if type(decodedData.Timeline) == "table" then
         local meta = type(decodedData.Meta) == "table" and decodedData.Meta or {}
         meta.SourceFormat = meta.SourceFormat or "TDSPro"
         return decodedData.Timeline, meta, tostring(meta.SourceFormat), nil
      end

      local isAutoTDS = false
      local firstTimerByWave = {}
      local meta = {
         FormatVersion = "AutoTDS",
         SourceFormat = "AutoTDS",
         TimingMode = "WaveTimerCountdown",
      }

      for _, rawEvent in ipairs(decodedData) do
         if type(rawEvent) == "table" and rawEvent.type ~= nil and type(rawEvent.typeInfo) == "table" then
            isAutoTDS = true
            local info = rawEvent.typeInfo
            local eventType = string.lower(tostring(rawEvent.type))
            if eventType == "game over" and type(info.mapData) == "table" then
               local mapData = info.mapData
               meta.Map = mapData.currentMap or mapData.Map
               meta.Mode = mapData.currentMode or mapData.Mode
               meta.Difficulty = mapData.currentDifficulty or mapData.Difficulty
               meta.Type = mapData.currentMode or mapData.Type
               meta.TotalTime = mapData.totalTime
               meta.Towers = mapData.currentTowers
               meta.Modifiers = mapData.modifiers
               meta.PlayerCount = mapData.playerCount
               meta.StackingEnabled = mapData.stackingEnabled
               meta.Triumph = mapData.triumph
               meta.FinalWave = mapData.currentWave
               meta.SourceFile = mapData.currentFile
            elseif tonumber(info.currentWave) ~= nil and tonumber(info.time) ~= nil then
               local waveKey = tostring(math.max(0, math.floor(tonumber(info.currentWave) or 0)))
               if firstTimerByWave[waveKey] == nil then
                  firstTimerByWave[waveKey] = tonumber(info.time)
               end
            end
         end
      end

      if not isAutoTDS then
         return nil, nil, nil, "Macro does not contain a TDSPro Timeline or AutoTDS event array."
      end

      local timeline = {}
      local placedTowerCount = 0
      local placedTowerNames = {}
      for sourceIndex, rawEvent in ipairs(decodedData) do
         if type(rawEvent) == "table" and type(rawEvent.typeInfo) == "table" then
            local sourceType = tostring(rawEvent.type or "Unknown")
            local eventType = string.lower(sourceType)
            local info = rawEvent.typeInfo

            if eventType ~= "game over" then
               local wave = tonumber(info.currentWave)
               if wave ~= nil then wave = math.max(0, math.floor(wave)) end
               local sourceTimer = tonumber(info.time)
               local event = {
                  Order = sourceIndex,
                  Wave = wave,
                  WaveTime = sourceTimer,
                  WaveTimer = sourceTimer,
                  Timestamp = 0,
                  SourceFormat = "AutoTDS",
                  SourceType = sourceType,
                  Details = { SourceFormat = "AutoTDS" },
               }

               if sourceTimer ~= nil and sourceTimer >= 1000000000 then
                  local firstTimer = firstTimerByWave[tostring(wave)] or sourceTimer
                  local relativeTime = math.max(0, firstTimer - sourceTimer)
                  event.TimingMode = "WaveRelative"
                  event.WaveElapsed = relativeTime
                  event.WaveTimestamp = relativeTime
               elseif sourceTimer ~= nil then
                  local firstTimer = firstTimerByWave[tostring(wave)] or sourceTimer
                  event.TimingMode = "WaveTimerCountdown"
                  event.WaveElapsedFallback = math.max(0, firstTimer - sourceTimer)
               else
                  event.TimingMode = "OrderOnly"
               end

               if eventType == "place" then
                  placedTowerCount = placedTowerCount + 1
                  placedTowerNames[placedTowerCount] = info.towerName
                  event.Action = "Place"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Troop = info.towerName,
                     TowerName = info.towerName,
                     TroopId = placedTowerCount,
                     Position = internal.serializeVector3Value(info.pos),
                     Rotation = tonumber(info.rot) or info.rot,
                  }
               elseif eventType == "upgrade" then
                  event.Action = "Upgrade"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Troop = info.towerName,
                     TowerName = info.towerName,
                     TroopId = tonumber(info.troopID) or info.troopID,
                     Path = tonumber(info.Path) or info.Path or 1,
                     Mode = "Set",
                  }
               elseif eventType == "sell" then
                  event.Action = "Sell"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Troop = info.towerName,
                     TowerName = info.towerName,
                     TroopId = tonumber(info.troopID) or info.troopID,
                  }
               elseif eventType == "abilities" or eventType == "ability" then
                  local abilityTroopId = tonumber(info.troopID) or info.troopID
                  event.Action = "Ability"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Name = info.abilityName,
                     TroopId = abilityTroopId,
                     Troop = placedTowerNames[abilityTroopId],
                     TowerName = placedTowerNames[abilityTroopId],
                     Data = type(info.extraData) == "table" and info.extraData or {},
                     Mode = "Activate",
                  }
               elseif eventType == "options" or eventType == "option" then
                  event.Action = "Option"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Troop = info.towerName,
                     TowerName = info.towerName,
                     TroopId = tonumber(info.troopID) or info.troopID,
                     Name = info.trackName,
                     Value = info.trackValue,
                     Mode = "Set",
                  }
               elseif eventType == "targetingmode" or eventType == "target" then
                  event.Action = "Target"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Troop = info.towerName,
                     TowerName = info.towerName,
                     TroopId = tonumber(info.troopID) or info.troopID,
                     Target = info.Target,
                     Mode = "Set",
                  }
               elseif eventType == "custom" then
                  event.Action = "Custom"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Flag = info.Flag,
                     Bool = info.Bool == true,
                  }
               elseif eventType == "wave" then
                  event.Action = "Skip"
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Wave = wave,
                     WaveTime = sourceTimer,
                  }
               else
                  event.Action = sourceType
                  event.Details = {
                     SourceFormat = "AutoTDS",
                     Raw = info,
                  }
               end

               table.insert(timeline, event)
            end
         end
      end

      meta.TotalActions = #timeline
      return timeline, meta, "AutoTDS", nil
   end

   function macroRuntime.ResolveExternalAbilityData(value, keyName, depth)
      depth = tonumber(depth) or 0
      if depth > 8 then return value end

      local normalizedKey = string.lower(tostring(keyName or ""))
      if normalizedKey == "towertoclone" then
         local troopId = tonumber(value)
         return (troopId and playbackTowerIdsByMacroId[troopId]) or value
      end

      if type(value) ~= "table" then return value end
      if normalizedKey == "position" or normalizedKey == "towerposition" then
         local x, y, z = internal.getVector3Components(value)
         if x ~= nil then return internal.makeVector3Value(x, y, z) end
      end

      local resolved = {}
      for childKey, childValue in pairs(value) do
         resolved[childKey] = macroRuntime.ResolveExternalAbilityData(childValue, childKey, depth + 1)
      end
      return resolved
   end

   function macroRuntime.HasPreWaveSetup()
      if macroRuntime.SourceFormat ~= "AutoTDS" then return false end
      for _, event in ipairs(recordedTimeline) do
         if type(event) == "table" and tonumber(event.Wave) == 0 and event.Action ~= "Skip" then
            return true
         end
      end
      return false
   end

   function internal.macroEventHasReplayData(event)
      if type(event) ~= "table" then return false end
      local action = event.Action
      local details = event.Details
      if type(details) == "table" and type(details.Remote) == "table" then return true end
      if action == "Skip" or action == "Ready" or action == "Veto" or action == "CreateSolo" then return true end
      if (action == "EquipTower" or action == "UnequipTower") and type(details) == "table" then
         return details.Tower ~= nil
      end
      if action == "OverrideMap" and type(details) == "table" then return details.Map ~= nil end
      if action == "VoteMap" and type(details) == "table" then return details.Map ~= nil end
      if action == "Place" and type(details) == "table" then return details.Troop and details.Position end
      if action == "Upgrade" and type(details) == "table" then return details.TroopId or details.TowerPosition end
      if action == "Sell" and type(details) == "table" then return details.TroopId or details.TowerPosition or details.Position end
      if action == "Ability" and type(details) == "table" then return details.Name and (details.TroopId or details.TowerPosition or details.Position) end
      if action == "Option" and type(details) == "table" then return details.Name and details.Value ~= nil and (details.TroopId or details.TowerPosition) end
      if action == "Target" and type(details) == "table" then return details.Target ~= nil and details.TroopId end
      if action == "Custom" and type(details) == "table" then
         local flag = string.lower(tostring(details.Flag or ""))
         return flag == "autoskip"
      end
      return false
   end

   function internal.getMacroReplayStats(timeline)
      local totalActions, replayableActions = 0, 0
      if type(timeline) ~= "table" then return totalActions, replayableActions end
      for _, event in ipairs(timeline) do
         totalActions = totalActions + 1
         if internal.macroEventHasReplayData(event) then replayableActions = replayableActions + 1 end
      end
      return totalActions, replayableActions
   end

   function internal.loadMacroConfig(macroName)
      local requestedMacroName = internal.trimMacroName(macroName or selectedMacroName or currentMacroName)
      local safeMacroName = internal.sanitizeMacroFilename(requestedMacroName)
      local macroPath = internal.getMacroPath(safeMacroName)
      if requestedMacroName ~= "" and macroPathsByName[requestedMacroName] then
         macroPath = macroPathsByName[requestedMacroName]
      elseif macroPathsByName[safeMacroName] then
         macroPath = macroPathsByName[safeMacroName]
      end
      if type(readfile) ~= "function" then
         internal.notifyMacro("Your executor does not support readfile().", 3)
         return false, "readfile() is unavailable."
      end
      local readSuccess, fileContents = pcall(function() return readfile(macroPath) end)
      if not readSuccess or not fileContents then
         internal.notifyMacro("Could not read macro file: " .. safeMacroName, 3)
         return false, "Could not read macro: " .. tostring(fileContents)
      end
      local decodeSuccess, decodedData = pcall(function() return HttpService:JSONDecode(fileContents) end)
      if not decodeSuccess or type(decodedData) ~= "table" then
         internal.notifyMacro("Invalid macro file format: " .. safeMacroName, 3)
         return false, "Invalid macro JSON."
      end

      local normalizedTimeline, normalizedMeta, sourceFormat, normalizeError = macroRuntime.NormalizeDocument(decodedData)
      if type(normalizedTimeline) ~= "table" then
         internal.notifyMacro("Invalid macro file format: " .. safeMacroName .. "\n" .. tostring(normalizeError or "Unsupported macro schema."), 5)
         return false, normalizeError or "Unsupported macro schema."
      end

      recordedTimeline = normalizedTimeline
      selectedMacroName = macroPathsByName[requestedMacroName] and requestedMacroName or safeMacroName
      currentMacroName = safeMacroName
      loadedMacroMeta = type(normalizedMeta) == "table" and normalizedMeta or {}
      macroRuntime.SourceFormat = sourceFormat or "TDSPro"
      macroRuntime.SourceLabel = selectedMacroName

      local totalActions, replayableActions = internal.getMacroReplayStats(recordedTimeline)

      if GameInfoParagraph then
         local mapName = loadedMacroMeta.Map or "Unknown"
         local modeName = loadedMacroMeta.Mode or "Unknown"
         local diffName = loadedMacroMeta.Difficulty or "Unknown"
         internal.safeSetParagraph(GameInfoParagraph, {
            Title = "Loaded Macro Info",
            Content = "Map: " .. mapName .. "\nMode: " .. modeName .. "\nDifficulty: " .. diffName .. "\nFormat: " .. tostring(macroRuntime.SourceFormat)
         })
      end

      if type(TimelineUI.Refresh) == "function" then TimelineUI.Refresh(true) end
      if type(recordingRuntime.RefreshStatsUI) == "function" then recordingRuntime.RefreshStatsUI() end

      if totalActions > 0 and replayableActions == 0 then
         internal.notifyMacro("Loaded " .. safeMacroName .. ", but it is an old timing-only macro. Re-record it to replay.", 5)
      elseif replayableActions < totalActions then
         internal.notifyMacro("Loaded " .. safeMacroName .. " (" .. tostring(macroRuntime.SourceFormat) .. "). Replayable: " .. replayableActions .. "/" .. totalActions .. ". Unsupported actions remain visible in Timeline.", 5)
      else
         internal.notifyMacro("Loaded " .. safeMacroName .. " (" .. tostring(macroRuntime.SourceFormat) .. ") with " .. totalActions .. " replayable action(s).", 3)
      end
      if macroRuntime.SourceFormat == "AutoTDS" and loadedMacroMeta.StackingEnabled == true then
         internal.notifyMacro("This AutoTDS macro was recorded with stacking enabled. TDSPro preserves those positions but does not enable stacking for you.", 6)
      end

      return true
   end

   function internal.replayPlaceEvent(details)
      if type(details) ~= "table" or not details.Troop or not details.Position then
         return false, "Place event is missing troop or position data."
      end
      local position = internal.deserializeVector3Value(details.Position)
      if not position then return false, "Place event has an invalid position." end
      local placementData = {
         Rotation = internal.deserializeCFrameValue(details.Rotation),
         Position = position
      }
      local beforeSnapshot = internal.getTowerSnapshot()
      local success, result, results = internal.invokeTDSRemoteFunction("Troops", "Place", placementData, details.Troop)
      if not success then return false, result, false end
      local accepted, retryable, rejectionReason = internal.classifyRemoteActionResult(result, results)
      if not accepted then
         return false, "Place event was rejected: " .. tostring(rejectionReason), retryable
      end
      if details.TroopId then
         local tower = internal.waitForPlacedTower(position, beforeSnapshot, result)
         if not tower then return false, "Place event did not create a new tower." end
         playbackTowerIdsByMacroId[details.TroopId] = tower
      end
      return true
   end

   function internal.findPlaybackTowerForUpgrade(details)
      if type(details) ~= "table" then return nil end
      if details.TroopId and playbackTowerIdsByMacroId[details.TroopId] then
         return playbackTowerIdsByMacroId[details.TroopId]
      end
      local tp = internal.deserializeVector3Value(details.TowerPosition)
      if tp then return internal.findNearestTowerToPosition(tp, nil, nil) end
      return nil
   end

   function internal.findPlaybackTowerForSell(details)
      if type(details) ~= "table" then return nil end
      if details.TroopId and playbackTowerIdsByMacroId[details.TroopId] then
         return playbackTowerIdsByMacroId[details.TroopId]
      end
      local tp = internal.deserializeVector3Value(details.TowerPosition or details.Position)
      if tp then return internal.findNearestTowerToPosition(tp, nil, nil) end
      return nil
   end

   function internal.findPlaybackTowerForAbility(details)
      if type(details) ~= "table" then return nil end
      if details.TroopId and playbackTowerIdsByMacroId[details.TroopId] then
         return playbackTowerIdsByMacroId[details.TroopId]
      end
      local tp = internal.deserializeVector3Value(details.TowerPosition or details.Position)
      if tp then return internal.findNearestTowerToPosition(tp, nil, nil) end
      return nil
   end

   function recordingRuntime.GetTopLevelTower(instance)
      local tower = internal.normalizeTowerInstance(instance)
      local folder = internal.getTowersFolder()
      if tower and folder and tower.Parent == folder then return tower end
      return nil
   end

   function recordingRuntime.TowerOwnerMatchesLocalPlayer(tower)
      if typeof(tower) ~= "Instance" then return false end
      local player = LocalPlayer or Players.LocalPlayer
      if not player then return nil end

      local ownerValue = tower:FindFirstChild("Owner", true)
      local owner = ownerValue and internal.safeReadValue(ownerValue, nil) or nil
      if owner == nil then
         for _, attributeName in ipairs({"Owner", "OwnerId", "OwnerUserId", "Player", "PlayerId", "UserId"}) do
            local ok, value = pcall(function() return tower:GetAttribute(attributeName) end)
            if ok and value ~= nil then
               owner = value
               break
            end
         end
      end
      if owner == nil then return nil end
      if typeof(owner) == "Instance" then return owner == player end
      if type(owner) == "number" then return owner == player.UserId end
      local normalizedOwner = string.lower(tostring(owner))
      return normalizedOwner == string.lower(player.Name) or normalizedOwner == tostring(player.UserId)
   end

   function recordingRuntime.NormalizeTowerTypeName(value)
      return string.lower(tostring(value or "")):gsub("[^%w]", "")
   end

   function recordingRuntime.TowerNameMatchesExpected(tower, expectedName)
      local expected = recordingRuntime.NormalizeTowerTypeName(expectedName)
      if expected == "" or typeof(tower) ~= "Instance" then return nil end
      local sawAuthoritativeName = false
      local sources = {tower}
      for _, descendant in ipairs(tower:GetDescendants()) do
         if descendant:IsA("Model") or descendant:IsA("Folder") or descendant:IsA("Configuration") then
            table.insert(sources, descendant)
         end
      end
      for _, source in ipairs(sources) do
         if recordingRuntime.NormalizeTowerTypeName(source.Name) == expected then return true end
         for _, attributeName in ipairs({"Tower", "TowerName", "Troop", "TroopName", "UnitName", "Type"}) do
            local ok, value = pcall(function() return source:GetAttribute(attributeName) end)
            if ok and value ~= nil and tostring(value) ~= "" then
               local normalized = recordingRuntime.NormalizeTowerTypeName(value)
               if normalized == expected then return true end


               local generic = normalized == "tower" or normalized == "troop" or normalized == "unit" or
                  normalized == "model" or normalized == "true" or normalized == "false" or
                  normalized == "golden" or normalized == "normal"
               if attributeName ~= "Type" and not generic then sawAuthoritativeName = true end
            end
         end
      end
      if sawAuthoritativeName then return false end
      return nil
   end

   function recordingRuntime.FindConfirmedNewTower(position, beforeSnapshot, returnedInstance, expectedName, afterSnapshot)
      local returnedTower = recordingRuntime.GetTopLevelTower(returnedInstance)
      if returnedTower and not (beforeSnapshot and beforeSnapshot[returnedTower]) and
         not recordedTowerIdsByInstance[returnedTower] and recordingRuntime.TowerOwnerMatchesLocalPlayer(returnedTower) ~= false and
         recordingRuntime.TowerNameMatchesExpected(returnedTower, expectedName) ~= false then
         local returnedPosition = internal.getTowerPosition(returnedTower)
         local returnedDistance = position and returnedPosition and internal.getVectorDistance(position, returnedPosition) or nil
         if returnedDistance == nil or returnedDistance <= RECORDING_PLACE_MATCH_DISTANCE then return returnedTower end
      end

      local folder = internal.getTowersFolder()
      if not folder or not position then return nil end
      local candidate = nil
      local candidateCount = 0
      for _, tower in ipairs(folder:GetChildren()) do
         if (not afterSnapshot or afterSnapshot[tower]) and not (beforeSnapshot and beforeSnapshot[tower]) and not recordedTowerIdsByInstance[tower] and
            recordingRuntime.TowerOwnerMatchesLocalPlayer(tower) ~= false then
            local towerPosition = internal.getTowerPosition(tower)
            local distance = towerPosition and internal.getVectorDistance(towerPosition, position) or nil
            if distance and distance <= RECORDING_PLACE_MATCH_DISTANCE then
               local nameMatch = recordingRuntime.TowerNameMatchesExpected(tower, expectedName)
               if nameMatch ~= false then
                  candidate = tower
                  candidateCount = candidateCount + 1
               end
            end
         end
      end
      if candidateCount == 1 then return candidate end
      return nil
   end

   function recordingRuntime.NormalizeUpgradeMarkerName(value)
      return string.lower(tostring(value or "")):gsub("[^%w]", "")
   end

   function recordingRuntime.EncodeUpgradeMarkerValue(value)
      if typeof(value) == "Instance" then
         local ok, fullName = pcall(function() return value:GetFullName() end)
         return ok and fullName or value.Name
      end
      return tostring(value)
   end

   function recordingRuntime.ReadTowerUpgradeState(tower)
      tower = recordingRuntime.GetTopLevelTower(tower) or internal.normalizeTowerInstance(tower)
      if typeof(tower) ~= "Instance" then return {Ordinal = nil, Fingerprint = nil, Paths = {}} end

      local fingerprintParts = {}
      local bestGeneric = nil
      local pathValues = {}
      local genericPriority = {
         upgradelevel = 90, currentupgrade = 80, currentlevel = 70,
         level = 60, tier = 50, stage = 40, rank = 30, upgrade = 20,
      }
      local pathAliases = {
         path1 = {Index = 1, Priority = 100}, path1level = {Index = 1, Priority = 110},
         upgradepath1 = {Index = 1, Priority = 90}, upgradepath1level = {Index = 1, Priority = 95},
         toppath = {Index = 1, Priority = 80}, toppathlevel = {Index = 1, Priority = 85},
         leftpath = {Index = 1, Priority = 70}, leftpathlevel = {Index = 1, Priority = 75},
         pathone = {Index = 1, Priority = 60}, pathonelevel = {Index = 1, Priority = 65},
         path2 = {Index = 2, Priority = 100}, path2level = {Index = 2, Priority = 110},
         upgradepath2 = {Index = 2, Priority = 90}, upgradepath2level = {Index = 2, Priority = 95},
         bottompath = {Index = 2, Priority = 80}, bottompathlevel = {Index = 2, Priority = 85},
         rightpath = {Index = 2, Priority = 70}, rightpathlevel = {Index = 2, Priority = 75},
         pathtwo = {Index = 2, Priority = 60}, pathtwolevel = {Index = 2, Priority = 65},
      }

      local function isBetter(existing, score, key)
         return not existing or score > existing.Score or (score == existing.Score and key < existing.Key)
      end

      local function noteValue(path, name, value, depth, isAttribute)
         local normalized = recordingRuntime.NormalizeUpgradeMarkerName(name)
         if normalized == "" or string.find(normalized, "cost", 1, true) or string.find(normalized, "price", 1, true) or
            string.find(normalized, "max", 1, true) or string.find(normalized, "next", 1, true) or
            string.find(normalized, "require", 1, true) or string.find(normalized, "available", 1, true) or
            string.find(normalized, "unlock", 1, true) then return end

         local alias = pathAliases[normalized]
         local genericScore = genericPriority[normalized]
         if not alias and not genericScore then return end
         if alias and depth > 3 then return end
         if genericScore and depth > 1 then return end

         local key = (isAttribute and "A:" or "V:") .. path .. ":" .. normalized
         table.insert(fingerprintParts, key .. "=" .. recordingRuntime.EncodeUpgradeMarkerValue(value))
         local numeric = internal.coerceNumber(value)
         if numeric == nil then return end
         local depthScore = 1000 - (depth * 100) + (isAttribute and 10 or 0)
         if alias then
            local score = depthScore + alias.Priority
            if isBetter(pathValues[alias.Index], score, key) then
               pathValues[alias.Index] = {Value = numeric, Score = score, Key = key}
            end
         elseif genericScore then
            local score = depthScore + genericScore
            if isBetter(bestGeneric, score, key) then
               bestGeneric = {Value = numeric, Score = score, Key = key}
            end
         end
      end

      local objects = {{Object = tower, Depth = 0, Path = tower.Name}}
      local descendantsOk, descendants = pcall(function() return tower:GetDescendants() end)
      if descendantsOk then
         for _, object in ipairs(descendants) do
            local depth = 1
            local parent = object.Parent
            while parent and parent ~= tower and depth < 8 do
               depth = depth + 1
               parent = parent.Parent
            end
            table.insert(objects, {Object = object, Depth = depth, Path = object.Name})
         end
      end

      for _, entry in ipairs(objects) do
         local object = entry.Object
         local attributesOk, attributes = pcall(function() return object:GetAttributes() end)
         if attributesOk then
            for name, value in pairs(attributes) do
               noteValue(entry.Path, name, value, entry.Depth, true)
            end
         end
         local isValueBase = false
         pcall(function() isValueBase = object:IsA("ValueBase") end)
         if isValueBase then
            local valueOk, value = pcall(function() return object.Value end)
            if valueOk then noteValue(entry.Path, object.Name, value, entry.Depth, false) end
         end
      end

      table.sort(fingerprintParts)
      local paths = {}
      local pathTotal, pathCount = 0, 0
      for index = 1, 2 do
         local entry = pathValues[index]
         if entry then
            paths[index] = entry.Value
            pathTotal = pathTotal + entry.Value
            pathCount = pathCount + 1
         end
      end
      local ordinal = pathCount > 0 and pathTotal or (bestGeneric and bestGeneric.Value or nil)

      return {
         Ordinal = ordinal,
         Generic = bestGeneric and bestGeneric.Value or nil,
         Fingerprint = #fingerprintParts > 0 and table.concat(fingerprintParts, "|") or nil,
         Paths = paths,
         Sources = {
            [1] = pathValues[1] and pathValues[1].Key or nil,
            [2] = pathValues[2] and pathValues[2].Key or nil,
            Generic = bestGeneric and bestGeneric.Key or nil,
         },
      }
   end

   function internal.waitForUpgradeAttemptSlot()
      while isPlayingMacro do
         local lastAttemptAt = tonumber(macroRuntime.LastUpgradeAttemptAt) or 0
         local remaining = UPGRADE_MIN_ATTEMPT_GAP - (os.clock() - lastAttemptAt)
         if remaining <= 0 then return true end
         task.wait(math.min(remaining, 0.05))
      end
      return false
   end

   function internal.replayUpgradeEvent(details)
      local tower = internal.findPlaybackTowerForUpgrade(details)
      if not tower then return false, "Upgrade event could not find the matching placed tower." end
      if not internal.waitForUpgradeAttemptSlot() then return false, "Macro playback stopped before the upgrade attempt." end
      local towerPosition = internal.getTowerPosition(tower)
      local beforeTowers = internal.getTowerSnapshot()
      local beforeState = recordingRuntime.ReadTowerUpgradeState(tower)
      local upgradeData = {
         Troop = tower,
         Path = (type(details) == "table" and details.Path) or 1
      }
      macroRuntime.LastUpgradeAttemptAt = os.clock()
      local success, result, results = internal.invokeTDSRemoteFunction("Troops", "Upgrade", (type(details) == "table" and details.Mode) or "Set", upgradeData)
      if not success then return false, result, false end
      local explicitAccepted, explicitReason = recordingRuntime.ClassifyActionResult(result, results)
      local accepted, retryable, rejectionReason = internal.classifyRemoteActionResult(result, results)
      if explicitAccepted == false then
         return false, "Upgrade event was rejected: " .. tostring(rejectionReason), retryable
      end
      if explicitAccepted == true then return true end

      local afterState = beforeState
      local replacement = nil
      local confirmationEnvelope = {
         Tower = tower,
         BeforeTowers = beforeTowers,
         Results = results,
         Details = {
            Troop = type(details) == "table" and (details.Troop or details.TowerName) or nil,
            TowerName = type(details) == "table" and details.TowerName or nil,
            TowerPosition = internal.serializeVector3Value(towerPosition),
            Path = upgradeData.Path,
         },
      }
      local deadline = os.clock() + UPGRADE_CONFIRM_TIMEOUT
      repeat
         replacement = recordingRuntime.FindUpgradeReplacement(confirmationEnvelope)
         afterState = recordingRuntime.ReadTowerUpgradeState(replacement or tower)
         local transitionUnits = recordingRuntime.MeasureUpgradeTransition(beforeState, afterState, upgradeData.Path)
         if replacement or transitionUnits > 0 then
            if replacement and type(details) == "table" and details.TroopId then
               playbackTowerIdsByMacroId[details.TroopId] = replacement
            end
            return true
         end
         task.wait(0.04)
      until not isPlayingMacro or os.clock() >= deadline

      local stateInspectable = beforeState.Fingerprint ~= nil or afterState.Fingerprint ~= nil or
         beforeState.Ordinal ~= nil or afterState.Ordinal ~= nil
      if stateInspectable then
         return false, "Upgrade produced no tower level/path change yet (usually not enough cash).", true
      end
      if not accepted then
         return false, "Upgrade event was rejected: " .. tostring(rejectionReason or explicitReason), retryable
      end


      return true
   end

   function internal.replaySellEvent(details)
      local tower = internal.findPlaybackTowerForSell(details)
      if not tower then return false, "Sell event could not find the matching placed tower." end
      local sellData = {
         Troop = tower,
      }
      local success, result = internal.invokeTDSRemoteFunction("Troops", "Sell", sellData)
      if not success then return false, result end
      return true
   end

   function internal.replayAbilityEvent(details)
      if type(details) ~= "table" or not details.Name or details.Name == "" then
         return false, "Ability event is missing its ability name."
      end
      local tower = internal.findPlaybackTowerForAbility(details)
      if not tower then return false, "Ability event could not find the matching placed tower." end
      local abilityData = internal.decodeValue(details.Data)
      if type(abilityData) ~= "table" then abilityData = {} end
      if details.SourceFormat == "AutoTDS" then
         abilityData = macroRuntime.ResolveExternalAbilityData(abilityData, nil, 0)
      end
      local success, result = internal.invokeTDSRemoteFunction("Troops", "Abilities", details.Mode or "Activate", {
         Troop = tower,
         Name = details.Name,
         Data = abilityData
      })
      if not success then return false, result end
      return true
   end

   function internal.replayKnownMacroEvent(event)
      if type(event) ~= "table" then return nil, "Invalid macro event." end
      local action = event.Action
      local details = event.Details or {}
      if action == "EquipTower" or action == "UnequipTower" then
         if not details.Tower then return nil, "No known replay handler." end
         local mode = details.Mode or (action == "EquipTower" and "Equip" or "Unequip")
         return internal.fireTDSRemoteEvent("Inventory", mode, "Tower", details.Tower)
      elseif action == "CreateSolo" then
         return internal.invokeTDSRemoteFunction("Multiplayer", "single_create")
      elseif action == "OverrideMap" then
         if not details.Map then return nil, "No known replay handler." end
         return internal.invokeTDSRemoteFunction("LobbyVoting", "Override", details.Map)
      elseif action == "VoteMap" then
         if not details.Map then return nil, "No known replay handler." end
         local votePos = internal.deserializeVector3Value(details.Position) or internal.makeVector3Value(16.46, 9.6, 58.34)
         return internal.fireTDSRemoteEvent("LobbyVoting", "Vote", details.Map, votePos)
      elseif action == "Place" then
         if not (details.Troop and details.Position) then return nil, "No known replay handler." end
         return internal.replayPlaceEvent(details)
      elseif action == "Upgrade" then
         if not (details.TroopId or details.TowerPosition) then return nil, "No known replay handler." end
         return internal.replayUpgradeEvent(details)
      elseif action == "Option" then
         if not (details.Name and details.Value ~= nil and (details.TroopId or details.TowerPosition)) then return nil, "No known replay handler." end
         local tower = internal.findPlaybackTowerForAbility(details)
         if not tower then return false, "Option event could not find the matching placed tower." end
         return internal.invokeTDSRemoteFunction("Troops", "Option", details.Mode or "Set", {
            Troop = tower,
            Name = details.Name,
            Value = details.Value,
         })
      elseif action == "Target" and details.Target ~= nil then
         if not details.TroopId then return nil, "No known replay handler." end
         local tower = internal.findPlaybackTowerForAbility(details)
         if not tower then return false, "Target event could not find the matching placed tower." end
         return internal.invokeTDSRemoteFunction("Troops", "Target", details.Mode or "Set", {
            Troop = tower,
            Target = details.Target,
         })
      elseif action == "Custom" then
         if type(macroRuntime.SetCustomFlag) ~= "function" then return false, "Custom macro actions are unavailable." end
         return macroRuntime.SetCustomFlag(details.Flag, details.Bool)
      elseif action == "Skip" then
         local timestamp = tonumber(event.Timestamp) or 0
         if timestamp <= 1 and skipSync.StartSkipAt and (os.clock() - skipSync.StartSkipAt) < internal.adjustMacroPlaybackSeconds(30) then
            return true
         end
         if skipCurrentWave then
            return skipCurrentWave("Replaying skip...")
         end
         return internal.invokeTDSRemoteFunction("Voting", "Skip")
      elseif action == "Ready" then
         return internal.fireTDSRemoteEvent("LobbyVoting", "Ready")
      elseif action == "Veto" then
         return internal.fireTDSRemoteEvent("LobbyVoting", "Veto")
      elseif action == "Sell" then
         if not (details.TroopId or details.Position or details.TowerPosition) then return nil, "NO replay data yay" end
         return internal.replaySellEvent(details)
      elseif action == "Ability" then
         if not (details.Name and (details.TroopId or details.TowerPosition or details.Position)) then return nil, "No known replay handler." end
         return internal.replayAbilityEvent(details)
      end
      return nil, "No known replay handler."
   end

   function internal.replayMacroEvent(event)
      if type(event) ~= "table" then return false, "Invalid macro event." end
      local details = event.Details or {}
      local remoteData = details.Remote
      local knownSuccess, knownError, knownRetryable = internal.replayKnownMacroEvent(event)
      if knownSuccess ~= nil then return knownSuccess, knownError, knownRetryable end
      if type(remoteData) ~= "table" then return false, "This event has no replay data." end
      local remote = internal.resolveInstancePath(remoteData.Path)
      if not remote then return false, "Remote could not be found." end
      local args = internal.decodeRemoteArgs(remoteData.Args)
      local method = remoteData.Method
      local replaySuccess, replayError = pcall(function()
         if method == "FireServer" then
            remote:FireServer(internal.unpackValues(args))
         elseif method == "InvokeServer" then
            remote:InvokeServer(internal.unpackValues(args))
         else
            error("Unsupported remote method: " .. tostring(method))
         end
      end)
      if not replaySuccess then return false, tostring(replayError) end
      return true
   end

   function internal.replayMacroEventWithEconomyRetry(event)
      local action = type(event) == "table" and tostring(event.Action or "") or ""
      local isEconomyAction = action == "Place" or action == "Upgrade"
      local startedAt = os.clock()
      local attempts = 0
      local lastError = nil

      while isPlayingMacro do
         attempts = attempts + 1
         local success, replayError, retryable = internal.replayMacroEvent(event)
         if success then return true, nil, attempts end
         lastError = replayError
         if not isEconomyAction or retryable ~= true then
            return false, replayError, attempts
         end

         if type(updateReplayStatus) == "function" and (attempts == 1 or attempts % 10 == 0) then
            updateReplayStatus("Waiting to retry " .. action .. " (attempt " .. tostring(attempts) ..
               "): " .. tostring(replayError))
         end

         local elapsed = os.clock() - startedAt
         if elapsed >= ECONOMY_RETRY_TIMEOUT then
            return false, action .. " was still rejected after " .. tostring(attempts) ..
               " attempts / " .. tostring(ECONOMY_RETRY_TIMEOUT) .. "s: " .. tostring(lastError), attempts
         end

         local waitUntil = os.clock() + ECONOMY_RETRY_INTERVAL
         while isPlayingMacro and os.clock() < waitUntil do
            task.wait(math.max(0.01, math.min(waitUntil - os.clock(), 0.05)))
         end
      end

      return false, "Macro playback stopped while waiting to retry " .. action .. ".", attempts
   end

   function internal.waitForMacroTimestamp(timestamp, playbackStartClock)
      local target = internal.adjustMacroPlaybackSeconds(timestamp)
      local startedAt = tonumber(playbackStartClock) or os.clock()
      while isPlayingMacro do
         local elapsed = os.clock() - startedAt
         local remaining = target - elapsed
         if remaining <= 0 then break end
         task.wait(math.min(remaining, 0.05))
      end
   end

   function internal.readStateValue(name)
      local state = ReplicatedStorage:FindFirstChild("State")
      if not state then return nil end
      local obj = state:FindFirstChild(name)
      if not obj then return nil end
      local success, val = pcall(function() return obj.Value end)
      if success then return val end
      return nil
   end

   function internal.readWaveValue()
      local player = LocalPlayer or Players.LocalPlayer
      local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
      local topDisplay = playerGui and playerGui:FindFirstChild("ReactGameTopGameDisplay")
      local frame = topDisplay and topDisplay:FindFirstChild("Frame")
      local waveFrame = frame and frame:FindFirstChild("wave")
      local container = waveFrame and waveFrame:FindFirstChild("container")
      local valueLabel = container and container:FindFirstChild("value")
      if valueLabel then
         local success, text = pcall(function() return valueLabel.Text end)
         if success and text ~= nil then
            local currentWaveText = string.match(tostring(text), "^%s*([^/]+)") or tostring(text)
            local guiWave = tonumber(internal.coerceNumber(currentWaveText))
            if guiWave ~= nil and guiWave >= 0 then
               return math.floor(guiWave)
            end
         end
      end

      local state = ReplicatedStorage:FindFirstChild("State")
      if not state then return 0 end
      local waveNames = { "Wave", "CurrentWave", "Current", "Value", "Number", "Count" }
      local waveObj = state:FindFirstChild("Wave")
      local wave = internal.readInstanceNumber(waveObj, waveNames)
      local fallbackWave = internal.readInstanceNumber(state, waveNames)
      if wave == nil or (wave == 0 and fallbackWave ~= nil and fallbackWave ~= 0) then
         wave = fallbackWave
      end
      wave = tonumber(wave) or 0
      if wave < 0 then return 0 end
      return math.floor(wave)
   end

   function internal.readWaveTimerValue()
      local state = ReplicatedStorage:FindFirstChild("State")
      if not state then return nil end
      local timerNames = { "Time", "Timer", "Value", "Current", "Seconds" }
      local timerObj = state:FindFirstChild("Timer")
      local timeObj = timerObj and timerObj:FindFirstChild("Time")
      return internal.readInstanceNumber(timeObj, timerNames) or internal.readInstanceNumber(timerObj, timerNames)
   end

   function internal.describeWaveStateDebug()
      local player = LocalPlayer or Players.LocalPlayer
      local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
      local topDisplay = playerGui and playerGui:FindFirstChild("ReactGameTopGameDisplay")
      local frame = topDisplay and topDisplay:FindFirstChild("Frame")
      local waveFrame = frame and frame:FindFirstChild("wave")
      local container = waveFrame and waveFrame:FindFirstChild("container")
      local valueLabel = container and container:FindFirstChild("value")
      local guiText = nil
      if valueLabel then
         local guiSuccess, readText = pcall(function() return valueLabel.Text end)
         if guiSuccess then guiText = readText end
      end

      local state = ReplicatedStorage:FindFirstChild("State")
      if not state then return "guiWaveText=" .. tostring(guiText) .. " State=nil" end
      local waveObj = state:FindFirstChild("Wave")
      if not waveObj then return "guiWaveText=" .. tostring(guiText) .. " WaveObj=nil" end

      local parts = { "guiWaveText=" .. tostring(guiText), "WaveObj=" .. tostring(waveObj.ClassName), "raw=" .. tostring(internal.safeReadValue(waveObj, nil)) }
      local success, text = pcall(function() return waveObj.Text end)
      if success and text ~= nil then table.insert(parts, "text=" .. tostring(text)) end

      local childParts = {}
      for _, child in ipairs(waveObj:GetChildren()) do
         if #childParts >= 4 then break end
         table.insert(childParts, tostring(child.Name) .. ":" .. tostring(child.ClassName) .. "=" .. tostring(internal.safeReadValue(child, nil)))
      end
      if #childParts > 0 then table.insert(parts, "children=" .. table.concat(childParts, ",")) end

      local stateChildParts = {}
      for _, child in ipairs(state:GetChildren()) do
         local lowerName = string.lower(tostring(child.Name))
         if string.find(lowerName, "wave") or string.find(lowerName, "round") then
            table.insert(stateChildParts, tostring(child.Name) .. ":" .. tostring(child.ClassName) .. "=" .. tostring(internal.safeReadValue(child, nil)))
            if #stateChildParts >= 4 then break end
         end
      end
      if #stateChildParts > 0 then table.insert(parts, "stateChildren=" .. table.concat(stateChildParts, ",")) end
      return table.concat(parts, " ")
   end

   function internal.findFirstSkipReadyPrompt()
      local player = LocalPlayer or Players.LocalPlayer
      local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
      if not playerGui then return nil end
      local root = playerGui:FindFirstChild("ReactOverridesVote")
      local frame = root and root:FindFirstChild("Frame")
      local votes = frame and frame:FindFirstChild("votes")
      local container = votes and votes:FindFirstChild("container")
      return container and container:FindFirstChild("ready")
   end

   function internal.waitForFirstSkipReadyPrompt(timeout)
      local deadline = os.clock() + (tonumber(timeout) or 30)
      while autoReplayEnabled and os.clock() < deadline do
         local prompt = internal.findFirstSkipReadyPrompt()
         if prompt then return prompt end
         task.wait(0.1)
      end
      return nil
   end

   function internal.hasMatchActuallyStarted()
      if internal.getTowersFolder() then return true end
      if internal.readWaveValue() > 0 then return true end
      if internal.readWaveTimerValue() ~= nil then return true end
      return false
   end

   function internal.isInActualMap()
      if workspace:FindFirstChild("IntermissionLobby") then return false end

      local placeType = workspace:FindFirstChild("Type")
      local placeTypeValue = string.lower(tostring(internal.safeReadValue(placeType, "")))
      if placeTypeValue == "lobby" then return false end

      if internal.hasMatchActuallyStarted() then return true end
      if placeTypeValue == "game" then
         if type(isVotingLobbyReady) == "function" and isVotingLobbyReady() then return false end
         return true
      end
      return false
   end

   function internal.canChangeInventoryLoadout()
      local placeType = workspace:FindFirstChild("Type")
      local placeTypeValue = string.lower(tostring(internal.safeReadValue(placeType, "")))




      if placeTypeValue == "lobby" or workspace:FindFirstChild("IntermissionLobby") then
         return true
      end
      return not internal.isInActualMap()
   end

   local MAX_INVENTORY_LOADOUT_SIZE = 5

   function internal.normalizeInventoryTowerName(value)
      local normalized = string.lower(tostring(value or ""))
         :gsub("^%s+", ""):gsub("%s+$", "")
         :gsub("^golden%s+", "")
         :gsub("[^%w]", "")
      return normalized
   end

   function macroRuntime.GetRequiredLoadoutTowers()
      local towers = {}
      local seen = {}

      local function addTower(value)
         local name = nil
         if type(value) == "string" or type(value) == "number" then
            name = tostring(value)
         elseif type(value) == "table" then
            name = value.name or value.Name or value.Troop or value.TowerName or value.towerName
         end
         name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
         local key = internal.normalizeInventoryTowerName(name)
         if key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(towers, name)
         end
      end

      local metadataTowers = type(loadedMacroMeta.Towers) == "table" and loadedMacroMeta.Towers or {}
      for _, towerInfo in ipairs(metadataTowers) do addTower(towerInfo) end
      for key, towerInfo in pairs(metadataTowers) do
         if type(key) == "string" then
            local beforeCount = #towers
            addTower(towerInfo)
            if #towers == beforeCount then addTower(key) end
         end
      end

      for _, event in ipairs(recordedTimeline) do
         if type(event) == "table" and tostring(event.Action) == "Place" then
            local details = type(event.Details) == "table" and event.Details or {}
            addTower(details.Troop or details.TowerName)
         end
      end
      return towers
   end

   function macroRuntime.ReadInventoryTroops(timeoutSeconds)
      local completed, success, inventory, queryError = false, false, nil, nil
      task.spawn(function()
         local callSuccess, result = internal.invokeTDSRemoteFunction("Session", "Search", "Inventory.Troops")
         success = callSuccess == true and type(result) == "table"
         inventory = success and result or nil
         queryError = success and nil or tostring(result or "Inventory query returned no troop data.")
         completed = true
      end)

      local deadline = os.clock() + math.max(1, tonumber(timeoutSeconds) or 5)
      while not completed and os.clock() < deadline do task.wait(0.05) end
      if not completed then return nil, "Inventory query timed out." end
      if not success then return nil, queryError end
      return inventory
   end

   function macroRuntime.ReadSessionValue(cachePath, timeoutSeconds)
      local completed, success, value, queryError = false, false, nil, nil
      task.spawn(function()
         local callSuccess, result = internal.invokeTDSRemoteFunction("Session", "Search", tostring(cachePath or ""))
         success = callSuccess == true and result ~= nil
         value = success and result or nil
         queryError = success and nil or tostring(result or "Session value query returned no data.")
         completed = true
      end)

      local deadline = os.clock() + math.max(0.5, tonumber(timeoutSeconds) or 2)
      while not completed and os.clock() < deadline do task.wait(0.05) end
      if not completed then return nil, "Session value query timed out." end
      if not success then return nil, queryError end
      return value
   end

   function macroRuntime.ReadEquippedTroops(timeoutSeconds, cachePath)
      local completed, success, equipped, queryError = false, false, nil, nil
      cachePath = tostring(cachePath or "Equipped.Troops")
      task.spawn(function()
         local callSuccess, result = internal.invokeTDSRemoteFunction("Session", "Search", cachePath)
         success = callSuccess == true and type(result) == "table"
         equipped = success and result or nil
         queryError = success and nil or tostring(result or "Equipped loadout query returned no troop data.")
         completed = true
      end)

      local deadline = os.clock() + math.max(1, tonumber(timeoutSeconds) or 5)
      while not completed and os.clock() < deadline do task.wait(0.05) end
      if not completed then return nil, "Equipped loadout query timed out." end
      if not success then return nil, queryError end
      return equipped
   end

   function macroRuntime.GetEquippedTowerNames(equippedData)
      local names = {}
      local seen = {}
      if type(equippedData) ~= "table" then return names end

      for key, value in pairs(equippedData) do
         local towerName = nil
         if type(key) == "number" and type(value) == "string" then
            towerName = value
         elseif type(key) == "string" and (value == true or type(value) == "table") then
            towerName = key
         end

         if towerName then
            local normalized = internal.normalizeInventoryTowerName(towerName)
            if normalized ~= "" and not seen[normalized] then
               seen[normalized] = true
               table.insert(names, tostring(towerName))
            end
         end
      end
      return names
   end

   function macroRuntime.GetInventoryLoadoutContext()
      local mode = string.lower(tostring(loadedMacroMeta.Mode or detectedGameInfo.Mode or ""))
      local isPVP = mode == "pvp" or mode:find("player%s*versus%s*player") ~= nil
      local playerLevel = tonumber(macroRuntime.ReadSessionValue("Values.Level", 2))
      local standardLimit = playerLevel and playerLevel < 10 and 4 or MAX_INVENTORY_LOADOUT_SIZE
      return {
         IsPVP = isPVP,
         CachePath = isPVP and "Equipped.PVPTroops" or "Equipped.Troops",
         ItemType = isPVP and "pvptower" or "tower",
         Limit = isPVP and 4 or standardLimit,
         Label = isPVP and "PVP loadout" or "loadout",
      }
   end

   function macroRuntime.RequestInventoryTowerChange(mode, towerName, itemType)
      local callSuccess, accepted, results = internal.invokeTDSRemoteFunction(
         "Inventory",
         mode,
         tostring(itemType or "tower"),
         towerName
      )
      if not callSuccess then return false, accepted end
      if accepted ~= true then
         local reason = type(results) == "table" and results[2] or nil
         return false, tostring(reason or accepted or "The server rejected the inventory change.")
      end
      return true
   end

   function macroRuntime.ResolveInventoryTowerName(requestedName, inventory)
      local requestedText = tostring(requestedName or "")
      if type(inventory[requestedText]) == "table" then return requestedText end

      local requestedLower = string.lower(requestedText)
      local requestedNormalized = internal.normalizeInventoryTowerName(requestedText)
      for inventoryName, towerData in pairs(inventory) do
         if type(towerData) == "table" then
            local candidate = tostring(inventoryName)
            if string.lower(candidate) == requestedLower or
               internal.normalizeInventoryTowerName(candidate) == requestedNormalized then
               return candidate
            end
         end
      end
      return nil
   end

   function macroRuntime.AutoEquipInventory()
      if isPlayingMacro or autoReplayRunning then
         return false, "Stop macro playback and Auto Replay before changing the inventory."
      end
      if not internal.canChangeInventoryLoadout() then
         return false, "Auto Equip Inventory is available in the lobby and before a match starts."
      end

      local required = macroRuntime.GetRequiredLoadoutTowers()
      if #required == 0 then
         return false, "The selected macro does not contain a tower loadout or any Place actions."
      end

      local inventory, inventoryError = macroRuntime.ReadInventoryTroops(5)
      if not inventory then return false, "Could not read Inventory.Troops: " .. tostring(inventoryError) end
      local loadoutContext = macroRuntime.GetInventoryLoadoutContext()

      local desired = {}
      local desiredSet = {}
      local missing = {}
      for _, requestedName in ipairs(required) do
         local inventoryName = macroRuntime.ResolveInventoryTowerName(requestedName, inventory)
         if inventoryName then
            local key = internal.normalizeInventoryTowerName(inventoryName)
            if not desiredSet[key] then
               desiredSet[key] = true
               table.insert(desired, inventoryName)
            end
         else
            table.insert(missing, tostring(requestedName))
         end
      end

      if #missing > 0 then
         return false, "These macro towers were not found in your inventory: " .. table.concat(missing, ", ")
      end
      if #desired > loadoutContext.Limit then
         return false, "The macro requires " .. tostring(#desired) .. " unique towers, but the " ..
            loadoutContext.Label .. " limit is " .. tostring(loadoutContext.Limit) .. "."
      end

      local currentlyEquipped = {}
      local equippedSet = {}
      local equippedData = macroRuntime.ReadEquippedTroops(5, loadoutContext.CachePath)
      if equippedData then
         currentlyEquipped = macroRuntime.GetEquippedTowerNames(equippedData)
      else

         for towerName, towerData in pairs(inventory) do
            if type(towerData) == "table" and towerData.Equipped == true then
               table.insert(currentlyEquipped, tostring(towerName))
            end
         end
      end
      for _, towerName in ipairs(currentlyEquipped) do
         equippedSet[internal.normalizeInventoryTowerName(towerName)] = true
      end
      table.sort(currentlyEquipped)

      local changed = false
      for _, towerName in ipairs(currentlyEquipped) do
         if not desiredSet[internal.normalizeInventoryTowerName(towerName)] then
            changed = true
            break
         end
      end
      if not changed then
         for _, towerName in ipairs(desired) do
            if not equippedSet[internal.normalizeInventoryTowerName(towerName)] then
               changed = true
               break
            end
         end
      end

      if not changed then
         return true, "The selected macro " .. loadoutContext.Label .. " is already equipped: " ..
            table.concat(desired, ", ")
      end

      macroRuntime.PreviousLoadout = {}
      for _, towerName in ipairs(currentlyEquipped) do
         table.insert(macroRuntime.PreviousLoadout, towerName)
      end
      macroRuntime.PreviousLoadoutContext = {
         CachePath = loadoutContext.CachePath,
         ItemType = loadoutContext.ItemType,
         Limit = loadoutContext.Limit,
         Label = loadoutContext.Label,
      }

      for _, towerName in ipairs(currentlyEquipped) do
         if not desiredSet[internal.normalizeInventoryTowerName(towerName)] then
            local sent, sendError = macroRuntime.RequestInventoryTowerChange(
               "Unequip",
               towerName,
               loadoutContext.ItemType
            )
            if not sent then return false, "Could not unequip " .. towerName .. ": " .. tostring(sendError) end
            task.wait(0.12)
         end
      end

      for _, towerName in ipairs(desired) do
         if not equippedSet[internal.normalizeInventoryTowerName(towerName)] then
            local sent, sendError = macroRuntime.RequestInventoryTowerChange(
               "Equip",
               towerName,
               loadoutContext.ItemType
            )
            if not sent then return false, "Could not equip " .. towerName .. ": " .. tostring(sendError) end
            task.wait(0.12)
         end
      end

      task.wait(0.6)
      local verifiedEquipped = macroRuntime.ReadEquippedTroops(5, loadoutContext.CachePath)
      if not verifiedEquipped then
         return true, "Equip requests sent for: " .. table.concat(desired, ", ") .. " (verification unavailable)."
      end

      local verifiedSet = {}
      for _, towerName in ipairs(macroRuntime.GetEquippedTowerNames(verifiedEquipped)) do
         verifiedSet[internal.normalizeInventoryTowerName(towerName)] = true
      end
      local failed = {}
      for _, towerName in ipairs(desired) do
         if not verifiedSet[internal.normalizeInventoryTowerName(towerName)] then table.insert(failed, towerName) end
      end
      if #failed > 0 then
         return false, "The server did not equip: " .. table.concat(failed, ", ")
      end
      for towerKey in pairs(verifiedSet) do
         if not desiredSet[towerKey] then
            return false, "The server kept an extra tower equipped; reopen the inventory and try again."
         end
      end
      return true, "Equipped the selected macro " .. loadoutContext.Label .. ": " .. table.concat(desired, ", ")
   end

   function macroRuntime.RestorePreviousLoadout()
      if isPlayingMacro or autoReplayRunning then
         return false, "Stop macro playback and Auto Replay before restoring the inventory."
      end
      if not internal.canChangeInventoryLoadout() then
         return false, "The previous loadout can be restored in the lobby or before a match starts."
      end

      local desired = macroRuntime.PreviousLoadout
      local context = macroRuntime.PreviousLoadoutContext
      if type(desired) ~= "table" or type(context) ~= "table" then
         return false, "No previous Auto Equip loadout has been saved yet."
      end

      local equippedData, equippedError = macroRuntime.ReadEquippedTroops(5, context.CachePath)
      if not equippedData then
         return false, "Could not read the current " .. tostring(context.Label or "loadout") .. ": " ..
            tostring(equippedError)
      end

      local currentlyEquipped = macroRuntime.GetEquippedTowerNames(equippedData)
      local desiredSet = {}
      local currentSet = {}
      for _, towerName in ipairs(desired) do
         desiredSet[internal.normalizeInventoryTowerName(towerName)] = true
      end
      for _, towerName in ipairs(currentlyEquipped) do
         currentSet[internal.normalizeInventoryTowerName(towerName)] = true
      end

      local changed = false
      for _, towerName in ipairs(currentlyEquipped) do
         if not desiredSet[internal.normalizeInventoryTowerName(towerName)] then
            local sent, sendError = macroRuntime.RequestInventoryTowerChange(
               "Unequip",
               towerName,
               context.ItemType
            )
            if not sent then return false, "Could not unequip " .. towerName .. ": " .. tostring(sendError) end
            changed = true
            task.wait(0.12)
         end
      end

      for _, towerName in ipairs(desired) do
         if not currentSet[internal.normalizeInventoryTowerName(towerName)] then
            local sent, sendError = macroRuntime.RequestInventoryTowerChange(
               "Equip",
               towerName,
               context.ItemType
            )
            if not sent then return false, "Could not equip " .. towerName .. ": " .. tostring(sendError) end
            changed = true
            task.wait(0.12)
         end
      end

      local loadoutText = #desired > 0 and table.concat(desired, ", ") or "empty"
      if not changed then
         return true, "The previous " .. tostring(context.Label or "loadout") .. " is already restored: " ..
            loadoutText
      end

      task.wait(0.6)
      local verifiedData = macroRuntime.ReadEquippedTroops(5, context.CachePath)
      if verifiedData then
         local verifiedSet = {}
         for _, towerName in ipairs(macroRuntime.GetEquippedTowerNames(verifiedData)) do
            verifiedSet[internal.normalizeInventoryTowerName(towerName)] = true
         end
         for _, towerName in ipairs(desired) do
            if not verifiedSet[internal.normalizeInventoryTowerName(towerName)] then
               return false, "The server did not restore " .. towerName .. "."
            end
         end
         for towerKey in pairs(verifiedSet) do
            if not desiredSet[towerKey] then
               return false, "The server kept an extra tower equipped while restoring the loadout."
            end
         end
      end

      return true, "Restored the previous " .. tostring(context.Label or "loadout") .. ": " .. loadoutText
   end

   function internal.getEventWaveFields(event)
      if type(event) ~= "table" then return nil, nil, nil end
      local wave = tonumber(event.Wave)
      local elapsed = tonumber(event.WaveElapsed or event.WaveTimestamp)
      return wave, elapsed, tonumber(event.WaveTimer or event.WaveTime)
   end

   function internal.compareMacroEvents(a, b)
      local aWave, aElapsed = internal.getEventWaveFields(a)
      local bWave, bElapsed = internal.getEventWaveFields(b)
      if aWave ~= nil and bWave ~= nil then
         if aWave ~= bWave then return aWave < bWave end
         if (type(a) == "table" and a.SourceFormat == "AutoTDS") or (type(b) == "table" and b.SourceFormat == "AutoTDS") then
            local aOrder = type(a) == "table" and tonumber(a.Order) or 0
            local bOrder = type(b) == "table" and tonumber(b.Order) or 0
            return (aOrder or 0) < (bOrder or 0)
         end
         if (aElapsed or 0) ~= (bElapsed or 0) then return (aElapsed or 0) < (bElapsed or 0) end
      elseif aWave ~= nil then
         return true
      elseif bWave ~= nil then
         return false
      end

      local aTime = type(a) == "table" and tonumber(a.Timestamp) or 0
      local bTime = type(b) == "table" and tonumber(b.Timestamp) or 0
      if (aTime or 0) ~= (bTime or 0) then return (aTime or 0) < (bTime or 0) end

      local aOrder = type(a) == "table" and tonumber(a.Order) or nil
      local bOrder = type(b) == "table" and tonumber(b.Order) or nil
      return (aOrder or 0) < (bOrder or 0)
   end

   function internal.waitForMacroWaveEvent(event, fallbackTimestamp, playbackStartClock, waveStartTimes)
      local targetWave, targetElapsed = internal.getEventWaveFields(event)
      if type(event) == "table" and event.TimingMode == "WaveTimerCountdown" and targetWave ~= nil then
         targetWave = math.max(0, math.floor(targetWave))
         local targetTimer = tonumber(event.WaveTimer or event.WaveTime)
         local fallbackElapsed = math.max(0, tonumber(event.WaveElapsedFallback) or 0)
         waveStartTimes = waveStartTimes or {}

         while isPlayingMacro do
            local currentWave = internal.readWaveValue()
            if currentWave >= targetWave then
               if currentWave == targetWave and not waveStartTimes[tostring(targetWave)] then
                  waveStartTimes[tostring(targetWave)] = os.clock()
               end
               break
            end
            task.wait(0.1)
         end

         while isPlayingMacro do
            local currentWave = internal.readWaveValue()
            if currentWave > targetWave then break end
            if currentWave < targetWave then
               task.wait(0.1)
            else
               local key = tostring(targetWave)
               if not waveStartTimes[key] then waveStartTimes[key] = os.clock() end
               local currentTimer = internal.readWaveTimerValue()
               local timerUsable = currentTimer ~= nil and math.abs(tonumber(currentTimer) or 0) < 1000000000
               if timerUsable and targetTimer ~= nil and currentTimer <= targetTimer + 0.05 then break end
               local observedWaveElapsed = os.clock() - waveStartTimes[key]
               if not timerUsable and observedWaveElapsed >= internal.adjustMacroPlaybackSeconds(math.max(3, fallbackElapsed)) then break end
               task.wait(0.05)
            end
         end
         return
      end

      if targetWave == nil or targetElapsed == nil then
         internal.waitForMacroTimestamp(fallbackTimestamp, playbackStartClock)
         return
      end

      targetWave = math.max(0, math.floor(targetWave))
      targetElapsed = internal.adjustMacroPlaybackSeconds(math.max(0, targetElapsed))
      waveStartTimes = waveStartTimes or {}

      while isPlayingMacro do
         local currentWave = internal.readWaveValue()
         if currentWave >= targetWave then
            if currentWave == targetWave and not waveStartTimes[tostring(targetWave)] then
               waveStartTimes[tostring(targetWave)] = os.clock()
            end
            break
         end
         task.wait(0.1)
      end

      while isPlayingMacro do
         local currentWave = internal.readWaveValue()
         if currentWave > targetWave then break end
         if currentWave < targetWave then
            task.wait(0.1)
         else
            local key = tostring(targetWave)
            if not waveStartTimes[key] then waveStartTimes[key] = os.clock() end
            local waveElapsed = os.clock() - waveStartTimes[key]
            local remaining = targetElapsed - waveElapsed
            if remaining <= 0 then break end
            task.wait(math.min(remaining, 0.05))
         end
      end
   end

   function internal.isEarlyEconomyMacroEvent(event)
      if type(event) ~= "table" then return false end
      return event.Action == "Place" or event.Action == "Upgrade"
   end

   local cachedMatchCashAmount = nil

   function internal.readMatchCash()
      local names = {"Cash", "Money", "Currency", "Current", "Value", "Amount"}
      local player = LocalPlayer or Players.LocalPlayer
      local playerGui = player and player:FindFirstChildOfClass("PlayerGui")

      if playerGui then
         if typeof(cachedMatchCashAmount) ~= "Instance" or cachedMatchCashAmount.Parent == nil then
            local hotbar = playerGui:FindFirstChild("ReactUniversalHotbar")
            local frame = hotbar and hotbar:FindFirstChild("Frame")
            local values = frame and frame:FindFirstChild("values")
            local cash = values and values:FindFirstChild("cash")
            cachedMatchCashAmount = cash and cash:FindFirstChild("amount")
         end

         local hotbarCash = internal.readInstanceNumber(cachedMatchCashAmount, names)
         if hotbarCash ~= nil then return hotbarCash end
      end

      if player then
         for _, name in ipairs({"Cash", "Money", "Currency"}) do
            local attributeSuccess, attributeValue = pcall(function() return player:GetAttribute(name) end)
            local attributeNumber = attributeSuccess and internal.coerceNumber(attributeValue) or nil
            if attributeNumber ~= nil then return attributeNumber end

            local playerValue = internal.readInstanceNumber(player:FindFirstChild(name), names)
            if playerValue ~= nil then return playerValue end
         end
      end

      local state = ReplicatedStorage:FindFirstChild("State")
      local cashState = state and (state:FindFirstChild("Cash") or state:FindFirstChild("Money"))
      if cashState then
         local cashValue = internal.readInstanceNumber(cashState, names)
         if cashValue ~= nil then return cashValue end

         if player then
            for _, childName in ipairs({tostring(player.UserId), player.Name, "Current", "Value"}) do
               cashValue = internal.readInstanceNumber(cashState:FindFirstChild(childName), names)
               if cashValue ~= nil then return cashValue end
            end
         end
      end

      local topDisplay = playerGui and playerGui:FindFirstChild("ReactGameTopGameDisplay")
      local frame = topDisplay and topDisplay:FindFirstChild("Frame")
      if frame then
         for _, cashName in ipairs({"cash", "Cash", "money", "Money"}) do
            local cashDisplay = frame:FindFirstChild(cashName, true)
            local cashValue = internal.readInstanceNumber(cashDisplay, names)
            if cashValue ~= nil then return cashValue end
            if cashDisplay then
               for _, descendant in ipairs(cashDisplay:GetDescendants()) do
                  cashValue = internal.readInstanceNumber(descendant, names)
                  if cashValue ~= nil then return cashValue end
               end
            end
         end
      end

      return nil
   end

   function internal.isMacroEventDueNow(event, fallbackTimestamp, playbackStartClock, waveStartTimes)
      local targetWave, targetElapsed, targetTimer = internal.getEventWaveFields(event)
      local currentWave = internal.readWaveValue()
      waveStartTimes = waveStartTimes or {}

      if type(event) == "table" and event.TimingMode == "WaveTimerCountdown" and targetWave ~= nil then
         targetWave = math.max(0, math.floor(targetWave))
         if currentWave > targetWave then return true end
         if currentWave < targetWave then return false end

         local key = tostring(targetWave)
         if not waveStartTimes[key] then waveStartTimes[key] = os.clock() end
         local currentTimer = internal.readWaveTimerValue()
         local timerUsable = currentTimer ~= nil and math.abs(tonumber(currentTimer) or 0) < 1000000000
         if timerUsable and targetTimer ~= nil then
            return currentTimer <= targetTimer + 0.05
         end

         local fallbackElapsed = math.max(3, tonumber(event.WaveElapsedFallback) or 0)
         return (os.clock() - waveStartTimes[key]) >= internal.adjustMacroPlaybackSeconds(fallbackElapsed)
      end

      if targetWave == nil or targetElapsed == nil then
         local target = internal.adjustMacroPlaybackSeconds(fallbackTimestamp)
         return (os.clock() - (tonumber(playbackStartClock) or os.clock())) >= target
      end

      targetWave = math.max(0, math.floor(targetWave))
      if currentWave > targetWave then return true end
      if currentWave < targetWave then return false end

      local key = tostring(targetWave)
      if not waveStartTimes[key] then waveStartTimes[key] = os.clock() end
      local adjustedElapsed = internal.adjustMacroPlaybackSeconds(math.max(0, targetElapsed))
      return (os.clock() - waveStartTimes[key]) >= adjustedElapsed
   end

   function internal.startEarlyEconomyActionWorker(timeline, playbackStartClock, waveStartTimes)
      local states = {}
      if not earlyEconomyActionsEnabled then return states end

      task.spawn(function()
         for _, event in ipairs(timeline) do
            if not isPlayingMacro or not earlyEconomyActionsEnabled then break end
            if internal.isEarlyEconomyMacroEvent(event) then
               local attempted = false
               local lastAttemptAt = 0
               local lastAttemptCash = nil

               while isPlayingMacro and earlyEconomyActionsEnabled and states[event] == nil do
                  if internal.isMacroEventDueNow(event, event.Timestamp, playbackStartClock, waveStartTimes) then
                     break
                  end

                  local now = os.clock()
                  local currentCash = internal.readMatchCash()
                  local cashChanged = currentCash ~= nil and currentCash ~= lastAttemptCash
                  if not attempted or cashChanged or (now - lastAttemptAt) >= 1 then
                     attempted = true
                     lastAttemptAt = now
                     lastAttemptCash = currentCash
                     states[event] = "attempting"

                     local callSuccess, replaySuccess, _, replayRetryable = pcall(internal.replayMacroEvent, event)
                     if callSuccess and replaySuccess then
                        states[event] = "early-success"
                        print("[TDSPro] Early " .. tostring(event.Action) .. " completed" ..
                           (currentCash ~= nil and (" at $" .. tostring(currentCash)) or ""))
                     elseif callSuccess and replayRetryable == true then
                        states[event] = nil
                     else
                        states[event] = "deferred"
                        break
                     end
                  end
                  task.wait(0.05)
               end



               while isPlayingMacro and earlyEconomyActionsEnabled and
                  (states[event] == nil or states[event] == "attempting" or states[event] == "deferred") do
                  task.wait(0.05)
               end
            elseif type(event) == "table" then

               while isPlayingMacro and earlyEconomyActionsEnabled and states[event] ~= "timeline-complete" do
                  task.wait(0.05)
               end
            end
         end
      end)

      return states
   end

   function internal.waitForEconomicEventOrEarly(event, fallbackTimestamp, playbackStartClock, waveStartTimes, states)
      while isPlayingMacro do
         if states[event] == "early-success" then return true end
         if internal.isMacroEventDueNow(event, fallbackTimestamp, playbackStartClock, waveStartTimes) then return false end
         task.wait(0.05)
      end
      return false
   end

   function internal.createSkipDetails(remoteData)
      local wave = recordingWatch.GetWave and recordingWatch.GetWave() or internal.readWaveValue()
      return {
         Wave = wave,
         WaveTime = internal.readWaveTimerValue(),
         Remote = remoteData
      }
   end

   function internal.detectCurrentGameInfo()
      local info = {
         Map = tostring(internal.readStateValue("Map") or "Unknown"),
         Mode = tostring(internal.readStateValue("Mode") or "Unknown"),
         Difficulty = tostring(internal.readStateValue("Difficulty") or "Unknown"),
         Type = tostring(internal.readStateValue("Type") or "Unknown"),
         Wave = internal.readWaveValue(),
         WaveTime = internal.readWaveTimerValue(),
      }
      return info
   end

   internal.simplifiedMapVisualsEnabled = false
   internal.simplifiedMapVisualsQueued = false
   internal.simplifiedMapOriginalProperties = setmetatable({}, { __mode = "k" })
   internal.simplifiedMapProcessedObjects = setmetatable({}, { __mode = "k" })

   local SIMPLIFIED_SCENERY_FOLDERS = {
      background = true,
      decoration = true,
      decorations = true,
      detail = true,
      details = true,
      easteregg = true,
      eastereggs = true,
      foliage = true,
      scenery = true,
      trees = true,
   }

   function internal.setSimplifiedMapProperty(object, propertyName, value)
      if typeof(object) ~= "Instance" then return false end

      local originalProperties = internal.simplifiedMapOriginalProperties[object]
      if not originalProperties then
         originalProperties = {}
         internal.simplifiedMapOriginalProperties[object] = originalProperties
      end

      if originalProperties[propertyName] == nil then
         local readSuccess, originalValue = pcall(function()
            return object[propertyName]
         end)
         if not readSuccess then return false end
         originalProperties[propertyName] = { Value = originalValue }
      end

      return pcall(function()
         object[propertyName] = value
      end)
   end

   function internal.isOptionalMapScenery(object, environment)
      if typeof(object) ~= "Instance" or typeof(environment) ~= "Instance" then return false end
      if object ~= environment and not object:IsDescendantOf(environment) then return false end

      local current = object
      while current and current ~= environment do
         local normalizedName = string.lower(tostring(current.Name)):gsub("[^%w]", "")
         if SIMPLIFIED_SCENERY_FOLDERS[normalizedName] then return true end
         current = current.Parent
      end
      return false
   end

   function internal.applySimplifiedMapObject(object, map, ground, cliff)
      if not internal.simplifiedMapVisualsEnabled or typeof(object) ~= "Instance" then return end
      if internal.simplifiedMapProcessedObjects[object] then return end

      local inMap = map and (object == map or object:IsDescendantOf(map))
      local inGround = ground and (object == ground or object:IsDescendantOf(ground))
      local inCliff = cliff and (object == cliff or object:IsDescendantOf(cliff))
      if not (inMap or inGround or inCliff) then return end

      internal.simplifiedMapProcessedObjects[object] = true

      local environment = map and map:FindFirstChild("Environment")
      if object:IsA("ParticleEmitter") or object:IsA("Trail") or object:IsA("Beam") or
         object:IsA("Smoke") or object:IsA("Fire") or object:IsA("Sparkles") then
         internal.setSimplifiedMapProperty(object, "Enabled", false)
         return
      end

      if object:IsA("Light") or object:IsA("Highlight") then
         internal.setSimplifiedMapProperty(object, "Enabled", false)
         if object:IsA("Light") then internal.setSimplifiedMapProperty(object, "Shadows", false) end
         return
      end

      if object:IsA("SurfaceAppearance") then


         internal.setSimplifiedMapProperty(object, "ColorMap", "")
         internal.setSimplifiedMapProperty(object, "MetalnessMap", "")
         internal.setSimplifiedMapProperty(object, "NormalMap", "")
         internal.setSimplifiedMapProperty(object, "RoughnessMap", "")
         return
      end

      if object:IsA("Decal") or object:IsA("Texture") then
         internal.setSimplifiedMapProperty(object, "Transparency", 1)
         return
      end

      if object:IsA("SpecialMesh") then
         internal.setSimplifiedMapProperty(object, "TextureId", "")
         return
      end

      if object:IsA("BasePart") then
         internal.setSimplifiedMapProperty(object, "CastShadow", false)
         internal.setSimplifiedMapProperty(object, "Reflectance", 0)
         internal.setSimplifiedMapProperty(object, "Material", Enum.Material.SmoothPlastic)
         internal.setSimplifiedMapProperty(object, "MaterialVariant", "")

         if object:IsA("MeshPart") then
            internal.setSimplifiedMapProperty(object, "RenderFidelity", Enum.RenderFidelity.Performance)
            internal.setSimplifiedMapProperty(object, "TextureID", "")
         elseif object:IsA("PartOperation") then
            internal.setSimplifiedMapProperty(object, "RenderFidelity", Enum.RenderFidelity.Performance)
         end




         local nonCollidable = false
         pcall(function() nonCollidable = object.CanCollide == false end)
         if nonCollidable and internal.isOptionalMapScenery(object, environment) then
            internal.setSimplifiedMapProperty(object, "LocalTransparencyModifier", 1)
         end
      end
   end

   function internal.restoreSimplifiedMapVisuals()
      for object, originalProperties in pairs(internal.simplifiedMapOriginalProperties) do
         if typeof(object) == "Instance" and object.Parent then
            for propertyName, original in pairs(originalProperties) do
               pcall(function()
                  object[propertyName] = original.Value
               end)
            end
         end
      end
      internal.simplifiedMapOriginalProperties = setmetatable({}, { __mode = "k" })
      internal.simplifiedMapProcessedObjects = setmetatable({}, { __mode = "k" })
   end

   function internal.applySimplifiedMapVisuals()
      if not internal.simplifiedMapVisualsEnabled then return end

      local map = workspace:FindFirstChild("Map")
      local ground = workspace:FindFirstChild("Ground")
      local cliff = workspace:FindFirstChild("Cliff")
      for _, root in pairs({ map, ground, cliff }) do
         if typeof(root) == "Instance" then
            internal.applySimplifiedMapObject(root, map, ground, cliff)
            local descendantsSuccess, descendants = pcall(function()
               return root:GetDescendants()
            end)
            if descendantsSuccess then
               for _, descendant in ipairs(descendants) do
                  internal.applySimplifiedMapObject(descendant, map, ground, cliff)
               end
            end
         end
      end
   end

   function internal.queueSimplifiedMapVisuals()
      if not internal.simplifiedMapVisualsEnabled or internal.simplifiedMapVisualsQueued then return end
      internal.simplifiedMapVisualsQueued = true
      task.defer(function()
         internal.simplifiedMapVisualsQueued = false
         internal.applySimplifiedMapVisuals()
      end)
   end

   function internal.normalizeVotingMapName(mapName)
      if mapName == nil then return "" end
      local normalized = tostring(mapName)
      normalized = normalized:gsub("<[^>]->", "")
      normalized = normalized:gsub("\194\160", " ")
      normalized = normalized:gsub("%s+", " ")
      normalized = normalized:match("^%s*(.-)%s*$") or ""
      return normalized:lower()
   end

   function internal.canonicalVotingMapName(mapName)
      local normalized = internal.normalizeVotingMapName(mapName)
      normalized = normalized:gsub("^map%s*:%s*", "")
      return normalized:gsub("[^%w]", "")
   end

   function internal.votingMapNamesMatch(candidate, targetMap)
      local candidateName = internal.normalizeVotingMapName(candidate)
      local targetName = internal.normalizeVotingMapName(targetMap)
      if candidateName == "" or targetName == "" then return false end
      if candidateName == targetName then return true end

      local candidateCanonical = internal.canonicalVotingMapName(candidateName)
      local targetCanonical = internal.canonicalVotingMapName(targetName)
      return candidateCanonical ~= "" and candidateCanonical == targetCanonical
   end

   function internal.isUsableVotingMapName(mapName)
      local normalized = internal.normalizeVotingMapName(mapName)
      if normalized == "" or normalized == "unknown" or normalized == "n/a" or normalized == "..." then
         return false
      end
      if normalized:match("^loading") or normalized:match("^selecting") then
         return false
      end
      return true
   end

   function internal.readTextValue(object)
      if typeof(object) ~= "Instance" then return nil end

      local textSuccess, text = pcall(function() return object.Text end)
      if textSuccess and type(text) == "string" and internal.isUsableVotingMapName(text) then
         return text
      end

      local value = internal.safeReadValue(object, nil)
      if type(value) == "string" and internal.isUsableVotingMapName(value) then
         return value
      end
      return nil
   end

   function internal.getVotingBoardsRoot()
      local lobby = workspace:FindFirstChild("IntermissionLobby")
      if not lobby then return nil, nil end

      local boards = lobby:FindFirstChild("Boards") or lobby:FindFirstChild("Boards", true)
      if not boards then
         boards = lobby:FindFirstChild("VotingBoards") or lobby:FindFirstChild("VotingBoards", true)
      end
      return boards, lobby
   end

   function internal.getLocalPlayerGui()
      local player = LocalPlayer or Players.LocalPlayer
      return player and player:FindFirstChildOfClass("PlayerGui") or nil
   end

   function internal.isExcludedVotingGuiObject(object)
      local current = object
      while typeof(current) == "Instance" do
         if current:IsA("ScreenGui") then
            local guiName = tostring(current.Name):lower()
            return guiName:find("tdspro", 1, true) ~= nil
               or guiName:find("rayfield", 1, true) ~= nil
               or guiName:find("fluent", 1, true) ~= nil
         end
         current = current.Parent
      end
      return false
   end

   function internal.isVisibleVotingGuiObject(object, playerGui)
      local current = object
      while typeof(current) == "Instance" and current ~= playerGui do
         if current:IsA("GuiObject") and current.Visible == false then return false end
         if current:IsA("ScreenGui") and current.Enabled == false then return false end
         current = current.Parent
      end
      return current == playerGui
   end

   isVotingLobbyReady = function()
      if workspace:FindFirstChild("IntermissionLobby") then return true end

      local playerGui = internal.getLocalPlayerGui()
      if not playerGui then return false end

      local descendantsSuccess, descendants = pcall(function()
         return playerGui:GetDescendants()
      end)
      if not descendantsSuccess then return false end

      for _, object in ipairs(descendants) do
         if not internal.isExcludedVotingGuiObject(object) and internal.isVisibleVotingGuiObject(object, playerGui) then
            local objectName = tostring(object.Name):lower():gsub("[^%w]", "")
            if objectName:find("maptesting", 1, true)
               or objectName:find("mapselection", 1, true)
               or objectName:find("mapvoting", 1, true)
               or objectName:find("votingboards", 1, true) then
               return true
            end

            local textSuccess, objectText = pcall(function() return object.Text end)
            if textSuccess and type(objectText) == "string" then
               local normalizedText = internal.normalizeVotingMapName(objectText):gsub("[^%w]", "")
               if normalizedText == "maptesting"
                  or normalizedText == "mapselection"
                  or normalizedText == "mapvoting" then
                  return true
               end
            end
         end
      end

      return false
   end

   function internal.findTargetMapInVotingUi(targetMap)
      local boards, lobby = internal.getVotingBoardsRoot()
      local searchRoots = {}
      local worldRoot = boards or lobby
      if worldRoot then table.insert(searchRoots, worldRoot) end

      local playerGui = internal.getLocalPlayerGui()
      if playerGui then table.insert(searchRoots, playerGui) end

      for _, searchRoot in ipairs(searchRoots) do
         local objects = {searchRoot}
         local descendantsSuccess, descendants = pcall(function()
            return searchRoot:GetDescendants()
         end)
         if descendantsSuccess then
            for _, descendant in ipairs(descendants) do
               table.insert(objects, descendant)
            end
         end

         for _, object in ipairs(objects) do
            local guiObjectVisible = searchRoot ~= playerGui or internal.isVisibleVotingGuiObject(object, playerGui)
            if not internal.isExcludedVotingGuiObject(object) and guiObjectVisible then
               for _, propertyName in ipairs({"Text", "ContentText", "Value"}) do
                  local propertySuccess, propertyValue = pcall(function()
                     return object[propertyName]
                  end)
                  if propertySuccess and type(propertyValue) == "string" and internal.votingMapNamesMatch(propertyValue, targetMap) then
                     return true, propertyValue
                  end
               end

               if internal.votingMapNamesMatch(object.Name, targetMap) then
                  return true, object.Name
               end

               for _, attributeName in ipairs({"Map", "MapName", "MapTitle", "Title"}) do
                  local attributeSuccess, attributeValue = pcall(function()
                     return object:GetAttribute(attributeName)
                  end)
                  if attributeSuccess and type(attributeValue) == "string" and internal.votingMapNamesMatch(attributeValue, targetMap) then
                     return true, attributeValue
                  end
               end
            end
         end
      end

      return false
   end

   function internal.readVotingBoardMap(board)
      if typeof(board) ~= "Instance" then return nil end



      local directSuccess, directTitle = pcall(function()
         return board.Hitboxes.Bottom.MapDisplay.Title
      end)
      if directSuccess then
         local directText = internal.readTextValue(directTitle)
         if directText then return directText end
      end



      for _, descendant in ipairs(board:GetDescendants()) do
         local descendantName = tostring(descendant.Name):lower()
         if descendantName == "mapdisplay" then
            local title = descendant:FindFirstChild("Title", true)
            local titleText = internal.readTextValue(title)
            if titleText then return titleText end

            local displayText = internal.readTextValue(descendant)
            if displayText then return displayText end
         end
      end


      for _, descendant in ipairs(board:GetDescendants()) do
         local descendantName = tostring(descendant.Name):lower()
         if descendantName == "mapname" or descendantName == "maptitle" then
            local mapText = internal.readTextValue(descendant)
            if mapText then return mapText end
         end
      end

      for _, descendant in ipairs(board:GetDescendants()) do
         if tostring(descendant.Name):lower() == "title" then
            local titleText = internal.readTextValue(descendant)
            if titleText then return titleText end
         end
      end

      for _, attributeName in ipairs({"Map", "MapName"}) do
         local attributeSuccess, attributeValue = pcall(function()
            return board:GetAttribute(attributeName)
         end)
         if attributeSuccess and type(attributeValue) == "string" and internal.isUsableVotingMapName(attributeValue) then
            return attributeValue
         end
      end

      return nil
   end

   function internal.getVotingBoardMaps()
      local maps = {}
      local boards = internal.getVotingBoardsRoot()
      if not boards then return maps, 0, 0 end

      local children = boards:GetChildren()
      local boardCandidates = {}
      for _, child in ipairs(children) do
         if tostring(child.Name):lower():match("board") then
            table.insert(boardCandidates, child)
         end
      end
      if #boardCandidates == 0 then
         boardCandidates = children
      end

      local boardCount = 0
      local readableBoardCount = 0
      for _, board in ipairs(boardCandidates) do
         boardCount = boardCount + 1
         local readSuccess, mapName = pcall(internal.readVotingBoardMap, board)
         if readSuccess and mapName then
            readableBoardCount = readableBoardCount + 1
            table.insert(maps, mapName)
         end
      end
      return maps, boardCount, readableBoardCount
   end

   function macroRuntime.GetVotingMapSignature(maps)
      local normalizedMaps = {}
      for _, mapName in ipairs(maps or {}) do
         table.insert(normalizedMaps, internal.canonicalVotingMapName(mapName))
      end
      table.sort(normalizedMaps)
      return table.concat(normalizedMaps, "\31")
   end

   function macroRuntime.WaitForVetoResult(targetMap, previousMaps, timeout)
      local previousSignature = macroRuntime.GetVotingMapSignature(previousMaps)
      local deadline = os.clock() + (tonumber(timeout) or 15)
      local lastMaps = previousMaps or {}
      local changedSignature = nil
      local stableReads = 0

      while autoReplayEnabled and os.clock() < deadline do
         local targetVisible, matchedText = internal.findTargetMapInVotingUi(targetMap)
         if targetVisible then return true, {matchedText} end

         local maps, boardCount, readableBoardCount = internal.getVotingBoardMaps()
         if #maps > 0 then lastMaps = maps end
         if boardCount >= 4 and readableBoardCount == boardCount then
            for _, mapName in ipairs(maps) do
               if internal.votingMapNamesMatch(mapName, targetMap) then return true, maps end
            end

            local signature = macroRuntime.GetVotingMapSignature(maps)
            if signature ~= "" and signature ~= previousSignature then
               if signature == changedSignature then
                  stableReads = stableReads + 1
               else
                  changedSignature = signature
                  stableReads = 1
               end
               if stableReads >= 2 then return false, maps end
            end
         end
         task.wait(0.4)
      end

      return nil, lastMaps, "Vetoed boards did not finish refreshing."
   end

   function macroRuntime.TryMapVeto(targetMap, previousMaps)
      local lastMaps = previousMaps or {}
      local lastError = nil




      for attempt = 1, 2 do
         updateReplayStatus("Map Reroll: sending veto" .. (attempt == 2 and " again..." or "..."))
         local vetoSent, vetoError = internal.fireTDSRemoteEvent("LobbyVoting", "Veto")
         if vetoSent then
            local vetoFound, vetoMaps, vetoWaitError = macroRuntime.WaitForVetoResult(targetMap, lastMaps, 12)
            if type(vetoMaps) == "table" and #vetoMaps > 0 then lastMaps = vetoMaps end
            if vetoFound ~= nil then return vetoFound, lastMaps, vetoWaitError end
            lastError = vetoWaitError
         else
            lastError = vetoError
         end

         if attempt == 1 and autoReplayEnabled then
            updateReplayStatus("Veto produced no board refresh. Retrying once before rejoining...")
            task.wait(0.75)
         end
      end

      return nil, lastMaps, lastError or "Veto request was not confirmed by a board refresh."
   end

   function internal.findMapOnStableVotingBoards(targetMap, timeout)
      local targetName = internal.normalizeVotingMapName(targetMap)
      if targetName == "" then return nil, {}, "Target map name is empty." end

      local deadline = os.clock() + (tonumber(timeout) or 10)
      local stableSignature = nil
      local stableReads = 0
      local lastMaps = {}
      local lastBoardCount = 0
      local lastReadableCount = 0
      local guiReadySince = nil

      while autoReplayEnabled and os.clock() < deadline do
         local targetVisible, matchedText = internal.findTargetMapInVotingUi(targetMap)
         if targetVisible then
            return true, {matchedText}
         end

         if isVotingLobbyReady() then
            guiReadySince = guiReadySince or os.clock()
         else
            guiReadySince = nil
         end

         local boardMaps, boardCount, readableBoardCount = internal.getVotingBoardMaps()
         lastMaps = boardMaps
         lastBoardCount = boardCount
         lastReadableCount = readableBoardCount

         local normalizedMaps = {}
         for _, boardMap in ipairs(boardMaps) do
            local normalizedMap = internal.normalizeVotingMapName(boardMap)
            table.insert(normalizedMaps, normalizedMap)
            if internal.votingMapNamesMatch(boardMap, targetName) then
               return true, boardMaps
            end
         end



         local completeScan = boardCount >= 4 and readableBoardCount == boardCount
         if completeScan then
            table.sort(normalizedMaps)
            local signature = table.concat(normalizedMaps, "\31")
            if signature == stableSignature then
               stableReads = stableReads + 1
            else
               stableSignature = signature
               stableReads = 1
            end

            if stableReads >= 3 then
               return false, boardMaps
            end
         elseif guiReadySince and (os.clock() - guiReadySince) >= 5 then



            return false, {"map-selection UI (target not displayed)"}
         else
            stableSignature = nil
            stableReads = 0
         end

         task.wait(0.4)
      end

      return nil, lastMaps, "Board scan incomplete (" .. tostring(lastReadableCount) .. "/" .. tostring(lastBoardCount) .. " readable)."
   end

   function macroRuntime.WaitForVIPOverrideConfirmation(targetMap, timeout)
      local deadline = os.clock() + math.max(2, tonumber(timeout) or 10)
      local lastVisibleMaps = {}

      while autoReplayEnabled and os.clock() < deadline do
         local targetVisible, matchedText = internal.findTargetMapInVotingUi(targetMap)
         if targetVisible then
            return true, tostring(matchedText or targetMap)
         end

         local boardMaps = internal.getVotingBoardMaps()
         if #boardMaps > 0 then
            lastVisibleMaps = boardMaps
            for _, mapName in ipairs(boardMaps) do
               if internal.votingMapNamesMatch(mapName, targetMap) then
                  return true, tostring(mapName)
               end
            end
         end
         task.wait(0.25)
      end

      local visibleText = #lastVisibleMaps > 0 and table.concat(lastVisibleMaps, ", ") or "no readable maps"
      return false, "TDS accepted the request, but the target map never appeared (" .. visibleText .. ")."
   end

   function macroRuntime.TryVIPMapOverride(targetMap)
      local alreadyVisible, matchedText = internal.findTargetMapInVotingUi(targetMap)
      if alreadyVisible then
         return true, tostring(matchedText or targetMap) .. " already available"
      end

      local lastError = nil

      for attempt = 1, 2 do
         updateReplayStatus("VIP Override: selecting '" .. tostring(targetMap) .. "'" ..
            (attempt == 2 and " (retry 2/2)..." or "..."))

         local callSuccess, acceptedResult, packedResults = internal.invokeTDSRemoteFunction(
            "LobbyVoting",
            "Override",
            targetMap
         )
         if not callSuccess then
            lastError = tostring(acceptedResult or "the override remote call failed")
         elseif acceptedResult ~= true then
            local serverMessage = type(packedResults) == "table" and packedResults[2] or nil
            return false, tostring(serverMessage or acceptedResult or "TDS rejected the VIP override request")
         else
            local confirmed, confirmation = macroRuntime.WaitForVIPOverrideConfirmation(targetMap, 10)
            if confirmed then
               return true, confirmation
            end
            lastError = confirmation
         end

         if attempt == 1 and autoReplayEnabled then
            updateReplayStatus("VIP Override was not confirmed. Retrying once...")
            task.wait(0.75)
         end
      end

      return false, lastError or "VIP override was not confirmed."
   end

   function internal.formatTimestamp(seconds)
      seconds = tonumber(seconds) or 0
      local negative = seconds < 0
      seconds = math.abs(seconds)
      local mins = math.floor(seconds / 60)
      local secs = math.floor(seconds % 60)
      return (negative and "-" or "") .. string.format("%02d:%02d", mins, secs)
   end

   function internal.formatLogEntry(actionType, details, elapsed, event)
      local wave = type(event) == "table" and tonumber(event.Wave) or nil
      local waveElapsed = type(event) == "table" and tonumber(event.WaveElapsed or event.WaveTimestamp) or nil
      local ts = internal.formatTimestamp(waveElapsed or elapsed)
      local prefix = wave ~= nil and ("[W" .. tostring(wave) .. " " .. ts .. "]") or ("[" .. ts .. "]")
      local msg = ""

      if actionType == "Place" then
         local troop = internal.formatTowerLabel(details)
         msg = prefix .. " Placed [" .. troop .. "]"
      elseif actionType == "Upgrade" then
         local name = internal.formatTowerLabel(details)
         local path = (type(details) == "table" and details.Path) or "?"
         msg = prefix .. " Upgraded [" .. name .. "] Path " .. tostring(path)
      elseif actionType == "Sell" then
         local troop = internal.formatTowerLabel(details)
         msg = prefix .. " Sold [" .. troop .. "]"
      elseif actionType == "Skip" then
         local skipWave = wave or (type(details) == "table" and tonumber(details.Wave) or nil)
         local waveTime = type(details) == "table" and tonumber(details.WaveTime) or nil
         local timerText = waveTime and (" @ " .. tostring(math.floor(waveTime)) .. "s") or ""
         if skipWave and skipWave > 0 then
            msg = prefix .. " Skipped Wave " .. tostring(skipWave) .. timerText
         else
            msg = prefix .. " Skipped Wave" .. timerText
         end
      elseif actionType == "Ready" then
         msg = prefix .. " Readied Up"
      elseif actionType == "Veto" then
         msg = prefix .. " Vetoed"
      elseif actionType == "EquipTower" then
         local tower = (type(details) == "table" and details.Tower) or "Unknown"
         msg = prefix .. " Equipped [" .. tower .. "]"
      elseif actionType == "UnequipTower" then
         local tower = (type(details) == "table" and details.Tower) or "Unknown"
         msg = prefix .. " Unequipped [" .. tower .. "]"
      elseif actionType == "CreateSolo" then
         msg = prefix .. " Created Solo Game"
      elseif actionType == "OverrideMap" then
         local map = (type(details) == "table" and details.Map) or "Unknown"
         msg = prefix .. " Override Map: " .. map
      elseif actionType == "VoteMap" then
         local map = (type(details) == "table" and details.Map) or "Unknown"
         msg = prefix .. " Voted Map: " .. map
      elseif actionType == "Target" then
         msg = prefix .. " Changed Target"
      elseif actionType == "Ability" then
         local abilityName = (type(details) == "table" and details.Name) or "Ability"
         local towerName = internal.formatTowerLabel(details)
         msg = prefix .. " Used [" .. abilityName .. "] on [" .. towerName .. "]"
      elseif actionType == "SellAll" then
         msg = prefix .. " Sold All Towers"
      else
         msg = prefix .. " " .. tostring(actionType)
      end

      return msg
   end

   function TimelineUI.FormatPreciseTime(seconds)
      local value = tonumber(seconds) or 0
      if math.abs(value) >= 100000000 then return "order-only" end
      local negative = value < 0
      value = math.abs(value)
      local minutes = math.floor(value / 60)
      local remainingSeconds = value - (minutes * 60)
      return (negative and "-" or "") .. string.format("%02d:%05.2f", minutes, remainingSeconds)
   end

   function TimelineUI.GetTimingLabel(event)
      if type(event) ~= "table" then return "unknown" end
      local wave = tonumber(event.Wave)
      if event.SourceFormat == "AutoTDS" and event.TimingMode == "WaveTimerCountdown" then
         local timer = tonumber(event.WaveTimer or event.WaveTime)
         if wave ~= nil and timer ~= nil then
            return "W" .. tostring(math.floor(wave)) .. " @ " .. string.format("%.2fs left", timer)
         end
      elseif event.SourceFormat == "AutoTDS" and event.TimingMode == "WaveRelative" then
         return "W" .. tostring(math.floor(wave or 0)) .. " endgame +" .. TimelineUI.FormatPreciseTime(event.WaveElapsed)
      end

      local waveElapsed = tonumber(event.WaveElapsed or event.WaveTimestamp)
      if wave ~= nil and waveElapsed ~= nil then
         return "W" .. tostring(math.floor(wave)) .. " +" .. TimelineUI.FormatPreciseTime(waveElapsed)
      end
      if wave ~= nil and tonumber(event.WaveTimer or event.WaveTime) ~= nil then
         return "W" .. tostring(math.floor(wave)) .. " @ " .. string.format("%.2fs", tonumber(event.WaveTimer or event.WaveTime))
      end
      return TimelineUI.FormatPreciseTime(event.Timestamp)
   end

   function TimelineUI.DescribeEvent(event)
      if type(event) ~= "table" then return "Invalid event" end
      local action = tostring(event.Action or "Unknown")
      local details = type(event.Details) == "table" and event.Details or {}
      local towerLabel = internal.formatTowerLabel(details)

      if action == "Place" then
         local x, y, z = internal.getVector3Components(details.Position)
         local positionText = x and string.format(" at (%.2f, %.2f, %.2f)", x, y, z) or ""
         return "Place " .. towerLabel .. positionText
      elseif action == "Upgrade" then
         return "Upgrade " .. towerLabel .. " (path " .. tostring(details.Path or "?") .. ")"
      elseif action == "Sell" then
         return "Sell " .. towerLabel
      elseif action == "Ability" then
         return "Use " .. tostring(details.Name or "ability") .. " on " .. towerLabel
      elseif action == "Option" then
         return "Set " .. towerLabel .. " " .. tostring(details.Name or "option") .. " = " .. tostring(details.Value)
      elseif action == "Target" and details.Target ~= nil then
         return "Set " .. towerLabel .. " targeting mode = " .. tostring(details.Target)
      elseif action == "Custom" then
         return "Set " .. tostring(details.Flag or "custom flag") .. " = " .. (details.Bool and "ON" or "OFF")
      elseif action == "Skip" then
         return "Skip/start wave"
      end

      local formatted = internal.formatLogEntry(action, details, tonumber(event.Timestamp) or 0, event)
      return (formatted:gsub("^%b[]%s*", ""))
   end

   function macroRuntime.GetSelectedModifiers()
      local modifiers = {}
      if not modifierVotingEnabled then return modifiers end

      local seen = {}
      for _, modifier in ipairs(type(selectedModifierOptions) == "table" and selectedModifierOptions or {}) do
         local name = tostring(modifier or "")
         if name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(modifiers, name)
         end
      end
      table.sort(modifiers, function(a, b) return tostring(a) < tostring(b) end)
      return modifiers
   end

   function TimelineUI.Refresh()
      local events = {}
      for _, event in ipairs(recordedTimeline) do
         table.insert(events, event)
      end
      table.sort(events, internal.compareMacroEvents)
      TimelineUI.Events = events
      libraryEmit("TimelineChanged", events)
   end

   function macroRuntime.BeginRunTelemetry(timeline)
      local towerLoadout = {}
      for _, towerInfo in ipairs(type(loadedMacroMeta.Towers) == "table" and loadedMacroMeta.Towers or {}) do
         if type(towerInfo) == "table" then
            table.insert(towerLoadout, tostring(towerInfo.name or towerInfo.Name or "Unknown"))
         else
            table.insert(towerLoadout, tostring(towerInfo))
         end
      end
      local modifiers = macroRuntime.GetSelectedModifiers()
      local currentPlayers = 1
      local partyPlayers = {}
      pcall(function()
         local players = Players:GetPlayers()
         currentPlayers = #players
         for _, player in ipairs(players) do table.insert(partyPlayers, tostring(player.Name)) end
      end)
      macroRuntime.RunTelemetry = {
         Version = 1,
         Macro = tostring(selectedMacroName or currentMacroName or "Unknown"),
         MacroVersion = tostring(loadedMacroMeta.Version or loadedMacroMeta.SchemaVersion or loadedMacroMeta.Created or "1"),
         StartedAt = os.time(),
         StartedClock = os.clock(),
         TotalActions = #(timeline or {}),
         Actions = {},
         EconomySamples = {},
         HealthSamples = {},
         Retried = 0,
         Skipped = 0,
         MapRerolls = tonumber(macroRuntime.PendingMapRerolls) or 0,
         PlayerCount = currentPlayers,
         Players = partyPlayers,
         Modifiers = modifiers,
         Towers = towerLoadout,
      }
      macroRuntime.ActionTelemetryByEvent = {}
      TimelineUI.PlaybackIndex = nil
      TimelineUI.PlaybackTelemetry = macroRuntime.RunTelemetry
   end

   function macroRuntime.BeginActionTelemetry(event, index, playbackStartClock)
      local run = macroRuntime.RunTelemetry
      if type(run) ~= "table" or type(event) ~= "table" then return nil end
      local actualTime = math.max(0, os.clock() - (tonumber(playbackStartClock) or os.clock()))
      local plannedTime = tonumber(event.Timestamp) or 0
      local details = type(event.Details) == "table" and event.Details or {}
      local record = {
         Index = tonumber(index) or (#run.Actions + 1),
         Action = tostring(event.Action or "Unknown"),
         Tower = internal.formatTowerLabel(details),
         TowerId = tonumber(details.TroopId),
         Path = tonumber(details.Path),
         Ability = details.Name and tostring(details.Name) or nil,
         Wave = tonumber(event.Wave),
         Planned = plannedTime,
         PlannedLabel = TimelineUI.GetTimingLabel(event),
         Actual = actualTime,
         Drift = tonumber(event.Wave) == nil and (actualTime - internal.adjustMacroPlaybackSeconds(plannedTime)) or nil,
         CashBefore = internal.readMatchCash(),
         HealthBefore = type(internal.getBaseHealthCurrent) == "function" and internal.getBaseHealthCurrent() or nil,
         Status = "running",
      }
      table.insert(run.Actions, record)
      macroRuntime.ActionTelemetryByEvent[event] = record
      TimelineUI.PlaybackIndex = record.Index
      return record
   end

   function macroRuntime.FinishActionTelemetry(event, success, replayError, attempts)
      local run = macroRuntime.RunTelemetry
      local record = macroRuntime.ActionTelemetryByEvent and macroRuntime.ActionTelemetryByEvent[event] or nil
      if type(run) ~= "table" or type(record) ~= "table" then return end
      record.Completed = math.max(0, os.clock() - (tonumber(run.StartedClock) or os.clock()))
      record.CashAfter = internal.readMatchCash()
      record.HealthAfter = type(internal.getBaseHealthCurrent) == "function" and internal.getBaseHealthCurrent() or nil
      record.Attempts = math.max(1, tonumber(attempts) or 1)
      record.Retries = math.max(0, record.Attempts - 1)
      record.Status = success and "success" or "failed"
      record.Error = success and nil or tostring(replayError or "Unknown playback failure")
      run.Retried = (tonumber(run.Retried) or 0) + record.Retries
      if not success then
         run.Skipped = (tonumber(run.Skipped) or 0) + 1
      end
      table.insert(run.EconomySamples, {Time = record.Completed, Cash = record.CashAfter, Action = record.Action})
      table.insert(run.HealthSamples, {Time = record.Completed, Health = record.HealthAfter, Action = record.Action})
      TimelineUI.PlaybackTelemetry = run
      libraryEmit("TelemetryChanged", run)
      if type(TimelineUI.Refresh) == "function" then TimelineUI.Refresh(false) end
   end

   function internal.pushRecordingLog(entry)
      table.insert(recordingLogLines, entry)
      while #recordingLogLines > MAX_LOG_LINES do
         table.remove(recordingLogLines, 1)
      end
      libraryEmit("RecordingLog", recordingLogLines)
      if RecordingLogParagraph then
         local content = table.concat(recordingLogLines, "\n")
         if content == "" then content = "Waiting for actions..." end
         internal.safeSetParagraph(RecordingLogParagraph, {
            Title = "Recording Log (" .. #recordedTimeline .. " events)",
            Content = content
         })
      end
   end

   function internal.refreshRecordingLogFromTimeline()
      internal.clearTable(recordingLogLines)
      local startIndex = math.max(1, #recordedTimeline - MAX_LOG_LINES + 1)
      for index = startIndex, #recordedTimeline do
         local event = recordedTimeline[index]
         if type(event) == "table" then
            internal.pushRecordingLog(internal.formatLogEntry(event.Action, event.Details, tonumber(event.Timestamp) or 0, event))
         end
      end
   end

   function internal.pushRecordingLogSafe(entry)
       table.insert(PendingLogs, entry)
   end

   function recordingWatch.GetWave()
      local wave = internal.readWaveValue()
      if wave < 0 then return 0 end
      return wave
   end

   function recordingWatch.EnsureWaveStart(wave, clockValue)
      local waveKey = tostring(tonumber(wave) or 0)
      if not recordingWatch.WaveStartTimes[waveKey] then
         recordingWatch.WaveStartTimes[waveKey] = tonumber(clockValue) or os.clock()
      end
      return recordingWatch.WaveStartTimes[waveKey]
   end

   function recordingWatch.GetWaveTiming(clockValue)
      local now = tonumber(clockValue) or os.clock()
      local wave = recordingWatch.GetWave()
      local startedAt = recordingWatch.EnsureWaveStart(wave, now)
      return wave, internal.readWaveTimerValue(), math.max(0, now - startedAt)
   end

   function recordingWatch.Debug(reason, selectedWave, waveTime, waveElapsed)
      if not recordingWatch.DebugEnabled then return end
      local now = os.clock()
      if (now - (recordingWatch.LastDebugAt or 0)) < 0.5 then return end
      recordingWatch.LastDebugAt = now
      local readyPresent = internal.findFirstSkipReadyPrompt() ~= nil
      local stateWave = internal.readWaveValue()
      local stateTimer = internal.readWaveTimerValue()
      internal.pushRecordingLogSafe("[DBG] " .. tostring(reason or "wave") ..
         " ready=" .. tostring(readyPresent) ..
         " readyForcesW0=false" ..
         " stateWave=" .. tostring(stateWave) ..
         " stateTimer=" .. tostring(stateTimer) ..
         " recordingStarted=" .. tostring(recordingTimerStarted) ..
         " selectedWave=" .. tostring(selectedWave) ..
         " waveElapsed=" .. tostring(math.floor((tonumber(waveElapsed) or 0) * 10) / 10) ..
         " eventTimer=" .. tostring(waveTime) ..
         " " .. internal.describeWaveStateDebug())
   end

   function recordingWatch.Anchor(anchorClock, source)
      return false
   end

   function recordingWatch.Start()
      local token = {}
      recordingWatch.Token = token
      recordingWatch.LastWave = internal.readWaveValue()
      recordingWatch.LastTimer = internal.readWaveTimerValue()
      recordingWatch.AnchorAt = nil
      recordingWatch.AnchorSource = nil
      recordingWatch.ReadyPromptSeen = false
      recordingWatch.LastDebugAt = 0
      internal.clearTable(recordingWatch.WaveStartTimes)

       task.spawn(function()
          while recordingWatch.Token == token do
             if isRecording and internal.isInActualMap() then
               local now = os.clock()
               local wave = recordingWatch.GetWave()
               local timer = internal.readWaveTimerValue()
               local lastWave = tonumber(recordingWatch.LastWave) or 0
               if wave ~= lastWave then
                  recordingWatch.WaveStartTimes[tostring(wave)] = now
               end
               recordingWatch.EnsureWaveStart(wave, now)
               recordingWatch.LastWave = wave
               recordingWatch.LastTimer = timer
             end
            task.wait(0.1)
         end
      end)
   end

   function recordingWatch.Stop()
      recordingWatch.Token = nil
      recordingWatch.LastWave = 0
      recordingWatch.LastTimer = nil
      recordingWatch.AnchorAt = nil
      recordingWatch.AnchorSource = nil
      recordingWatch.ReadyPromptSeen = false
      recordingWatch.LastDebugAt = 0
      internal.clearTable(recordingWatch.WaveStartTimes)
   end

   updateReplayStatus = function(text)
      text = tostring(text or "")
      lifecycle.Status = text
      libraryEmit("StatusChanged", text)
      if api.GetState then libraryEmit("StateChanged", api:GetState()) end
      if ReplayStatusParagraph then
         internal.safeSetParagraph(ReplayStatusParagraph, {
            Title = "Auto Replay Status",
            Content = text
         })
      end
      print("[TDSPro AutoReplay] " .. text)
   end

   function internal.normalizeModifierSelection(selection)
      local normalized = {}
      local seen = {}
      if type(selection) == "table" then
         for key, value in pairs(selection) do
            if type(value) == "string" then
               if value ~= "" and not seen[value] then
                  seen[value] = true
                  table.insert(normalized, value)
               end
            elseif value == true and type(key) == "string" then
               if key ~= "" and not seen[key] then
                  seen[key] = true
                  table.insert(normalized, key)
               end
            end
         end
      elseif type(selection) == "string" and selection ~= "" then
         table.insert(normalized, selection)
      end
      table.sort(normalized, function(a, b) return tostring(a) < tostring(b) end)
      return normalized
   end

   function internal.buildSelectedModifierArgs()
      local modifierFlags = {}
      for _, option in ipairs(selectedModifierOptions) do
         local flagName = modifierOptionFlags[option] or tostring(option):gsub("%s+", "")
         if flagName and flagName ~= "" then
            modifierFlags[flagName] = true
         end
      end
      if not next(modifierFlags) then return nil end
      return { modifierFlags }
   end

   function internal.voteSelectedModifiers()
      if not modifierVotingEnabled then return true end
      local modifierArgs = internal.buildSelectedModifierArgs()
      if not modifierArgs then return false, "No modifiers selected." end
      updateReplayStatus("Voting modifiers: " .. table.concat(selectedModifierOptions, ", "))
      return internal.invokeBulkVoteModifiers(modifierArgs)
   end

   function internal.startMatchmaking(difficulty, mode)
      if multiplayerEnabled and not isHost then
         updateReplayStatus("Guest: Waiting for Host to start matchmaking...")
         return true, "Guest bypass"
      end

      local difficultyVal = difficulty or loadedMacroMeta.Difficulty or "Easy"
      local modeVal = mode or loadedMacroMeta.Mode or "survival"

      local countVal = 1
      if multiplayerEnabled then
         countVal = tonumber(playerCount) or 2
         local hostDelaySeconds = tonumber(hostDelayVal) or 0
         if hostDelaySeconds > 0 then
            updateReplayStatus("Host: Waiting " .. tostring(hostDelaySeconds) .. "s for guests to load...")
            task.wait(hostDelaySeconds)
         end
      end

      updateReplayStatus("Starting matchmaking (Count: " .. tostring(countVal) .. ", Mode: " .. tostring(modeVal) .. ", Diff: " .. tostring(difficultyVal) .. ")...")
      return internal.invokeTDSRemoteFunction("Multiplayer", "v2:start", {
         difficulty = difficultyVal,
         mode = tostring(modeVal):lower(),
         count = countVal
      })
   end

   function macroRuntime.IsGuiTreeVisible(object)
      if typeof(object) ~= "Instance" then return false end
      local playerGui = internal.getLocalPlayerGui()
      local current = object
      while current and current ~= playerGui do
         if current:IsA("GuiObject") and current.Visible == false then return false end
         if current:IsA("ScreenGui") and current.Enabled == false then return false end
         current = current.Parent
      end
      return current == playerGui
   end

   function macroRuntime.GetGuiCoverage(object, viewportArea)
      if typeof(object) ~= "Instance" or not object:IsA("GuiObject") then return 0 end
      local success, absoluteSize = pcall(function() return object.AbsoluteSize end)
      if not success or not absoluteSize then return 0 end
      return math.max(0, (absoluteSize.X * absoluteSize.Y) / math.max(1, viewportArea))
   end

   function macroRuntime.IsLoadingGuiName(name)
      local normalized = string.lower(tostring(name or "")):gsub("[^%w]", "")
      return string.find(normalized, "loading", 1, true) ~= nil
         or string.find(normalized, "transition", 1, true) ~= nil
         or string.find(normalized, "teleport", 1, true) ~= nil
   end

   function macroRuntime.FindVisibleGameLoadingOverlay()
      local playerGui = internal.getLocalPlayerGui()
      if not playerGui then return nil end
      local camera = workspace.CurrentCamera
      local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
      local viewportArea = math.max(1, viewport.X * viewport.Y)

      for _, screenGui in ipairs(playerGui:GetChildren()) do
         if screenGui:IsA("ScreenGui") and not internal.isExcludedVotingGuiObject(screenGui) then
            local enabledSuccess, enabled = pcall(function() return screenGui.Enabled end)
            if enabledSuccess and enabled ~= false then
               local objects = {screenGui}
               local descendantsSuccess, descendants = pcall(function() return screenGui:GetDescendants() end)
               if descendantsSuccess then
                  for _, descendant in ipairs(descendants) do table.insert(objects, descendant) end
               end

               for _, object in ipairs(objects) do
                  if macroRuntime.IsLoadingGuiName(object.Name) and macroRuntime.IsGuiTreeVisible(object) then
                     local coverage = macroRuntime.GetGuiCoverage(object, viewportArea)
                     if object:IsA("ScreenGui") or coverage < 0.45 then
                        for _, descendant in ipairs(descendantsSuccess and descendants or {}) do
                           if macroRuntime.IsGuiTreeVisible(descendant) then
                              coverage = math.max(coverage, macroRuntime.GetGuiCoverage(descendant, viewportArea))
                           end
                        end
                     end
                     if coverage >= 0.45 then
                        local fullNameSuccess, fullName = pcall(function() return object:GetFullName() end)
                        return object, fullNameSuccess and fullName or tostring(object.Name)
                     end
                  end
               end
            end
         end
      end
      return nil
   end

   function recordingRuntime.EmitLoadingRejoinFailed(reason)
      if recordingRuntime.LoadingRejoinFailureReported then return end
      recordingRuntime.LoadingRejoinFailureReported = true
      recordingRuntime.DispatchWebhookEvent(
         "LoadingRejoinFailed",
         "LOADING SCREEN FAILED TO REJOIN",
         tostring(reason or "The automatic loading-screen recovery could not move the client to a fresh server."),
         15548997,
         {
            {name = "MACRO", value = tostring(selectedMacroName or currentMacroName or "Unknown"), inline = true},
            {name = "MAP", value = tostring(loadedMacroMeta.Map or "Unknown"), inline = true},
            {name = "ATTEMPT", value = tostring(macroRuntime.LoadingRecoveryAttempts or 0), inline = true},
         },
         {Critical = true}
      )
   end

   function macroRuntime.RecoverFromStuckLoading(reason)
      if macroRuntime.LoadingRecoveryActive then return end
      macroRuntime.LoadingRecoveryActive = true
      macroRuntime.LoadingRecoveryAttempts = (tonumber(macroRuntime.LoadingRecoveryAttempts) or 0) + 1
      recordingRuntime.LoadingRejoinFailureReported = false
      local attempt = macroRuntime.LoadingRecoveryAttempts
      local timeoutText = tostring(math.floor(tonumber(loadingStallTimeout) or 90))
      warn("[TDSPro Loading Recovery] Loading overlay remained visible for " .. timeoutText .. "s: " .. tostring(reason))
      recordingRuntime.DispatchWebhookEvent(
         "LoadingScreenBroke",
         "LOADING SCREEN BROKE",
         "The loading screen remained visible for " .. timeoutText .. " seconds and automatic recovery started.",
         16753920,
         {
            {name = "DETAIL", value = tostring(reason or "Unknown loading overlay"), inline = false},
            {name = "MACRO", value = tostring(selectedMacroName or currentMacroName or "Unknown"), inline = true},
            {name = "MAP", value = tostring(loadedMacroMeta.Map or "Unknown"), inline = true},
         },
         {Critical = true}
      )
      updateReplayStatus("Loading screen appears stuck. Requesting a fresh match...")
      internal.notifyMacro("Loading screen stuck for " .. timeoutText .. " seconds. Recovering automatically...", 6)

      local requestedFreshMatch = false
      if autoReplayEnabled and not (multiplayerEnabled and not isHost) then
         local requestSuccess, requestResult = internal.startMatchmaking(loadedMacroMeta.Difficulty, loadedMacroMeta.Mode)
         requestedFreshMatch = requestSuccess == true and requestResult ~= false
         if not requestedFreshMatch then
            warn("[TDSPro Loading Recovery] Fresh-match request failed: " .. tostring(requestResult))
         end
      end

      if requestedFreshMatch then
         updateReplayStatus("Fresh match requested. Waiting for the loading screen to clear...")
         local recoveryWait = math.max(20, math.min(45, (tonumber(loadingStallTimeout) or 90) / 2))
         local deadline = os.clock() + recoveryWait
         while loadingStallRecoveryEnabled and os.clock() < deadline do
            if not macroRuntime.FindVisibleGameLoadingOverlay() then
               macroRuntime.LoadingRecoveryActive = false
               macroRuntime.LoadingOverlayVisibleSince = nil
               macroRuntime.LoadingOverlayReason = nil
               updateReplayStatus("Loading recovery succeeded. Continuing Auto Replay...")
               print("[TDSPro Loading Recovery] Loading overlay cleared after fresh-match request.")
               return
            end
            task.wait(1)
         end
      end

      if not loadingStallRecoveryEnabled then
         macroRuntime.LoadingRecoveryActive = false
         macroRuntime.LoadingOverlayVisibleSince = nil
         macroRuntime.LoadingOverlayReason = nil
         return
      end

      local player = LocalPlayer or Players.LocalPlayer
      if not player then
         macroRuntime.LoadingRecoveryActive = false
         macroRuntime.LoadingOverlayVisibleSince = os.clock()
         warn("[TDSPro Loading Recovery] Rejoin failed because LocalPlayer is unavailable.")
         recordingRuntime.EmitLoadingRejoinFailed("LocalPlayer was unavailable during the automatic rejoin.")
         return
      end

      updateReplayStatus("Fresh-match recovery did not clear loading. Returning through the public TDS server...")
      if type(recordingRuntime.MarkIntentionalTransition) == "function" then
         recordingRuntime.MarkIntentionalTransition("Stuck-loading recovery through public TDS server", 60)
      end
      local recoveryJobId = tostring(game.JobId or "")
      local teleportSuccess, teleportError = pcall(function()


         TeleportService:Teleport(TDS_PUBLIC_START_PLACE_ID, player)
      end)
      if not teleportSuccess then
         recordingRuntime.IntentionalTransitionUntil = 0
         recordingRuntime.IntentionalTransitionReason = nil
         warn("[TDSPro Loading Recovery] Rejoin failed: " .. tostring(teleportError))
         internal.notifyMacro("Automatic recovery failed. Retrying in 30 seconds.", 6)
         recordingRuntime.EmitLoadingRejoinFailed("TeleportService rejected the automatic rejoin: " .. tostring(teleportError))
      else
         print("[TDSPro Loading Recovery] Public-server recovery requested (attempt " .. tostring(attempt) .. ").")
      end

      task.wait(30)
      if teleportSuccess and tostring(game.JobId or "") == recoveryJobId then
         recordingRuntime.EmitLoadingRejoinFailed("The teleport request did not move the client to a fresh server within 30 seconds.")
      end
      macroRuntime.LoadingRecoveryActive = false
      macroRuntime.LoadingOverlayVisibleSince = os.clock()
   end

   function macroRuntime.StartLoadingStallWatchdog()
      if macroRuntime.LoadingWatchdogStarted then return end
      macroRuntime.LoadingWatchdogStarted = true
      task.spawn(function()
         while not lifecycle.Destroyed do
            local automationActive = autoReplayEnabled or currentMatchStartClock ~= nil
            if loadingStallRecoveryEnabled and automationActive and not macroRuntime.LoadingRecoveryActive then
               local overlay, reason = macroRuntime.FindVisibleGameLoadingOverlay()
               if overlay then
                  macroRuntime.LoadingOverlayVisibleSince = macroRuntime.LoadingOverlayVisibleSince or os.clock()
                  macroRuntime.LoadingOverlayReason = reason
                  if os.clock() - macroRuntime.LoadingOverlayVisibleSince >= math.max(30, tonumber(loadingStallTimeout) or 90) then
                     task.spawn(function()
                        macroRuntime.RecoverFromStuckLoading(macroRuntime.LoadingOverlayReason or "Unknown loading overlay")
                     end)
                  end
               else
                  macroRuntime.LoadingOverlayVisibleSince = nil
                  macroRuntime.LoadingOverlayReason = nil
               end
            elseif not macroRuntime.LoadingRecoveryActive then
               macroRuntime.LoadingOverlayVisibleSince = nil
               macroRuntime.LoadingOverlayReason = nil
            end
            task.wait(2)
         end
      end)
   end

   skipCurrentWave = function(statusText, options)
      options = type(options) == "table" and options or {}
      if options.MarkStart then
         skipSync.StartSkipAt = os.clock()
      end
      if statusText then updateReplayStatus(statusText) end
      local success, result = internal.invokeTDSRemoteFunction("Voting", "Skip")
      if not success then
         warn("[TDSPro] Wave skip failed: " .. tostring(result))
      end
      return success, result
   end

   function macroRuntime.StartStandaloneAutoSkipLoop()
      standaloneAutoSkipToken = standaloneAutoSkipToken + 1
      local token = standaloneAutoSkipToken
      task.spawn(function()
         local lastSkippedWave = nil
         while standaloneAutoSkipEnabled and standaloneAutoSkipToken == token do


            if not isPlayingMacro and not autoReplayEnabled and not autoReplayRunning and internal.isInActualMap() then
               local wave = internal.readWaveValue()
               local timer = internal.readWaveTimerValue()
               local skipPrompt = internal.findFirstSkipReadyPrompt()
               local waveCanEnd = skipPrompt ~= nil or
                  (timer ~= nil and tonumber(timer) ~= nil and tonumber(timer) <= 0.25)
               if waveCanEnd and lastSkippedWave ~= wave then
                  local success, result = skipCurrentWave(nil)
                  if success and result ~= false then
                     lastSkippedWave = wave
                  end
               end
            else
               lastSkippedWave = nil
            end
            task.wait(0.1)
         end
      end)
   end

   function macroRuntime.ResetCustomFlags()
      macroRuntime.AutoSkipToken = (tonumber(macroRuntime.AutoSkipToken) or 0) + 1
      internal.clearTable(macroRuntime.CustomFlags)
   end

   function macroRuntime.StartAutoSkipLoop()
      macroRuntime.AutoSkipToken = (tonumber(macroRuntime.AutoSkipToken) or 0) + 1
      local token = macroRuntime.AutoSkipToken
      task.spawn(function()
         local lastSkippedWave = nil
         while isPlayingMacro and macroRuntime.CustomFlags.autoskip == true and macroRuntime.AutoSkipToken == token do
            local wave = internal.readWaveValue()
            local timer = internal.readWaveTimerValue()
            local skipPrompt = internal.findFirstSkipReadyPrompt()
            local waveCanEnd = skipPrompt ~= nil or (timer ~= nil and tonumber(timer) ~= nil and tonumber(timer) <= 0.25)
            if waveCanEnd and lastSkippedWave ~= wave then
               local success, result = skipCurrentWave(nil)
               if success and result ~= false then lastSkippedWave = wave end
            end
            task.wait(0.1)
         end
      end)
   end

   function macroRuntime.SetCustomFlag(flagName, value)
      local normalizedFlag = string.lower(tostring(flagName or ""))
      local enabled = internal.toBooleanFlag(value, false)
      if normalizedFlag == "autoskip" then
         macroRuntime.CustomFlags.autoskip = enabled
         if enabled then
            macroRuntime.StartAutoSkipLoop()
         else
            macroRuntime.AutoSkipToken = (tonumber(macroRuntime.AutoSkipToken) or 0) + 1
         end
         return true
      elseif normalizedFlag == "autotoggle" then


         macroRuntime.CustomFlags.autotoggle = enabled
         print("[TDSPro] AutoTDS autoToggle = " .. tostring(enabled))
         return false, "AutoTDS autoToggle is preserved but its executor-specific behavior is unavailable."
      end
      return false, "Unsupported AutoTDS custom flag: " .. tostring(flagName)
   end

   function internal.getPlayerStats()
      local coins, coinsAvailable = internal.tryGetPlayerStatValue("Coins")
      local gems, gemsAvailable = internal.tryGetPlayerStatValue("Gems")
      return {
         Coins = tonumber(coins) or 0,
         Gems = tonumber(gems) or 0,
         CoinsAvailable = coinsAvailable == true,
         GemsAvailable = gemsAvailable == true,
      }
   end

   function internal.formatNumber(value)
      local number = math.floor(tonumber(value) or 0)
      local sign = number < 0 and "-" or ""
      local text = tostring(math.abs(number))
      local reversed = text:reverse():gsub("(%d%d%d)", "%1,")
      return sign .. reversed:reverse():gsub("^,", "")
   end

   function internal.formatDuration(seconds)
      local totalSeconds = math.max(0, math.floor(tonumber(seconds) or 0))
      local hours = math.floor(totalSeconds / 3600)
      local minutes = math.floor((totalSeconds % 3600) / 60)
      local secs = totalSeconds % 60
      if hours > 0 then
         return string.format("%dh %02dm %02ds", hours, minutes, secs)
      end
      return string.format("%dm %02ds", minutes, secs)
   end

   function internal.normalizeSavedStats(data)
      data = type(data) == "table" and data or {}
      local pendingRound = type(data.PendingRound) == "table" and data.PendingRound or nil
      local balances = type(data.LastKnownBalances) == "table" and data.LastKnownBalances or {}
      local rawCoins = balances.Coins
      local rawGems = balances.Gems
      if rawCoins == nil then rawCoins = data.LastKnownCoins end
      if rawGems == nil then rawGems = data.LastKnownGems end
      local hasCoins = balances.HasCoins
      local hasGems = balances.HasGems
      if type(hasCoins) ~= "boolean" then hasCoins = tonumber(rawCoins) ~= nil end
      if type(hasGems) ~= "boolean" then hasGems = tonumber(rawGems) ~= nil end
      return {
         SchemaVersion = 7,
         StartedAt = tonumber(data.StartedAt) or os.time(),
         Rounds = tonumber(data.Rounds) or 0,
         CoinsGained = tonumber(data.CoinsGained) or 0,
         GemsGained = tonumber(data.GemsGained) or 0,
         PlaySeconds = tonumber(data.PlaySeconds) or 0,
         PendingRound = pendingRound,
         ActionsRetried = tonumber(data.ActionsRetried) or 0,
         ActionsSkipped = tonumber(data.ActionsSkipped) or 0,
         MapRerolls = tonumber(data.MapRerolls) or 0,
         FastestCompletion = tonumber(data.FastestCompletion),
         SlowestCompletion = tonumber(data.SlowestCompletion),
         DeliveryQueue = type(data.DeliveryQueue) == "table" and data.DeliveryQueue or {},
         LastKnownBalances = {
            Coins = math.max(0, tonumber(rawCoins) or 0),
            Gems = math.max(0, tonumber(rawGems) or 0),
            HasCoins = hasCoins == true,
            HasGems = hasGems == true,
            UpdatedAt = tonumber(balances.UpdatedAt) or tonumber(data.LastBalanceUpdate) or 0,
         },
      }
   end

   function internal.loadStatsData()
      if statsLoaded then return end
      statsLoaded = true
      savedStats = internal.normalizeSavedStats(savedStats)

      if type(readfile) ~= "function" then return end
      local folderReady = internal.ensureMacroFolder()
      if not folderReady then return end

      local readSuccess, fileContents = pcall(function()
         return readfile(statsFileName)
      end)
      if not readSuccess or not fileContents or fileContents == "" then return end

      local decodeSuccess, decoded = pcall(function()
         return HttpService:JSONDecode(fileContents)
      end)
      if decodeSuccess and type(decoded) == "table" then
         savedStats = internal.normalizeSavedStats(decoded)
         pcall(function()
            writefile(statsFileName, HttpService:JSONEncode(savedStats))
         end)
      end
   end

   function internal.saveStatsData()
      internal.loadStatsData()
      if type(writefile) ~= "function" then return false end
      local folderReady = internal.ensureMacroFolder()
      if not folderReady then return false end

      local encodeSuccess, json = pcall(function()
         return HttpService:JSONEncode(savedStats)
      end)
      if not encodeSuccess or not json then return false end

      local writeSuccess = pcall(function()
         writefile(statsFileName, json)
      end)
      return writeSuccess
   end

   function internal.updateStatsHud()
      recordingRuntime.RefreshStatsUI()
   end

   function internal.isGuiActuallyVisible(gui)
      if typeof(gui) ~= "Instance" then return false end
      local current = gui
      while current and current ~= LocalPlayer do
         local visibleSuccess, visible = pcall(function() return current.Visible end)
         if visibleSuccess and visible == false then return false end
         local enabledSuccess, enabled = pcall(function() return current.Enabled end)
         if enabledSuccess and enabled == false then return false end
         if current:IsA("GuiObject") then
            local sizeSuccess, size = pcall(function() return current.AbsoluteSize end)
            if sizeSuccess and (size.X <= 1 or size.Y <= 1) then return false end

            local textTransparencySuccess, textTransparency = pcall(function() return current.TextTransparency end)
            if textTransparencySuccess and tonumber(textTransparency) and tonumber(textTransparency) >= 1 then return false end

            local camera = workspace.CurrentCamera
            if camera and sizeSuccess then
               local positionSuccess, position = pcall(function() return current.AbsolutePosition end)
               if positionSuccess then
                  local viewport = camera.ViewportSize
                  if position.X + size.X < 0 or position.Y + size.Y < 0 or position.X > viewport.X or position.Y > viewport.Y then
                     return false
                  end
               end
            end
         end
         current = current.Parent
      end
      return true
   end

   function internal.getGameOverBannerText()
      local rewardsScreen = internal.safeIndex(LocalPlayer, "PlayerGui", "ReactGameNewRewards", "Frame", "gameOver", "RewardsScreen")
      if internal.isGuiActuallyVisible(rewardsScreen) then
         local bannerLabel = internal.safeIndex(rewardsScreen, "RewardBanner", "textLabel")
         if internal.isGuiActuallyVisible(bannerLabel) then
            local bannerText = internal.safeIndex(bannerLabel, "Text")
            local upperBannerText = string.upper(tostring(bannerText or ""))
            if string.find(upperBannerText, "TRIUMPH") or string.find(upperBannerText, "VICTORY") then
               return bannerText
            end
         end
      end

      local player = LocalPlayer or Players.LocalPlayer
      local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
      if not playerGui then return nil end

      for _, obj in ipairs(playerGui:GetDescendants()) do
         if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            local ok, text = pcall(function() return obj.Text end)
            if ok and text and text ~= "" and internal.isGuiActuallyVisible(obj) then
               local upperText = string.upper(tostring(text))
               if string.find(upperText, "TRIUMPH") or string.find(upperText, "VICTORY") then
                  return text
               end
            end
         end
      end

      return nil
   end

   function recordingRuntime.CaptureVisibleMatchRewards()
      local summary = {Exp = nil, Misc = {}}
      local rewardsScreen = internal.safeIndex(LocalPlayer, "PlayerGui", "ReactGameNewRewards", "Frame", "gameOver", "RewardsScreen")
      if typeof(rewardsScreen) ~= "Instance" then return summary end

      local seenMisc = {}
      local miscKeywords = {"crate", "skin", "ticket", "chest", "item"}

      local function cleanText(value)
         return tostring(value or "")
            :gsub("<[^>]->", "")
            :gsub("\194\160", " ")
            :gsub("%s+", " ")
            :match("^%s*(.-)%s*$") or ""
      end

      local function largestNumber(value)
         local largest = nil
         for token in cleanText(value):gmatch("[+%-]?[%d,]+%.?%d*") do
            local normalizedToken = token:gsub(",", "")
            local number = tonumber(normalizedToken)
            if number and number >= 0 then largest = math.max(largest or 0, number) end
         end
         return largest
      end

      local function readGuiText(object)
         if not (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")) then return nil end
         local success, value = pcall(function() return object.Text end)
         if not success then return nil end
         local text = cleanText(value)
         return text ~= "" and text or nil
      end

      local function findNearbyNumber(object)
         local parent = object.Parent
         if typeof(parent) ~= "Instance" then return nil end
         for _, sibling in ipairs(parent:GetChildren()) do
            if sibling ~= object then
               local text = readGuiText(sibling)
               if text and text:match("^%+?[%d,]+%.?%d*$") then
                  return largestNumber(text)
               end
            end
         end
         return nil
      end

      for _, object in ipairs(rewardsScreen:GetDescendants()) do
         local text = readGuiText(object)
         if text and internal.isGuiActuallyVisible(object) then
            local lowerText = string.lower(text)
            local fullNameSuccess, fullName = pcall(function() return object:GetFullName() end)
            local lowerPath = fullNameSuccess and string.lower(tostring(fullName)) or ""
            local expContext = lowerText:find("exp", 1, true) ~= nil
               or lowerText:find("xp", 1, true) ~= nil
               or lowerPath:find("experience", 1, true) ~= nil
               or lowerPath:find("exp", 1, true) ~= nil
            if expContext then
               local amount = largestNumber(text) or findNearbyNumber(object)
               if amount then summary.Exp = math.max(tonumber(summary.Exp) or 0, amount) end
            end

             for _, keyword in ipairs(miscKeywords) do
                if lowerText:find(keyword, 1, true) then
                   local display = text
                   local amount = largestNumber(display) or findNearbyNumber(object)
                   if amount then
                      local label = cleanText(display:gsub("[+%-]?[%d,]+%.?%d*", ""):gsub("^[xX]%s*", ""))
                      display = "+" .. internal.formatNumber(amount) .. (label ~= "" and (" " .. label) or "")
                   end
                   local key = string.lower(display)
                   if display ~= "" and not seenMisc[key] and #summary.Misc < 6 then
                     seenMisc[key] = true
                     table.insert(summary.Misc, display)
                  end
                  break
               end
            end
         end
      end

      return summary
   end

   function internal.getBaseHealthCurrent()
      local currentHealth = internal.safeIndex(ReplicatedStorage, "State", "Health", "Current")
      local healthValue = internal.coerceNumber(internal.safeReadValue(currentHealth, nil))
      if healthValue == nil then
         healthValue = internal.coerceNumber(currentHealth)
      end
      return healthValue
   end

   function internal.getImmediateGameOverResult()
      local healthValue = internal.getBaseHealthCurrent()
      if healthValue and healthValue <= 0 then
         return "loss", "Health.Current = 0"
      end

      local bannerText = internal.getGameOverBannerText()
      if bannerText then
         local upperText = string.upper(tostring(bannerText))
         if string.find(upperText, "TRIUMPH") or string.find(upperText, "VICTORY") then
            return "win", bannerText
         end
      end
      return nil, nil
   end

   function internal.waitForGameOverResult(timeout)
      local maxWait = tonumber(timeout)
      local deadline = maxWait and maxWait > 0 and (os.clock() + maxWait) or nil

      while autoReplayEnabled do
         local gameResult, bannerText = internal.getImmediateGameOverResult()
         if gameResult then return gameResult, bannerText end
         if deadline and os.clock() >= deadline then
            return nil, nil
         end
         task.wait(0.5)
      end
      return nil, nil
   end

   function recordingRuntime.GetHttpRequestFunction()
       return request or http_request or (syn and syn.request) or (http and http.request)
   end

   function recordingRuntime.GetHttpResponseBody(response)
       if type(response) == "table" then
           return response.Body or response.body or response.Response or response.response
       end
       if type(response) == "string" then
           return response
       end
       return nil
   end

   function recordingRuntime.ResolveRobloxHeadshotUrl(userId, req)
       local id = tonumber(userId) or 0
       local fallbackUrl =
           ("https://www.roblox.com/headshot-thumbnail/image?userId=%s&width=150&height=150&format=png")
           :format(id)

       if id <= 0 then return fallbackUrl end

       local apiUrl =
           ("https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=%s&size=150x150&format=Png&isCircular=false")
           :format(id)
       local success, response

       if req then
           success, response = pcall(function()
               return req({
                   Url = apiUrl,
                   url = apiUrl,
                   Method = "GET",
                   method = "GET"
               })
           end)
       else
           success, response = pcall(function()
               return game:HttpGet(apiUrl)
           end)
       end

       if not success then
           warn("[Webhook] Could not resolve Roblox headshot URL: " .. tostring(response))
           return fallbackUrl
       end

       local responseBody = recordingRuntime.GetHttpResponseBody(response)
       if not responseBody or responseBody == "" then return fallbackUrl end

       local decodeSuccess, decoded = pcall(function()
           return HttpService:JSONDecode(responseBody)
       end)
       if not decodeSuccess or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
           return fallbackUrl
       end

       for _, item in ipairs(decoded.data) do
           local imageUrl = type(item) == "table" and item.imageUrl or nil
           if type(imageUrl) == "string" and imageUrl ~= "" then
               return imageUrl
           end
       end

       return fallbackUrl
   end

   function recordingRuntime.ParseWebhookUrls(value)
       for candidate in tostring(value or ""):gmatch("[^,%s;]+") do
           local clean = tostring(candidate):gsub("^%s+", ""):gsub("%s+$", "")
           if clean:lower():match("^https://[^/]*discord[^/]*/api/webhooks/") then
               return {clean}
           end
       end
       return {}
   end

   function recordingRuntime.GetWebhookEventUrls(eventName, overrideUrls)
       return recordingRuntime.ParseWebhookUrls(webhookUrl)
   end

   function recordingRuntime.QueueWebhookDelivery(item)
       internal.loadStatsData()
       savedStats.DeliveryQueue = type(savedStats.DeliveryQueue) == "table" and savedStats.DeliveryQueue or {}
       item = type(item) == "table" and item or {}
       item.Attempts = tonumber(item.Attempts) or 0
       item.NextAttempt = tonumber(item.NextAttempt) or os.time()
       table.insert(savedStats.DeliveryQueue, item)
       while #savedStats.DeliveryQueue > 50 do table.remove(savedStats.DeliveryQueue, 1) end
       internal.saveStatsData()
   end

   function recordingRuntime.DispatchWebhookEvent(eventName, title, description, color, fields, options)
       options = type(options) == "table" and options or {}
       local config = recordingRuntime.WebhookConfig
       if webhookEnabled ~= true or config.Events[eventName] ~= true then return false, "event disabled" end
       local urls = recordingRuntime.GetWebhookEventUrls(eventName, options.Urls)
       if #urls == 0 then return false, "no valid webhook destinations" end

       local delivery = {
           Event = tostring(eventName),
           Title = tostring(title or eventName),
           Description = tostring(description or ""),
           Color = tonumber(color) or 5793266,
           Fields = type(fields) == "table" and fields or {},
           Urls = urls,
           Critical = options.Critical == true,
           CreatedAt = os.time(),
       }
       local minimumGap = math.max(0, tonumber(config.RateLimit) or 2)
       if os.clock() - (tonumber(recordingRuntime.LastWebhookEventClock) or -math.huge) < minimumGap then
           recordingRuntime.QueueWebhookDelivery(delivery)
           return true, "queued by rate limit"
       end
       recordingRuntime.LastWebhookEventClock = os.clock()

       local allSent = true
       local permanentFailure = false
       for _, url in ipairs(urls) do
           local sent, failureKind = recordingRuntime.SendDiscordWebhook(delivery.Title, delivery.Description, delivery.Color, delivery.Fields, nil, {
               Enabled = true,
               Url = url,
               Silent = true,
           })
           if not sent then
               allSent = false
               if failureKind == "permanent" then permanentFailure = true end
           end
       end
       if not allSent and not permanentFailure then recordingRuntime.QueueWebhookDelivery(delivery) end
       if permanentFailure then
           return false, "Discord permanently rejected the configured webhook"
       end
       return allSent, allSent and "sent" or "queued after delivery failure"
   end

   function recordingRuntime.ProcessWebhookDeliveryQueue()
       if recordingRuntime.WebhookQueueRunning then return end
       recordingRuntime.WebhookQueueRunning = true
       task.spawn(function()
           while webhookEnabled do
               internal.loadStatsData()
               local queue = savedStats.DeliveryQueue or {}
               local item = queue[1]
               if not item then break end
               if os.time() < (tonumber(item.NextAttempt) or 0) then
                   task.wait(1)
               else
                   local allowed = recordingRuntime.WebhookConfig.Events[tostring(item.Event or "")] == true
                   local urls = recordingRuntime.GetWebhookEventUrls(item.Event)
                   local url = urls[1]
                   local allSent = not allowed or url == nil
                   local permanentFailure = allowed and url == nil
                   if allowed and url then
                       local sent, failureKind = recordingRuntime.SendDiscordWebhook(item.Title, item.Description, item.Color, item.Fields, nil, {
                           Enabled = true, Url = url, Silent = true,
                       })
                       allSent = sent == true
                       permanentFailure = failureKind == "permanent"
                   end
                   if allSent or permanentFailure then
                       table.remove(queue, 1)
                   else
                       item.Attempts = (tonumber(item.Attempts) or 0) + 1
                       if item.Attempts >= 5 then table.remove(queue, 1) else item.NextAttempt = os.time() + math.min(300, 5 * (2 ^ item.Attempts)) end
                   end
                   savedStats.DeliveryQueue = queue
                   internal.saveStatsData()
                   task.wait(math.max(0.5, tonumber(recordingRuntime.WebhookConfig.RateLimit) or 2))
               end
           end
           recordingRuntime.WebhookQueueRunning = false
       end)
   end

   function recordingRuntime.SendDiscordWebhook(title, description, color, fields, thumbnail, options)
       options = type(options) == "table" and options or {}
       local effectiveEnabled = webhookEnabled
       if options.Enabled ~= nil then effectiveEnabled = options.Enabled == true end
       if not effectiveEnabled then
           warn("[Webhook] Webhooks are disabled.")
           return false, "disabled"
       end

       local targetUrl = tostring(options.Url or webhookUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
       if targetUrl == "" then
           warn("[Webhook] No webhook URL configured.")
           return false, "permanent"
       end

       local req = recordingRuntime.GetHttpRequestFunction()

       local privacyEnabled = options.Privacy == true
       local userId = privacyEnabled and 0 or (LocalPlayer and LocalPlayer.UserId or 0)
       local playerName = privacyEnabled and "Private Player" or (LocalPlayer and LocalPlayer.Name or "Unknown Player")
       local avatarUrl = recordingRuntime.ResolveRobloxHeadshotUrl(userId, req)
       local profileUrl = ("https://www.roblox.com/users/%s/profile"):format(userId)
       local logoUrl = tostring(options.LogoUrl or webhookLogoUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
       if logoUrl ~= "" and not string.match(string.lower(logoUrl), "^https?://") then
           logoUrl = ""
       end
       local embedThumbnail = thumbnail or (logoUrl ~= "" and logoUrl or avatarUrl)
       local botAvatarUrl = logoUrl ~= "" and logoUrl or avatarUrl

       local embed = {
           author = {
               name = playerName .. " | TDSPro",
               url = profileUrl,
               icon_url = avatarUrl
           },
           title = tostring(title or "Notification"),
           description = tostring(description or ""),
           color = tonumber(color) or 3066993,
           fields = fields or {},
           thumbnail = {
               url = embedThumbnail
           },
           timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
           footer = {
               text = "TDSPro Stats Tracker",
               icon_url = botAvatarUrl
           }
       }
       if options.Minimal == true then
           embed.author = nil
           embed.thumbnail = nil
           embed.timestamp = nil
           embed.footer = nil
       end

       local payload = {
           username = "TDSPro",
           avatar_url = botAvatarUrl,
           allowed_mentions = {
               parse = {}
           },
           embeds = {
               embed
           }
       }

       local roleId = tostring(options.RoleId or ""):match("(%d+)")
       if roleId then
           payload.content = "<@&" .. roleId .. ">"
           payload.allowed_mentions.roles = {roleId}
       end

       local jsonBody = HttpService:JSONEncode(payload)
       local body = jsonBody
       local contentType = "application/json"
       local screenshotData = options.ScreenshotData
       if type(screenshotData) == "string" and #screenshotData > 100 then
           local boundary = "----TDSPro" .. tostring(math.floor(os.clock() * 1000000))
           contentType = "multipart/form-data; boundary=" .. boundary
           body = "--" .. boundary .. "\r\n" ..
               "Content-Disposition: form-data; name=\"payload_json\"\r\n" ..
               "Content-Type: application/json\r\n\r\n" .. jsonBody .. "\r\n" ..
               "--" .. boundary .. "\r\n" ..
               "Content-Disposition: form-data; name=\"files[0]\"; filename=\"tdspro.png\"\r\n" ..
               "Content-Type: image/png\r\n\r\n" .. screenshotData .. "\r\n" ..
               "--" .. boundary .. "--\r\n"
       end
       local success, response

       if req then
           success, response = pcall(function()
               return req({
                   Url = targetUrl,
                   url = targetUrl,
                   Method = "POST",
                   method = "POST",
                   Headers = {
                       ["Content-Type"] = contentType
                   },
                   headers = {
                       ["Content-Type"] = contentType
                   },
                   Body = body,
                   body = body
               })
           end)
       else
           local httpPost = internal.safeIndex(game, "HttpPost")
           if type(httpPost) ~= "function" then
               warn("[Webhook] No supported HTTP request function found.")
               if options.Silent ~= true then internal.notifyMacro("No supported HTTP request function found for webhooks.", 5) end
               return false, "retryable"
           end
           success, response = pcall(function()
               return httpPost(game, targetUrl, jsonBody, "application/json")
           end)
       end

       if not success then
           warn("[Webhook Error]", response)
           if options.Silent ~= true then internal.notifyMacro("Webhook error: " .. tostring(response), 5) end
           return false, "retryable"
       end

       if response then
           if type(response) ~= "table" then
               print("[Webhook] Response:", tostring(response))
               print("[Webhook] Sent successfully!")
               return true
           end

           local statusCode = tonumber(response.StatusCode or response.Status or response.status_code or response.status)
           local responseBody = recordingRuntime.GetHttpResponseBody(response)

           print("[Webhook] Status:", statusCode or tostring(response.StatusCode or response.Status or "unknown"))
           print("[Webhook] Response:", responseBody or "No Body")

           if not statusCode or (statusCode >= 200 and statusCode < 300) then
               print("[Webhook] Sent successfully!")
               return true, "sent", statusCode
           else
               warn("[Webhook] Failed with status:", statusCode)
               local permanentFailure = statusCode >= 400 and statusCode < 500 and
                   statusCode ~= 408 and statusCode ~= 409 and statusCode ~= 425 and statusCode ~= 429
               if options.Silent ~= true then
                   local message = permanentFailure
                       and ("Discord rejected this webhook (" .. tostring(statusCode) .. "). Replace the webhook URL; this delivery will not be retried.")
                       or ("Webhook failed with status: " .. tostring(statusCode) .. ". It will be retried.")
                   internal.notifyMacro(message, permanentFailure and 7 or 5)
               end
               return false, permanentFailure and "permanent" or "retryable", statusCode, responseBody
           end
       end

       print("[Webhook] Request completed with no response object.")
       return true, "sent"
   end

   function recordingRuntime.TrackMatchStart()
      if not currentMatchStartClock then
         currentMatchStartClock = os.clock()
         currentMatchStartedAt = os.time()
      end
      recordingRuntime.DisconnectErrorReported = false

      if matchStatsBaselineCaptured then return false end

      local stats = internal.getPlayerStats()
      initialCoins = stats.Coins
      initialGems = stats.Gems
      recordingRuntime.InitialExp, recordingRuntime.InitialExpAvailable = internal.getPlayerExperienceValue()
      matchStatsBaselineCaptured = true
      internal.updateStatsHud()
      print("[TDSPro Webhook] Cached starting stats: Coins=" .. tostring(initialCoins) ..
         ", Gems=" .. tostring(initialGems) .. ", EXP=" ..
         (recordingRuntime.InitialExpAvailable and tostring(recordingRuntime.InitialExp) or "unavailable"))
      return true
   end

   function recordingRuntime.GetCurrencySnapshot()
      local player = LocalPlayer or Players.LocalPlayer
      if not player then return false, nil, nil end
      local leaderstats = player:FindFirstChild("leaderstats")
      local coinsObject = player:FindFirstChild("Coins") or (leaderstats and leaderstats:FindFirstChild("Coins"))
      local gemsObject = player:FindFirstChild("Gems") or (leaderstats and leaderstats:FindFirstChild("Gems"))
      if not coinsObject or not gemsObject then return false, nil, nil end
      local coins = internal.coerceNumber(internal.safeReadValue(coinsObject, nil))
      local gems = internal.coerceNumber(internal.safeReadValue(gemsObject, nil))
      if coins == nil or gems == nil then return false, nil, nil end
      local exp, expAvailable = internal.getPlayerExperienceValue()
      return true, math.floor(coins), math.floor(gems), math.floor(exp), expAvailable
   end

   function recordingRuntime.ResolveMatchDuration(pending)
      pending = type(pending) == "table" and pending or {}
      local measuredSeconds = math.max(0, tonumber(pending.MatchSeconds) or 0)
      local startedAt = tonumber(pending.MatchStartedAt)
      local endedAt = tonumber(pending.EndedAt)
      local wallClockSeconds = startedAt and endedAt and math.max(0, endedAt - startedAt) or 0

      if measuredSeconds >= minimumValidMatchSeconds and measuredSeconds <= maximumValidMatchSeconds then
         return measuredSeconds, true
      end
      if wallClockSeconds >= minimumValidMatchSeconds and wallClockSeconds <= maximumValidMatchSeconds then
         return wallClockSeconds, true
      end
      return math.max(measuredSeconds, wallClockSeconds), false
   end

   function recordingRuntime.QueuePendingRound(gameResult)
      internal.loadStatsData()
      if type(savedStats.PendingRound) == "table" then
         warn("[TDSPro Webhook] A previous round is still pending reconciliation; the new round was not allowed to overwrite it.")
         return false
      end

      local endedAt = os.time()
      local measuredSeconds = currentMatchStartClock and math.max(0, os.clock() - currentMatchStartClock) or 0
      local wallClockSeconds = currentMatchStartedAt and math.max(0, endedAt - currentMatchStartedAt) or 0
      local matchSeconds = math.max(measuredSeconds, wallClockSeconds)
      local configuredUrls = recordingRuntime.GetWebhookEventUrls("MatchResult")
      local visibleRewards = {Exp = nil, Misc = {}}
      local rewardsCaptured, capturedRewards = pcall(recordingRuntime.CaptureVisibleMatchRewards)
      if rewardsCaptured and type(capturedRewards) == "table" then
         visibleRewards = capturedRewards
      elseif not rewardsCaptured then
         warn("[TDSPro Webhook] Reward-screen parsing failed without stopping Auto Replay: " .. tostring(capturedRewards))
      end
      savedStats.PendingRound = {
         Version = 1,
         Id = tostring(game.JobId or "") .. ":" .. tostring(os.time()) .. ":" .. tostring(math.floor(os.clock() * 1000)),
         SourceJobId = tostring(game.JobId or ""),
         BaselineCoins = math.max(0, tonumber(initialCoins) or 0),
         BaselineGems = math.max(0, tonumber(initialGems) or 0),
         BaselineExp = math.max(0, tonumber(recordingRuntime.InitialExp) or 0),
         BaselineExpAvailable = recordingRuntime.InitialExpAvailable == true,
         CapturedExpGained = tonumber(visibleRewards.Exp),
         MiscRewards = type(visibleRewards.Misc) == "table" and visibleRewards.Misc or {},
         Result = tostring(gameResult or "unknown"),
         MatchSeconds = matchSeconds,
         MatchStartedAt = currentMatchStartedAt,
         Telemetry = type(macroRuntime.RunTelemetry) == "table" and {
            Retried = tonumber(macroRuntime.RunTelemetry.Retried) or 0,
            Skipped = tonumber(macroRuntime.RunTelemetry.Skipped) or 0,
         } or nil,
         MapRerolls = type(macroRuntime.RunTelemetry) == "table" and tonumber(macroRuntime.RunTelemetry.MapRerolls) or
            (tonumber(macroRuntime.PendingMapRerolls) or 0),
         EndedAt = endedAt,
         WebhookEnabled = webhookEnabled == true and recordingRuntime.WebhookConfig.Events.MatchResult == true and #configuredUrls > 0,
         WebhookUrl = configuredUrls[1] or "",
         WebhookLogoUrl = tostring(webhookLogoUrl or ""),
         StatsRecorded = false,
      }
      currentMatchStartClock = nil
      currentMatchStartedAt = nil
      matchStatsBaselineCaptured = false
      local saved = internal.saveStatsData()
      if saved then
         print("[TDSPro Webhook] Round saved. Gains will be reconciled after the next server credits them.")
         macroRuntime.PendingMapRerolls = 0
      else
         warn("[TDSPro Webhook] Could not save the pending round for next-server reconciliation.")
      end
      return saved
   end

   function recordingRuntime.RecordRoundSummary(pending)
      local telemetry = type(pending.Telemetry) == "table" and pending.Telemetry or {}
      local resultText = string.lower(tostring(pending.Result or "unknown"))
      local seconds, durationValid = recordingRuntime.ResolveMatchDuration(pending)
      local actionsRetried = math.max(0, tonumber(telemetry.Retried) or 0)
      local actionsSkipped = math.max(0, tonumber(telemetry.Skipped) or 0)
      local mapRerolls = math.max(0, tonumber(pending.MapRerolls or telemetry.MapRerolls) or 0)
      savedStats.ActionsRetried = (tonumber(savedStats.ActionsRetried) or 0) + actionsRetried
      savedStats.ActionsSkipped = (tonumber(savedStats.ActionsSkipped) or 0) + actionsSkipped
      savedStats.MapRerolls = (tonumber(savedStats.MapRerolls) or 0) + mapRerolls

      local previousFastest = tonumber(savedStats.FastestCompletion)
      if resultText == "win" and durationValid then
         savedStats.FastestCompletion = previousFastest and math.min(previousFastest, seconds) or seconds
         savedStats.SlowestCompletion = math.max(tonumber(savedStats.SlowestCompletion) or 0, seconds)
         if previousFastest and seconds < previousFastest then
            task.defer(function()
               internal.notifyMacro("New personal best: " .. internal.formatDuration(seconds) .. "!", 5)
            end)
         end
      end
   end

   function recordingRuntime.ApplyPendingRoundStats(pending, coinsGained, gemsGained, totalCoins, totalGems, expGained, totalExp)
      if type(pending) ~= "table" then return false end
      if pending.StatsRecorded == true then return true end
      local safeCoins = math.max(0, math.floor(tonumber(coinsGained) or 0))
      local safeGems = math.max(0, math.floor(tonumber(gemsGained) or 0))
      local safeExp = tonumber(expGained)
      if safeExp == nil then safeExp = tonumber(pending.CapturedExpGained) end
      if safeExp ~= nil then safeExp = math.max(0, math.floor(safeExp)) end
      local safeSeconds, durationValid = recordingRuntime.ResolveMatchDuration(pending)
      local savedStatsBackup = nil
      pcall(function()
         savedStatsBackup = HttpService:JSONDecode(HttpService:JSONEncode(savedStats))
      end)
      local oldSaved = {
         Rounds = savedStats.Rounds,
         CoinsGained = savedStats.CoinsGained, GemsGained = savedStats.GemsGained, PlaySeconds = savedStats.PlaySeconds,
      }

      if durationValid then
         savedStats.Rounds = (tonumber(savedStats.Rounds) or 0) + 1
         savedStats.CoinsGained = (tonumber(savedStats.CoinsGained) or 0) + safeCoins
         savedStats.GemsGained = (tonumber(savedStats.GemsGained) or 0) + safeGems
         savedStats.PlaySeconds = (tonumber(savedStats.PlaySeconds) or 0) + safeSeconds
      else
         warn("[TDSPro Stats] Excluded a round with an invalid duration from aggregate hourly rates.")
      end

      pending.ResolvedCoinsGained = safeCoins
      pending.ResolvedGemsGained = safeGems
      pending.ResolvedTotalCoins = math.max(0, math.floor(tonumber(totalCoins) or 0))
      pending.ResolvedTotalGems = math.max(0, math.floor(tonumber(totalGems) or 0))
      pending.ResolvedExpGained = safeExp
      pending.ResolvedTotalExp = tonumber(totalExp) and math.max(0, math.floor(tonumber(totalExp))) or nil
      pending.ResolvedJobId = tostring(game.JobId or "")
      pending.StatsRecorded = true
      if durationValid then recordingRuntime.RecordRoundSummary(pending) end
      savedStats.PendingRound = pending
      if internal.saveStatsData() then
         internal.updateStatsHud()
         return true
      end

      if type(savedStatsBackup) == "table" then
         savedStats = internal.normalizeSavedStats(savedStatsBackup)
         return false
      end
      for key, value in pairs(oldSaved) do savedStats[key] = value end
      pending.StatsRecorded = false
      pending.ResolvedCoinsGained = nil
      pending.ResolvedGemsGained = nil
      pending.ResolvedTotalCoins = nil
      pending.ResolvedTotalGems = nil
      pending.ResolvedExpGained = nil
      pending.ResolvedTotalExp = nil
      pending.ResolvedJobId = nil
      savedStats.PendingRound = pending
      return false
   end

   function recordingRuntime.SendPendingRoundWebhook(pending)
      if type(pending) ~= "table" or pending.WebhookEnabled ~= true then return true end
      local resultText = string.lower(tostring(pending.Result or ""))
      local color = 5793266
      if resultText == "win" then
         color = 5763719
      elseif resultText == "loss" then
         color = 15548997
      end

      local matchSeconds, durationValid = recordingRuntime.ResolveMatchDuration(pending)
      local matchHours = durationValid and (matchSeconds / 3600) or 0
      local coinsGained = math.max(0, tonumber(pending.ResolvedCoinsGained) or 0)
      local gemsGained = math.max(0, tonumber(pending.ResolvedGemsGained) or 0)
      local expGained = tonumber(pending.ResolvedExpGained)
      local coinsPerHour = matchHours > 0 and (coinsGained / matchHours) or 0
      local gemsPerHour = matchHours > 0 and (gemsGained / matchHours) or 0
      local expPerHour = expGained and matchHours > 0 and (expGained / matchHours) or nil
      local miscRewards = type(pending.MiscRewards) == "table" and pending.MiscRewards or {}
      local miscText = #miscRewards > 0 and table.concat(miscRewards, ", ") or "None detected"
      local expGainText = expGained and ("+" .. internal.formatNumber(expGained)) or "Not detected"
      local coinsHourlyText = durationValid and (internal.formatNumber(coinsPerHour) .. "/hr") or "Unavailable"
      local gemsHourlyText = durationValid and (internal.formatNumber(gemsPerHour) .. "/hr") or "Unavailable"
      local expHourlyText = expPerHour and (internal.formatNumber(expPerHour) .. "/hr") or
         (durationValid and "Not detected" or "Unavailable")
      local matchTimeText = durationValid and internal.formatDuration(matchSeconds) or "Unavailable"
      local description = table.concat({
         "💰 Coins: +" .. internal.formatNumber(coinsGained),
         "💎 Gems: +" .. internal.formatNumber(gemsGained),
         "⭐ EXP: " .. expGainText,
         "🎁 Misc: " .. miscText,
         "",
         "━━━━━━━━━━━━━━━━━━",
         "",
         "📈 **Hourly Earnings**",
         "💰 Coins: " .. coinsHourlyText,
         "💎 Gems: " .. gemsHourlyText,
         "⭐ EXP: " .. expHourlyText,
         "",
         "⏱️ Match Time: " .. matchTimeText,
      }, "\n")

      local url = tostring(pending.WebhookUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if url == "" and type(pending.WebhookUrls) == "table" then
         url = tostring(pending.WebhookUrls[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
      end
      if url == "" then return false end
      return recordingRuntime.SendDiscordWebhook("📊 TDSPro Match Summary", description, color, {}, nil, {
         Enabled = true,
         Url = url,
         LogoUrl = pending.WebhookLogoUrl,
         Minimal = true,
      })
   end

   function recordingRuntime.ReconcilePendingRound(timeoutSeconds)
      internal.loadStatsData()
      local pending = savedStats.PendingRound
      if type(pending) ~= "table" then return true, "nothing pending" end

      if pending.StatsRecorded ~= true then
         local sourceJobId = tostring(pending.SourceJobId or "")
         local currentJobId = tostring(game.JobId or "")
         if sourceJobId ~= "" and sourceJobId == currentJobId then
            return false, "waiting for the next server"
         end

         local deadline = os.clock() + math.max(2, tonumber(timeoutSeconds) or 15)
         local lastCoins, lastGems, stableReads, firstReadyAt = nil, nil, 0, nil
         local resolvedCoins, resolvedGems = nil, nil
         local resolvedExp = nil
         repeat
            local ready, coins, gems, exp, expAvailable = recordingRuntime.GetCurrencySnapshot()
            if ready and coins >= (tonumber(pending.BaselineCoins) or 0) and gems >= (tonumber(pending.BaselineGems) or 0) then
               firstReadyAt = firstReadyAt or os.clock()
               if coins == lastCoins and gems == lastGems then stableReads = stableReads + 1 else stableReads = 1 end
               lastCoins, lastGems = coins, gems
               local coinDelta = math.max(0, coins - (tonumber(pending.BaselineCoins) or coins))
               local gemDelta = math.max(0, gems - (tonumber(pending.BaselineGems) or gems))
               if stableReads >= 3 and (coinDelta > 0 or gemDelta > 0 or os.clock() - firstReadyAt >= 8) then
                  resolvedCoins, resolvedGems = coins, gems
                  if pending.BaselineExpAvailable == true and expAvailable and exp >= (tonumber(pending.BaselineExp) or 0) then
                     resolvedExp = exp
                  end
                  break
               end
            end
            task.wait(0.25)
         until os.clock() >= deadline

         if resolvedCoins == nil or resolvedGems == nil then
            return false, "currency totals were not ready"
         end
         local coinsGained = math.max(0, resolvedCoins - (tonumber(pending.BaselineCoins) or resolvedCoins))
         local gemsGained = math.max(0, resolvedGems - (tonumber(pending.BaselineGems) or resolvedGems))
         local expGained = resolvedExp and math.max(0, resolvedExp - (tonumber(pending.BaselineExp) or resolvedExp)) or nil
         if not recordingRuntime.ApplyPendingRoundStats(
            pending,
            coinsGained,
            gemsGained,
            resolvedCoins,
            resolvedGems,
            expGained,
            resolvedExp
         ) then
            return false, "could not save reconciled round stats"
         end
      end

      local webhookComplete = pending.WebhookSent == true
      local webhookFailureKind, webhookStatus
      if pending.WebhookEnabled == true and not webhookComplete then
         webhookComplete, webhookFailureKind, webhookStatus = recordingRuntime.SendPendingRoundWebhook(pending)
      end
      if pending.WebhookEnabled == true and not webhookComplete and webhookFailureKind ~= "permanent" then
         savedStats.PendingRound = pending
         internal.saveStatsData()
         return false, "webhook delivery failed; saved for retry"
      end
      if pending.WebhookEnabled == true and webhookComplete and pending.WebhookSent ~= true then
         pending.WebhookSent = true
         savedStats.PendingRound = pending
         internal.saveStatsData()
      elseif webhookFailureKind == "permanent" then
         warn("[TDSPro Webhook] Discord permanently rejected the configured webhook" ..
            (webhookStatus and (" (HTTP " .. tostring(webhookStatus) .. ")") or "") ..
            "; the reconciled round was cleared instead of being retried.")
      end
      savedStats.PendingRound = nil
      if not internal.saveStatsData() then return false, "could not clear reconciled round" end
      print("[TDSPro Webhook] Reconciled last round: +" .. internal.formatNumber(pending.ResolvedCoinsGained) ..
         " coins, +" .. internal.formatNumber(pending.ResolvedGemsGained) .. " gems.")
      return true, "reconciled"
   end

   recordingRuntime.StatsUI = recordingRuntime.StatsUI or {}

   function recordingRuntime.GetStatsRate(bucket)
      bucket = type(bucket) == "table" and bucket or {}
      local rounds = math.max(0, tonumber(bucket.Rounds) or 0)
      local seconds = math.max(0, tonumber(bucket.PlaySeconds or bucket.Seconds) or 0)
      local hours = seconds / 3600
      return {
         Rounds = rounds,
         AverageSeconds = rounds > 0 and (seconds / rounds) or 0,
         CoinsPerHour = hours > 0 and ((tonumber(bucket.Coins or bucket.CoinsGained) or 0) / hours) or 0,
         GemsPerHour = hours > 0 and ((tonumber(bucket.Gems or bucket.GemsGained) or 0) / hours) or 0,
         AverageRerolls = rounds > 0 and ((tonumber(bucket.MapRerolls) or 0) / rounds) or 0,
      }
   end

   function recordingRuntime.RefreshStatsUI()
      internal.loadStatsData()
      libraryEmit("StatsChanged", {Totals = savedStats, Rates = recordingRuntime.GetStatsRate(savedStats)})
   end

   function recordingRuntime.ResetAllStats()
      internal.loadStatsData()
      local pending = savedStats.PendingRound
      savedStats = internal.normalizeSavedStats({StartedAt = os.time(), PendingRound = pending})
      local saved = internal.saveStatsData()
      recordingRuntime.RefreshStatsUI()
      return saved, saved and "All statistics reset." or "Could not save the reset."
   end

   internal.trackMatchEnd = function(gameResult)
      return recordingRuntime.QueuePendingRound(gameResult)
   end

   function recordingRuntime.CaptureTiming(clockValue)
      local now = tonumber(clockValue) or os.clock()
      local eventWave, eventWaveTime, eventWaveElapsed = recordingWatch.GetWaveTiming(now)
      return {
         Clock = now,
         Wave = eventWave,
         WaveTime = eventWaveTime,
         WaveElapsed = eventWaveElapsed,
         Elapsed = recordingArmedAt > 0 and math.max(0, now - recordingArmedAt) or 0,
         InActualMap = internal.isInActualMap(),
      }
   end

   function recordingRuntime.AddMacroEvent(actionType, details, capturedTiming, recordingSession)
      if recordingSession then
         if recordingRuntime.ActiveSession ~= recordingSession or not recordingSession.AllowCommit then return false end
         if type(capturedTiming) ~= "table" or capturedTiming.InActualMap ~= true then return false end
      else
         if not isRecording then return false end
         if not internal.isInActualMap() then return false end
      end

      local now = type(capturedTiming) == "table" and tonumber(capturedTiming.Clock) or os.clock()
      if recordingArmedAt <= 0 then recordingArmedAt = now end

      local eventWave = type(capturedTiming) == "table" and capturedTiming.Wave or nil
      local eventWaveTime = type(capturedTiming) == "table" and capturedTiming.WaveTime or nil
      local eventWaveElapsed = type(capturedTiming) == "table" and capturedTiming.WaveElapsed or nil
      if eventWave == nil then
         eventWave, eventWaveTime, eventWaveElapsed = recordingWatch.GetWaveTiming(now)
      end
      recordingWatch.Debug("event=" .. tostring(actionType), eventWave, eventWaveTime, eventWaveElapsed)
      if actionType == "Skip" and type(details) == "table" then
         details.Wave = eventWave
         details.WaveTime = eventWaveTime
      end
      local elapsed = type(capturedTiming) == "table" and tonumber(capturedTiming.Elapsed) or math.max(0, now - recordingArmedAt)
      elapsed = math.max(0, tonumber(elapsed) or 0)

      recordedEventCounter = recordedEventCounter + 1
      local event = {
         Order = recordedEventCounter,
         Wave = eventWave,
         WaveTime = eventWaveTime,
         WaveTimer = eventWaveTime,
         WaveElapsed = eventWaveElapsed,
         WaveTimestamp = eventWaveElapsed,
         Timestamp = elapsed,
         Action = actionType,
         Details = details
      }
      table.insert(recordedTimeline, event)
      if type(TimelineUI.Refresh) == "function" then TimelineUI.Refresh(false) end

      local logEntry = internal.formatLogEntry(actionType, details, elapsed, event)
      internal.pushRecordingLogSafe(logEntry)
   	print("[TDSPro] Recorded: " .. logEntry)
      return true
   end

   function recordingRuntime.ClassifyActionResult(result, packedResults)
      local explicitStatus = nil
      local negativeDiagnostic = false
      local positiveDiagnostic = false
      local diagnosticResult = nil

      local function noteDiagnostic(value)
         local raw = tostring(value or "")
         if raw == "" then return end
         if diagnosticResult == nil then diagnosticResult = raw end
         local normalized = string.lower(raw):gsub("^%s+", ""):gsub("%s+$", "")
         local acceptedMessages = {
            ["ok"] = true, ["true"] = true, ["success"] = true, ["successful"] = true,
            ["accepted"] = true, ["upgraded"] = true, ["placed"] = true,
            ["complete"] = true, ["completed"] = true, ["upgrade successful"] = true,
            ["place successful"] = true, ["placement successful"] = true,
            ["successfully upgraded"] = true, ["successfully placed"] = true,
            ["upgrade complete"] = true, ["upgrade completed"] = true,
            ["placement complete"] = true, ["placement completed"] = true,
         }
         if acceptedMessages[normalized] then
            positiveDiagnostic = true
            return
         end
         for _, pattern in ipairs({
            "not enough", "insufficient", "cannot afford", "can't afford", "cant afford",
            "rejected", "failed", "failure", "denied", "invalid", "not owned",
            "wrong owner", "does not exist", "not found", "max level", "maximum level",
            "already max", "maxed", "fully upgraded", "cannot upgrade", "can't upgrade",
            "cannot place", "can't place", "cooldown", "error",
         }) do
            if string.find(normalized, pattern, 1, true) then
               negativeDiagnostic = true
               return
            end
         end
      end

      local function inspect(value)
         if value == nil then return end
         if typeof(value) == "Instance" then
            if explicitStatus == nil then explicitStatus = true end
            return
         end
         if type(value) == "boolean" then
            if value == false then explicitStatus = false elseif explicitStatus == nil then explicitStatus = true end
            return
         end
         if type(value) == "table" then
            for _, key in ipairs({"Success", "success", "Accepted", "accepted", "Ok", "ok"}) do
               if type(value[key]) == "boolean" then
                  if value[key] == false then explicitStatus = false elseif explicitStatus == nil then explicitStatus = true end
                  break
               end
            end
            for _, key in ipairs({"Reason", "reason", "Error", "error", "Message", "message"}) do
               local field = value[key]
               if field ~= nil and field ~= false and tostring(field) ~= "" then
                  noteDiagnostic(field)
                  break
               end
            end
            return
         end
         if type(value) == "string" and value ~= "" then
            noteDiagnostic(value)
         end
      end

      inspect(result)
      if type(packedResults) == "table" then
         local count = tonumber(packedResults.n) or #packedResults
         for index = 2, count do inspect(packedResults[index]) end
      end

      if negativeDiagnostic or explicitStatus == false then
         return false, diagnosticResult or "server rejected the request"
      end
      if explicitStatus == true or positiveDiagnostic then return true, diagnosticResult end
      return nil, diagnosticResult or "no authoritative response"
   end

   function recordingRuntime.GetHorizontalDistance(a, b)
      if not a or not b then return nil end
      local ok, distance = pcall(function()
         local dx = a.X - b.X
         local dz = a.Z - b.Z
         return math.sqrt((dx * dx) + (dz * dz))
      end)
      return ok and distance or nil
   end

   function recordingRuntime.ObserveTower(session, tower, seenAt)
      if not session or typeof(tower) ~= "Instance" then return end
      session.TowerObservations = session.TowerObservations or {}
      local isNewObservation = session.TowerObservations[tower] == nil
      if isNewObservation then
         session.NextTowerObservationSerial = (tonumber(session.NextTowerObservationSerial) or 0) + 1
         session.TowerObservations[tower] = {
            SeenAt = tonumber(seenAt) or os.clock(),
            Serial = session.NextTowerObservationSerial,
         }
      end
      if isNewObservation and next(session.UpgradeProducerAttempts or {}) ~= nil and
         type(recordingRuntime.IsPendingUpgradeReplacementTower) == "function" then
         task.spawn(function()
            local deadline = os.clock() + RECORDING_CONFIRM_TIMEOUT
            repeat
               recordingRuntime.IsPendingUpgradeReplacementTower(tower, session)
               if session.NonPlacementTowers and session.NonPlacementTowers[tower] then return end
               task.wait(0.05)
            until not session.AllowCommit or os.clock() >= deadline
         end)
      end
   end

   function recordingRuntime.RefreshTowerObservations(session)
      local folder = internal.getTowersFolder()
      if not folder then return end
      if session.ObservedTowersFolder ~= folder then
         if session.TowerAddedConnection then pcall(function() session.TowerAddedConnection:Disconnect() end) end
         session.ObservedTowersFolder = folder
         local connected, connection = pcall(function()
            return folder.ChildAdded:Connect(function(tower)
               recordingRuntime.ObserveTower(session, tower, os.clock())
            end)
         end)
         session.TowerAddedConnection = connected and connection or nil
      end
      local now = os.clock()
      for _, tower in ipairs(folder:GetChildren()) do recordingRuntime.ObserveTower(session, tower, now) end
   end

   function recordingRuntime.StopTowerObservations(session)
      if session and session.TowerAddedConnection then
         pcall(function() session.TowerAddedConnection:Disconnect() end)
         session.TowerAddedConnection = nil
      end
   end

   function recordingRuntime.IsTowerProducingAbilityName(value)
      local normalized = string.lower(tostring(value or ""))
      for _, marker in ipairs({"hologram", "clone", "summon", "spawn", "copy", "decoy"}) do
         if string.find(normalized, marker, 1, true) then return true end
      end
      return false
   end

   function recordingRuntime.GetAbilitySpawnExpectedName(producer)
      local data = producer and producer.AbilityData
      if type(data) ~= "table" then return nil end
      local reference = data.towerToClone or data.TowerToClone or data.TroopToClone or data.Clone or
         data.Troop or data.Tower or data.TowerName or data.towerName
      if typeof(reference) == "Instance" then
         local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, reference)
         return internal.getRecordedTroopName(troopId, reference.Name)
      end
      local troopId = tonumber(reference)
      if troopId and recordedPlaceDetailsByTroopId[troopId] then return recordedPlaceDetailsByTroopId[troopId].Troop end
      if type(reference) == "string" and reference ~= "" then return reference end
      return nil
   end

   function recordingRuntime.IsNonPlacementProducerTower(tower, session)
      local observation = session.TowerObservations and session.TowerObservations[tower] or nil
      local seenAt = observation and observation.SeenAt or os.clock()
      for _, producer in pairs(session.TowerProducerAttempts or {}) do
         if not producer.Cancelled and producer.ResultAcceptance ~= false and not (producer.BeforeTowers and producer.BeforeTowers[tower]) then
            local capturedAt = producer.Timing and tonumber(producer.Timing.Clock) or 0
            local deadline = tonumber(producer.ConfirmationDeadline) or (capturedAt + RECORDING_RESPONSE_TIMEOUT + RECORDING_CONFIRM_TIMEOUT)
            if seenAt + 0.01 >= capturedAt and seenAt <= deadline then
               local returnedTower = recordingRuntime.GetTopLevelTower(producer.Results and producer.Results[1])
               local returnedIsNew = returnedTower and not (producer.BeforeTowers and producer.BeforeTowers[returnedTower])
               if returnedIsNew and returnedTower == tower then return true end

               local rawData = producer.AbilityData
               local spawnPosition = type(rawData) == "table" and internal.deserializeVector3Value(
                  rawData.Position or rawData.position or rawData.TargetPosition or rawData.targetPosition
               ) or nil
               local expectedName = recordingRuntime.GetAbilitySpawnExpectedName(producer)
               if spawnPosition or expectedName then
                  local towerPosition = internal.getTowerPosition(tower)
                  local distance = recordingRuntime.GetHorizontalDistance(spawnPosition, towerPosition)
                  local positionMatches = spawnPosition == nil or (distance and distance <= 3)
                  local nameMatches = expectedName == nil or recordingRuntime.TowerNameMatchesExpected(tower, expectedName) == true
                  if positionMatches and nameMatches then return true end
               end
            end
         end
      end
      return false
   end

   function recordingRuntime.HasPendingSellForTower(session, tower)
      if not session or typeof(tower) ~= "Instance" then return false end
      for _, pendingEnvelope in pairs(session.Pending or {}) do
         if pendingEnvelope.Action == "Sell" and pendingEnvelope.Tower == tower and
            pendingEnvelope.Ready ~= true and not pendingEnvelope.Cancelled then
            return true
         end
      end
      return false
   end

   function recordingRuntime.IsPendingUpgradeReplacementTower(tower, session)
      if typeof(tower) ~= "Instance" or not session then return false end
      local observation = session.TowerObservations and session.TowerObservations[tower] or nil
      local seenAt = observation and observation.SeenAt or os.clock()
      for _, producer in pairs(session.UpgradeProducerAttempts or {}) do
         local callStartedAt = tonumber(producer.UpgradeCallStartedAt)
         local producerDeadline = tonumber(producer.UpgradeProducerDeadline) or tonumber(producer.ResponseDeadline) or
            (callStartedAt and (callStartedAt + RECORDING_RESPONSE_TIMEOUT + RECORDING_CONFIRM_TIMEOUT) or nil)
         if producer.Action == "Upgrade" and callStartedAt and not producer.Cancelled and
            not (producer.BeforeTowers and producer.BeforeTowers[tower]) then
            local responseDeadline = tonumber(producer.ResponseDeadline) or (callStartedAt + RECORDING_RESPONSE_TIMEOUT)
            local unresolved = producer.UpgradeOutcomeComplete ~= true
            local pendingSellOutcome = recordingRuntime.HasPendingSellForTower(session, producer.Tower)
            local completedCandidateWindow = not unresolved and producer.UpgradeMayStillReplace == true and
               producer.UpgradeProducerInvalidated ~= true and
               producer.ReplacementTower == nil and producerDeadline and seenAt <= producerDeadline and
               recordingRuntime.GetTopLevelTower(producer.Tower) == nil
            local completedReplacementWindow = completedCandidateWindow and not pendingSellOutcome
            local pendingSellWindow = completedCandidateWindow and pendingSellOutcome
            local withinUnresolvedWindow = unresolved and seenAt <= responseDeadline + RECORDING_UPGRADE_SETTLE_TIMEOUT
            if seenAt + 0.01 >= callStartedAt and (withinUnresolvedWindow or completedReplacementWindow or pendingSellWindow) then
               local details = producer.Details or {}
               local expectedPosition = internal.deserializeVector3Value(details.TowerPosition)
               local towerPosition = internal.getTowerPosition(tower)
               local distance = recordingRuntime.GetHorizontalDistance(expectedPosition, towerPosition)
               local expectedName = details.Troop or details.TowerName or details.InstanceName
               local nameMatches = recordingRuntime.TowerNameMatchesExpected(tower, expectedName)



               if distance and distance <= 3 and nameMatches ~= false then
                  if completedReplacementWindow then
                     producer.ReplacementTower = tower
                     session.NonPlacementTowers[tower] = true
                     session.UpgradeReplacementAliases[producer.Tower] = tower
                     local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, producer.Tower)
                     local ledger = (troopId and recordedUpgradeStateByTower[troopId]) or
                        recordedUpgradeStateByTower[internal.normalizeTowerInstance(producer.Tower)]
                     if type(recordingRuntime.UpdateTowerMapping) == "function" then
                        recordingRuntime.UpdateTowerMapping(producer.Tower, tower, troopId, ledger)
                     end
                     if producer.UpgradeProcessed == true and producer.UpgradeRecorded ~= true and
                        type(recordingRuntime.CommitConfirmedUpgrade) == "function" and
                        recordingRuntime.CommitConfirmedUpgrade(producer, session, tower, troopId) then
                        if producer.UpgradeDropCounted then
                           session.Dropped = math.max(0, (tonumber(session.Dropped) or 0) - 1)
                           producer.UpgradeDropCounted = false
                        end
                        print("[TDSPro] Recorded delayed Upgrade replacement after replication confirmation.")
                     end
                  end



                  return true
               end
            end
         end
      end
      return false
   end

   function recordingRuntime.IsPlaceCandidateForAttempt(tower, attempt, session)
      if not attempt or attempt.Retired or attempt.Cancelled or attempt.ResultAcceptance == false then return false, false end
      if attempt.MatchedTower and attempt.MatchedTower ~= tower then return false, false end
      if typeof(tower) ~= "Instance" or (attempt.BeforeTowers and attempt.BeforeTowers[tower]) then return false, false end
      local currentTowersFolder = internal.getTowersFolder()
      if attempt.TowersFolder and tower.Parent ~= attempt.TowersFolder and tower.Parent ~= currentTowersFolder then
         return false, false
      end
      if session.NonPlacementTowers and session.NonPlacementTowers[tower] then return false, false end
      if recordingRuntime.IsNonPlacementProducerTower(tower, session) then return false, false end
      if recordingRuntime.IsPendingUpgradeReplacementTower(tower, session) then return false, false end
      if session.PlaceTowerClaims and session.PlaceTowerClaims[tower] and session.PlaceTowerClaims[tower] ~= attempt then return false, false end
      local details = attempt.Details or {}
      local requestedPosition = internal.deserializeVector3Value(details.Position)
      local towerPosition = internal.getTowerPosition(tower)
      local distance = recordingRuntime.GetHorizontalDistance(requestedPosition, towerPosition)
      if distance == nil or distance > RECORDING_PLACE_MATCH_DISTANCE then return false, false end
      if recordingRuntime.TowerNameMatchesExpected(tower, details.Troop) == false then return false, false end
      local ownerMatch = recordingRuntime.TowerOwnerMatchesLocalPlayer(tower)
      if ownerMatch == false then return false, false end

      local observation = session.TowerObservations and session.TowerObservations[tower] or nil
      local seenAt = observation and observation.SeenAt or os.clock()
      local capturedAt = attempt.Timing and tonumber(attempt.Timing.Clock) or 0
      local deadline = tonumber(attempt.ConfirmationDeadline) or math.huge
      if seenAt + 0.01 < capturedAt or seenAt > deadline then return false, false end

      local returnedTower = recordingRuntime.GetTopLevelTower(attempt.Results and attempt.Results[1])



      local strong = returnedTower == tower
      local playerCount = 1
      pcall(function() playerCount = #Players:GetPlayers() end)
      if ownerMatch == nil and not strong and playerCount > 1 then return false, false end
      return true, strong
   end

   function recordingRuntime.FindUniquelyMatchedPlaceTower(envelope, session)
      recordingRuntime.RefreshTowerObservations(session)
      local returnedTower = recordingRuntime.GetTopLevelTower(envelope.Results and envelope.Results[1])
      if returnedTower then
         local valid = recordingRuntime.IsPlaceCandidateForAttempt(returnedTower, envelope, session)
         if valid then return returnedTower end
      end

      local folder = internal.getTowersFolder()
      if not folder then return nil end
      local matchedTower, matchedCount = nil, 0
      for _, tower in ipairs(folder:GetChildren()) do
         local currentEligible = recordingRuntime.IsPlaceCandidateForAttempt(tower, envelope, session)
         if currentEligible then
            local eligible = {}
            local strongCount = 0
            for _, attempt in pairs(session.PlaceAttempts or {}) do
               local attemptEligible, strong = recordingRuntime.IsPlaceCandidateForAttempt(tower, attempt, session)
               if attemptEligible then
                  table.insert(eligible, {Attempt = attempt, Strong = strong})
                  if strong then strongCount = strongCount + 1 end
               end
            end
            local soleAttempt, eligibleCount = nil, 0
            for _, entry in ipairs(eligible) do
               if strongCount == 0 or entry.Strong then
                  soleAttempt = entry.Attempt
                  eligibleCount = eligibleCount + 1
               end
            end
            if eligibleCount == 1 and soleAttempt == envelope then
               matchedTower = tower
               matchedCount = matchedCount + 1
            end
         end
      end
      if matchedCount == 1 then return matchedTower end
      return nil
   end

   function recordingRuntime.AssignPlaceTowerGroup(session)
      recordingRuntime.RefreshTowerObservations(session)
      local folder = internal.getTowersFolder()
      if not folder then return end

      local attempts = {}
      for _, attempt in pairs(session.PlaceAttempts or {}) do
         if attempt.Ready and not attempt.Retired and not attempt.Cancelled and attempt.ResultAcceptance ~= false and
            not attempt.PreassignedTower then
            table.insert(attempts, attempt)
         end
      end
      table.sort(attempts, function(a, b) return (tonumber(a.Sequence) or 0) < (tonumber(b.Sequence) or 0) end)

      local candidates = {}
      for _, tower in ipairs(folder:GetChildren()) do
         if not session.PlaceTowerClaims[tower] and not session.NonPlacementTowers[tower] then table.insert(candidates, tower) end
      end
      table.sort(candidates, function(a, b)
         local aObservation = session.TowerObservations[a]
         local bObservation = session.TowerObservations[b]
         local aSerial = aObservation and tonumber(aObservation.Serial) or math.huge
         local bSerial = bObservation and tonumber(bObservation.Serial) or math.huge
         if aSerial ~= bSerial then return aSerial < bSerial end
         return tostring(a.Name) < tostring(b.Name)
      end)

      local assignedByAttempt = {}
      local lockedTowers = {}
      for _, attempt in ipairs(attempts) do
         local returnedTower = recordingRuntime.GetTopLevelTower(attempt.Results and attempt.Results[1])
         if returnedTower and not lockedTowers[returnedTower] then
            local eligible, strong = recordingRuntime.IsPlaceCandidateForAttempt(returnedTower, attempt, session)
            if eligible and strong then
               assignedByAttempt[attempt] = returnedTower
               lockedTowers[returnedTower] = true
            end
         end
      end

      local matchedByTower = {}
      local function tryMatch(attempt, seen)
         for _, tower in ipairs(candidates) do
            if not lockedTowers[tower] and not seen[tower] then
               local eligible = recordingRuntime.IsPlaceCandidateForAttempt(tower, attempt, session)
               if eligible then
                  seen[tower] = true
                  local previousAttempt = matchedByTower[tower]
                  if not previousAttempt or tryMatch(previousAttempt, seen) then
                     matchedByTower[tower] = attempt
                     return true
                  end
               end
            end
         end
         return false
      end
      for _, attempt in ipairs(attempts) do
         if not assignedByAttempt[attempt] then tryMatch(attempt, {}) end
      end
      for tower, attempt in pairs(matchedByTower) do assignedByAttempt[attempt] = tower end
      for attempt, tower in pairs(assignedByAttempt) do
         attempt.PreassignedTower = tower
         session.PlaceTowerClaims[tower] = attempt
      end
   end

   function recordingRuntime.WaitForUniquelyMatchedPlaceTower(envelope, session)
      if envelope.PreassignedTower then return envelope.PreassignedTower end
      local deadline = tonumber(envelope.ConfirmationDeadline) or (os.clock() + RECORDING_CONFIRM_TIMEOUT)
      repeat
         if not session.AllowCommit then return nil end
         local tower = recordingRuntime.FindUniquelyMatchedPlaceTower(envelope, session)
         if tower then
            envelope.PreassignedTower = tower
            session.PlaceTowerClaims[tower] = envelope
            return tower
         end
         task.wait(0.03)
      until os.clock() >= deadline
      recordingRuntime.AssignPlaceTowerGroup(session)
      return envelope.PreassignedTower
   end

   function recordingRuntime.FindUniqueTroopId(position, maxDistance)
      if not position then return nil end
      local bestId, bestDistance, matchCount = nil, nil, 0
      for troopId, placeDetails in pairs(recordedPlaceDetailsByTroopId) do
         local placedPosition = internal.deserializeVector3Value(placeDetails.Position)
         local distance = placedPosition and internal.getVectorDistance(placedPosition, position) or nil
         if distance and distance <= (tonumber(maxDistance) or 2) then
            matchCount = matchCount + 1
            if bestDistance == nil or distance < bestDistance then
               bestId = troopId
               bestDistance = distance
            end
         end
      end
      if matchCount == 1 then return bestId end
      return nil
   end

   function recordingRuntime.GetUpgradeLedger(tower, troopId, fallbackState)
      local normalizedTower = internal.normalizeTowerInstance(tower)
      local ledger = troopId and recordedUpgradeStateByTower[troopId] or nil
      if not ledger and normalizedTower then ledger = recordedUpgradeStateByTower[normalizedTower] end
      if not ledger then
         ledger = {
            Tower = normalizedTower,
            InitialState = fallbackState,
            LastStateByScope = {},
            AcceptedDebtByScope = {},
            DebtQueueByScope = {},
         }
      end
      ledger.AcceptedDebtByScope = ledger.AcceptedDebtByScope or {}
      ledger.DebtQueueByScope = ledger.DebtQueueByScope or {}
      ledger.LastStateByScope = ledger.LastStateByScope or {}
      if normalizedTower then ledger.Tower = normalizedTower end
      if troopId then recordedUpgradeStateByTower[troopId] = ledger end
      if normalizedTower then recordedUpgradeStateByTower[normalizedTower] = ledger end
      return ledger
   end

   function recordingRuntime.UpdateTowerMapping(oldTower, newTower, troopId, ledger)
      if troopId then
         if oldTower then internal.rememberTowerId(recordedTowerIdsByInstance, oldTower, troopId) end
         if newTower then internal.rememberTowerId(recordedTowerIdsByInstance, newTower, troopId) end
      end
      if ledger then
         if troopId then recordedUpgradeStateByTower[troopId] = ledger end
         local normalizedOld = internal.normalizeTowerInstance(oldTower)
         local normalizedNew = internal.normalizeTowerInstance(newTower)
         if normalizedOld then recordedUpgradeStateByTower[normalizedOld] = ledger end
         if normalizedNew then recordedUpgradeStateByTower[normalizedNew] = ledger end
         if normalizedNew then ledger.Tower = normalizedNew end
      end
   end

   function recordingRuntime.InvalidateUpgradeProducersForSell(session, soldTower, capturedAt)
      if not session or typeof(soldTower) ~= "Instance" then return end
      for _, producer in pairs(session.UpgradeProducerAttempts or {}) do
         local startedAt = tonumber(producer.UpgradeCallStartedAt)
         if producer.Action == "Upgrade" and producer.Tower == soldTower and
            (not startedAt or (tonumber(capturedAt) or os.clock()) + 0.01 >= startedAt) then


            producer.UpgradeProducerInvalidated = true
         end
      end
   end

   function recordingRuntime.CommitConfirmedUpgrade(envelope, session, confirmedTower, troopId)
      if not envelope or not session or envelope.UpgradeRecorded == true then return envelope and envelope.UpgradeRecorded == true end
      local details = envelope.Details or {}
      troopId = troopId or internal.getRememberedTowerId(recordedTowerIdsByInstance, confirmedTower) or
         internal.getRememberedTowerId(recordedTowerIdsByInstance, envelope.Tower)
      details.TroopId = troopId or details.TroopId
      if confirmedTower and not details.TowerPosition then
         details.TowerPosition = internal.serializeVector3Value(internal.getTowerPosition(confirmedTower))
      end
      if details.TroopId then
         details.Troop = internal.getRecordedTroopName(details.TroopId, details.Troop)
         details.TowerName = details.Troop
      end
      local recorded = recordingRuntime.AddMacroEvent("Upgrade", details, envelope.Timing, session)
      if recorded then
         envelope.UpgradeRecorded = true
         session.Committed = session.Committed + 1
      end
      return recorded
   end

   function recordingRuntime.MeasureUpgradeTransition(beforeState, afterState, requestedPath)
      beforeState = type(beforeState) == "table" and beforeState or {}
      afterState = type(afterState) == "table" and afterState or {}
      local path = tonumber(requestedPath)
      path = path and math.floor(path) or nil
      local beforePath = path and type(beforeState.Paths) == "table" and tonumber(beforeState.Paths[path]) or nil
      local afterPath = path and type(afterState.Paths) == "table" and tonumber(afterState.Paths[path]) or nil
      if afterPath ~= nil and beforePath ~= nil then
         return math.max(0, math.floor(afterPath - beforePath)), "path " .. tostring(path) .. " state"
      end
      if afterPath ~= nil and beforePath == nil and afterPath > 0 and beforeState.Fingerprint ~= afterState.Fingerprint then
         return 1, "path " .. tostring(path) .. " marker appeared"
      end

      if path then



         if beforePath ~= nil or afterPath ~= nil then return 0, "requested path did not advance" end

         local beforeSources = type(beforeState.Sources) == "table" and beforeState.Sources or {}
         local afterSources = type(afterState.Sources) == "table" and afterState.Sources or {}
         local hasGenericSource = beforeSources.Generic ~= nil or afterSources.Generic ~= nil
         if hasGenericSource then
            for index = 1, 2 do
               if index ~= path then
                  local beforeOther = type(beforeState.Paths) == "table" and tonumber(beforeState.Paths[index]) or nil
                  local afterOther = type(afterState.Paths) == "table" and tonumber(afterState.Paths[index]) or nil
                  if beforeOther ~= afterOther then
                     return 0, "another upgrade path changed"
                  end
               end
            end

            local beforeGeneric = tonumber(beforeState.Generic)
            local afterGeneric = tonumber(afterState.Generic)
            local beforeHasAnyPath = type(beforeState.Paths) == "table" and next(beforeState.Paths) ~= nil
            local afterHasAnyPath = type(afterState.Paths) == "table" and next(afterState.Paths) ~= nil
            if beforeGeneric == nil and beforeSources.Generic ~= nil and not beforeHasAnyPath then
               beforeGeneric = tonumber(beforeState.Ordinal)
            end
            if afterGeneric == nil and afterSources.Generic ~= nil and not afterHasAnyPath then
               afterGeneric = tonumber(afterState.Ordinal)
            end
            if afterGeneric ~= nil and beforeGeneric ~= nil then
               local genericDelta = math.max(0, math.floor(afterGeneric - beforeGeneric))
               if genericDelta > 0 then return genericDelta, "generic upgrade level" end
               return 0, "generic upgrade level did not advance"
            end
            if afterGeneric ~= nil and beforeGeneric == nil and afterGeneric > 0 then
               return 1, "generic upgrade marker appeared"
            end
         end
         return 0, "no requested-path or generic level change"
      end

      local beforeOrdinal = tonumber(beforeState.Ordinal)
      local afterOrdinal = tonumber(afterState.Ordinal)
      if afterOrdinal ~= nil and beforeOrdinal ~= nil then
         local ordinalDelta = math.max(0, math.floor(afterOrdinal - beforeOrdinal))
         if ordinalDelta > 0 then return ordinalDelta, "upgrade level" end
      end
      if afterOrdinal ~= nil and beforeOrdinal == nil and afterOrdinal > 0 and beforeState.Fingerprint ~= afterState.Fingerprint then
         return 1, "upgrade marker appeared"
      end
      if beforeState.Fingerprint and afterState.Fingerprint and beforeState.Fingerprint ~= afterState.Fingerprint then
         return 1, "upgrade marker changed"
      end
      return 0, "no fenced level/path change"
   end

   function recordingRuntime.ConfirmUpgrade(envelope, session, explicitAccepted)
      local details = envelope.Details or {}
      local oldTower = envelope.Tower
      local position = internal.deserializeVector3Value(details.TowerPosition)
      local troopId = internal.getRememberedTowerId(recordedTowerIdsByInstance, oldTower)
      local capturedId = details.TroopId
      if not troopId and capturedId and recordedPlaceDetailsByTroopId[capturedId] then
         local capturedPosition = internal.deserializeVector3Value(recordedPlaceDetailsByTroopId[capturedId].Position)
         local distance = capturedPosition and position and internal.getVectorDistance(capturedPosition, position) or nil
         if distance == nil or distance <= 2 then troopId = capturedId end
      end
      if not troopId then
         troopId = recordingRuntime.FindUniqueTroopId(position, 2)
      end
      local ledger = recordingRuntime.GetUpgradeLedger(oldTower, troopId, envelope.BeforeUpgradeState)
      local tower = envelope.ReplacementTower or recordingRuntime.GetTopLevelTower(oldTower) or ledger.Tower or oldTower
      local transitionUnits, transitionReason = recordingRuntime.MeasureUpgradeTransition(
         envelope.BeforeUpgradeState,
         envelope.AfterUpgradeState,
         details.Path
      )
      if envelope.ReplacementTower and transitionUnits < 1 then
         transitionUnits = 1
         transitionReason = "tower replacement"
      end
      local cashConfirmed = envelope.CashEvidenceSafe and envelope.CashDecreaseObserved == true
      local beforeState = type(envelope.BeforeUpgradeState) == "table" and envelope.BeforeUpgradeState or {}
      local afterState = type(envelope.AfterUpgradeState) == "table" and envelope.AfterUpgradeState or {}
      local requestedPath = tonumber(details.Path)
      local beforePathObservable = requestedPath and type(beforeState.Paths) == "table" and beforeState.Paths[requestedPath] ~= nil
      local afterPathObservable = requestedPath and type(afterState.Paths) == "table" and afterState.Paths[requestedPath] ~= nil
      local beforeGenericObservable = type(beforeState.Sources) == "table" and beforeState.Sources.Generic ~= nil
      local afterGenericObservable = type(afterState.Sources) == "table" and afterState.Sources.Generic ~= nil
      local stateObservable = nil
      if requestedPath then
         stateObservable = beforePathObservable or afterPathObservable or beforeGenericObservable or afterGenericObservable
      else
         stateObservable = beforeState.Fingerprint ~= nil or afterState.Fingerprint ~= nil or
            beforeState.Ordinal ~= nil or afterState.Ordinal ~= nil
      end

      local scope = "path:" .. tostring(tonumber(details.Path) or "generic")
      local debtQueue = ledger.DebtQueueByScope[scope] or {}
      ledger.DebtQueueByScope[scope] = debtQueue
      if not stateObservable then internal.clearTable(debtQueue) end
      local function payDebt(units)
         local paid, cashSettled = 0, 0
         units = math.max(0, math.floor(tonumber(units) or 0))
         while units > 0 and #debtQueue > 0 do
            local wasCashSettled = table.remove(debtQueue, 1)
            paid = paid + 1
            if wasCashSettled == true then cashSettled = cashSettled + 1 end
            units = units - 1
         end
         return paid, cashSettled
      end
      local previousScopeState = ledger.LastStateByScope[scope] or ledger.InitialState
      if #debtQueue > 0 and previousScopeState and envelope.BeforeUpgradeState then
         local historicalUnits = recordingRuntime.MeasureUpgradeTransition(previousScopeState, envelope.BeforeUpgradeState, details.Path)
         payDebt(historicalUnits)
      end
      local paidDebt, paidCashSettledDebt = payDebt(transitionUnits)
      transitionUnits = transitionUnits - paidDebt
      ledger.AcceptedDebtByScope[scope] = #debtQueue
      ledger.LastStateByScope[scope] = envelope.AfterUpgradeState or envelope.BeforeUpgradeState or previousScopeState
      if envelope.ReplacementTower then recordingRuntime.UpdateTowerMapping(oldTower, tower, troopId, ledger) end

      if explicitAccepted == false then
         return false, tower, troopId, "server rejected the upgrade"
      end
      if explicitAccepted == true then
         if transitionUnits < 1 and stateObservable then
            table.insert(debtQueue, cashConfirmed == true)
            ledger.AcceptedDebtByScope[scope] = #debtQueue
         end
         recordingRuntime.UpdateTowerMapping(oldTower, tower, troopId, ledger)
         return true, tower, troopId, transitionUnits > 0 and transitionReason or "explicit server acceptance"
      end
      if transitionUnits > 0 then
         recordingRuntime.UpdateTowerMapping(oldTower, tower, troopId, ledger)
         return true, tower, troopId, transitionReason
      end
      local allRemainingDebtCashSettled = true
      for _, wasCashSettled in ipairs(debtQueue) do
         if wasCashSettled ~= true then
            allRemainingDebtCashSettled = false
            break
         end
      end
      if cashConfirmed and paidDebt == paidCashSettledDebt and allRemainingDebtCashSettled then



         if stateObservable then
            table.insert(debtQueue, true)
            ledger.AcceptedDebtByScope[scope] = #debtQueue
         end
         recordingRuntime.UpdateTowerMapping(oldTower, tower, troopId, ledger)
         return true, tower, troopId, "fenced upgrade cash decrease"
      end
      return false, tower, troopId, paidDebt > 0 and "state change belonged to an earlier accepted upgrade" or transitionReason
   end

   function recordingRuntime.FindUpgradeReplacement(envelope)
      local oldTower = envelope.Tower
      local details = envelope.Details or {}
      local position = internal.deserializeVector3Value(details.TowerPosition)
      local expectedName = details.Troop or details.TowerName
      local beforeTowers = envelope.BeforeTowers or {}

      local function isValid(tower)
         tower = recordingRuntime.GetTopLevelTower(tower)
         if not tower or beforeTowers[tower] or recordingRuntime.TowerOwnerMatchesLocalPlayer(tower) == false then return nil end
         local towerPosition = internal.getTowerPosition(tower)
         local distance = position and towerPosition and internal.getVectorDistance(position, towerPosition) or nil
         if distance and distance > 3 then return nil end
         if recordingRuntime.TowerNameMatchesExpected(tower, expectedName) == false then return nil end
         return tower
      end



      local returnedTower = isValid(envelope.Results and envelope.Results[1])
      if returnedTower then return returnedTower, true end
      if recordingRuntime.HasPendingSellForTower(envelope.Session, oldTower) then return nil, false end
      if envelope.UpgradeProducerInvalidated then return nil, false end
      if recordingRuntime.GetTopLevelTower(oldTower) then return nil end
      local folder = internal.getTowersFolder()
      if not folder then return nil end
      local candidate, count = nil, 0
      for _, tower in ipairs(folder:GetChildren()) do
         local validTower = isValid(tower)
         if validTower then
            candidate = validTower
            count = count + 1
         end
      end
      if count == 1 then return candidate, false end
      return nil, false
   end

   function recordingRuntime.AcquireUpgradeLane(session, envelope)
      local ticket = envelope and envelope.UpgradeTicket
      if not ticket then return false end
      local deadline = os.clock() + RECORDING_UPGRADE_LANE_TIMEOUT
      local lastServingTicket = session.UpgradeServingTicket
      while session.UpgradeServingTicket ~= ticket do
         if session.UpgradeServingTicket ~= lastServingTicket then
            lastServingTicket = session.UpgradeServingTicket
            deadline = os.clock() + RECORDING_UPGRADE_LANE_TIMEOUT
         end
         if not session.AllowCommit or (session.UpgradeSkippedTickets and session.UpgradeSkippedTickets[ticket]) or os.clock() >= deadline then
            return false
         end
         task.wait(0.01)
      end
      if not session.AllowCommit then return false end
      envelope.UpgradeLaneHeld = true
      return true
   end

   function recordingRuntime.RetireUpgradeTicket(session, envelope)
      local ticket = envelope and envelope.UpgradeTicket
      if not session or not ticket then return end
      session.UpgradeSkippedTickets = session.UpgradeSkippedTickets or {}
      session.UpgradeSkippedTickets[ticket] = true
      envelope.UpgradeLaneHeld = false
      while session.UpgradeSkippedTickets[session.UpgradeServingTicket] do
         session.UpgradeSkippedTickets[session.UpgradeServingTicket] = nil
         session.UpgradeServingTicket = session.UpgradeServingTicket + 1
      end
   end

   function recordingRuntime.ReleaseUpgradeLane(session, envelope)
      if not envelope or not envelope.UpgradeLaneHeld then return end
      recordingRuntime.RetireUpgradeTicket(session, envelope)
   end

   function recordingRuntime.PrepareUpgradeCall(envelope)
      local session = envelope.Session
      if envelope.UpgradeProducerInvalidated then
         error("upgrade target was sold before this queued request could dispatch")
      end
      local liveTower = envelope.Tower
      for _ = 1, 8 do
         local replacement = session and session.UpgradeReplacementAliases[liveTower] or nil
         if not replacement then break end
         liveTower = replacement
      end
      if liveTower ~= envelope.Tower and recordingRuntime.GetTopLevelTower(liveTower) then
         envelope.Tower = liveTower
         if envelope.Args and type(envelope.Args[4]) == "table" then envelope.Args[4].Troop = liveTower end
         if envelope.Details then
            envelope.Details.TowerPosition = internal.serializeVector3Value(internal.getTowerPosition(liveTower))
            envelope.Details.InstanceName = liveTower.Name
         end
      end
      envelope.ResponseDeadline = os.clock() + RECORDING_RESPONSE_TIMEOUT
      envelope.BeforeTowers = internal.getTowerSnapshot()
      envelope.BeforeUpgradeState = recordingRuntime.ReadTowerUpgradeState(envelope.Tower)
      envelope.BeforeCash = internal.readMatchCash()
      envelope.CashEvidenceGeneration = session and session.NonUpgradeSpendGeneration or 0
      envelope.CashEvidenceSafe = not session or (
         (os.clock() - (tonumber(session.LastEconomyActivityAt) or 0)) >= RECORDING_CONFIRM_TIMEOUT and
         os.clock() >= (tonumber(session.UpgradeCashQuarantineUntil) or 0)
      )
      if session then
         for _, pendingEnvelope in pairs(session.Pending or {}) do
            if pendingEnvelope ~= envelope and pendingEnvelope.Action ~= "Upgrade" and not pendingEnvelope.Ready then
               envelope.CashEvidenceSafe = false
               break
            end
         end
      end
      envelope.UpgradeOutcomeComplete = false
      envelope.UpgradeCallStartedAt = os.clock()
   end

   function recordingRuntime.CaptureUpgradeOutcome(envelope, explicitAccepted)
      local settleStartedAt = os.clock()
      local deadline = settleStartedAt + RECORDING_UPGRADE_SETTLE_TIMEOUT
      local earliestReleaseAt = settleStartedAt + UPGRADE_MIN_ATTEMPT_GAP
      local cashMoved = false
      repeat
         envelope.AfterTowers = internal.getTowerSnapshot()
         local replacementTower, authoritativeReplacement = recordingRuntime.FindUpgradeReplacement(envelope)
         envelope.ReplacementTower = replacementTower
         envelope.ReplacementTowerAuthoritative = authoritativeReplacement == true
         local stateTower = envelope.ReplacementTower or envelope.Tower
         envelope.AfterUpgradeState = recordingRuntime.ReadTowerUpgradeState(stateTower)
         envelope.AfterCash = internal.readMatchCash()
         if envelope.Session and envelope.CashEvidenceGeneration ~= envelope.Session.NonUpgradeSpendGeneration then
            envelope.CashEvidenceSafe = false
         end
         local observedCash = tonumber(envelope.AfterCash)
         if envelope.CashEvidenceSafe and envelope.BeforeCash ~= nil and observedCash ~= nil and
            observedCash < envelope.BeforeCash then
            envelope.CashDecreaseObserved = true
            envelope.MinimumCashObserved = math.min(tonumber(envelope.MinimumCashObserved) or observedCash, observedCash)
         end
         cashMoved = envelope.CashEvidenceSafe and envelope.CashDecreaseObserved == true
         if (explicitAccepted == false or cashMoved) and os.clock() >= earliestReleaseAt then break end
         task.wait(0.03)
      until os.clock() >= deadline
      envelope.AfterCash = envelope.AfterCash or internal.readMatchCash()
      if envelope.Session and envelope.CashEvidenceGeneration ~= envelope.Session.NonUpgradeSpendGeneration then
         envelope.CashEvidenceSafe = false
      end
      if envelope.Session and explicitAccepted ~= false and not cashMoved then
         envelope.Session.UpgradeCashQuarantineUntil = os.clock() + RECORDING_UPGRADE_SETTLE_TIMEOUT
      end
      local pendingSellOutcome = recordingRuntime.HasPendingSellForTower(envelope.Session, envelope.Tower)
      if (envelope.UpgradeProducerInvalidated or pendingSellOutcome) and not envelope.ReplacementTowerAuthoritative then
         envelope.ReplacementTower = nil
         envelope.AfterUpgradeState = recordingRuntime.ReadTowerUpgradeState(envelope.Tower)
      end
      if envelope.ReplacementTower and envelope.Session and envelope.Session.NonPlacementTowers then
         envelope.Session.NonPlacementTowers[envelope.ReplacementTower] = true
         envelope.Session.UpgradeReplacementAliases[envelope.Tower] = envelope.ReplacementTower
      end
      envelope.UpgradeProducerDeadline = tonumber(envelope.ConfirmationDeadline) or
         (os.clock() + RECORDING_CONFIRM_TIMEOUT)



      envelope.UpgradeMayStillReplace = explicitAccepted ~= false
      envelope.UpgradeOutcomeComplete = true
   end

   function recordingRuntime.FinalizeEnvelopeAfterCall(envelope, results, method)
      envelope.ResponseDeadline = os.clock() + RECORDING_UPGRADE_SETTLE_TIMEOUT + 1
      envelope.Results = results
      envelope.ResponseClock = tonumber(envelope.ResponseClock) or os.clock()
      envelope.ConfirmationDeadline = tonumber(envelope.ConfirmationDeadline) or
         (envelope.ResponseClock + RECORDING_CONFIRM_TIMEOUT)
      envelope.ResultAcceptance = recordingRuntime.ClassifyActionResult(results[1], results)
      if envelope.Action == "Place" then
         if envelope.Session then envelope.Session.LastEconomyActivityAt = envelope.ResponseClock end
         envelope.AfterTowers = internal.getTowerSnapshot()
         local details = envelope.Details or {}
         local position = internal.deserializeVector3Value(details.Position)
         envelope.CausalTower = recordingRuntime.FindConfirmedNewTower(
            position,
            envelope.BeforeTowers,
            results[1],
            details.Troop,
            method == "InvokeServer" and envelope.AfterTowers or nil
         )
         envelope.AfterPlaceState = recordingRuntime.ReadTowerUpgradeState(envelope.CausalTower)
      elseif envelope.Action == "Upgrade" then
         local explicitAccepted = recordingRuntime.ClassifyActionResult(results[1], results)
         recordingRuntime.CaptureUpgradeOutcome(envelope, explicitAccepted)
      elseif envelope.Action == "Sell" then
         local explicitAccepted = recordingRuntime.ClassifyActionResult(results[1], results)
         local removedDuringCall = envelope.BeforeSellTowerPresent == true and
            recordingRuntime.GetTopLevelTower(envelope.Tower) == nil
         local overlappingUpgradeProducer = false
         local sellStartedAt = envelope.Timing and tonumber(envelope.Timing.Clock) or envelope.ResponseClock
         for _, producer in pairs((envelope.Session and envelope.Session.UpgradeProducerAttempts) or {}) do
            local producerStartedAt = tonumber(producer.UpgradeCallStartedAt)
            local producerDeadline = tonumber(producer.UpgradeProducerDeadline) or tonumber(producer.ResponseDeadline)
            if producer.Tower == envelope.Tower and producer.ResultAcceptance ~= false and not producer.Cancelled and
               producer.UpgradeProducerInvalidated ~= true and producerStartedAt and
               producerStartedAt <= envelope.ResponseClock and (not producerDeadline or sellStartedAt <= producerDeadline) then
               overlappingUpgradeProducer = true
               break
            end
         end
         if explicitAccepted == true or (explicitAccepted ~= false and removedDuringCall and not overlappingUpgradeProducer) then
            recordingRuntime.InvalidateUpgradeProducersForSell(
               envelope.Session,
               envelope.Tower,
               envelope.ResponseClock
            )
         end
      elseif envelope.Action == "Ability" and envelope.Session and envelope.Session.NonPlacementTowers then
         envelope.Session.LastEconomyActivityAt = envelope.ResponseClock
         envelope.AfterTowers = internal.getTowerSnapshot()
         local returnedTower = recordingRuntime.GetTopLevelTower(results[1])
         if returnedTower and not (envelope.BeforeTowers and envelope.BeforeTowers[returnedTower]) then
            envelope.Session.NonPlacementTowers[returnedTower] = true
         end
      end
   end

   function recordingRuntime.ProcessEnvelope(session, envelope)
      if not session.AllowCommit or recordingRuntime.ActiveSession ~= session then return end
      if envelope.Cancelled or not envelope.Timing or envelope.Timing.InActualMap ~= true then
         if envelope.Action == "Place" then envelope.Retired = true end
         return
      end

      local explicitAccepted, responseReason = recordingRuntime.ClassifyActionResult(envelope.Results and envelope.Results[1], envelope.Results)
      if recordingWatch.DebugEnabled and (envelope.Action == "Place" or envelope.Action == "Upgrade") then
         print("[TDSPro Recording] #" .. tostring(envelope.Sequence) .. " " .. tostring(envelope.Action) ..
            " response=" .. tostring(explicitAccepted) .. " (" .. tostring(responseReason) .. ")")
      end

      if envelope.Action == "Place" then
         if explicitAccepted == false then
            envelope.Retired = true
            print("[TDSPro] Rejected Place was not recorded: " .. tostring(responseReason))
            session.Dropped = session.Dropped + 1
            return
         end
         local detailsTemplate = envelope.Details or {}
         local placedTower = recordingRuntime.WaitForUniquelyMatchedPlaceTower(envelope, session)
         if not placedTower then
            envelope.Retired = true
            print("[TDSPro] Unconfirmed Place was not recorded (no new tower appeared).")
            session.Dropped = session.Dropped + 1
            return
         end

         recordedTroopCounter = recordedTroopCounter + 1
         envelope.MatchedTower = placedTower
         envelope.Retired = true
         local troopId = recordedTroopCounter
         detailsTemplate.TroopId = troopId
         recordedPlaceDetailsByTroopId[troopId] = detailsTemplate
         internal.rememberTowerId(recordedTowerIdsByInstance, placedTower, troopId)
         local placedState = envelope.CausalTower == placedTower and envelope.AfterPlaceState or nil
         if not placedState or (placedState.Ordinal == nil and placedState.Fingerprint == nil) then
            placedState = recordingRuntime.ReadTowerUpgradeState(placedTower)
         end
         local ledger = recordingRuntime.GetUpgradeLedger(placedTower, troopId, placedState)
         recordingRuntime.UpdateTowerMapping(placedTower, placedTower, troopId, ledger)
         if recordingRuntime.AddMacroEvent("Place", detailsTemplate, envelope.Timing, session) then session.Committed = session.Committed + 1 end
         return
      end

      if envelope.Action == "Upgrade" then
         envelope.UpgradeProcessed = true
         if explicitAccepted == false then
            recordingRuntime.ConfirmUpgrade(envelope, session, false)
            print("[TDSPro] Rejected Upgrade was not recorded: " .. tostring(responseReason))
            session.Dropped = session.Dropped + 1
            envelope.UpgradeDropCounted = true
            return
         end
         local confirmed, confirmedTower, troopId, confirmationReason = recordingRuntime.ConfirmUpgrade(envelope, session, explicitAccepted)
         if not confirmed then
            print("[TDSPro] Unconfirmed Upgrade was not recorded: " .. tostring(confirmationReason))
            session.Dropped = session.Dropped + 1
            envelope.UpgradeDropCounted = true
            return
         end
         recordingRuntime.CommitConfirmedUpgrade(envelope, session, confirmedTower, troopId)
         return
      end

      if recordingRuntime.AddMacroEvent(envelope.Action, envelope.Details or {}, envelope.Timing, session) then
         session.Committed = session.Committed + 1
      end
   end

   function recordingRuntime.KickWorker(session)
      if not session or session.WorkerRunning or not session.AllowCommit then return end
      session.WorkerRunning = true
      task.spawn(function()
         while session.AllowCommit and recordingRuntime.ActiveSession == session do
            local envelope = session.Pending[session.NextCommit]
             if envelope and envelope.Ready then
                local ok, err = xpcall(function() recordingRuntime.ProcessEnvelope(session, envelope) end, traceback)
                if not ok then warn("[TDSPro Recording] " .. tostring(err)) end
                session.Pending[session.NextCommit] = nil
                session.NextCommit = session.NextCommit + 1
             elseif envelope and envelope.ResponseDeadline and os.clock() >= envelope.ResponseDeadline then
                envelope.Cancelled = true
                envelope.Ready = true
                if envelope.Action == "Upgrade" then recordingRuntime.RetireUpgradeTicket(session, envelope) end
                warn("[TDSPro Recording] Timed out waiting for action #" .. tostring(envelope.Sequence) .. " to return; skipped it.")
             elseif not session.Accepting and session.NextCommit > session.NextIssued then
               break
            else
               task.wait(0.02)
            end
         end
         session.WorkerRunning = false
      end)
   end

   function recordingRuntime.BeginSession()
      local previous = recordingRuntime.ActiveSession
      if previous then
         previous.Accepting = false
         previous.AllowCommit = false
         recordingRuntime.StopTowerObservations(previous)
      end
      recordingRuntime.NextSessionId = recordingRuntime.NextSessionId + 1
      local session = {
         Id = recordingRuntime.NextSessionId,
         Accepting = true,
         AllowCommit = true,
         NextIssued = 0,
         NextCommit = 1,
         NextUpgradeTicket = 0,
         UpgradeServingTicket = 1,
         UpgradeSkippedTickets = {},
         UpgradeReplacementAliases = {},
         UpgradeProducerAttempts = {},
         Pending = {},
         PlaceAttempts = {},
         PlaceTowerClaims = {},
         NonPlacementTowers = {},
         TowerProducerAttempts = {},
         NonUpgradeSpendGeneration = 0,
         LastEconomyActivityAt = 0,
         UpgradeCashQuarantineUntil = 0,
         TowerObservations = {},
         NextTowerObservationSerial = 0,
         WorkerRunning = false,
         Committed = 0,
         Dropped = 0,
      }
      recordingRuntime.ActiveSession = session
      recordingRuntime.RefreshTowerObservations(session)
      return session
   end

   function recordingRuntime.CancelSession()
      local session = recordingRuntime.ActiveSession
      if not session then return end
      session.Accepting = false
      session.AllowCommit = false
      recordingRuntime.StopTowerObservations(session)
      recordingRuntime.ActiveSession = nil
   end

   function recordingRuntime.CloseAndDrainSession(timeoutSeconds)
      local session = recordingRuntime.ActiveSession
      if not session then return true, 0, 0 end
      session.Accepting = false
      recordingRuntime.KickWorker(session)
      local pendingCount = math.max(0, session.NextIssued - session.NextCommit + 1)
      local baseTimeout = math.max(0, tonumber(timeoutSeconds) or RECORDING_STOP_DRAIN_TIMEOUT)
      local scaledTimeout = math.min(120, RECORDING_RESPONSE_TIMEOUT + RECORDING_CONFIRM_TIMEOUT + 1 +
         (pendingCount * RECORDING_UPGRADE_SETTLE_TIMEOUT))
      local deadline = os.clock() + math.max(baseTimeout, scaledTimeout)
      while session.AllowCommit and session.NextCommit <= session.NextIssued and os.clock() < deadline do
         task.wait(0.05)
      end



      while session.AllowCommit and os.clock() < deadline do
         recordingRuntime.RefreshTowerObservations(session)
         for tower in pairs(session.TowerObservations or {}) do
            recordingRuntime.IsPendingUpgradeReplacementTower(tower, session)
         end
         local waitingForLateReplacement = false
         local now = os.clock()
         for _, producer in pairs(session.UpgradeProducerAttempts or {}) do
            local producerDeadline = tonumber(producer.UpgradeProducerDeadline)
            if producer.UpgradeDropCounted == true and producer.UpgradeRecorded ~= true and
               producer.UpgradeMayStillReplace == true and producer.UpgradeProducerInvalidated ~= true and
               not producer.Cancelled and producerDeadline and now < producerDeadline then
               waitingForLateReplacement = true
               break
            end
         end
         if not waitingForLateReplacement then break end
         task.wait(0.05)
      end
      local drained = session.NextCommit > session.NextIssued
      local unresolved = math.max(0, session.NextIssued - session.NextCommit + 1)
      session.AllowCommit = false
      recordingRuntime.StopTowerObservations(session)
      if recordingRuntime.ActiveSession == session then recordingRuntime.ActiveSession = nil end
      return drained, unresolved, session.Dropped
   end

   function recordingRuntime.GetAction(args)
      local a1, a2 = args[1], args[2]
      if a1 == "Troops" and a2 == "Place" then return "Place" end
      if a1 == "Troops" and a2 == "Upgrade" then return "Upgrade" end
      if a1 == "Troops" and a2 == "Sell" then return "Sell" end
      if a1 == "Troops" and a2 == "Target" then return "Target" end
      if a1 == "Troops" and (a2 == "Abilities" or a2 == "Ability") then return "Ability" end
      if a1 == "Troops" and a2 == "Option" then return "Option" end
      if a1 == "Voting" and a2 == "Skip" then return "Skip" end
      return nil
   end

   function recordingRuntime.CaptureEnvelope(method, remote, args, session)
      local action = recordingRuntime.GetAction(args)
      if not action then return nil end
      session.NextIssued = session.NextIssued + 1
      local sequence = session.NextIssued
      local envelope = {
         Session = session,
         Sequence = sequence,
         Action = action,
         Method = method,
         Args = args,
         Ready = false,
      }


      session.Pending[sequence] = envelope
      if action ~= "Upgrade" then session.NonUpgradeSpendGeneration = session.NonUpgradeSpendGeneration + 1 end
      if action == "Place" then
         session.PlaceAttempts[sequence] = envelope
         session.LastEconomyActivityAt = os.clock()
      elseif action == "Ability" then
         session.LastEconomyActivityAt = os.clock()
      end

      local captureOk, captureError = xpcall(function()
         local remoteData = internal.encodeRemoteCall(method, remote, args)
         local a3, a4 = args[3], args[4]
         envelope.Timing = recordingRuntime.CaptureTiming(os.clock())
         if action ~= "Upgrade" then envelope.ResponseDeadline = envelope.Timing.Clock + RECORDING_RESPONSE_TIMEOUT end
         envelope.RemoteData = remoteData
         if action == "Place" then
            envelope.TowersFolder = internal.getTowersFolder()
            envelope.BeforeTowers = internal.getTowerSnapshot()
            envelope.Details = internal.createPlaceDetails(a3, a4, nil, remoteData)
         elseif action == "Upgrade" then
            local tower = type(a4) == "table" and a4.Troop or nil
            envelope.Tower = tower
            envelope.BeforeTowers = internal.getTowerSnapshot()
            envelope.BeforeUpgradeState = recordingRuntime.ReadTowerUpgradeState(tower)
            envelope.BeforeCash = internal.readMatchCash()
            envelope.Details = internal.createUpgradeDetails(a3, a4, remoteData)
         elseif action == "Sell" then
            envelope.Tower = type(a3) == "table" and a3.Troop or nil
            envelope.BeforeSellTowerPresent = recordingRuntime.GetTopLevelTower(envelope.Tower) ~= nil
            envelope.Details = internal.createSellDetails(a3, remoteData)
         elseif action == "Target" then
            envelope.Details = {Remote = remoteData}
         elseif action == "Ability" then
            envelope.BeforeTowers = internal.getTowerSnapshot()
            envelope.AbilityData = type(a4) == "table" and a4.Data or nil
            envelope.Details = internal.createAbilityDetails(a3, a4, remoteData)
            if recordingRuntime.IsTowerProducingAbilityName(envelope.Details.Name) then
               session.TowerProducerAttempts[sequence] = envelope
            end
         elseif action == "Option" then
            envelope.Details = internal.createOptionDetails(a3, a4, remoteData)
         elseif action == "Skip" then
            envelope.Details = internal.createSkipDetails(remoteData)
         end
      end, traceback)

      if not captureOk then
         envelope.Cancelled = true
         envelope.Ready = true
         recordingRuntime.KickWorker(session)
         error(captureError, 0)
      end

      if action == "Upgrade" then
         session.NextUpgradeTicket = session.NextUpgradeTicket + 1
         envelope.UpgradeTicket = session.NextUpgradeTicket
         session.UpgradeProducerAttempts[sequence] = envelope
      end

      return envelope
   end

   recordingRuntime.OldNamecall = nil
   recordingRuntime.RemoteHookAttempted = false
   recordingRuntime.RemoteHookInstalled = false

   function recordingRuntime.ForwardCapturedRemote(method, remote, args)






      local restoredMethod = false
      if type(setnamecallmethod) == "function" then
         restoredMethod = pcall(setnamecallmethod, method)
      end
      if restoredMethod then
         return recordingRuntime.OldNamecall(remote, internal.unpackValues(args))
      end

      local remoteMethod = remote[method]
      if type(remoteMethod) ~= "function" then
         error("Unable to forward remote method " .. tostring(method), 0)
      end
      return remoteMethod(remote, internal.unpackValues(args))
   end

   function internal.installRemoteRecordingHook()
      if recordingRuntime.RemoteHookInstalled then return true end
      if recordingRuntime.RemoteHookAttempted then return false end
      recordingRuntime.RemoteHookAttempted = true

      if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
         warn("[TDSPro] Remote recording hook unavailable in this executor.")
         return false
      end

      local hookSuccess, hookError = pcall(function()
         local hookHandler = function(self, ...)
            local method = getnamecallmethod()

            if lifecycle.Destroyed or not isRecording or (method ~= "InvokeServer" and method ~= "FireServer") or typeof(self) ~= "Instance" then
               return recordingRuntime.OldNamecall(self, ...)
            end

             local args = internal.packValues(...)
            local session = recordingRuntime.ActiveSession
            if not session or not session.Accepting or not recordingRuntime.GetAction(args) then
               return recordingRuntime.OldNamecall(self, ...)
            end

            local captureOk, envelope = xpcall(function()
               return recordingRuntime.CaptureEnvelope(method, self, args, session)
            end, traceback)
             if not captureOk or not envelope then
                warn("[TDSPro Recording] Failed to capture action before request: " .. tostring(envelope))
                return recordingRuntime.ForwardCapturedRemote(method, self, args)
             end
             recordingRuntime.KickWorker(session)

             if envelope.Action == "Upgrade" then
                local prepareOk, prepareError = xpcall(function()
                   recordingRuntime.PrepareUpgradeCall(envelope)
                end, traceback)
                if not prepareOk then
                   recordingRuntime.RetireUpgradeTicket(session, envelope)
                   envelope.Cancelled = true
                   envelope.Ready = true
                   recordingRuntime.KickWorker(session)
                   warn("[TDSPro Recording] Failed to prepare Upgrade capture: " .. tostring(prepareError))
                   return recordingRuntime.ForwardCapturedRemote(method, self, args)
                end
             end

             local callOk, results = pcall(function()
                return internal.packValues(recordingRuntime.ForwardCapturedRemote(method, self, args))
             end)
             if not callOk then
                if envelope.Action == "Upgrade" then recordingRuntime.RetireUpgradeTicket(session, envelope) end
                envelope.Cancelled = true
                envelope.Ready = true
                recordingRuntime.KickWorker(session)
                error(results, 0)
             end




            envelope.Results = results
            envelope.ResponseClock = os.clock()
            envelope.ConfirmationDeadline = envelope.ResponseClock + RECORDING_CONFIRM_TIMEOUT
            if envelope.Action == "Upgrade" then envelope.ResponseDeadline = nil end
            task.spawn(function()
               if envelope.Action == "Upgrade" then
                  local acquired = recordingRuntime.AcquireUpgradeLane(session, envelope)
                  if not acquired then
                     recordingRuntime.RetireUpgradeTicket(session, envelope)
                     envelope.Cancelled = true
                     envelope.Ready = true
                     recordingRuntime.KickWorker(session)
                     return
                  end
               end

               local finalizeOk, finalizeError = xpcall(function()
                  recordingRuntime.FinalizeEnvelopeAfterCall(envelope, results, method)
               end, traceback)
               recordingRuntime.ReleaseUpgradeLane(session, envelope)
               if not finalizeOk then
                  envelope.Cancelled = true
                  warn("[TDSPro Recording] Failed to confirm captured action: " .. tostring(finalizeError))
               end
               envelope.Ready = true
               recordingRuntime.KickWorker(session)
            end)
            return internal.unpackValues(results)
         end
         local wrappedHandler = type(newcclosure) == "function" and newcclosure(hookHandler) or hookHandler
         recordingRuntime.OldNamecall = hookmetamethod(game, "__namecall", wrappedHandler)
      end)

      if not hookSuccess then
         warn("[TDSPro] Remote recording hook failed: " .. tostring(hookError))
         return false
      end

      recordingRuntime.RemoteHookInstalled = true
      return true
   end

   function macroRuntime.SaveConfig(filename)
      if isRecording or recordingRuntime.ActiveSession then
         internal.notifyMacro("Stop recording first so pending placements/upgrades can be confirmed before saving.", 4)
         return false, "Stop recording before saving."
      end
      local safeFilename = internal.sanitizeMacroFilename(filename)
      local folderReady, folderError = internal.ensureMacroFolder()
      if not folderReady then
         internal.notifyMacro("Failed to create " .. macroFolderName .. ": " .. tostring(folderError), 3)
         return false, tostring(folderError)
      end
      if type(writefile) ~= "function" then
         internal.notifyMacro("Your executor does not support writefile().", 3)
         return false, "writefile() is unavailable."
      end
      if #recordedTimeline == 0 then
         internal.notifyMacro("Nothing to save. Record some actions first!", 3)
         return false, "The timeline is empty."
      end

      local gameInfo = internal.detectCurrentGameInfo()

      local success, jsonStr = pcall(function()
         return HttpService:JSONEncode({
             Meta = {
                Created = os.time(),
                TotalActions = #recordedTimeline,
                FormatVersion = 5,
                SourceFormat = macroRuntime.SourceFormat or "TDSPro",
                TimingMode = loadedMacroMeta.TimingMode or "WaveOnly",
                ReadyPromptWave = 0,
                MacroFolder = macroFolderName,
                Map = loadedMacroMeta.Map or gameInfo.Map,
                Mode = loadedMacroMeta.Mode or gameInfo.Mode,
                Difficulty = loadedMacroMeta.Difficulty or gameInfo.Difficulty,
                Type = loadedMacroMeta.Type or gameInfo.Type,
                TotalTime = loadedMacroMeta.TotalTime,
                Towers = loadedMacroMeta.Towers,
                Modifiers = loadedMacroMeta.Modifiers,
                PlayerCount = loadedMacroMeta.PlayerCount,
                StackingEnabled = loadedMacroMeta.StackingEnabled,
                Triumph = loadedMacroMeta.Triumph,
                FinalWave = loadedMacroMeta.FinalWave,
                SourceFile = loadedMacroMeta.SourceFile,
            },
            Timeline = recordedTimeline
         })
      end)
      if not success or not jsonStr then
         internal.notifyMacro("Failed to encode macro data to JSON.", 3)
         return false, "Could not encode macro JSON."
      end

      local macroPath = internal.getMacroPath(safeFilename)
      local fileSuccess = pcall(function() writefile(macroPath, jsonStr) end)
      if fileSuccess then
         selectedMacroName = safeFilename
         currentMacroName = safeFilename
         macroRuntime.SourceLabel = safeFilename
         internal.refreshMacroDropdown(false)
         if type(TimelineUI.Refresh) == "function" then TimelineUI.Refresh(true) end
         internal.notifyMacro("Macro saved to " .. macroPath .. "\nMap: " .. gameInfo.Map .. " | Mode: " .. gameInfo.Mode .. " | " .. gameInfo.Difficulty, 4)
         return true
      else
         internal.notifyMacro("Failed to write file. Check your executor permissions.", 3)
         return false, "Could not write macro file."
      end
   end

   function macroRuntime.PlayLoaded()
      if isPlayingMacro or macroRuntime.PlaybackTaskActive then
         if macroRuntime.PlaybackTaskActive and not isPlayingMacro then
            internal.notifyMacro("The previous macro is still stopping. Try again in a moment.", 3)
            return
         end
         internal.notifyMacro("A macro is already playing.", 3)
         return
      end
      if isRecording then
         internal.notifyMacro("Stop recording before playing a macro.", 3)
         return
      end
      if #recordedTimeline == 0 and selectedMacroName then
         internal.loadMacroConfig(selectedMacroName)
      end
      if #recordedTimeline == 0 then
         internal.notifyMacro("No macro loaded. Refresh and select a macro first.", 3)
         return
      end

      local timeline = {}
      for index, event in ipairs(recordedTimeline) do
         timeline[index] = event
      end
      table.sort(timeline, internal.compareMacroEvents)

      internal.clearTable(playbackTowerIdsByMacroId)
      macroRuntime.ResetCustomFlags()
      macroRuntime.LastUpgradeAttemptAt = 0
      isPlayingMacro = true
      macroRuntime.PlaybackTaskActive = true
      macroRuntime.BeginRunTelemetry(timeline)
      recordingRuntime.TrackMatchStart()
      local totalEvents = #timeline
      internal.notifyMacro("Playing macro: " .. (selectedMacroName or currentMacroName), 3)
      updateReplayStatus("Playing macro (" .. totalEvents .. " actions)...")

      task.spawn(function()
         local workerOk, workerError = xpcall(function()
         local lastTimestamp = 0
         local firstTimestamp = type(timeline[1]) == "table" and tonumber(timeline[1].Timestamp) or 0
         local playbackStartClock = os.clock()
         if firstTimestamp and firstTimestamp < 0 then
            playbackStartClock = playbackStartClock - internal.adjustMacroPlaybackSeconds(firstTimestamp)
         end
         local playbackWaveStartTimes = {}
         local earlyWorkerEnabled = earlyEconomyActionsEnabled
         local earlyActionStates = internal.startEarlyEconomyActionWorker(timeline, playbackStartClock, playbackWaveStartTimes)
         local playedActions = 0
         local skippedActions = 0
         local fatalPlaybackError = nil

         for i, event in ipairs(timeline) do
            if not isPlayingMacro then break end

            local timestamp = type(event) == "table" and tonumber(event.Timestamp) or lastTimestamp
            if earlyWorkerEnabled and internal.isEarlyEconomyMacroEvent(event) then
               internal.waitForEconomicEventOrEarly(event, timestamp, playbackStartClock, playbackWaveStartTimes, earlyActionStates)
            else
               internal.waitForMacroWaveEvent(event, timestamp, playbackStartClock, playbackWaveStartTimes)
            end
            lastTimestamp = timestamp

            if isPlayingMacro then
               while earlyActionStates[event] == "attempting" and isPlayingMacro do
                  task.wait(0.02)
               end
               if not isPlayingMacro then break end

               macroRuntime.BeginActionTelemetry(event, i, playbackStartClock)
               local replaySuccess, replayError, replayAttempts
               if earlyActionStates[event] == "early-success" then
                  updateReplayStatus("Early action " .. i .. "/" .. totalEvents .. " — " .. tostring(event.Action))
                  replaySuccess = true
                  replayAttempts = 1
               else
                  updateReplayStatus("Action " .. i .. "/" .. totalEvents .. " — " .. tostring(type(event) == "table" and event.Action or "Invalid"))
                  replaySuccess, replayError, replayAttempts = internal.replayMacroEventWithEconomyRetry(event)
                  if internal.isEarlyEconomyMacroEvent(event) then
                     earlyActionStates[event] = "scheduled"
                  else
                     earlyActionStates[event] = "timeline-complete"
                  end
               end

               macroRuntime.FinishActionTelemetry(event, replaySuccess, replayError, replayAttempts)
               if not isPlayingMacro and not replaySuccess then break end
               if replaySuccess then
                  playedActions = playedActions + 1
               else
                  skippedActions = skippedActions + 1
                  warn("[TDSPro] Macro event skipped: " .. tostring(replayError))
                  if type(event) == "table" and (event.Action == "Upgrade" or event.Action == "Place") then
                     fatalPlaybackError = tostring(replayError)
                     isPlayingMacro = false
                     break
                  end
               end
            end
         end

         local stoppedEarly = not isPlayingMacro
         if type(macroRuntime.RunTelemetry) == "table" then
            macroRuntime.RunTelemetry.CompletedAt = os.time()
            macroRuntime.RunTelemetry.PlaybackSeconds = math.max(0, os.clock() - playbackStartClock)
            macroRuntime.RunTelemetry.Played = playedActions
            macroRuntime.RunTelemetry.Skipped = math.max(tonumber(macroRuntime.RunTelemetry.Skipped) or 0, skippedActions)
            macroRuntime.RunTelemetry.FatalError = fatalPlaybackError
         end
         isPlayingMacro = false
         macroRuntime.PlaybackTaskActive = false
         macroRuntime.ResetCustomFlags()

         if stoppedEarly then
            if fatalPlaybackError then
               autoReplayEnabled = false
               if AutoReplayToggle and type(AutoReplayToggle.Set) == "function" then
                  pcall(function() AutoReplayToggle:Set(false) end)
               end
               internal.notifyMacro("Macro stopped to prevent desync: " .. fatalPlaybackError, 6)
               updateReplayStatus("Playback stopped to prevent desync: " .. fatalPlaybackError)
            else
               internal.notifyMacro("Macro playback stopped.", 3)
               updateReplayStatus("Playback stopped. Played " .. playedActions .. ", skipped " .. skippedActions)
            end
         else
            internal.notifyMacro("Macro finished. Played " .. playedActions .. ", skipped " .. skippedActions .. ".", 4)
            updateReplayStatus("Macro complete! Played " .. playedActions .. ", skipped " .. skippedActions)
            if autoReplayEnabled then
               updateReplayStatus("Macro complete. Waiting for end screen...")
            end
         end
         end, traceback)
         if not workerOk then
            isPlayingMacro = false
            macroRuntime.PlaybackTaskActive = false
            macroRuntime.ResetCustomFlags()
            if type(macroRuntime.RunTelemetry) == "table" then
               macroRuntime.RunTelemetry.FatalError = tostring(workerError)
               macroRuntime.RunTelemetry.CompletedAt = os.time()
            end
            autoReplayEnabled = false
            warn("[TDSPro Playback] Worker recovered from an error: " .. tostring(workerError))
            updateReplayStatus("Playback stopped after an internal error.")
            internal.notifyMacro("Playback recovered from an error and was safely stopped.", 6)
            if AutoReplayToggle and type(AutoReplayToggle.Set) == "function" then
               pcall(function() AutoReplayToggle:Set(false) end)
            end
         end
      end)
   end

   function macroRuntime.AutoReplayLoop()
      if autoReplayRunning then return end
      autoReplayRunning = true
      autoReplayRuns = 0
      macroRuntime.MapRerollVetoUsed = false
      macroRuntime.PendingMapRerolls = 0
      macroRuntime.AutoReplayStopMessage = nil

      updateReplayStatus("Auto Replay starting...")

      local loopOk, loopError = xpcall(function()
      while true do

         if not autoReplayEnabled then break end
         timeScaleActiveForRun = false

         if #recordedTimeline == 0 then
            if selectedMacroName then
               internal.loadMacroConfig(selectedMacroName)
            end
            if #recordedTimeline == 0 then
               updateReplayStatus("No macro loaded!")
               autoReplayEnabled = false
               break
            end
         end

         local macroMap = tostring(loadedMacroMeta.Map or "")
         local macroMode = tostring(loadedMacroMeta.Mode or "survival")
         local macroDifficulty = tostring(loadedMacroMeta.Difficulty or "Easy")

         if not macroMap or macroMap == "" or macroMap == "Unknown" then
            updateReplayStatus("Macro has no map/mode data. Re-record with v3.")
            internal.notifyMacro("Macro is missing map metadata. Re-record it so auto replay knows which map to pick.", 5)
            autoReplayEnabled = false
            break
         end

         autoReplayRuns = autoReplayRuns + 1








         local completedMatchResult = internal.getImmediateGameOverResult()
         local votingLobbyReady = isVotingLobbyReady()
         local gameAlreadyStarted = not completedMatchResult and not votingLobbyReady and internal.hasMatchActuallyStarted()
         if not gameAlreadyStarted and not votingLobbyReady then
            local locationDeadline = os.clock() + 8
            updateReplayStatus("Checking whether the voted match is already loading...")
            while autoReplayEnabled and os.clock() < locationDeadline do
               if isVotingLobbyReady() then break end
               local visibleResult = internal.getImmediateGameOverResult()
               if not visibleResult and internal.hasMatchActuallyStarted() then
                  gameAlreadyStarted = true
                  break
               end
               task.wait(0.25)
            end
         end

         if gameAlreadyStarted then
            updateReplayStatus("Active match detected. Continuing without rejoining map selection...")
         else



         local targetAlreadyVisible = internal.findTargetMapInVotingUi(macroMap)
         if not targetAlreadyVisible and not isVotingLobbyReady() then
            macroRuntime.MapRerollVetoUsed = false
            updateReplayStatus("Run #" .. autoReplayRuns .. " — Starting " .. macroMode .. " / " .. macroDifficulty)
            print(macroMap, macroMode, macroDifficulty)
            internal.startMatchmaking(macroDifficulty, macroMode)
            updateReplayStatus("Waiting for map-selection lobby...")
            local lobbyFound = false
            local gameLoadedWhileWaiting = false
            local maxLobbyWait = (multiplayerEnabled and not isHost) and 240 or 60
            for _ = 1, maxLobbyWait do
               if not autoReplayEnabled then break end
               if isVotingLobbyReady() then
                  lobbyFound = true
                  break
               end
               local visibleResult = internal.getImmediateGameOverResult()
               if not visibleResult and internal.hasMatchActuallyStarted() then
                  gameLoadedWhileWaiting = true
                  break
               end
               task.wait(1)
            end
            if not autoReplayEnabled then break end
            if gameLoadedWhileWaiting then



               autoReplayRuns = math.max(0, autoReplayRuns - 1)
               updateReplayStatus("Match loaded directly. Continuing without another map search...")
               continue
            end
            if not lobbyFound then
               updateReplayStatus("Lobby not found. Retrying in 3s...")
               task.wait(3)
               continue
            end
         end

         if not autoReplayEnabled then break end



         if VIPOverrideEnabled then
            local overrideSuccess, overrideError = macroRuntime.TryVIPMapOverride(macroMap)
            if not overrideSuccess then
               warn("[TDSPro] VIP map override failed: " .. tostring(overrideError))
               macroRuntime.AutoReplayStopMessage = "VIP Override stopped: " .. tostring(overrideError)
               updateReplayStatus(macroRuntime.AutoReplayStopMessage)
               internal.notifyMacro("VIP Override could not select '" .. macroMap .. "': " .. tostring(overrideError), 7)
               autoReplayEnabled = false
               break
            end
            updateReplayStatus("VIP Override confirmed: " .. tostring(overrideError or macroMap))
         else
            updateReplayStatus("Checking boards for: " .. macroMap)
            local mapOnBoard, boardMaps, boardScanError = internal.findMapOnStableVotingBoards(macroMap, 10)
            if not autoReplayEnabled then break end

            if mapOnBoard == nil then
               local visibleMaps = #boardMaps > 0 and table.concat(boardMaps, ", ") or "none yet"
               updateReplayStatus("Waiting for voting boards (visible: " .. visibleMaps .. ")")
               if boardScanError then
                  print("[TDSPro] " .. tostring(boardScanError))
               end
               task.wait(1)
               continue
            elseif mapOnBoard then
               local matchedMap = #boardMaps > 0 and tostring(boardMaps[1]) or macroMap
               updateReplayStatus("Found map on voting boards: " .. matchedMap)
               macroRuntime.MapRerollVetoUsed = false
            else
               local visibleMaps = #boardMaps > 0 and table.concat(boardMaps, ", ") or "none"
               if MapRerollEnabled and (not multiplayerEnabled or isHost) then
                  local reloadMatch = macroRuntime.MapRerollVetoUsed == true
                  if not reloadMatch then
                     macroRuntime.MapRerollVetoUsed = true
                     macroRuntime.PendingMapRerolls = (tonumber(macroRuntime.PendingMapRerolls) or 0) + 1
                     updateReplayStatus("Map '" .. macroMap .. "' missing. Using the one allowed veto...")
                     local vetoFound, vetoMaps, vetoWaitError = macroRuntime.TryMapVeto(macroMap, boardMaps)
                     if not autoReplayEnabled then break end
                     if vetoFound then
                        boardMaps = vetoMaps or boardMaps
                        updateReplayStatus("Veto found the requested map: " .. macroMap)
                     else
                        local vetoVisible = #(vetoMaps or {}) > 0 and table.concat(vetoMaps, ", ") or "none"
                        updateReplayStatus("Veto still missed '" .. macroMap .. "' (" .. vetoVisible .. "). Loading a new match...")
                        if vetoWaitError then print("[TDSPro] " .. tostring(vetoWaitError)) end
                        reloadMatch = true
                     end
                  end

                  if reloadMatch then
                     macroRuntime.PendingMapRerolls = (tonumber(macroRuntime.PendingMapRerolls) or 0) + 1
                     internal.notifyMacro("Target map was not available after one veto. Loading a fresh map-selection match...", 4)
                     local reloadSuccess, reloadError = internal.startMatchmaking(macroDifficulty, macroMode)
                     if not reloadSuccess then
                        warn("[TDSPro] New map-selection match failed: " .. tostring(reloadError))
                        updateReplayStatus("Could not load a new match. Retrying without another veto...")
                        task.wait(3)
                     else
                        updateReplayStatus("New match requested. Waiting for the current selection to close...")
                        for _ = 1, 60 do
                           if not autoReplayEnabled then break end
                           if not isVotingLobbyReady() then
                              break
                           end
                           task.wait(1)
                        end




                        macroRuntime.MapRerollVetoUsed = false
                        task.wait(1)
                     end
                     continue
                  end
               else
                  if MapRerollEnabled and multiplayerEnabled and not isHost then
                     updateReplayStatus("Map Reroll: waiting for the host to reload the match...")
                     task.wait(2)
                     continue
                  else
                     updateReplayStatus("Map '" .. macroMap .. "' absent from stable boards (" .. visibleMaps .. "). Re-rolling...")
                  end
                  internal.notifyMacro("Map not found after a complete voting-board scan. Re-rolling match...", 3)
                  macroRuntime.PendingMapRerolls = (tonumber(macroRuntime.PendingMapRerolls) or 0) + 1
                  internal.startMatchmaking(macroDifficulty, macroMode)
                  for _ = 1, 60 do
                     if not autoReplayEnabled then break end
                     if not isVotingLobbyReady() then break end
                     task.wait(1)
                  end
                  task.wait(1)
                  continue
               end
            end
         end

         if modifierVotingEnabled then
            local modifierSuccess, modifierError = internal.voteSelectedModifiers()
            if not modifierSuccess then
               warn("[TDSPro] Bulk modifier vote skipped: " .. tostring(modifierError))
            end
            task.wait(0.5)
         end

         updateReplayStatus("Voting for: " .. macroMap)
         local votePos = internal.makeVector3Value(7.131358623504639, 9.59998607635498, 61.79193115234375)
         local voteSuccess, voteError = internal.fireTDSRemoteEvent("LobbyVoting", "Vote", macroMap, votePos)

         if timeScaleEnabled then
            if voteSuccess then
               updateReplayStatus("Map voted. Using time-scale ticket for 2x...")
               task.wait(0.25)
               local timeScaleSuccess, timeScaleError = internal.unlockAndSetTimeScale2x()
               if timeScaleSuccess then
                  updateReplayStatus("2x time scale enabled for this run.")
               else
                  warn("[TDSPro] 2x time scale failed: " .. tostring(timeScaleError))
                  internal.notifyMacro("Could not enable 2x time scale. Macro timing will remain at 1x.", 4)
                  updateReplayStatus("2x failed; continuing with 1x timing.")
               end
            else
               warn("[TDSPro] Map vote failed; time-scale ticket was not used: " .. tostring(voteError))
               updateReplayStatus("Map vote failed; 2x ticket not used.")
            end
         end
         task.wait(1)


         updateReplayStatus("Readying up...")
         internal.fireTDSRemoteEvent("LobbyVoting", "Ready")
         end


         updateReplayStatus("Waiting for game to start...")
         local gameStarted = internal.hasMatchActuallyStarted()
         local gameStartWaitClock = os.clock()
         while autoReplayEnabled and not gameStarted and (os.clock() - gameStartWaitClock) < 120 do
            if not autoReplayEnabled then break end
            if internal.hasMatchActuallyStarted() then
               gameStarted = true
               break
            end
            task.wait(0.1)
         end
         if not autoReplayEnabled then break end
         if not gameStarted then
            if VIPOverrideEnabled then
               local timeoutMessage = "VIP map was confirmed, but the game did not start within 120 seconds. Auto Replay stopped instead of searching for another map."
               macroRuntime.AutoReplayStopMessage = timeoutMessage
               warn("[TDSPro] " .. timeoutMessage)
               updateReplayStatus(timeoutMessage)
               internal.notifyMacro(timeoutMessage, 7)
               autoReplayEnabled = false
               break
            else
               updateReplayStatus("Game start timeout. Retrying...")
               task.wait(3)
               continue
            end
         end
         macroRuntime.MapRerollVetoUsed = false

         local staleResult, staleBanner = internal.getImmediateGameOverResult()
         if staleResult then
            updateReplayStatus("Completed match detected before playback (" .. tostring(staleBanner) .. "). Requesting fresh map selection...")
            local freshLobbySuccess, freshLobbyResult = internal.startMatchmaking(macroDifficulty, macroMode)
            if not freshLobbySuccess or freshLobbyResult == false then
               warn("[TDSPro] Fresh map-selection request failed: " .. tostring(freshLobbyResult))
               task.wait(3)
               continue
            end




            updateReplayStatus("Waiting for fresh map selection...")
            local freshLobbyDeadline = os.clock() + ((multiplayerEnabled and not isHost) and 240 or 90)
            while autoReplayEnabled and os.clock() < freshLobbyDeadline do
               if isVotingLobbyReady() or internal.findTargetMapInVotingUi(macroMap) then break end
               local lingeringResult = internal.getImmediateGameOverResult()
               if not lingeringResult and internal.hasMatchActuallyStarted() then break end
               task.wait(0.25)
            end
            if not autoReplayEnabled then break end
            continue
         end




         recordingRuntime.TrackMatchStart()

         if macroRuntime.HasPreWaveSetup() then
            skipSync.StartSkipAt = nil
            updateReplayStatus("Macro has pre-wave actions - letting the macro start Wave 1...")
         else
            updateReplayStatus("Waiting for first skip prompt...")
            local firstSkipPrompt = internal.waitForFirstSkipReadyPrompt(internal.adjustMacroPlaybackSeconds(30))
            if not autoReplayEnabled then break end
            if firstSkipPrompt then
               skipCurrentWave("First skip prompt found - skipping...", { MarkStart = true })
            else
               skipCurrentWave("First skip prompt timeout - skipping anyway...", { MarkStart = true })
            end
         end
         task.wait(internal.adjustMacroPlaybackSeconds(0.5))

         updateReplayStatus("Run #" .. autoReplayRuns .. " — Playing macro...")
         macroRuntime.PlayLoaded()

         updateReplayStatus("Waiting for end screen...")
         local gameResult, bannerText = internal.waitForGameOverResult()

         if not autoReplayEnabled then break end
         if not gameResult then
            updateReplayStatus("Game result wait ended without a result. Stopping Auto Replay.")
            autoReplayEnabled = false
            break
         end
         isPlayingMacro = false

         updateReplayStatus("Match ended: " .. tostring(bannerText) .. ". Saving rewards for next-server webhook...")
         internal.trackMatchEnd(gameResult)
         if gameResult == "win" then
            updateReplayStatus("TRIUMPH! Run #" .. autoReplayRuns .. " complete!")
            internal.notifyMacro("Run #" .. autoReplayRuns .. " — TRIUMPH!", 3)
         elseif gameResult == "loss" then
            updateReplayStatus("YOU LOSE. Run #" .. autoReplayRuns .. " complete.")
            updateReplayStatus("Loss confirmed. Waiting 5 seconds before the next match...")
            task.wait(5)
            internal.notifyMacro("Run #" .. autoReplayRuns .. " — YOU LOSE.", 3)
         else
            updateReplayStatus("Game ended. Run #" .. autoReplayRuns .. " complete.")
         end

         if gameResult ~= "loss" then
            task.wait(1)
         end

         updateReplayStatus("Requesting the next map-selection lobby...")
         local nextLobbySuccess, nextLobbyResult = internal.startMatchmaking(macroDifficulty, macroMode)
         if not nextLobbySuccess or nextLobbyResult == false then
            warn("[TDSPro] Next map-selection request failed: " .. tostring(nextLobbyResult))
            updateReplayStatus("Could not request the next map selection. Retrying in 3s...")
            task.wait(3)
            continue
         end





         updateReplayStatus("Waiting for the next map selection...")
         local selectionReady = false
         local nextLobbyDeadline = os.clock() + ((multiplayerEnabled and not isHost) and 240 or 90)
         while autoReplayEnabled and os.clock() < nextLobbyDeadline do
            if isVotingLobbyReady() or internal.findTargetMapInVotingUi(macroMap) then
               selectionReady = true
               break
            end

            local lingeringResult = internal.getImmediateGameOverResult()
            if not lingeringResult and internal.hasMatchActuallyStarted() then


               break
            end
            task.wait(0.25)
         end
         if not autoReplayEnabled then break end

         if selectionReady then
            updateReplayStatus("Map selection ready. Checking maps before the next match...")
         else
            updateReplayStatus("Map selection was not detected yet. Re-checking the current state...")
         end



         task.wait(0.1)
      end
      end, traceback)

      autoReplayRunning = false
      timeScaleActiveForRun = false
      if not loopOk then
         autoReplayEnabled = false
         isPlayingMacro = false
         macroRuntime.ResetCustomFlags()
         warn("[TDSPro AutoReplay] Loop recovered from an error: " .. tostring(loopError))
         updateReplayStatus("Auto Replay stopped after an internal error.")
         internal.notifyMacro("Auto Replay recovered from an error and was safely stopped.", 6)
         if AutoReplayToggle and type(AutoReplayToggle.Set) == "function" then
            pcall(function() AutoReplayToggle:Set(false) end)
         end
      else
         updateReplayStatus(macroRuntime.AutoReplayStopMessage or
            ("Auto Replay stopped. Completed " .. autoReplayRuns .. " run(s)."))
      end

   end


   function recordingRuntime.MarkIntentionalTransition(reason, duration)
      local transitionDuration = math.max(3, tonumber(duration) or 30)
      recordingRuntime.IntentionalTransitionUntil = math.max(
         tonumber(recordingRuntime.IntentionalTransitionUntil) or 0,
         os.clock() + transitionDuration
      )
      recordingRuntime.IntentionalTransitionReason = tostring(reason or "Game transition")
   end

   function recordingRuntime.IsIntentionalTransition()
      return os.clock() <= (tonumber(recordingRuntime.IntentionalTransitionUntil) or 0)
   end

   function recordingRuntime.ShouldIgnoreDisconnectMessage(message)
      local text = tostring(message or "")
      local normalized = string.lower(text):gsub("[^%w]", "")



      if string.find(normalized, "disconnectclientinitiated", 1, true)
         or string.find(normalized, "disconnectclientrequested", 1, true) then
         recordingRuntime.MarkIntentionalTransition(text, 20)
         return true
      end

      return recordingRuntime.IsIntentionalTransition()
   end


   local function libraryStartRuntime()
      internal.refreshLocalPlayer()
      initialCoins = internal.getPlayerStatValue("Coins")
      initialGems = internal.getPlayerStatValue("Gems")
      recordingRuntime.InitialExp, recordingRuntime.InitialExpAvailable = internal.getPlayerExperienceValue()
      internal.loadStatsData()
   libraryConnect(workspace.DescendantAdded, function(descendant)
      if not internal.simplifiedMapVisualsEnabled then return end

      local map = workspace:FindFirstChild("Map")
      local ground = workspace:FindFirstChild("Ground")
      local cliff = workspace:FindFirstChild("Cliff")
      if descendant == map or descendant == ground or descendant == cliff or
         descendant.Name == "Map" or descendant.Name == "Ground" or descendant.Name == "Cliff" then
         internal.queueSimplifiedMapVisuals()
         return
      end

      internal.applySimplifiedMapObject(descendant, map, ground, cliff)
   end)

   if LocalPlayer and LocalPlayer.Idled then
      libraryConnect(LocalPlayer.Idled, function()
         if antiAFKEnabled then
            pcall(function()
               VirtualUser:CaptureController()
               VirtualUser:ClickButton2(Vector2.new(0, 0))
            end)
         end
      end)
   end

   if LocalPlayer and LocalPlayer.OnTeleport then
      pcall(function()
          libraryConnect(LocalPlayer.OnTeleport, function(teleportState)
             local stateName = tostring(teleportState or "Unknown")
             if string.find(string.lower(stateName), "failed", 1, true) then
                recordingRuntime.IntentionalTransitionUntil = 0
                recordingRuntime.IntentionalTransitionReason = nil
                if macroRuntime.LoadingRecoveryActive then
                   recordingRuntime.EmitLoadingRejoinFailed("Roblox reported teleport state: " .. stateName)
                end
             else
               recordingRuntime.MarkIntentionalTransition("Teleport: " .. stateName, 45)
            end
         end)
      end)
   end

   libraryConnect(Players.PlayerRemoving, function(player)
      if player == (LocalPlayer or Players.LocalPlayer) and (autoReplayEnabled or currentMatchStartClock ~= nil) then
         if recordingRuntime.IsIntentionalTransition() then
            print("[TDSPro Webhook] Ignored PlayerRemoving during " .. tostring(recordingRuntime.IntentionalTransitionReason or "an intentional transition") .. ".")
            return
         end
         if recordingRuntime.DisconnectErrorReported then return end
         recordingRuntime.DisconnectErrorReported = true
         recordingRuntime.DispatchWebhookEvent("Disconnect", "PLAYER DISCONNECTED", "The local player left while TDSPRO automation was active.", 15548997, {
            {name = "MACRO", value = tostring(selectedMacroName or currentMacroName or "Unknown"), inline = true},
            {name = "MAP", value = tostring(loadedMacroMeta.Map or "Unknown"), inline = true},
            {name = "WAVE", value = tostring(internal.readWaveValue()), inline = true},
         }, {Critical = true})
      end
   end)

   pcall(function()
      libraryConnect(game:GetService("GuiService").ErrorMessageChanged, function(message)
         if tostring(message or "") ~= "" and (autoReplayEnabled or currentMatchStartClock ~= nil) and not recordingRuntime.DisconnectErrorReported then
            if recordingRuntime.ShouldIgnoreDisconnectMessage(message) then
               print("[TDSPro Webhook] Ignored expected transition message: " .. tostring(message))
               return
            end
            recordingRuntime.DisconnectErrorReported = true
            recordingRuntime.DispatchWebhookEvent("Disconnect", "CONNECTION ERROR", tostring(message), 15548997, {
               {name = "MACRO", value = tostring(selectedMacroName or currentMacroName or "Unknown"), inline = true},
               {name = "WAVE", value = tostring(internal.readWaveValue()), inline = true},
            }, {Critical = true})
         end
      end)
   end)

   task.spawn(function()
       while not lifecycle.Destroyed do
           if PendingLogRefresh then
               PendingLogRefresh = false
               internal.refreshRecordingLogFromTimeline()
           elseif #PendingLogs > 0 then
               local entry = table.remove(PendingLogs, 1)
               internal.pushRecordingLog(entry)
           end
           task.wait(0.1)
       end
   end)


      macroRuntime.StartLoadingStallWatchdog()
      recordingRuntime.PendingRoundReconcileDone = false
      task.spawn(function()
         local ok, reason = recordingRuntime.ReconcilePendingRound(15)
         recordingRuntime.PendingRoundReconcileDone = true
         if not lifecycle.Destroyed then recordingRuntime.RefreshStatsUI() end
         if not ok and reason ~= "nothing pending" and reason ~= "waiting for the next server" then
            libraryEmit("Error", {Message = "Pending round reconciliation: " .. tostring(reason)})
         end
      end)
      task.spawn(function()
         while not lifecycle.Destroyed do
            recordingRuntime.RefreshStatsUI()
            task.wait(1)
         end
      end)
   end

   function internal.LibraryAlive()
      if lifecycle.Destroyed then return false, "This TDSPro instance has been destroyed." end
      return true
   end

   function internal.LibraryIdle()
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      if isRecording or recordingRuntime.ActiveSession or lifecycle.RecordingStopping then
         return false, "Stop recording and wait for pending actions before changing the macro."
      end
      if isPlayingMacro or macroRuntime.PlaybackTaskActive or autoReplayEnabled or autoReplayRunning then
         return false, "Stop playback and wait for it to finish before changing the macro."
      end
      if macroRuntime.AutoEquipBusy then return false, "Wait for the inventory change to finish." end
      return true
   end

   function internal.LibraryFinite(value)
      return type(value) == "number" and value == value and value > -math.huge and value < math.huge
   end

   function api:GetConfig()
      return {
         MacroFolder = macroFolderName,
         AntiAFK = antiAFKEnabled,
         VIPOverride = VIPOverrideEnabled,
         MapReroll = MapRerollEnabled,
         LoadingStallRecovery = loadingStallRecoveryEnabled,
         LoadingStallTimeout = loadingStallTimeout,
         TimeScale2x = timeScaleEnabled,
         EarlyEconomyActions = earlyEconomyActionsEnabled,
         ModifierVoting = modifierVotingEnabled,
         Modifiers = libraryCopy(selectedModifierOptions),
         AutoSkip = standaloneAutoSkipEnabled,
         SimplifyMapVisuals = internal.simplifiedMapVisualsEnabled,
         Multiplayer = multiplayerEnabled,
         IsHost = isHost,
         PlayerCount = playerCount,
         HostDelay = hostDelayVal,
         WebhookEnabled = webhookEnabled,
         WebhookURL = webhookUrl,
         WebhookLogoURL = webhookLogoUrl,
         WebhookEvents = libraryCopy(recordingRuntime.WebhookConfig.Events),
         WebhookRateLimit = recordingRuntime.WebhookConfig.RateLimit,
      }
   end

   function api:Configure(settings)
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      if type(settings) ~= "table" then return false, "Settings must be a table." end
      local previous = self:GetConfig()
      local nextConfig = libraryCopy(previous)
      for key, value in pairs(settings) do
         if nextConfig[key] == nil then return false, "Unknown setting: " .. tostring(key) end
         if type(previous[key]) == "boolean" then
            if type(value) ~= "boolean" then return false, key .. " must be a boolean." end
         elseif key == "LoadingStallTimeout" then
            if not internal.LibraryFinite(value) or value < 30 then return false, key .. " must be a finite number of at least 30 seconds." end
         elseif key == "PlayerCount" then
            if not internal.LibraryFinite(value) or value % 1 ~= 0 or value < 2 or value > 4 then return false, key .. " must be 2, 3, or 4." end
         elseif key == "HostDelay" then
            if not internal.LibraryFinite(value) or value < 0 or value > 30 then return false, key .. " must be between 0 and 30 seconds." end
         elseif key == "WebhookRateLimit" then
            if not internal.LibraryFinite(value) or value < 0 then return false, key .. " must be a nonnegative finite number." end
         elseif key == "Modifiers" then
            if type(value) ~= "table" then return false, "Modifiers must be an array of names or a name-to-boolean table." end
            for modifierKey, modifierValue in pairs(value) do
               if type(modifierKey) == "number" then
                  if modifierKey < 1 or modifierKey % 1 ~= 0 or type(modifierValue) ~= "string" or not modifierOptionFlags[modifierValue] then
                     return false, "Unknown or invalid modifier: " .. tostring(modifierValue)
                  end
               elseif type(modifierKey) ~= "string" or type(modifierValue) ~= "boolean" or not modifierOptionFlags[modifierKey] then
                  return false, "Unknown or invalid modifier: " .. tostring(modifierKey)
               end
            end
            value = internal.normalizeModifierSelection(value)
         elseif key == "WebhookEvents" then
            if type(value) ~= "table" then return false, "WebhookEvents must be a table." end
            local merged = libraryCopy(previous.WebhookEvents)
            for eventName, enabled in pairs(value) do
               if merged[eventName] == nil or type(enabled) ~= "boolean" then return false, "Invalid webhook event: " .. tostring(eventName) end
               merged[eventName] = enabled
            end
            value = merged
         elseif key == "MacroFolder" then
            if type(value) ~= "string" or value == "" or value:match("^[/\\]") or value:find(":", 1, true) or value:find("..", 1, true) then
               return false, "MacroFolder must be a nonempty relative folder path without parent traversal."
            end
            if lifecycle.Started and value ~= previous.MacroFolder then return false, "MacroFolder can only be changed before Start()." end
         elseif key == "WebhookURL" or key == "WebhookLogoURL" then
            if type(value) ~= "string" then return false, key .. " must be a string." end
            value = value:gsub("^%s+", ""):gsub("%s+$", "")
            if key == "WebhookURL" and value ~= "" then
               local host = value:match("^https://([^/]+)/api/webhooks/[^/]+/[^%s]+$")
               if host ~= "discord.com" and host ~= "discordapp.com" and host ~= "canary.discord.com" and host ~= "ptb.discord.com" then
                  return false, "WebhookURL must be empty or a Discord HTTPS webhook URL."
               end
            end
            if key == "WebhookLogoURL" and value ~= "" and not value:match("^https://[^%s]+$") then
               return false, "WebhookLogoURL must be empty or an HTTPS URL."
            end
         end
         nextConfig[key] = libraryCopy(value)
      end
      if settings.VIPOverride == true and settings.MapReroll == true then
         return false, "VIPOverride and MapReroll cannot both be enabled."
      elseif settings.VIPOverride == true then
         nextConfig.MapReroll = false
      elseif settings.MapReroll == true then
         nextConfig.VIPOverride = false
      end
      macroFolderName = nextConfig.MacroFolder
      statsFileName = macroFolderName .. "/stats.json"
      antiAFKEnabled = nextConfig.AntiAFK
      VIPOverrideEnabled = nextConfig.VIPOverride
      MapRerollEnabled = nextConfig.MapReroll
      if settings.MapReroll ~= nil then macroRuntime.MapRerollVetoUsed = false end
      loadingStallRecoveryEnabled = nextConfig.LoadingStallRecovery
      loadingStallTimeout = nextConfig.LoadingStallTimeout
      if not loadingStallRecoveryEnabled then
         macroRuntime.LoadingOverlayVisibleSince = nil
         macroRuntime.LoadingOverlayReason = nil
      end
      timeScaleEnabled = nextConfig.TimeScale2x
      earlyEconomyActionsEnabled = nextConfig.EarlyEconomyActions
      modifierVotingEnabled = nextConfig.ModifierVoting
      selectedModifierOptions = nextConfig.Modifiers
      standaloneAutoSkipEnabled = nextConfig.AutoSkip
      internal.simplifiedMapVisualsEnabled = nextConfig.SimplifyMapVisuals
      multiplayerEnabled = nextConfig.Multiplayer
      isHost = nextConfig.IsHost
      playerCount = nextConfig.PlayerCount
      hostDelayVal = nextConfig.HostDelay
      webhookEnabled = nextConfig.WebhookEnabled
      webhookUrl = nextConfig.WebhookURL
      webhookLogoUrl = nextConfig.WebhookLogoURL
      recordingRuntime.WebhookConfig.Events = nextConfig.WebhookEvents
      recordingRuntime.WebhookConfig.RateLimit = nextConfig.WebhookRateLimit
      if lifecycle.Started then
         if previous.AutoSkip ~= standaloneAutoSkipEnabled then
            if standaloneAutoSkipEnabled then macroRuntime.StartStandaloneAutoSkipLoop()
            else standaloneAutoSkipToken = standaloneAutoSkipToken + 1 end
         end
         if previous.SimplifyMapVisuals ~= internal.simplifiedMapVisualsEnabled then
            if internal.simplifiedMapVisualsEnabled then internal.queueSimplifiedMapVisuals()
            else internal.restoreSimplifiedMapVisuals() end
         end
         if webhookEnabled and (not previous.WebhookEnabled or previous.WebhookURL ~= webhookUrl) then
            task.spawn(recordingRuntime.ProcessWebhookDeliveryQueue)
         end
      end
      libraryEmit("ConfigChanged", self:GetConfig())
      return true, self:GetConfig()
   end

   function api:GetState()
      return {
         Started = lifecycle.Started,
         Destroyed = lifecycle.Destroyed,
         Status = lifecycle.Status,
         Recording = isRecording,
         RecordingStopping = lifecycle.RecordingStopping == true,
         Playing = isPlayingMacro,
         PlaybackBusy = macroRuntime.PlaybackTaskActive,
         AutoReplay = autoReplayEnabled,
         AutoReplayRunning = autoReplayRunning,
         AutoReplayRuns = autoReplayRuns,
         InventoryBusy = macroRuntime.AutoEquipBusy == true,
         MacroName = currentMacroName,
         SelectedMacro = selectedMacroName,
         EventCount = #recordedTimeline,
         Metadata = libraryCopy(loadedMacroMeta),
         SourceFormat = macroRuntime.SourceFormat,
         PendingRoundReconciled = recordingRuntime.PendingRoundReconcileDone == true,
      }
   end

   function api:On(eventName, callback)
      if lifecycle.Destroyed then return nil, "This TDSPro instance has been destroyed." end
      if type(eventName) ~= "string" or eventName == "" or type(callback) ~= "function" then
         return nil, "On expects an event name and callback function."
      end
      local listeners = lifecycle.Listeners[eventName]
      if not listeners then listeners = {}; lifecycle.Listeners[eventName] = listeners end
      local connection = {Connected = true, Callback = callback}
      function connection:Disconnect()
         self.Connected = false
         listeners[self] = nil
      end
      listeners[connection] = connection
      return connection
   end

   function api:Start()
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      if lifecycle.Started then return true, self:GetState() end
      lifecycle.Started = true
      local success, result = pcall(libraryStartRuntime)
      if not success then
         self:Destroy()
         return false, "TDSPro startup failed: " .. tostring(result)
      end
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed during startup." end
      if standaloneAutoSkipEnabled then macroRuntime.StartStandaloneAutoSkipLoop() end
      if internal.simplifiedMapVisualsEnabled then internal.queueSimplifiedMapVisuals() end
      if webhookEnabled then task.spawn(recordingRuntime.ProcessWebhookDeliveryQueue) end
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function api:Destroy()
      if lifecycle.Destroyed then return true end
      lifecycle.Destroyed = true
      lifecycle.Started = false
      lifecycle.Status = "Destroyed"
      autoReplayEnabled = false
      autoReplayRunning = false
      isPlayingMacro = false
      isRecording = false
      standaloneAutoSkipEnabled = false
      standaloneAutoSkipToken = standaloneAutoSkipToken + 1
      internal.simplifiedMapVisualsEnabled = false
      antiAFKEnabled = false
      webhookEnabled = false
      macroRuntime.ResetCustomFlags()
      recordingRuntime.CancelSession()
      recordingWatch.Stop()
      internal.restoreSimplifiedMapVisuals()
      recordingArmedAt = 0
      recordingTimerStarted = false
      macroRuntime.PlaybackTaskActive = false
      macroRuntime.AutoEquipBusy = false
      lifecycle.RecordingStopping = false
      for _, connection in pairs(lifecycle.Connections) do
         pcall(function() connection:Disconnect() end)
      end
      internal.clearTable(lifecycle.Connections)
      for key, value in pairs(lifecycle.Threads) do
         local thread = type(key) == "thread" and key or value
         if type(thread) == "thread" and thread ~= coroutine.running() and lifecycle.RawTask and lifecycle.RawTask.cancel then
            pcall(lifecycle.RawTask.cancel, thread)
         end
      end
      internal.clearTable(lifecycle.Threads)
      libraryEmit("Destroyed", self:GetState())
      for _, listeners in pairs(lifecycle.Listeners) do
         for _, connection in pairs(listeners) do connection.Connected = false end
      end
      internal.clearTable(lifecycle.Listeners)
      return true
   end

   function api:ListMacros()
      if lifecycle.Destroyed then return {}, "This TDSPro instance has been destroyed." end
      local names = internal.getSavedMacroNames()
      return libraryCopy(names), macroDirectoryError
   end

   function api:LoadMacro(name)
      local idle, message = internal.LibraryIdle()
      if not idle then return false, message end
      if type(name) ~= "string" or internal.trimMacroName(name) == "" then return false, "Macro name must be a nonempty string." end
      internal.getSavedMacroNames()
      local success, errorMessage = internal.loadMacroConfig(name)
      if not success then return false, errorMessage or "Could not load the macro." end
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function api:SaveMacro(name)
      local idle, message = internal.LibraryIdle()
      if not idle then return false, message end
      name = name or currentMacroName
      if type(name) ~= "string" or internal.trimMacroName(name) == "" then return false, "Macro name must be a nonempty string." end
      local success, errorMessage = macroRuntime.SaveConfig(name)
      if not success then return false, errorMessage or "Could not save the macro." end
      libraryEmit("StateChanged", self:GetState())
      return true, internal.getMacroPath(name)
   end

   function api:ImportMacro(document, name)
      local idle, message = internal.LibraryIdle()
      if not idle then return false, message end
      if name ~= nil and (type(name) ~= "string" or internal.trimMacroName(name) == "") then return false, "Macro name must be a nonempty string." end
      if type(document) == "string" then
         local decoded, value = pcall(function() return HttpService:JSONDecode(document) end)
         if not decoded then return false, "Invalid macro JSON: " .. tostring(value) end
         document = value
      end
      if type(document) ~= "table" then return false, "Macro must be a document table or JSON string." end
      local success, timeline, metadata, sourceFormat, normalizeError = pcall(macroRuntime.NormalizeDocument, libraryCopy(document))
      if not success then return false, "Could not normalize macro: " .. tostring(timeline) end
      if type(timeline) ~= "table" then return false, normalizeError or "Unsupported macro document." end
      local eventCount = 0
      for index, event in pairs(timeline) do
         eventCount = eventCount + 1
         if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or type(event) ~= "table" or type(event.Action) ~= "string" then
            return false, "Timeline must be an array of events with Action names."
         end
         if event.Details ~= nil and type(event.Details) ~= "table" then return false, "Event Details must be a table." end
         for _, field in ipairs({"Timestamp", "Wave", "WaveElapsed", "WaveTimestamp", "WaveTime", "WaveTimer", "Order"}) do
            if event[field] ~= nil and not internal.LibraryFinite(event[field]) then return false, "Invalid event " .. tostring(index) .. " field " .. field .. "." end
         end
      end
      if eventCount ~= #timeline then return false, "Timeline must be a contiguous array." end
      recordedTimeline = timeline
      loadedMacroMeta = type(metadata) == "table" and metadata or {}
      macroRuntime.SourceFormat = sourceFormat or "TDSPro"
      currentMacroName = name and internal.sanitizeMacroFilename(name) or currentMacroName
      selectedMacroName = nil
      macroRuntime.SourceLabel = name or "Imported macro"
      internal.clearTable(recordedTowerIdsByInstance)
      internal.clearTable(recordedPlaceDetailsByTroopId)
      internal.clearTable(recordedUpgradeStateByTower)
      internal.clearTable(recordingLogLines)
      TimelineUI.Refresh(true)
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function api:ExportMacro(asJSON)
      local metadata = libraryCopy(loadedMacroMeta)
      metadata.FormatVersion = metadata.FormatVersion or 5
      metadata.SourceFormat = macroRuntime.SourceFormat or "TDSPro"
      metadata.TimingMode = metadata.TimingMode or "WaveOnly"
      metadata.TotalActions = #recordedTimeline
      local document = {Meta = metadata, Timeline = libraryCopy(recordedTimeline)}
      if asJSON then
         local success, encoded = pcall(function() return HttpService:JSONEncode(document) end)
         if not success then return nil, "Could not encode macro JSON: " .. tostring(encoded) end
         return encoded
      end
      return document
   end

   function api:GetTimeline()
      local events = libraryCopy(recordedTimeline)
      table.sort(events, internal.compareMacroEvents)
      return events
   end

   function api:SetEventTime(index, seconds)
      local idle, message = internal.LibraryIdle()
      if not idle then return false, message end
      if not internal.LibraryFinite(index) or index % 1 ~= 0 or index < 1 then return false, "Event index must be a positive integer." end
      if not internal.LibraryFinite(seconds) or seconds < 0 then return false, "Event time must be a nonnegative finite number." end
      TimelineUI.Refresh(false)
      local event = TimelineUI.Events[index]
      if not event then return false, "Timeline event does not exist." end
      if event.TimingMode == "WaveTimerCountdown" and tonumber(event.Wave) ~= nil then
         event.WaveTimer = seconds
         if event.WaveTime ~= nil then event.WaveTime = seconds end
      elseif tonumber(event.Wave) ~= nil and tonumber(event.WaveElapsed or event.WaveTimestamp) ~= nil then
         event.WaveElapsed = seconds
         if event.WaveTimestamp ~= nil then event.WaveTimestamp = seconds end
      else
         event.Timestamp = seconds
      end
      TimelineUI.Refresh(false)
      return true, libraryCopy(event)
   end

   function api:GetRecordingLog()
      return libraryCopy(recordingLogLines)
   end

   function api:GetTelemetry()
      return libraryCopy(macroRuntime.RunTelemetry or {})
   end

   function api:GetGameInfo()
      return libraryCopy(internal.detectCurrentGameInfo())
   end

   function api:GetModifiers()
      local names = {}
      for name in pairs(modifierOptionFlags) do table.insert(names, name) end
      table.sort(names)
      return names
   end

   function api:StartRecording(name)
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      local idle, idleMessage = internal.LibraryIdle()
      if not idle then return false, idleMessage end
      if name ~= nil and (type(name) ~= "string" or internal.trimMacroName(name) == "") then return false, "Macro name must be a nonempty string." end
      if not internal.installRemoteRecordingHook() then return false, "Remote recording hooks are unavailable in this executor." end
      if lifecycle.Destroyed then return false, "This TDSPro instance has been destroyed." end
      recordingRuntime.BeginSession()
      isRecording = true
      recordingArmedAt = os.clock()
      recordingTimerStarted = true
      internal.clearTable(recordedTimeline)
      internal.clearTable(recordingLogLines)
      recordedEventCounter = 0
      recordedTroopCounter = 0
      internal.clearTable(recordedTowerIdsByInstance)
      internal.clearTable(recordedPlaceDetailsByTroopId)
      internal.clearTable(recordedUpgradeStateByTower)
      recordingWatch.Start()
      detectedGameInfo = internal.detectCurrentGameInfo()
      loadedMacroMeta = {
         SourceFormat = "TDSPro", TimingMode = "WaveOnly", Map = detectedGameInfo.Map,
         Mode = detectedGameInfo.Mode, Difficulty = detectedGameInfo.Difficulty, Type = detectedGameInfo.Type,
      }
      if name then currentMacroName = internal.sanitizeMacroFilename(name) end
      selectedMacroName = nil
      macroRuntime.SourceFormat = "TDSPro"
      macroRuntime.SourceLabel = "Current recording"
      TimelineUI.Refresh(true)
      internal.pushRecordingLog("[00:00] Recording started - wave-based timing")
      libraryEmit("RecordingChanged", self:GetState())
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function api:StopRecording()
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      if lifecycle.RecordingStopping then return false, "Recording is already stopping." end
      if not isRecording and not recordingRuntime.ActiveSession then return true, {Events = #recordedTimeline, Drained = true, Unresolved = 0, Dropped = 0} end
      lifecycle.RecordingStopping = true
      local session = recordingRuntime.ActiveSession
      if session then session.Accepting = false end
      isRecording = false
      local success, drained, unresolved, dropped = pcall(recordingRuntime.CloseAndDrainSession, RECORDING_STOP_DRAIN_TIMEOUT)
      lifecycle.RecordingStopping = false
      recordingWatch.Stop()
      local elapsed = recordingArmedAt > 0 and math.max(0, os.clock() - recordingArmedAt) or 0
      recordingArmedAt = 0
      recordingTimerStarted = false
      if not success then recordingRuntime.CancelSession(); return false, "Could not drain recording: " .. tostring(drained) end
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed while recording stopped." end
      internal.pushRecordingLog("[" .. internal.formatTimestamp(elapsed) .. "] Recording stopped. " .. #recordedTimeline .. " events; " .. tostring(unresolved) .. " unresolved; " .. tostring(dropped) .. " rejected/unconfirmed.")
      TimelineUI.Refresh(true)
      libraryEmit("RecordingChanged", self:GetState())
      libraryEmit("StateChanged", self:GetState())
      return true, {Events = #recordedTimeline, Drained = drained, Unresolved = unresolved, Dropped = dropped}
   end

   function api:ClearRecording()
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      if lifecycle.RecordingStopping then return false, "Wait for recording to finish stopping." end
      if isPlayingMacro or macroRuntime.PlaybackTaskActive or autoReplayEnabled or autoReplayRunning then return false, "Stop playback before clearing the timeline." end
      local resumeRecording = isRecording
      recordingRuntime.CancelSession()
      recordingWatch.Stop()
      internal.clearTable(recordedTimeline)
      internal.clearTable(recordingLogLines)
      internal.clearTable(recordedTowerIdsByInstance)
      internal.clearTable(recordedPlaceDetailsByTroopId)
      internal.clearTable(recordedUpgradeStateByTower)
      recordedEventCounter = 0
      recordedTroopCounter = 0
      recordingArmedAt = resumeRecording and os.clock() or 0
      recordingTimerStarted = resumeRecording
      if resumeRecording then recordingRuntime.BeginSession(); recordingWatch.Start() end
      macroRuntime.SourceLabel = resumeRecording and "Current recording" or (selectedMacroName or currentMacroName)
      TimelineUI.Refresh(true)
      libraryEmit("RecordingLog", self:GetRecordingLog())
      libraryEmit("StateChanged", self:GetState())
      return true
   end

   function api:Play()
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      local idle, idleMessage = internal.LibraryIdle()
      if not idle then return false, idleMessage end
      if #recordedTimeline == 0 then return false, "Load or import a macro before playing." end
      local _, replayable = internal.getMacroReplayStats(recordedTimeline)
      if replayable == 0 then return false, "The macro contains no replayable actions." end
      local success, result = pcall(macroRuntime.PlayLoaded)
      if not success then return false, tostring(result) end
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function api:Stop()
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      autoReplayEnabled = false
      isPlayingMacro = false
      macroRuntime.ResetCustomFlags()
      updateReplayStatus("Stopping playback...")
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function api:SetAutoReplay(enabled)
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      if type(enabled) ~= "boolean" then return false, "Auto replay expects a boolean." end
      if not enabled then return self:Stop() end
      if autoReplayEnabled then return true, self:GetState() end
      local idle, idleMessage = internal.LibraryIdle()
      if not idle then return false, idleMessage end
      if #recordedTimeline == 0 then return false, "Load or import a macro before enabling auto replay." end
      local _, replayable = internal.getMacroReplayStats(recordedTimeline)
      if replayable == 0 then return false, "The macro contains no replayable actions." end
      autoReplayEnabled = true
      task.spawn(macroRuntime.AutoReplayLoop)
      libraryEmit("StateChanged", self:GetState())
      return true, self:GetState()
   end

   function internal.LibraryInventoryOperation(operation)
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      if macroRuntime.AutoEquipBusy then return false, "An inventory change is already running." end
      if isRecording or isPlayingMacro or autoReplayEnabled then return false, "Stop recording and playback before changing the loadout." end
      macroRuntime.AutoEquipBusy = true
      libraryEmit("StateChanged", api:GetState())
      local success, completed, detail = xpcall(operation, traceback)
      macroRuntime.AutoEquipBusy = false
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed during the inventory operation." end
      libraryEmit("StateChanged", api:GetState())
      if not success then return false, tostring(completed) end
      return completed == true, detail
   end

   function api:AutoEquipInventory()
      return internal.LibraryInventoryOperation(macroRuntime.AutoEquipInventory)
   end

   function api:RestorePreviousLoadout()
      return internal.LibraryInventoryOperation(macroRuntime.RestorePreviousLoadout)
   end

   function api:GetStats()
      local stats = libraryCopy(savedStats)
      stats.Rates = recordingRuntime.GetStatsRate(savedStats)
      return stats
   end

   function api:RefreshStats()
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      internal.loadStatsData()
      recordingRuntime.RefreshStatsUI()
      return true, self:GetStats()
   end

   function api:ResetStats()
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      return recordingRuntime.ResetAllStats()
   end

   function api:SkipWave()
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      return skipCurrentWave(nil)
   end

   function api:SendTestWebhook()
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      local urls = recordingRuntime.GetWebhookEventUrls("MatchResult")
      if not urls[1] then return false, "Configure a valid Discord webhook URL first." end
      local success, sent = pcall(recordingRuntime.SendPendingRoundWebhook, {
         WebhookEnabled = true, WebhookUrl = urls[1], WebhookLogoUrl = webhookLogoUrl,
         Result = "win", ResolvedCoinsGained = 720, ResolvedGemsGained = 85, ResolvedExpGained = 1250,
         MiscRewards = {"+2 Crates", "+1 Rare Skin"}, MatchSeconds = 450,
      })
      if not success then return false, tostring(sent) end
      if not sent then return false, "The test webhook could not be sent." end
      return true
   end

   function api:ReconcilePendingRound(timeout)
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      timeout = timeout or 15
      if not internal.LibraryFinite(timeout) or timeout < 0 or timeout > 120 then return false, "Reconciliation timeout must be between 0 and 120 seconds." end
      if recordingRuntime.PendingRoundReconcileDone == false then return false, "Pending-round reconciliation is already running." end
      recordingRuntime.PendingRoundReconcileDone = false
      local success, reconciled, detail = pcall(recordingRuntime.ReconcilePendingRound, timeout)
      recordingRuntime.PendingRoundReconcileDone = true
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed during reconciliation." end
      if not success then return false, tostring(reconciled) end
      recordingRuntime.RefreshStatsUI()
      libraryEmit("StateChanged", self:GetState())
      return reconciled == true, detail
   end

   function api:StartMatchmaking(difficulty, mode)
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      local idle, idleMessage = internal.LibraryIdle()
      if not idle then return false, idleMessage end
      difficulty = difficulty or loadedMacroMeta.Difficulty
      mode = mode or loadedMacroMeta.Mode
      if type(difficulty) ~= "string" or difficulty == "" then return false, "A difficulty is required." end
      if mode ~= nil and type(mode) ~= "string" then return false, "Mode must be a string." end
      local success, matched, detail = pcall(internal.startMatchmaking, difficulty, mode)
      if not success then return false, tostring(matched) end
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed during matchmaking." end
      return matched == true, detail
   end

   function api:VoteModifiers()
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      local args = internal.buildSelectedModifierArgs()
      if not args then return false, "Configure at least one modifier first." end
      local success, voted, detail = pcall(internal.invokeBulkVoteModifiers, args)
      if not success then return false, tostring(voted) end
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed during modifier voting." end
      return voted == true, detail
   end

   function api:UseTimeScaleTicket()
      local started, message = libraryCheckStarted()
      if not started then return false, message end
      local idle, idleMessage = internal.LibraryIdle()
      if not idle then return false, idleMessage end
      local success, applied, detail = pcall(internal.unlockAndSetTimeScale2x)
      if not success then return false, tostring(applied) end
      if lifecycle.Destroyed then return false, "This TDSPro instance was destroyed while applying the time-scale ticket." end
      return applied == true, detail
   end

   function api:SaveSettings(path)
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      if path ~= nil and (type(path) ~= "string" or path == "") then return false, "Settings path must be a nonempty string." end
      if type(writefile) ~= "function" then return false, "This executor does not support writefile()." end
      local folderReady, folderError = internal.ensureMacroFolder()
      if not folderReady then return false, tostring(folderError) end
      path = path or (macroFolderName .. "/settings.json")
      local success, errorMessage = pcall(function() writefile(path, HttpService:JSONEncode(self:GetConfig())) end)
      if not success then return false, tostring(errorMessage) end
      return true, path
   end

   function api:LoadSettings(path)
      local alive, message = internal.LibraryAlive()
      if not alive then return false, message end
      if path ~= nil and (type(path) ~= "string" or path == "") then return false, "Settings path must be a nonempty string." end
      if type(readfile) ~= "function" then return false, "This executor does not support readfile()." end
      path = path or (macroFolderName .. "/settings.json")
      local success, settings = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
      if not success then return false, tostring(settings) end
      return self:Configure(settings)
   end

   local configured, configurationError = api:Configure(options or {})
   if not configured then error(configurationError, 2) end
   return api
end

if type(getgenv) == "function" then
   pcall(function() getgenv().TDSProLibrary = TDSPro end)
elseif type(_G) == "table" then
   pcall(function() _G.TDSProLibrary = TDSPro end)
end

return TDSPro
