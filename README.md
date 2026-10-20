# TDS Pro library

`TDSPro.lua` is a client-side Luau library for TDS macro recording, playback, inventory management, and match statistics. It returns a factory instead of opening an interface. Your application owns its buttons, controls, notifications, and presentation.

Requiring the module and creating an instance do not start automation. Subscribe to events, call `Start()`, then explicitly start the features your interface offers. The library does not download a UI framework, create a window or HUD, or send the old usage telemetry.

## Load from GitHub

Load the current library directly from the public repository:

```lua
local TDSPro = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/refs/heads/main/TDSPro.lua"
))()

local tds = TDSPro.new({MacroFolder = "TDSProMacros"})

tds:On("Notification", function(message)
    print(message.Title, message.Content)
end)

tds:On("StatusChanged", function(status)
    print(status)
end)

local ok, result = tds:Start()
if not ok then
    warn(result)
    tds:Destroy()
    return
end
```

The short form is:

```lua
local TDSPro = loadstring(game:HttpGet("https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/refs/heads/main/TDSPro.lua"))()
local tds = TDSPro.new()
tds:Start()
```

Keep the full form while developing a UI so download, compilation, and startup errors are visible:

```lua
local source = game:HttpGet("https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/refs/heads/main/TDSPro.lua")
local chunk, compileError = loadstring(source)
assert(chunk, compileError)

local TDSPro = chunk()
assert(type(TDSPro) == "table" and type(TDSPro.new) == "function", "Invalid TDS Pro library")

local tds = TDSPro.new()
local started, startError = tds:Start()
assert(started, startError)
```

Use GitHub's **Raw** link, not the normal repository page URL. Pin the URL to a release tag or commit instead of `main` if you do not want future library updates to change existing scripts.

## Runtime requirements

The core still depends on Roblox client services and the TDS game objects/remotes used by the original script. It is not a generic server-side Roblox package or a standalone Lua program.

- The executor must support `loadstring` and `game:HttpGet` to use the GitHub loader shown above.
- File-backed macros and statistics use the existing executor filesystem APIs, including `readfile`, `writefile`, `listfiles`, `isfile`, `isfolder`, and `makefolder`, as applicable to the operation.
- Recording requires executor remote-hook capabilities. A normal Roblox Studio LocalScript does not provide those APIs and cannot record with this implementation.
- Optional webhook delivery requires a supported executor HTTP request function. Gameplay actions require the matching live TDS client and remote protocol.

Installing the source as a ModuleScript does not grant an ordinary LocalScript these additional capabilities. Unsupported operations report errors; providing a UI does not remove the runtime requirements.

For local development, the same file can be evaluated with `loadstring(readfile("TDSPro.lua"))()`. It can also be placed in a ModuleScript and required, although executor-only features still need their corresponding APIs.

## Quick start

```lua
local TDSPro = loadstring(game:HttpGet("https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/refs/heads/main/TDSPro.lua"))()
local tds = TDSPro.new({MacroFolder = "TDSProMacros"})

local notificationConnection = tds:On("Notification", function(message)
    print(message.Title, message.Content)
end)
local statusConnection = tds:On("StatusChanged", function(status)
    print(status)
end)

local ok, result = tds:Start()
if not ok then
    warn(result)
    tds:Destroy()
    return
end
```

`TDSPro.new(options?)` returns an independent instance. `options` is a configuration table using the keys below; invalid constructor options raise an error. Configuration can also be applied with `Configure`, which returns `false, error` for invalid input. Use one active instance per gameplay session so multiple instances do not issue competing game actions.

Commands return `true` with optional result data, or `false, errorMessage`. Getters return data directly; table results and event payloads are copies. Changing a returned table does not update the library. `On` returns a connection with `Disconnect()`, or `nil, errorMessage` for invalid arguments or a destroyed instance.

`Start()` initializes event connections and background tracking. Recording, playback, and auto replay require separate calls. Settings such as `AutoSkip` or `SimplifyMapVisuals` take effect at `Start()` if configured beforehand, or immediately when enabled later. Some commands yield, including recording drain and inventory operations; invoke those from a UI callback/task that can yield. A successful `Play()` or `SetAutoReplay(true)` means the work started, not that the run completed. Observe events and `GetState()` for progress.

## Included default UI

Users who do not want to build a UI can load the included interface:

```lua
local base = "https://raw.githubusercontent.com/Madcowplayz/TDSProLibrary/refs/heads/main/"
local TDSPro = loadstring(game:HttpGet(base .. "TDSPro.lua"))()
local DefaultUI = loadstring(game:HttpGet(base .. "default-ui.lua"))()

local tds = TDSPro.new()
local ui, errorMessage = DefaultUI.mount(tds)
assert(ui, errorMessage)
```

`DefaultUI.mount` subscribes to the library, calls `Start()`, and returns a controller with `Destroy`, `SetVisible`, and `GetGui` methods. Closing the interface destroys the TDS Pro instance by default. Pass `{DestroyLibraryOnClose = false}` as the second argument if another part of the script owns the library lifecycle.

The default interface and the core library are separate files. Custom UI authors only need `TDSPro.lua`.

## Public API

All instance methods use colon syntax (`tds:Method(...)`). Optional arguments are marked `?`.

| Method | Result / behavior |
| --- | --- |
| `Start()` | Starts the runtime; returns `true, state`. Calling it again is safe. |
| `Destroy()` | Stops owned tasks, disconnects listeners, cancels automation, restores simplified visuals, and releases the instance. Safe to repeat; it cannot be restarted. |
| `On(eventName, callback)` | Subscribes to an event; returns a connection. Subscribe before `Start()`. |
| `GetState()` | Snapshot of lifecycle, recording/playback activity, macro selection, metadata, and pending-round reconciliation state. |
| `GetConfig()` | Snapshot of all configuration values. |
| `Configure(settings)` | Validates and applies a partial configuration; returns `true, config`. |
| `SaveSettings(path?)` | Writes configuration JSON; returns `true, path`. Default: `<MacroFolder>/settings.json`. |
| `LoadSettings(path?)` | Reads configuration JSON and calls `Configure`; returns `true, config`. Same default path. |
| `ListMacros()` | Returns `names, directoryError`; names are file-backed macros. A directory error may accompany an empty list. |
| `LoadMacro(name)` | Loads and selects a saved macro; returns `true, state`. |
| `SaveMacro(name?)` | Saves the current timeline; returns `true, path`. Uses the current macro name if omitted. |
| `ImportMacro(documentOrJSON, name?)` | Normalizes a macro document or JSON string into memory; returns `true, state`. Does not write a file. |
| `ExportMacro(asJSON?)` | Returns a copied `{Meta, Timeline}` document, or JSON if `true`; encoding failure returns `nil, error`. |
| `GetTimeline()` | Returns the timeline in playback sort order. |
| `SetEventTime(index, seconds)` | Edits the event at the current sorted timeline index; returns `true, event`. Refresh your timeline after editing because its order may change. |
| `GetRecordingLog()` | Returns the recent recording log array. |
| `GetTelemetry()` | Returns local playback diagnostics, including action results, retries, and economy/health samples. This getter does not send usage telemetry. |
| `GetGameInfo()` | Returns current detected map, mode, difficulty, and wave information. |
| `GetModifiers()` | Returns the supported modifier names. |
| `StartRecording(name?)` | Begins a new recording, replacing the in-memory timeline; returns `true, state`. Requires remote hooks. |
| `StopRecording()` | Stops accepting actions and drains pending confirmations (up to 10 seconds); returns `true, {Events, Drained, Unresolved, Dropped}`. Check `Drained` before treating the recording as complete. |
| `ClearRecording()` | Clears the in-memory timeline and log. If already recording, starts a fresh recording session. Does not delete files. |
| `Play()` | Starts the loaded/imported timeline once; returns `true, state`. |
| `Stop()` | Requests playback and auto replay to stop; returns `true, state`. Does not stop recording or configured auto skip. |
| `SetAutoReplay(enabled)` | Enables or disables the existing replay/matchmaking loop; returns `true, state`. Requires a replayable macro when enabling. |
| `AutoEquipInventory()` | Equips the selected macro's tower requirements; returns `success, message`. |
| `RestorePreviousLoadout()` | Restores the loadout saved by the last auto equip; returns `success, message`. |
| `GetStats()` | Returns saved totals with an additional `Rates` table. |
| `RefreshStats()` | Reloads saved stats and emits a refresh; returns `true, stats`. |
| `ResetStats()` | Resets accumulated statistics; returns `success, message`. Add any confirmation you need in your own UI. |
| `SkipWave()` | Sends a skip vote when applicable; returns `success, message`. |
| `SendTestWebhook()` | Sends sample match data to the configured webhook; returns `true` or `false, error`. |
| `ReconcilePendingRound(timeout?)` | Reconciles saved rewards/statistics; timeout defaults to 15 seconds and may be 0–120. |
| `StartMatchmaking(difficulty?, mode?)` | Starts matchmaking using explicit values or the loaded macro metadata. |
| `VoteModifiers()` | Votes for the modifiers selected through configuration. |
| `UseTimeScaleTicket()` | Unlocks/cycles the existing 2x time-scale ticket behavior. |

`LoadMacro`, `SaveMacro`, `ImportMacro`, and `SetEventTime` require an idle macro session. `Stop()` requests cancellation; wait until `Playing`, `PlaybackBusy`, `AutoReplay`, and `AutoReplayRunning` are false before replacing the macro. Stop recording separately and await its result before saving.

The state snapshot includes `Started`, `Destroyed`, `Status`, `Recording`, `RecordingStopping`, `Playing`, `PlaybackBusy`, `AutoReplay`, `AutoReplayRunning`, `AutoReplayRuns`, `InventoryBusy`, `MacroName`, `SelectedMacro`, `EventCount`, `Metadata`, `SourceFormat`, and `PendingRoundReconciled`.

## Configuration

Pass these keys directly to `TDSPro.new({...})` or `tds:Configure({...})`. Unknown keys and invalid values are rejected. Only the listed keys are public configuration; recording and auto replay are controlled through methods.

| Key | Default | Accepted value / purpose |
| --- | --- | --- |
| `MacroFolder` | `"TDSProMacros"` | Nonempty relative folder path without parent traversal. Set before `Start()`. |
| `AntiAFK` | `false` | Boolean; enables the existing idle handler. |
| `VIPOverride` | `false` | Boolean; enables VIP map override. |
| `MapReroll` | `false` | Boolean; enables the existing veto/new-match behavior. |
| `LoadingStallRecovery` | `true` | Boolean; enables recovery when the active automation detects stuck loading. |
| `LoadingStallTimeout` | `90` | Finite number of seconds, at least 30. |
| `TimeScale2x` | `false` | Boolean; allows the existing 2x ticket behavior during playback. |
| `EarlyEconomyActions` | `false` | Boolean; permits early placement/upgrade when affordable. |
| `ModifierVoting` | `false` | Boolean; enables voting for configured modifiers. |
| `Modifiers` | `{}` | Array of names, or a name-to-boolean table. Use `GetModifiers()` for valid names. |
| `AutoSkip` | `false` | Boolean; standalone auto-skip loop. |
| `SimplifyMapVisuals` | `false` | Boolean; simplifies effects/textures, restoring them when disabled or destroyed. |
| `Multiplayer` | `false` | Boolean; enables multiplayer workflow. |
| `IsHost` | `true` | Boolean; whether this client is party leader. |
| `PlayerCount` | `2` | Integer: 2, 3, or 4. |
| `HostDelay` | `5` | Finite number of seconds from 0 to 30. |
| `WebhookEnabled` | `false` | Boolean; enables configured webhook delivery. |
| `WebhookURL` | `""` | Empty string or Discord HTTPS webhook URL. |
| `WebhookLogoURL` | `""` | Empty string or HTTPS image URL. |
| `WebhookEvents` | All four enabled | Partial boolean map for `Disconnect`, `MatchResult`, `LoadingScreenBroke`, and `LoadingRejoinFailed`. |
| `WebhookRateLimit` | `2` | Nonnegative finite number of seconds between queued deliveries; the delivery worker has a 0.5-second minimum. |

`VIPOverride` and `MapReroll` are mutually exclusive. Enabling one disables the other; setting both to `true` in one update is rejected. `SaveSettings()` includes the configured webhook URL, so treat the saved file and `GetConfig()`/`ConfigChanged` payloads as private configuration rather than public logs. Settings are loaded only when you explicitly call `LoadSettings()`.

## Events

Use `tds:On(name, callback)`. Callbacks receive one copied payload and run when the event is emitted; keep them brief. Callback errors are reported without breaking the other subscribers. `connection:Disconnect()` removes one subscription; `Destroy()` disconnects all of them.

| Event | Payload |
| --- | --- |
| `Notification` | `{Title, Content, Duration, Image?}` for your own notification UI. |
| `StatusChanged` | Playback/status text string. |
| `StateChanged` | A state snapshot with the same shape as `GetState()`. |
| `ConfigChanged` | The updated configuration snapshot. |
| `RecordingChanged` | State snapshot after starting/stopping recording. |
| `RecordingLog` | Recent log array. |
| `TimelineChanged` | The sorted timeline array. |
| `TelemetryChanged` | Local run diagnostics after an action is completed. |
| `StatsChanged` | `{Totals = stats, Rates = rates}`. |
| `Error` | `{Message = string}` for an asynchronous runtime failure. |
| `Destroyed` | Final state snapshot, emitted before subscriptions are cleared. |

Get an initial snapshot from the matching getter when building a view. Events signal changes and do not automatically replay the last value to new subscribers.

## Bring your own UI

[`examples/custom-ui.lua`](examples/custom-ui.lua) is a small, caller-owned Roblox interface that loads the raw library from GitHub. Its buttons call the public API, its labels subscribe to events, and closing it destroys the library instance. It does not supply the executor capabilities described above.

You can use the same API with an existing UI framework: route a button callback into a command, route notifications and status events into your labels, and call `Destroy()` when the containing screen is removed.

## Migrating from the old script

- Replace execution-for-side-effects with a factory load and `TDSPro.new(...)`.
- Attach event listeners before `Start()` to receive initialization messages.
- Explicitly start recording, playback, auto replay, or other automation in response to your own controls.
- Replace the old Fluent controls, stats HUD, and advanced timeline window with your own UI and the public data getters.
- Apply library options through the public configuration API. UI framework themes, window state, and old Fluent configuration files are not library configuration.
- Keep the existing macro files; the library retains the original macro normalization and playback implementation.
- Destroy the instance when your interface closes. Create a new instance to start a fresh session after destruction.

## Verification scope

The repository includes mocked Luau checks in `tests/library.spec.luau` for the module contract and lifecycle. These checks do not verify the current live TDS remote protocol, executor hooks, inventory changes, matchmaking, or webhook delivery. Validate the features you expose in the intended client/runtime before distributing your integration.
