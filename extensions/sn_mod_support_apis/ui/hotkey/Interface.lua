Lua_Loader.define("extensions.sn_mod_support_apis.ui.hotkey.Interface", function(require)
    --[[
    Lua interface between Mod Director (MD) and the X4 Foundations Options Menu for custom hotkey management.
    Primary goal is to register, bind, and display custom hotkeys for actions defined by MD scripts,
    supporting keyboard, gamepad, and joystick inputs.

    Key Features:
    - Registers custom hotkey actions and binds them to inputs via the game's input API.
    - Integrates with the Options Menu to display hotkey bindings in a dedicated section.
    - Supports gamepad and joystick inputs alongside keyboard, using native input APIs.
    - Provides event-driven communication with MD for action updates and input remapping.
    - Includes robust error handling and debug logging for production reliability.

    Integration Notes:
    - Hooks into `gameoptions.lua` by overriding `displayControls`, `remapInput`, and input registration functions.
    - Uses NPC blackboard (`sn_hotkey_api`) to store and retrieve hotkey bindings.
    - Compatible with X4 Foundations versions 6.0 and 7.0+, including the 7.6 hotkey UI overhaul.
    - Suppresses direct text input to prevent conflicts with hotkey execution during typing.
    - Supports dynamic menu patching to handle menu open/close events and periodic checks.

    Usage:
    - MD scripts register actions via the `Hotkey.Update_Actions` event.
    - Players bind hotkeys in the Options Menu, which are saved to the blackboard and signaled to MD.
    - Debug logs (controlled by `isDebug`) aid troubleshooting during development.

    Limitations:
    - Requires gamepad/joystick events (`gamepadInput`, `joystickInput`) to be supported by the game's input API.
    - Assumes compatibility with `gameoptions.lua` input APIs; may need updates if new APIs are introduced.
    ]]

    local isDebug = true -- Set to false for production to reduce logging overhead
    
    -- FFI setup for native input functions
    local ffi = require("ffi")
    local C = ffi.C
    ffi.cdef [[
        typedef uint64_t UniverseID;
        UniverseID GetPlayerID(void);
        void DisableAutoMouseEmulation(void);
        void EnableAutoMouseEmulation(void);
        const char* GetInputName(int inputtype, int inputindex);
        void SetCustomControlAction(UniverseID controllableid, const char* actionid, int inputtype, int inputindex, int slot);
        void ClearCustomControlAction(UniverseID controllableid, const char* actionid, int inputtype, int inputindex, int slot);
    ]]

    -- Imports from mod support APIs
    local Lib = require("extensions.sn_mod_support_apis.ui.Library")
    local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")
    local T = require("extensions.sn_mod_support_apis.ui.Text")
    local Tables = require("extensions.sn_mod_support_apis.ui.simple_menu.Tables")
    local config = Tables.config

    --- @table L
    --- @field action_registry table<string, table> Registry of hotkey actions with their names and metadata
    --- @field player_action_keys table<string, table> Cached player key bindings
    --- @field input_event_handlers table<string, function> Handlers for input events (keyboard, gamepad, joystick)
    --- @field pipe_connected boolean Status of MD pipe connection
    --- @field direct_input_suppress_time number Duration (seconds) to suppress hotkeys after text input
    --- @field alarm_id string Identifier for direct input suppression timer
    --- @field alarm_pending boolean Tracks if suppression timer is active
    --- @field scene any UI scene element
    --- @field contract any UI contract element
    --- @field player_id UniverseID Player's unique ID
    local L = {
        action_registry = {},
        player_action_keys = {},
        input_event_handlers = {
            ["keyboardInput"] = function(_, keycode) L.remapInput(1, keycode, 0) end,
            ["gamepadInput"] = function(_, buttonid) L.remapInput(2, buttonid, 0) end,
            ["joystickInput"] = function(_, buttonid) L.remapInput(3, buttonid, 0) end,
        },
        pipe_connected = false,
        direct_input_suppress_time = 0.5,
        alarm_id = "hotkey_directinput_timeout",
        alarm_pending = false
    }
    local menu = nil

    --- Raises a signal to the Mod Director (MD) via UI events.
    --- @param name string Signal name (e.g., "Input_Remapped", "Menu_Opened")
    --- @param value any Signal value to pass
    function L.Raise_Signal(name, value)
        if isDebug then
            DebugError("[Hotkey.Interface] Raise_Signal: " .. tostring(name) .. " with value: " .. tostring(value))
        end
        -- Debug: Log signal emission
        AddUITriggeredEvent("Hotkey", name, value)
    end

    --- Initializes the hotkey interface, setting up event listeners and menu hooks.
    function L.Init()
        if isDebug then DebugError("[Hotkey.Interface] Init: Starting initialization") end
        -- Debug: Log initialization start
        L.scene = getElement("Scene")
        L.contract = getElement("UIContract", L.scene)
        if not L.scene or not L.contract then
            DebugError("[Hotkey.Interface] Init: Failed to get Scene or UIContract")
            return
        end
        registerForEvent("directtextinput", L.contract, L.onEvent_directtextinput)
        RegisterEvent("Hotkey.Update_Actions", L.Update_Actions)
        RegisterEvent("Hotkey.Update_Player_Keys", L.Read_Player_Keys)
        RegisterEvent("Hotkey.Update_Connection_Status", L.Update_Connection_Status)
        RegisterEvent("Hotkey.Process_Message", L.Process_Message)
        L.player_id = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
        if not L.player_id then
            DebugError("[Hotkey.Interface] Init: Failed to get player ID")
            return
        end
        L.Raise_Signal("reloaded")
        L.Init_Menu()
        -- Debug: Log initialization complete
        if isDebug then DebugError("[Hotkey.Interface] Init: Initialization complete") end
    end

    --- Handles direct text input events to suppress hotkeys during text entry.
    --- @param some_userdata any UI event userdata
    --- @param char_entered string Character entered by the user
    function L.onEvent_directtextinput(some_userdata, char_entered)
        if isDebug then DebugError("[Hotkey.Interface] onEvent_directtextinput: Caught char: " .. tostring(char_entered)) end
        -- Debug: Log direct text input event
        if not L.alarm_pending then
            L.Raise_Signal("disable")
            L.alarm_pending = true
            if isDebug then DebugError("[Hotkey.Interface] onEvent_directtextinput: Hotkeys disabled") end
            -- Debug: Log hotkey suppression
        end
        Time.Set_Alarm(L.alarm_id, L.direct_input_suppress_time, L.Reenable_Hotkeys)
    end

    --- Reenables hotkeys after direct input suppression timeout.
    function L.Reenable_Hotkeys()
        if isDebug then DebugError("[Hotkey.Interface] Reenable_Hotkeys: Reenabling hotkeys") end
        -- Debug: Log hotkey reenable
        L.Raise_Signal("enable")
        L.alarm_pending = false
    end

    --- Updates the action registry with new hotkey actions from MD.
    --- @param _ any Unused event parameter
    --- @param action_list table List of actions to register
    function L.Update_Actions(_, action_list)
        if isDebug then DebugError("[Hotkey.Interface] Update_Actions: Updating action registry") end
        -- Debug: Log action registry update
        L.action_registry = {}
        for _, action in ipairs(action_list or {}) do
            if action.id and action.name then
                L.action_registry[action.id] = action
            end
        end
        if menu then
            menu.displayControls()
        end
        -- Debug: Log action registry update complete
        if isDebug then DebugError("[Hotkey.Interface] Update_Actions: Action registry updated with " .. tostring(#action_list) .. " actions") end
    end

    --- Reads player key bindings from the blackboard.
    --- @param _ any Unused event parameter
    --- @param action_list table List of actions to read bindings for
    function L.Read_Player_Keys(_, action_list)
        if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: Reading player key bindings") end
        -- Debug: Log key binding read
        local blackboard = GetNPCBlackboard(L.player_id, "sn_hotkey_api") or {}
        L.player_action_keys = {}
        for _, actionid in ipairs(action_list or {}) do
            if blackboard[actionid] then
                L.player_action_keys[actionid] = blackboard[actionid]
            end
        end
        if menu and menu.optionTable then
            menu.displayControls()
            -- Debug: Log key binding read complete
            if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: Read bindings for " .. tostring(#action_list) .. " actions") end
        else
            DebugError("[Hotkey.Interface] Skipping displayControls: menu or optionTable not ready")
        end
    end

    --- Updates the MD pipe connection status.
    --- @param _ any Unused event parameter
    --- @param connected boolean New connection status
    function L.Update_Connection_Status(_, connected)
        if isDebug then DebugError("[Hotkey.Interface] Update_Connection_Status: Pipe connected = " .. tostring(connected)) end
        -- Debug: Log connection status update
        L.pipe_connected = connected
    end

    --- Processes messages from the MD script.
    --- @param _ any Unused event parameter
    --- @param message table Message data
    function L.Process_Message(_, message)
        if isDebug then DebugError("[Hotkey.Interface] Process_Message: Processing message") end
        -- Debug: Log message processing
        -- Implement message handling as needed
    end

    --- Remaps an input for a custom hotkey action.
    --- @param inputtype number Input type (1=keyboard, 2=gamepad, 3=joystick)
    --- @param inputindex number Input index (e.g., keycode, button ID)
    --- @param modifier number Modifier key (0 for none)
    function L.remapInput(inputtype, inputindex, modifier)
        if isDebug then
            DebugError("[Hotkey.Interface] remapInput: inputtype=" .. inputtype .. ", inputindex=" .. inputindex .. ", modifier=" .. modifier)
        end
        -- Debug: Log input remapping attempt
        if menu.remapControl and menu.remapControl.controlcontext == "hotkey_api" then
            local actionid = menu.remapControl.actionid
            local slot = menu.remapControl.slot or 1
            if L.action_registry[actionid] then
                local inputname = C.GetInputName(inputtype, inputindex)
                if inputname then
                    local blackboard = GetNPCBlackboard(L.player_id, "sn_hotkey_api")
                    if not blackboard then
                        blackboard = {}
                        SetNPCBlackboard(L.player_id, "sn_hotkey_api", blackboard)
                        -- Debug: Log blackboard initialization
                        if isDebug then DebugError("[Hotkey.Interface] remapInput: Initialized blackboard") end
                    end
                    blackboard[actionid] = blackboard[actionid] or {}
                    blackboard[actionid][slot] = { inputtype = inputtype, inputindex = inputindex, modifier = modifier }
                    C.SetCustomControlAction(L.player_id, actionid, inputtype, inputindex, slot)
                    L.Raise_Signal("Input_Remapped", actionid)
                    -- Debug: Log successful input binding
                    if isDebug then
                        DebugError("[Hotkey.Interface] remapInput: Bound action " .. actionid .. " to inputtype=" .. inputtype .. ", inputindex=" .. inputindex .. ", slot=" .. slot)
                    end
                else
                    DebugError("[Hotkey.Interface] remapInput: Invalid input for type=" .. inputtype .. ", index=" .. inputindex)
                    return
                end
            else
                DebugError("[Hotkey.Interface] remapInput: Invalid actionid " .. tostring(actionid))
                return
            end
            menu.remapControl = nil
            menu.registerDirectInput()
            menu.displayControls()
        end
        -- Debug: Log input remapping complete
        if isDebug then DebugError("[Hotkey.Interface] remapInput: Remapping complete") end
    end

    --- Displays custom hotkey rows in the Options Menu.
    --- Ensures the original gameoptions.lua displayControls is called to initialize menu.optionsTable,
    --- then appends custom hotkey rows for actions in the action registry.
    --- @param preselectOption any Option to preselect in the menu
    --- @param ... any Additional arguments from original displayControls
    function L.displayControls(preselectOption, ...)
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Adding custom hotkey rows") end
        -- Debug: Log display controls start

        -- Call the original displayControls to ensure menu.optionsTable is initialized
        if L.ego_displayControls then
            local success, error = pcall(L.ego_displayControls, preselectOption, ...)
            if not success then
                DebugError("[Hotkey.Interface] displayControls: Original displayControls failed: " .. tostring(error))
            end
        else
            DebugError("[Hotkey.Interface] displayControls: ego_displayControls not available")
        end

        -- Verify menu and optionsTable exist
        if not menu or not menu.optionsTable then
            DebugError("[Hotkey.Interface] displayControls: No menu or optionsTable found")
            return
        end
        local table = menu.optionsTable

        -- Find or create the keyboard_space section
        local keyboard_space = nil
        for _, section in ipairs(table) do
            if section[1] == "keyboard_space" then
                keyboard_space = section
                break
            end
        end
        if not keyboard_space then
            keyboard_space = { "keyboard_space", {} }
            table[#table + 1] = keyboard_space
            -- Debug: Log new keyboard_space section
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Created new keyboard_space section") end
        end

        -- Add custom hotkey rows
        for actionid, action in pairs(L.action_registry or {}) do
            local blackboard = GetNPCBlackboard(L.player_id, "sn_hotkey_api") or {}
            local bindings = blackboard[actionid] or {}
            local primary = bindings[1] or { inputtype = 1, inputindex = 0, modifier = 0 }
            local secondary = bindings[2] or { inputtype = 1, inputindex = 0, modifier = 0 }

            local primary_name = primary.inputindex > 0 and (C.GetInputName(primary.inputtype, primary.inputindex) or "") or ""
            local secondary_name = secondary.inputindex > 0 and (C.GetInputName(secondary.inputtype, secondary.inputindex) or "") or ""

            keyboard_space[2][#keyboard_space[2] + 1] = {
                { arrow = true },
                { action.name or actionid, fontsize = Helper.standardFontSize },
                { "", onClick = function() menu.buttonControl(actionid, 1) end, displayValue = primary_name },
                { "", onClick = function() menu.buttonControl(actionid, 2) end, displayValue = secondary_name }
            }
            -- Debug: Log added hotkey row
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Added row for action " .. tostring(actionid)) end
        end
    end

    --- Registers input event handlers for hotkey remapping.
    --- @param ego_registerDirectInput function Original registerDirectInput function
    function L.registerDirectInput(ego_registerDirectInput)
        if menu.remapControl and menu.remapControl.controlcontext == "hotkey_api" then
            C.DisableAutoMouseEmulation()
            for event, func in pairs(L.input_event_handlers) do
                RegisterEvent(event, func)
                -- Debug: Log event registration
                if isDebug then DebugError("[Hotkey.Interface] registerDirectInput: Registered event: " .. tostring(event)) end
            end
            ListenForInput(true)
            -- Debug: Log input listening start
            if isDebug then DebugError("[Hotkey.Interface] registerDirectInput: Listening for all input types") end
        else
            ego_registerDirectInput()
        end
    end

    --- Unregisters input event handlers after remapping.
    --- @param ego_unregisterDirectInput function Original unregisterDirectInput function
    function L.unregisterDirectInput(ego_unregisterDirectInput)
        if menu.remapControl and menu.remapControl.controlcontext == "hotkey_api" then
            ListenForInput(false)
            for event, func in pairs(L.input_event_handlers) do
                UnregisterEvent(event, func)
                -- Debug: Log event unregistration
                if isDebug then DebugError("[Hotkey.Interface] unregisterDirectInput: Unregistered event: " .. tostring(event)) end
            end
            C.EnableAutoMouseEmulation()
            -- Debug: Log input listening stop
            if isDebug then DebugError("[Hotkey.Interface] unregisterDirectInput: Stopped listening") end
        else
            ego_unregisterDirectInput()
        end
    end

    --- Initializes menu hooks for Options Menu integration.
    function L.Init_Menu()
        if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Starting menu initialization") end
        -- Debug: Log menu initialization start
        menu = Lib.Get_Egosoft_Menu("OptionsMenu")
        if not menu then
            DebugError("[Hotkey.Interface] Init_Menu: Failed to get OptionsMenu")
            return
        end
        local ego_displayControls = menu.displayControls
        menu.displayControls = function(...)
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Called with args: " .. tostring(select("#", ...))) end
            -- Debug: Log displayControls hook
            local ego_createOptionsFrame = menu.createOptionsFrame
            local frame, frame_display
            menu.createOptionsFrame = function(...)
                frame = ego_createOptionsFrame(...)
                if frame.display then
                    frame_display = frame.display
                    frame.display = function() return end
                    -- Debug: Log frame display suppression
                    if isDebug then DebugError("[Hotkey.Interface] createOptionsFrame: Suppressed frame display") end
                end
                return frame
            end
            local preselectOption = menu.preselectOption
            ego_displayControls(...)
            menu.createOptionsFrame = ego_createOptionsFrame
            local success, error = pcall(L.displayControls, preselectOption, ...)
            if not success then
                DebugError("[Hotkey.Interface] displayControls error: " .. tostring(error))
            end
            if frame_display then
                frame.display = frame_display
                frame:display()
                -- Debug: Log frame display restoration
                if isDebug then DebugError("[Hotkey.Interface] displayControls: Restored and called frame display") end
            elseif frame.display then
                frame:display()
            end
        end

        local ego_remapInput = menu.remapInput
        menu.remapInput = function(...)
            if menu.remapControl.controlcontext ~= "hotkey_api" then
                ego_remapInput(...)
                return
            end
            local success, error = pcall(L.remapInput, ...)
            if not success then
                DebugError("[Hotkey.Interface] remapInput error: " .. tostring(error))
            end
        end

        local ego_registerDirectInput = menu.registerDirectInput
        menu.registerDirectInput = function() L.registerDirectInput(ego_registerDirectInput) end
        local ego_unregisterDirectInput = menu.unregisterDirectInput
        menu.unregisterDirectInput = function() L.unregisterDirectInput(ego_unregisterDirectInput) end

        local ego_helper_clearMenu = Helper.clearMenu
        Helper.clearMenu = function(m, ...) ego_helper_clearMenu(m, ...) L.Menu_Closed(m) end
        for _, m in ipairs(Menus) do
            local ego_show = m.showMenuCallback
            m.showMenuCallback = function(...) ego_show(...) L.Menu_Opened(m) end
            UnregisterEvent("show" .. m.name, ego_show)
            RegisterEvent("show" .. m.name, m.showMenuCallback)
            -- Debug: Log menu show event registration
            if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Registered show event for menu " .. m.name) end
        end
        local ego_registerMenu = Helper.registerMenu
        Helper.registerMenu = function(m, ...)
            ego_registerMenu(m, ...)
            local ego_show = m.showMenuCallback
            m.showMenuCallback = function(...) ego_show(...) L.Menu_Opened(m) end
            UnregisterEvent("show" .. m.name, ego_show)
            RegisterEvent("show" .. m.name, m.showMenuCallback)
            -- Debug: Log new menu registration
            if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Registered new menu " .. m.name) end
        end
        local ego_minimizeMenu = Helper.minimizeMenu
        Helper.minimizeMenu = function(m, ...) ego_minimizeMenu(m, ...) L.Menu_Minimized(m) end
        local ego_restoreMenu = Helper.restoreMenu
        Helper.restoreMenu = function(m, ...) ego_restoreMenu(m, ...) L.Menu_Restored(m) end

        AddUITriggeredEvent("Hotkey", "periodic_menu_check", nil)
        RegisterEvent("Hotkey.periodic_menu_check", function()
            L.Periodic_Menu_Check()
            Helper.setTimeout(5, function() AddUITriggeredEvent("Hotkey", "periodic_menu_check", nil) end)
        end)
        -- Debug: Log periodic menu check registration
        if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Started periodic menu check") end
    end

    --- Periodically checks menu states to handle missed events.
    function L.Periodic_Menu_Check()
        if isDebug then DebugError("[Hotkey.Interface] Periodic_Menu_Check: Checking menu states") end
        -- Debug: Log periodic menu check
        local any_menu_open = false
        for _, m in ipairs(Menus) do
            if m.shown and not m.minimized then
                any_menu_open = true
                break
            end
        end
        if any_menu_open then
            L.Raise_Signal("Menu_Opened", "generic")
        else
            L.Raise_Signal("Menu_Closed", "generic")
        end
        AddUITriggeredEvent("Hotkey", "periodic_menu_check", nil)
        -- Debug: Log menu state check result
        if isDebug then DebugError("[Hotkey.Interface] Periodic_Menu_Check: Menu open = " .. tostring(any_menu_open)) end
    end

    --- Handles menu open events.
    --- @param menu table Menu object that was opened
    function L.Menu_Opened(menu)
        if isDebug then DebugError("[Hotkey.Interface] Menu_Opened: Menu " .. tostring(menu.name) .. " opened") end
        -- Debug: Log menu open
        L.Raise_Signal("Menu_Opened", menu.name)
    end

    --- Handles menu close events.
    --- @param menu table Menu object that was closed
    function L.Menu_Closed(menu)
        if isDebug then DebugError("[Hotkey.Interface] Menu_Closed: Menu " .. tostring(menu.name) .. " closed") end
        -- Debug: Log menu close
        L.Raise_Signal("Menu_Closed", menu.name)
    end

    --- Handles menu minimize events.
    --- @param menu table Menu object that was minimized
    function L.Menu_Minimized(menu)
        if isDebug then DebugError("[Hotkey.Interface] Menu_Minimized: Menu " .. tostring(menu.name) .. " minimized") end
        -- Debug: Log menu minimize
        L.Raise_Signal("Menu_Minimized", menu.name)
    end

    --- Handles menu restore events.
    --- @param menu table Menu object that was restored
    function L.Menu_Restored(menu)
        if isDebug then DebugError("[Hotkey.Interface] Menu_Restored: Menu " .. tostring(menu.name) .. " restored") end
        -- Debug: Log menu restore
        L.Raise_Signal("Menu_Restored", menu.name)
    end

    return nil, L.Init
end)