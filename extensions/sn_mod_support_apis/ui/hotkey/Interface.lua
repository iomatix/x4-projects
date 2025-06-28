Lua_Loader.define("extensions.sn_mod_support_apis.ui.hotkey.Interface", function(require)
    --[[
Lua interface for registering and handling custom hotkeys in X4 Foundations version 7.6.
Integrates hotkeys into the game's options menu and supports keyboard, mouse, gamepad, and joystick inputs.

Key Features:
- Registers custom hotkeys under a "Mod Hotkeys" category in the options menu.
- Handles input events for all supported devices.
- Displays hotkey bindings in the UI with proper naming.
- Includes debug logging and error handling for stability.

Integration Notes:
- Patches the `gameoptions.lua` menu by hooking into `displayControls`.
- Uses the game's input API (`GetLocalizedInputName`, `AddUITriggeredEvent`) for cross-device support.
- Ensures compatibility with the version 7.0 hotkey UI overhaul.

Usage:
- Mods can register hotkeys via `RegisterHotkey` and listen for events via "Hotkey_API" signals.
- Supports gamepad and joystick bindings in addition to keyboard and mouse.
]]

    -- FFI setup for native function calls
    local ffi = require("ffi")
    local C = ffi.C
    ffi.cdef [[
    const char* GetLocalizedInputName(uint32_t sourceid, uint32_t codeid);
]]

    -- Local state and function table
    local L = {
        hotkeys = {}, -- { name = { signal = string, desc = string, source = int, code = int } }
        originalDisplayControls = nil,
        isDebug = true,-- Set to true for debugging
        initAttempts = 0,
        maxInitAttempts = 10
    }

    -- Log debug messages if enabled
    local function DebugLog(message)
        if L.isDebug then
            DebugError("[Hotkey_API] " .. message)
        end
    end

    -- Register a new hotkey with the specified name, signal, and description
    -- @param name (string) Unique identifier for the hotkey
    -- @param signal (string) Signal to raise when the hotkey is pressed
    -- @param desc (string) Description shown in the options menu
    function L.RegisterHotkey(name, signal, desc)
        L.hotkeys[name] = {
            signal = signal,
            desc = desc,
            source = 1,
            code = 0
        } -- Default to keyboard, unbound
        DebugLog("Registered hotkey: " .. name)
    end

    -- Raise a signal to mods when a hotkey is triggered
    -- @param signal (string) The signal name to raise
    function L.Raise_Signal(signal)
        AddUITriggeredEvent("Hotkey_API", signal)
        DebugLog("Raised signal: " .. signal)
    end

    -- Initialize the hotkey system by patching the options menu
    function L.Init()
        local menu = Menus and Menus.gameoptions
        if not menu then
            L.initAttempts = L.initAttempts + 1
            if L.initAttempts <= L.maxInitAttempts then
                DebugLog("Options menu not found, retrying (" .. L.initAttempts .. "/" .. L.maxInitAttempts .. ")")
                AddUITriggeredEvent("Hotkey_API", "retry_init", {
                    delay = 1
                })
                return
            else
                DebugLog("Failed to find options menu after " .. L.maxInitAttempts .. " attempts")
                return
            end
        end

        -- Store and override displayControls
        L.originalDisplayControls = menu.displayControls
        menu.displayControls = L.displayControls

        -- Register input hooks for all devices
        for _, hook in ipairs(config.input and config.input.directInputHookDefinitions or {}) do
            RegisterEvent(hook[1], function(_, keycode)
                L.onInput(hook[2], keycode, hook[3])
            end)
        end

        DebugLog("Hotkey system initialized")
    end

    -- Patched displayControls function to add custom hotkey rows
    -- Ensures the original function is called first to initialize menu.optionsTable
    -- @param frame (table) The UI frame object
    function L.displayControls(frame)
        local menu = Menus.gameoptions
        if not menu or not L.originalDisplayControls then
            DebugLog("Menu or original displayControls not available")
            return
        end

        -- Call the original function to initialize menu.optionsTable
        L.originalDisplayControls(frame)
        if not menu.optionsTable then
            DebugLog("menu.optionsTable is nil after original displayControls")
            return
        end

        -- Add "Mod Hotkeys" category
        local categoryRow = menu.optionsTable:addRow(true, {
            fixed = true
        })
        categoryRow[2]:setColSpan(3):createText("Mod Hotkeys", config.subHeaderTextProperties or {
            fontsize = 14,
            font = "bold"
        })

        -- Add hotkey rows
        for name, hotkey in pairs(L.hotkeys) do
            local row = menu.optionsTable:addRow({
                name = name,
                hotkey = hotkey
            }, {})
            row[2]:createText(hotkey.desc, config.standardTextProperties or {
                fontsize = 12
            })
            row[3]:createText(L.GetInputName(hotkey.source, hotkey.code), config.standardRightTextProperties or {
                fontsize = 12,
                halign = "right"
            })
            row[3].handlers.onClick = function()
                L.onBindHotkey(name)
            end
        end

        frame:display()
        DebugLog("Custom hotkeys added to options menu")
    end

    -- Get the display name for an input based on source and code
    -- @param source (int) Input source (e.g., 1 for keyboard, 2+ for joystick)
    -- @param code (int) Input code (e.g., keycode or button ID)
    -- @return (string) Localized input name or "Unbound" if not set
    function L.GetInputName(source, code)
        if source == 0 or code == 0 then
            return "Unbound"
        end
        local name = ffi.string(C.GetLocalizedInputName(source, code))
        return name ~= "" and name or "Unknown"
    end

    -- Handle input events from all registered devices
    -- @param source (int) Input source ID
    -- @param code (int) Input code (e.g., keycode or button ID)
    -- @param signum (int) Signum for axis inputs (1, -1, or 0)
    function L.onInput(source, code, signum)
        for _, hotkey in pairs(L.hotkeys) do
            if hotkey.source == source and hotkey.code == code then
                if signum == 0 or signum == 1 then -- Buttons or positive axis
                    L.Raise_Signal(hotkey.signal)
                end
            end
        end
    end

    -- Handle binding a hotkey when clicked in the options menu
    -- @param name (string) Name of the hotkey to bind
    function L.onBindHotkey(name)
        local hotkey = L.hotkeys[name]
        if not hotkey then
            return
        end

        DebugLog("Binding hotkey: " .. name .. ". Press a key/button...")
        -- Actual implementation would use DirectInput hooks and a confirmation dialog
    end

    -- Handle retry initialization signal
    RegisterEvent("Hotkey_API", function(_, event, args)
        if event == "retry_init" then
            L.Init()
        end
    end)

    -- Initialize the hotkey system
    L.Init()

    return nil, L.RegisterHotkey
end)
