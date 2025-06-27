Lua_Loader.define("extensions.sn_mod_support_apis.ui.hotkey.Interface",function(require)
--[[
Lua side of the hotkey api.
This primarily aims to interface tightly with the egosoft menu system,
to leverage existing code for allowing players to customize hotkeys.

Patches the OptionsMenu.

Notes on edit boxes:
    The external hotkey detection has no implicit knowledge of the in-game
    context of the keys.
    Contexts are resolved partially below and in md by detecting if the
    player is flying, on foot, or in a menu (and which menu).
    However, complexity arises when the player is trying to type into
    an edit box (or similar), where hotkeys should be suppressed.
    Edit box activation and deactivation callbacks can be difficult to
    get at, notably the chat window that is present in a flying context.

    As a possible workaround, registerForEvent can be used on the ui to
    catch directtextinput events, which fire once per key press for an
    edit box. This can potentially be used to suppress key events.

    Functionality: on direct input key, set an alarm for some time in the
    future.  Immediately signal the md to suppress keys. After the alarm
    goes off, signal md to reenable keys. If more direct inputs come in
    during this period, have them just reset the alarm time.
    The alarm should be long enough to cover the latency from the external
    python code through the pipe to the game. That is not well measured,
    but some generous delay should handle the large majority of cases,
    unless there was some odd hiccup on key processing.

TODO: split apart md interface stuff from the menu plugin stuff,
to reduce file sizes.
]]

local isDebug = false -- Set to true for debug messages, false for production

-- Set up any used ffi functions.
local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    UniverseID GetPlayerID(void);
]]
-- Unused functions for now.
--[[
    void ActivateDirectInput(void);
    uint32_t GetMouseHUDModeOption(void);
    void DisableAutoMouseEmulation(void);
    void EnableAutoMouseEmulation(void);
]]

-- Imports.
local Lib = require("extensions.sn_mod_support_apis.ui.Library")
local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")
local T = require("extensions.sn_mod_support_apis.ui.Text")
-- Reuse the config table from simple menu api.
local Tables = require("extensions.sn_mod_support_apis.ui.simple_menu.Tables")
local config = Tables.config

-- Local functions and data.
local debug = {
    print_keycodes = false,
    print_keynames = false,
}
local L = {
    -- Shadow copy of the md's action registry.
    action_registry = {},

    -- Table of assigned keys and their actions, keyed by id.
    -- This is mirrored in a player blackboard var whenever it changes.
    player_action_keys = {},

    -- Wrapper functions on remapInput to be used in registering for input events.
    input_event_handlers = {},

    -- Status of the pipe connection, updated from md.
    pipe_connected = false,

    -- How long to wait after a direct input before reenabling hotkeys.
    direct_input_suppress_time = 0.5,
    -- Id to use for the alarm.
    alarm_id = "hotkey_directinput_timeout",
    -- If input currently disabled. Used to suppress some excess signals.
    alarm_pending = false,
}

-- Proxy for the gameoptions menu, linked further below.
local menu = nil

-- Signalling results from lua to md.
-- Takes the row,col of the activated widget, and an optional new value
-- for that widget.
-- TODO: think about this more.
local function Raise_Signal(name, value)
    if isDebug then DebugError("[Hotkey.Interface] Raise_Signal: Signalling " .. tostring(name) .. " with value: " .. tostring(value)) end -- Debug: Log signal trigger
    AddUITriggeredEvent("Hotkey", name, value)
end

local function Init()
    if isDebug then DebugError("[Hotkey.Interface] Init: Starting initialization") end -- Debug: Log initialization start
    -- Set up ui linkage to listen for text entry state changes.
    -- (Goal is to suppress hotkeys when entering text.)
    L.scene = getElement("Scene")
    L.contract = getElement("UIContract", L.scene)
    registerForEvent("directtextinput", L.contract, L.onEvent_directtextinput)
    if isDebug then DebugError("[Hotkey.Interface] Init: Registered directtextinput event") end -- Debug: Log directtextinput registration

    -- MD triggered events.
    RegisterEvent("Hotkey.Update_Actions", L.Update_Actions)
    if isDebug then DebugError("[Hotkey.Interface] Init: Registered Hotkey.Update_Actions event") end -- Debug: Log Update_Actions registration
    RegisterEvent("Hotkey.Update_Player_Keys", L.Read_Player_Keys)
    if isDebug then DebugError("[Hotkey.Interface] Init: Registered Hotkey.Update_Player_Keys event") end -- Debug: Log Update_Player_Keys registration
    RegisterEvent("Hotkey.Update_Connection_Status", L.Update_Connection_Status)
    if isDebug then DebugError("[Hotkey.Interface] Init: Registered Hotkey.Update_Connection_Status event") end -- Debug: Log Update_Connection_Status registration
    RegisterEvent("Hotkey.Process_Message", L.Process_Message)
    if isDebug then DebugError("[Hotkey.Interface] Init: Registered Hotkey.Process_Message event") end -- Debug: Log Process_Message registration
    
    -- Cache the player component id.
    L.player_id = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    if isDebug then DebugError("[Hotkey.Interface] Init: Cached player ID: " .. tostring(L.player_id)) end -- Debug: Log player ID caching
    
    -- Signal to md that a reload event occurred.
    -- This will also trigger md to send over its stored list of
    -- player assigned keys.
    Raise_Signal("reloaded")
    if isDebug then DebugError("[Hotkey.Interface] Init: Signalled reloaded") end -- Debug: Log reloaded signal

    -- Run the menu init stuff.
    -- Disabled as of 7.0; TODO: needs an overhaul since the hotkey ui has
    -- drastically changed. (Explicit md defined hotkeys should still work.)
    --L.Init_Menu()
    if isDebug then DebugError("[Hotkey.Interface] Init: Skipped Init_Menu (disabled)") end -- Debug: Log Init_Menu skip
end

-------------------------------------------------------------------------------
-- Handle direct input detection.

-- Handler for direct input key presses.
-- Fires once for each key.
function L.onEvent_directtextinput(some_userdata, char_entered)
    if isDebug then DebugError("[Hotkey.Interface] onEvent_directtextinput: Caught directtextinput, char: " .. tostring(char_entered)) end -- Debug: Log directtextinput event
    -- Note: to get number of vargs, use: select("#",...)
    -- This appears to receive 3 args according to the "...", but when trying
    -- to capture them only get 2 args.
    -- First arg is some userdata object, second is the key pressed (not
    -- as a keycode).

    --if isDebug then DebugError("Caught directtextinput event; starting disable")

    -- Signal md to suppress hotkeys, if not already disabled.
    if not L.alarm_pending then
        Raise_Signal("disable")
        L.alarm_pending = true
        if isDebug then DebugError("[Hotkey.Interface] onEvent_directtextinput: Signalled disable, set alarm_pending to true") end -- Debug: Log disable signal and alarm state
    end

    -- Start or reset the timer.
    Time.Set_Alarm(L.alarm_id, L.direct_input_suppress_time, L.Reenable_Hotkeys)
    if isDebug then DebugError("[Hotkey.Interface] onEvent_directtextinput: Set alarm " .. tostring(L.alarm_id) .. " for " .. tostring(L.direct_input_suppress_time) .. " seconds") end -- Debug: Log alarm setting
end

function L.Reenable_Hotkeys()
    --if isDebug then DebugError("directtextinput event timed out; ending disable")
    if isDebug then DebugError("[Hotkey.Interface] Reenable_Hotkeys: Alarm timed out, reenabling hotkeys") end -- Debug: Log hotkey reenable
    Raise_Signal("enable")
    L.alarm_pending = false
    if isDebug then DebugError("[Hotkey.Interface] Reenable_Hotkeys: Signalled enable, set alarm_pending to false") end -- Debug: Log enable signal and alarm state
end

-------------------------------------------------------------------------------
-- MD -> Lua signal handlers

-- Process a pipe message, a series of matched hotkey event names
-- semicolon separated.
function L.Process_Message(_, message)
    if isDebug then DebugError("[Hotkey.Interface] Process_Message: Processing message: " .. tostring(message)) end -- Debug: Log message processing
    -- Split it.
    local events = Lib.Split_String_Multi(message, ";")
    if isDebug then DebugError("[Hotkey.Interface] Process_Message: Split message into " .. tostring(#events) .. " events") end -- Debug: Log event splitting
    -- Add '$' prefixes and return.
    for i, event in ipairs(events) do
        events[i] = "$"..event
        if isDebug then DebugError("[Hotkey.Interface] Process_Message: Prefixed event " .. tostring(i) .. ": " .. tostring(events[i])) end -- Debug: Log event prefixing
    end
    -- Send back.
    Raise_Signal("handle_events", events)
    if isDebug then DebugError("[Hotkey.Interface] Process_Message: Signalled handle_events with " .. tostring(#events) .. " events") end -- Debug: Log handle_events signal
end

-- Handle md pipe connection status update. Param is 0 or 1.
function L.Update_Connection_Status(_, connected)
    if isDebug then DebugError("[Hotkey.Interface] Update_Connection_Status: Received connection status: " .. tostring(connected)) end -- Debug: Log connection status update
    -- Translate the 0 or 1 to false/true.
    if connected == 0 then 
        L.pipe_connected = false 
    else 
        L.pipe_connected = true 
    end
    if isDebug then DebugError("[Hotkey.Interface] Update_Connection_Status: Set pipe_connected to " .. tostring(L.pipe_connected)) end -- Debug: Log pipe_connected state
end

-- Handle md requests to update the action registry.
-- Reads data from a player blackboard var.
function L.Update_Actions()
    if isDebug then DebugError("[Hotkey.Interface] Update_Actions: Reading action registry from blackboard") end -- Debug: Log action registry read
    -- Args are attached to the player component object.
    local md_table = GetNPCBlackboard(L.player_id, "$hotkey_api_actions")
    if isDebug then DebugError("[Hotkey.Interface] Update_Actions: Blackboard read result: " .. tostring(md_table)) end -- Debug: Log blackboard read result

    -- Note: md may have sent several of these events on the same frame,
    -- in which case the blackboard var has just the args for the latest
    -- event, and later events processed will get nil.
    -- Skip those nil cases.
    if not md_table then 
        if isDebug then DebugError("[Hotkey.Interface] Update_Actions: No action registry data found, skipping") end -- Debug: Log nil blackboard skip
        return 
    end
    L.action_registry = md_table
    if isDebug then DebugError("[Hotkey.Interface] Update_Actions: Updated action_registry") end -- Debug: Log action registry update

    -- Clear the md var by writing nil.
    SetNPCBlackboard(L.player_id, "$hotkey_api_actions", nil)
    if isDebug then DebugError("[Hotkey.Interface] Update_Actions: Cleared $hotkey_api_actions blackboard") end -- Debug: Log blackboard clear
    
    --Lib.Print_Table(L.action_registry, "Update_Actions action_registry")
end

-- Read in the stored list of player action keys.
-- Generally md will send this on init.
function L.Read_Player_Keys()
    if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: Reading player action keys from blackboard") end -- Debug: Log player keys read
    -- Args are attached to the player component object.
    local md_table = GetNPCBlackboard(L.player_id, "$hotkey_api_player_keys_from_md")
    if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: Blackboard read result: " .. tostring(md_table)) end -- Debug: Log blackboard read result
    -- This shouldn't get getting nil values since the md init is
    -- sent just once, but play it safe.
    if not md_table then 
        if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: No player keys data found, skipping") end -- Debug: Log nil blackboard skip
        return 
    end
    L.player_action_keys = md_table
    if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: Updated player_action_keys") end -- Debug: Log player keys update

    -- Clear the md var by writing nil.
    SetNPCBlackboard(L.player_id, "$hotkey_api_player_keys_from_md", nil)
    if isDebug then DebugError("[Hotkey.Interface] Read_Player_Keys: Cleared $hotkey_api_player_keys_from_md blackboard") end -- Debug: Log blackboard clear
    
    --Lib.Print_Table(L.player_action_keys, "Read_Player_Keys player_action_keys")
end

-- Write to the list of player action keys to be stored in md.
-- This could be integrated into remapInput, but kept separate for now.
function L.Write_Player_Keys()
    if isDebug then DebugError("[Hotkey.Interface] Write_Player_Keys: Writing player action keys to blackboard") end -- Debug: Log player keys write
    -- Args are attached to the player component object.
    SetNPCBlackboard(L.player_id, "$hotkey_api_player_keys_from_lua", L.player_action_keys)
    if isDebug then DebugError("[Hotkey.Interface] Write_Player_Keys: Set $hotkey_api_player_keys_from_lua blackboard") end -- Debug: Log blackboard set
    Raise_Signal("Store_Player_Keys")
    if isDebug then DebugError("[Hotkey.Interface] Write_Player_Keys: Signalled Store_Player_Keys") end -- Debug: Log signal
    
    --Lib.Print_Table(L.player_action_keys, "Write_Player_Keys player_action_keys")
end

-------------------------------------------------------------------------------
-- Menu setup.
-- TODO: break into more init subfunctions for organization.

function L.Init_Menu()
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Starting menu initialization") end -- Debug: Log menu initialization start
    -- Look up the menu, store in this module's local.
    menu = Lib.Get_Egosoft_Menu("OptionsMenu")
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Retrieved OptionsMenu") end -- Debug: Log menu retrieval
    
    -- Patch displayControls.
    local ego_displayControls = menu.displayControls
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patching displayControls") end -- Debug: Log displayControls patch
    menu.displayControls = function(...)
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Called with args: " .. tostring(select("#", ...))) end -- Debug: Log displayControls call
        -- Start by building the original menu.
        -- Note that displayControls calls frame:display(), which would need
        -- to be called a second time after new rows are added, but leads
        -- to backend confusion.
        -- Since attempts to re-display after adding new rows lead to many
        end -- Debuglog errors when the menu closes (widgets still alive not
        -- having a table), the original display() can be suppressed by
        -- intercepting the frame building function, and putting in a
        -- dummy function for the frame's display member.
        local ego_createOptionsFrame = menu.createOptionsFrame
        -- Store the frame and its display function.
        local frame
        local frame_display
        menu.createOptionsFrame = function(...)
            if isDebug then DebugError("[Hotkey.Interface] createOptionsFrame: Creating options frame") end -- Debug: Log frame creation
            -- Build the frame.
            frame = ego_createOptionsFrame(...)
            -- Record its display function.
            frame_display = frame.display
            -- Replace it with a dummy.
            frame.display = function() return end
            if isDebug then DebugError("[Hotkey.Interface] createOptionsFrame: Suppressed frame display") end -- Debug: Log display suppression
            -- Return the edited frame to displayControls.
            return frame
        end

        -- Record the prior selected option, since the below call clears it.
        local preselectOption = menu.preselectOption
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Recorded preselectOption: " .. tostring(preselectOption)) end -- Debug: Log preselectOption
        -- Build the menu.
        ego_displayControls(...)
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Ran original displayControls") end -- Debug: Log original displayControls call

        -- Reconnect the createOptionsFrame function, to avoid impacting
        -- other menu pages.
        menu.createOptionsFrame = ego_createOptionsFrame
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Restored createOptionsFrame") end -- Debug: Log frame restoration

        -- Safety call to add in the new rows.
        local success, error = pcall(L.displayControls, preselectOption, ...)
        if not success then
            DebugError("displayControls error: "..tostring(error))
        end
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Custom displayControls call success: " .. tostring(success)) end -- Debug: Log custom displayControls result

        -- Re-attach the original frame display, and call it.
        -- (Note: this method worked out great, much better than attempts
        -- to re-display after clearing scripts or whatever.)
        frame.display = frame_display
        frame:display()
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Restored and called frame display") end -- Debug: Log frame display
    end
    
    -- Patch remapInput, which catches the player's new keys.
    local ego_remapInput = menu.remapInput
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patching remapInput") end -- Debug: Log remapInput patch
    menu.remapInput = function(...)
        if isDebug then DebugError("[Hotkey.Interface] remapInput: Called with args: " .. tostring(select("#", ...))) end -- Debug: Log remapInput call
        -- Hand off to ego function if this isn't a custom key.
        if menu.remapControl.controlcontext ~= "hotkey_api" then
            if isDebug then DebugError("[Hotkey.Interface] remapInput: Non-hotkey_api context, calling original remapInput") end -- Debug: Log non-hotkey_api context
            ego_remapInput(...)
            return
        end        
        -- Safety call.
        local success, error = pcall(L.remapInput, ...)
        if not success then
            if isDebug then DebugError("remapInput error: "..tostring(error))
        end
        if isDebug then DebugError("[Hotkey.Interface] remapInput: Custom remapInput call success: " .. tostring(success)) end -- Debug: Log custom remapInput result
    end
    
    -- TODO: replace the event registration functions which select which
    -- input types to capture.  Just want keyboard for custom controls.
    -- TODO: also need to suppress hotkey_api from triggering cues while
    -- this is going on.
    --L.input_event_handlers = {
    --    -- Args patterned off of config.input.directInputHookDefinitions.
    --    -- Just keyboard for now.
    --    ["keyboardInput"] = function (_, keycode) L.remapInput(1, keycode, 0) end,
    --}
    --
    ---- Patch registration.
    --local ego_registerDirectInput = menu.registerDirectInput
    --menu.registerDirectInput = function()
    --    L.registerDirectInput(ego_registerDirectInput)
    --}
    --
    ---- Patch unregistration.
    --local ego_unregisterDirectInput = menu.unregisterDirectInput
    --menu.unregisterDirectInput = function()
    --    L.unregisterDirectInput(ego_unregisterDirectInput)
    --}
    
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Skipped input event handler patches") end -- Debug: Log skipped input patches

    -- Listen for when menus open/close, to inform the md side what the
    -- current hotkey context is (eg. suppress space-based hotkeys while
    -- menus are open).
        -- (Alternatively, can check this live by scanning all menus for
    -- the menu.shown flag being set and menu.minimized being false.)

    --[[
        Closing raises a ui signal of the menu name, but that is awkward
        to catch for all menus, and not reasonable to account for
        modded menus (outside of known mods).

        However, any menu closing should eventually call Helper's
        local closeMenu() function, which ends by calling
        Helper.clearMenu(...), so in theory wrapping clearMenu should
        be sufficient to capturing all menu closings.

        However, UserQuestionMenu doesn't get caught like others, even though
        it has a clear path by which it calls the Helper close function,
        even if the menu is set to auto-confirm (eg. when ejecting into
        a spacesuit).  From a glance at the code, it is unclear why
        this particular menu would be difficult.

        TODO: maybe revisit this to figure it out.
        For now, just ignore the menu.
    ]]
    -- Patch into Helper.clearMenu for closings.
    local ego_helper_clearMenu = Helper.clearMenu
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patching Helper.clearMenu") end -- Debug: Log clearMenu patch
    Helper.clearMenu = function(menu, ...)
        if isDebug then DebugError("[Hotkey.Interface] clearMenu: Closing menu: " .. tostring(menu.name)) end -- Debug: Log menu closing
        ego_helper_clearMenu(menu, ...)
        L.Menu_Closed(menu)
    end

    -- Patch into all menu.showMenuCallback functions to catch when
    -- they open.  Two steps: patch existing menus, and patch helper
    -- for any future registered menus.
    -- Both share this bit of logic:
    local function patch_showMenuCallback(menu)
        local ego_showMenuCallback = menu.showMenuCallback
        menu.showMenuCallback = function(...)
            if isDebug then DebugError("[Hotkey.Interface] showMenuCallback: Opening menu: " .. tostring(menu.name)) end -- Debug: Log menu opening
            ego_showMenuCallback(...)
            L.Menu_Opened(menu)
        end
        -- These callbacks were registered to a 'show<name>' event, so update
        -- that registry.
        UnregisterEvent("show"..menu.name, ego_showMenuCallback)
        RegisterEvent("show"..menu.name, menu.showMenuCallback)
        if isDebug then DebugError("[Hotkey.Interface] showMenuCallback: Patched showMenuCallback for menu: " .. tostring(menu.name)) end -- Debug: Log callback patch
    end

    -- Patch existing menus.
    for _, menu in ipairs(Menus) do
        patch_showMenuCallback(menu)
    end
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patched existing menus") end -- Debug: Log existing menu patches
    -- Patch future menus.
    local ego_registerMenu = Helper.registerMenu
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patching Helper.registerMenu") end -- Debug: Log registerMenu patch
    Helper.registerMenu = function(menu, ...)
        if isDebug then DebugError("[Hotkey.Interface] registerMenu: Registering menu: " .. tostring(menu.name)) end -- Debug: Log menu registration
        -- Run helper function first to set up the menu's callback func.
        ego_registerMenu(menu, ...)
        -- Can now patch it.
        patch_showMenuCallback(menu)
        
    end

    -- Also want to catch minimized menus.
    local ego_minimizeMenu = Helper.minimizeMenu
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patching Helper.minimizeMenu") end -- Debug: Log minimizeMenu patch
    Helper.minimizeMenu = function(menu, ...)
        if isDebug then DebugError("[Hotkey.Interface] minimizeMenu: Minimizing menu: " .. tostring(menu.name)) end -- Debug: Log menu minimizing
        ego_minimizeMenu(menu, ...)
        L.Menu_Minimized(menu)
    end
    -- And restored menus.
    local ego_restoreMenu = Helper.restoreMenu
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Patching Helper.restoreMenu") end -- Debug: Log restoreMenu patch
    Helper.restoreMenu = function(menu, ...)
        if isDebug then DebugError("[Hotkey.Interface] restoreMenu: Restoring menu: " .. tostring(menu.name)) end -- Debug: Log menu restoring
        ego_restoreMenu(menu, ...)
        L.Menu_Restored(menu)
    end
    
    if isDebug then DebugError("[Hotkey.Interface] Init_Menu: Completed menu initialization") end -- Debug: Log menu initialization complete
end

-------------------------------------------------------------------------------
-- Menu open/close handlers.

-- Note: TopLevelMenu is the default when no other menus are open, and will
-- generally be ignored here.
-- This is called when menus are closed in Helper.
function L.Menu_Closed(menu)
    if menu.name == "TopLevelMenu" then 
        if isDebug then DebugError("[Hotkey.Interface] Menu_Closed: Ignoring TopLevelMenu") end -- Debug: Log ignored menu
        return 
    end
    -- DebugError("Menu closed: "..tostring(menu.name))
    if isDebug then DebugError("[Hotkey.Interface] Menu_Closed: Signalling Menu_Closed for: " .. tostring(menu.name)) end -- Debug: Log menu close signal
    Raise_Signal("Menu_Closed", menu.name)
    -- TODO: in practice, some menu closures might get missed.
    --  Can maybe check all menu open states, and indicate if they
    --  are all closed at the time (to recover from bad information).
    -- Can scan all menus for .shown and not .minimized to see if
    -- any are open.
end

-- This is called when menus are opened in Helper.
function L.Menu_Opened(menu)
    if menu.name == "TopLevelMenu" then 
        if isDebug then DebugError("[Hotkey.Interface] Menu_Opened: Ignoring TopLevelMenu") end -- Debug: Log ignored menu
        return 
    end
    if menu.name == "UserQuestionMenu" then 
        if isDebug then DebugError("[Hotkey.Interface] Menu_Opened: Ignoring UserQuestionMenu") end -- Debug: Log ignored menu
        return 
    end
    -- DebugError("Menu opened: "..tostring(menu.name))
    if isDebug then DebugError("[Hotkey.Interface] Menu_Opened: Signalling Menu_Opened for: " .. tostring(menu.name)) end -- Debug: Log menu open signal
    Raise_Signal("Menu_Opened", menu.name)
end

-- This is called when menus are minimized in Helper.
-- Treats menu as closing for the md side.
function L.Menu_Minimized(menu)
    if menu.name == "TopLevelMenu" then 
        if isDebug then DebugError("[Hotkey.Interface] Menu_Minimized: Ignoring TopLevelMenu") end -- Debug: Log ignored menu
        return 
    end
    --if isDebug then DebugError("Menu minimized: "..tostring(menu.name))
    if isDebug then DebugError("[Hotkey.Interface] Menu_Minimized: Signalling Menu_Closed for: " .. tostring(menu.name)) end -- Debug: Log menu minimize signal
    Raise_Signal("Menu_Closed", menu.name)
end

-- This is called when menus are restored (unminimized) in Helper.
-- Treats menu as opening for the md side.
function L.Menu_Restored(menu)
    if menu.name == "TopLevelMenu" then 
        if isDebug then DebugError("[Hotkey.Interface] Menu_Restored: Ignoring TopLevelMenu") end -- Debug: Log ignored menu
        return 
    end
    -- DebugError("Menu restored: "..tostring(menu.name))
    if isDebug then DebugError("[Hotkey.Interface] Menu_Restored: Signalling Menu_Opened for: " .. tostring(menu.name)) end -- Debug: Log menu restore signal
    Raise_Signal("Menu_Opened", menu.name)
end
-- TODO: a timed check to occasionally go through all the menus and
-- verify which are open/closed, just incase there is a problem above
-- with missing an opened/closed signal, so that the api can recover.


-- Test code: catching inputs directly.
-- Result: ListenForInput is only good for one key press, and it will
-- prevent that keypress from any other in-game effect.
-- So this is a dead end without a way to refire the caught key artificially.
-- There is also a C.ActivateDirectInput function, but that appears to be
-- just for editboxes when selected to enable typing.
--[[
local keys_to_catch = 10
function L.Input_Listener()
    ListenForInput(true)
    RegisterEvent("keyboardInput", L.Handle_Caught_Key)
    -- In testing, the above only catch a single input, suggesting
    -- either ListenForInput or the event registration gets cleared
    -- after one catch.
end
function L.Handle_Caught_Key(_, keycode)
    DebugError("Caught keyboard keycode: "..tostring(keycode))
    keys_to_catch = keys_to_catch -1
    if keys_to_catch > 0 then
        -- Restart the listen function.
        -- Limit how many times it happens, in case this locks out
        -- inputs to the game.
        ListenForInput(true)
    end
end
-- Fire it off.
L.Input_Listener()
]]
-- Patch to add custom keys to the control remap menu.
function L.displayControls(preselectOption, optionParameter)
    if isDebug then DebugError("[Hotkey.Interface] displayControls: Called with preselectOption: " .. tostring(preselectOption) .. ", optionParameter: " .. tostring(optionParameter)) end -- Debug: Log function call
    -- Skip if the pipe is not connected, to avoid clutter for users that
    -- have this api installed but aren't using the server.
    if not L.pipe_connected then 
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Pipe not connected, skipping") end -- Debug: Log pipe not connected
        return 
    end
    -- TODO: skip if there are no actions available. For now, the
    -- stock example actions should always be present, so can skip this
    -- check.

    -- TODO: skip if hotkey menu items are disabled using an extension options
    -- Debug flag, in case this code breaks the menu otherwise.
    -- For now, stick keys on the keyboard/space submenu.
    -- Skip others.
    if optionParameter ~= "keyboard_space" then 
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Not keyboard_space, skipping") end -- Debug: Log non-keyboard_space skip
        return 
    end

    -- Look up the frame with the table.
    -- This should be in layer 3, matching config.optionsLayer.
    local frame = menu.optionsFrame
    if frame == nil then
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Failed to find optionsFrame") end -- Debug: Log frame not found
        error("Failed to find gameoptions menu main frame")
    end
            
    -- Look up the table in the frame.
    -- There is probably just the one content entry, but to be safe
    -- search content for a table.
    -- TODO: could maybe also do menu.optionTable.
    local ftable
    for i=1,#frame.content do
        if frame.content[i].type == "table" then
            ftable = frame.content[i]
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Found table in frame content at index: " .. tostring(i)) end -- Debug: Log table found
        end
    end
    if ftable == nil then
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Failed to find ftable") end -- Debug: Log table not found
        error("Failed to find gameoptions menu main ftable")
    end

    -- Error check.
    if not L.action_registry then
        DebugError("action_registry is nil")
        return
    end
    if isDebug then DebugError("[Hotkey.Interface] displayControls: Action registry available, proceeding") end -- Debug: Log action registry check

    -- Add some space.
    row = ftable:addRow(false, { bgColor = Color.row_background })
    if isDebug then DebugError("[Hotkey.Interface] displayControls: Added spacer row") end -- Debug: Log spacer row addition
    row[2]:setColSpan(3):createText(" ", { 
        fontsize = 1, 
        height = config.infoTextHeight, 
        cellBGColor = Color.row_background })
        
    -- Add a nice title.
    -- Make this a larger than normal font.
    local row = ftable:addRow(false, { bgColor = Color.row_background })
    if isDebug then DebugError("[Hotkey.Interface] displayControls: Added title row") end -- Debug: Log title row addition
    row[2]:setColSpan(3):createText(T.extensions, config.subHeaderTextProperties_2)
    
    -- Make sure all actions have an entry in the player keys table.
    for _, action in pairs(L.action_registry) do
        if not L.player_action_keys[action.id] then
            L.player_action_keys[action.id] = {
                -- Repetition of id, in case it is ever useful.
                -- (This will not get a $ prefix when sent to md.)
                id = action.id,
                -- List of inputs.
                -- Note: unused entries are elsewhere {-1,-1,0}, though that
                -- led to problems when tried.  All nil works okay.
                -- TODO: limit to only supporting one hotkey, maybe, or
                -- arbitrary number.
                inputs = {
                    [1] = {combo  = "", code = nil, source = nil, signum = nil},
                    [2] = {combo  = "", code = nil, source = nil, signum = nil},
                }
            }
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Initialized player_action_keys for action ID: " .. tostring(action.id)) end -- Debug: Log player keys initialization
        end
    end
        

    -- Set up the custom actions.
    -- These will be sorted into their categories, with uncategorized
    -- lumped together at the top of the menu.
    -- Start by sorting actions into categories.
    local cat_action_dict = {}
    for _, action in pairs(L.action_registry) do
        local cat = action.category
        -- Set default category.
        if not cat then cat = "" end
        -- Set up a new sublist if needed.
        if not cat_action_dict[cat] then cat_action_dict[cat] = {} end
        -- Add it in.
        table.insert(cat_action_dict[cat], action)
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Added action ID " .. tostring(action.id) .. " to category: " .. tostring(cat)) end -- Debug: Log action categorization
    end

    -- Convert the cat table to a list, to enable lua sorting.
    local cats_sorted = {}
    for cat, sublist in pairs(cat_action_dict) do 
        table.insert(cats_sorted, cat)
        -- Also sort the actions by name while here.
        -- This lambda function returns True if the left arg goes first.
        table.sort(sublist, function (a,b) return (a.name < b.name) end)
        if isDebug then DebugError("[Hotkey.Interface] displayControls: Sorted actions for category: " .. tostring(cat)) end -- Debug: Log action sorting
    end
    -- Sort the cat names.
    table.sort(cats_sorted)
    if isDebug then DebugError("[Hotkey.Interface] displayControls: Sorted categories: " .. tostring(table.concat(cats_sorted, ","))) end -- Debug: Log category sorting

    -- Loop over cat names.
    for _, cat in ipairs(cats_sorted) do
        -- Make a header if this is a named category.
        if cat ~= "" then
            local row = ftable:addRow(false, { bgColor = Color.row_background })
            -- TODO: maybe colspan 7.            
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Added category header for: " .. tostring(cat)) end -- Debug: Log category header
            row[2]:setColSpan(3):createText(cat, config.subHeaderTextProperties)
        end
        -- Loop over the sorted action list.
        for _, action in ipairs(cat_action_dict[cat]) do
            -- Hand off to custom function.
            L.displayControlRow(ftable, action.id)
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Added row for action ID: " .. tostring(action.id)) end -- Debug: Log action row addition
        end
    end

    -- Fix the row selection.
    -- The preselectOption should match the id of the desired row.
    -- TODO: maybe fix the preselectCol as well, though not as important;
    -- see gameoptions around line 2482.
    for i = 1, #ftable.rows do
        if ftable.rows[i].index == preselectOption then
            ftable:setSelectedRow(ftable.rows[i].index)
            if isDebug then DebugError("[Hotkey.Interface] displayControls: Set selected row to: " .. tostring(preselectOption)) end -- Debug: Log row selection
            break
        end
    end

    -- -Removed; display is handled above.
    --[[
    -- Need to re-display.
    -- TODO: stress test for problems.
    -- In practice, this causes log warning spam if display() done directly,
    -- since the display() function builds a whole new frame, but the old
    -- frame's scripts weren't cleared out.
    -- Manually do the script clear first.
    -- (Unlike clearDataForRefresh, this call just removes scripts,
    -- not existing widget descriptors.)
    Helper.removeAllWidgetScripts(menu, config.optionsLayer)
    -- TODO: need to revit this all again; when the menu is closed it throws
    -- ~1600 errors into the log with: "GetCellContent(): invalid table ID
    --  2336 - table might have been destroyed already." (Where the id
    -- number changes each time.)
    -- Suggests something; not sure what.
    frame:display()
    ]]
end

-- Copy/edit of ego's function for displaying a control row of text
-- and two buttons.
function L.displayControlRow(ftable, action_id)
    if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Adding row for action ID: " .. tostring(action_id)) end -- Debug: Log row addition
    local action = L.action_registry[action_id]
    local player_keys = L.player_action_keys[action_id]
    
    local row = ftable:addRow(true, { bgColor = Color.row_background })
    if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Created row for action ID: " .. tostring(action_id)) end -- Debug: Log row creation
    
    -- Select the row if it was selected before menu reload.
    if row.index == menu.preselectOption then
        ftable:setSelectedRow(row.index)
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set selected row: " .. tostring(row.index)) end -- Debug: Log row selection
        if menu.preselectCol == 3 or menu.preselectCol == 4 then
            ftable:setSelectedCol(menu.preselectCol)
            if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set selected column: " .. tostring(menu.preselectCol)) end -- Debug: Log column selection
        end
    end

    -- Set the action title.
    -- This is column 2, since 1 is under the back arrow.
    row[2]:createText(action.name, config.standardTextProperties)
    if action.description then
        row[2].properties.mouseOverText = action.description
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set action title: " .. tostring(action.name) .. ", description: " .. tostring(action.description)) end -- Debug: Log title and description
    else
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set action title: " .. tostring(action.name) .. ", no description") end -- Debug: Log title without description
    end
    
    -- Create the two buttons.
    for i = 1,2 do
        local info = player_keys.inputs[i]
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Processing input " .. tostring(i) .. " for action ID: " .. tostring(action_id)) end -- Debug: Log input processing

        -- Get the name of an existing key, or blank.
        local keyname, keyicon = "", nil
        if info.source then
            keyname, keyicon = menu.getInputName(info.source, info.code, info.signum)
            if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Input " .. tostring(i) .. " keyname: " .. tostring(keyname) .. ", keyicon: " .. tostring(keyicon)) end -- Debug: Log keyname and keyicon
        end

        -- Skip the funkiness regarding truncating the text string to
        -- make room for the icon. TODO: maybe revisit if needed.

        -- Buttons start at column 3, so offset i.
        local col = i+2
        local button = row[col]:createButton({ mouseOverText = action.description or "" })
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Created button at column: " .. tostring(col)) end -- Debug: Log button creation
        -- Set up the text label; this applies even without a keyname since
        -- it handles blinking _.
        button:setText(
            -- 'nameControl' handles label blinking when changing.
            function () return menu.nameControl(keyname, row.index, col) end,
            { color = Color.text_normal })
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set button text for column: " .. tostring(col)) end -- Debug: Log button text
        -- Add the icon.
        if keyicon then
            button:setText2(keyicon, { halign = "right" })
            if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set button icon for column: " .. tostring(col)) end -- Debug: Log button icon
        end

        -- Clicks will hand off to buttonControl.
        row[col].handlers.onClick = function () return menu.buttonControl(
            row.index, {
                "functions",
                action_id,
                info.source,
                info.code,
                info.signum,
                col,
                false,
                "hotkey_api",
                false,
            }) end            
        if isDebug then DebugError("[Hotkey.Interface] displayControlRow: Set onClick handler for column: " .. tostring(col)) end -- Debug: Log click handler
    end    
end

--[[
The following functions are after buttonControl(), the function
called when a button is pressed.

At this point, most of the args fed to displayControlRow are
present in a named table at menu.remapControl.
Fields are:
{ row, col, controltype, controlcode, controlcontext, oldinputtype,
    oldinputcode, oldinputsgn, nokeyboard, allowmouseaxis}
]]
    

-- This handles player input when setting custom keys.
-- Should only be called on player keys, not ego keys, so has no link
-- back to the original remapInput.
function L.remapInput(...)
    if isDebug then DebugError("[Hotkey.Interface] remapInput: Called with args: " .. tostring(select("#", ...))) end -- Debug: Log function call
    -- Always call this; ego does it right away.
    menu.unregisterDirectInput()
    if isDebug then DebugError("[Hotkey.Interface] remapInput: Unregistered direct input") end -- Debug: Log input unregistration

    -- Code to call on any return path, except those that still listen
    -- for keys.
    local return_func = function()
        -- Reboot the menu. All paths in ego code end with this, so it may
        -- be required to recover properly.
        -- (At least need to clear remapControl, since it being filled triggers
        -- other code, eg. trying to unregister events when the menu closes
        -- causes log errors.)
        menu.preselectTopRow = GetTopRow(menu.optionTable)
        menu.preselectOption = menu.remapControl.row
        menu.preselectCol = menu.remapControl.col
        if isDebug then DebugError("[Hotkey.Interface] remapInput: Set preselect - topRow: " .. tostring(menu.preselectTopRow) .. ", option: " .. tostring(menu.preselectOption) .. ", col: " .. tostring(menu.preselectCol)) end -- Debug: Log preselect settings
        menu.remapControl = nil
        if isDebug then DebugError("[Hotkey.Interface] remapInput: Cleared remapControl") end -- Debug: Log remapControl clear
        menu.submenuHandler(menu.currentOption)
        if isDebug then DebugError("[Hotkey.Interface] remapInput: Called submenuHandler with option: " .. tostring(menu.currentOption)) end -- Debug: Log submenuHandler call
    end

    -- Safety wrap the rest of this logic.
    local success, error = pcall(L.remapInput_wrapped, return_func, ...)
    -- On error, still aim for the good return function setup.
    if not success then
        DebugError("remapInput error: "..tostring(error))
        return_func()
    end
    if isDebug then DebugError("[Hotkey.Interface] remapInput: Wrapped call success: " .. tostring(success)) end -- Debug: Log wrapped call result
end

-- Inner part of remapInput, allowed to error.
function L.remapInput_wrapped(return_func, newinputtype, newinputcode, newinputsgn)
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Processing input - type: " .. tostring(newinputtype) .. ", code: " .. tostring(newinputcode) .. ", signum: " .. tostring(newinputsgn)) end -- Debug: Log input processing
    if debug.print_keycodes then
        Lib.Print_Table({
            controlcode = menu.remapControl.controlcode,
            newinputtype = newinputtype,
            newinputcode = newinputcode,
            newinputsgn = newinputsgn,
        }, "Control remap info")
        -- DebugError(string.format(
        --    "Detected remap of code '%s'; new aspects: type %s, %s, %s", 
        --    tostring(menu.remapControl.controlcode),
        --    tostring(newinputtype),
        --    tostring(newinputcode),
        --    tostring(newinputsgn)
        --    ))
        --Lib.Print_Table(menu.remapControl, "menu.remapControl")
    end

    -- Look up the matching action.
    local action_keys = L.player_action_keys[menu.remapControl.controlcode]
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Looked up action_keys for ID: " .. tostring(menu.remapControl.controlcode)) end -- Debug: Log action keys lookup
    -- Error if not found.
    if not action_keys then
        if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: No action_keys for ID: " .. tostring(menu.remapControl.controlcode)) end -- Debug: Log action keys not found
        error("Found no action_keys matching id: "..tostring(menu.remapControl.controlcode))
    end
            
    -- 'newinputtype' will be 1 for keyboard.
    -- Since only keyboard is wanted for now, restart listening if something
    -- else arrived.
    if newinputtype ~= 1 then
        if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Non-keyboard input not supported, restarting input listener") end -- Debug: Log non-keyboard input
        menu.registerDirectInput()
        -- Normal return; keep listener going.
        return
    end
    
    -- TODO: consider integrating other ego style functions for avoiding
    -- control conflicts and such.

    -- Use col (3 or 4) to know which index to replace (1 or 2).
    -- Try to make this a little safe against patches adding columns.
    local input_index
    if menu.remapControl.col <= 3 then
        input_index = 1
    else
        input_index = 2
    end
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Selected input index: " .. tostring(input_index) .. " for column: " .. tostring(menu.remapControl.col)) end -- Debug: Log input index selection
    
    -- Note the prior key combo.
    local old_combo = action_keys.inputs[input_index].combo
    local new_combo
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Old combo: " .. tostring(old_combo)) end -- Debug: Log old combo

    -- Note: ego menu behavior has "escape" cancel the selection with no change,
    -- and "delete" remove the key binding.
    -- Try to mimic that here.
    -- Check for escape.
    if newinputtype == 1 and newinputcode == 1 then
        if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Escape key detected, cancelling") end -- Debug: Log escape key
        -- Do nothing.
        return return_func()
    -- Check for "delete" on a key that was mapped.
    -- (oldinputcode == -1 means it wasn't mapped.)
    elseif newinputtype == 1 and newinputcode == 211 then
        -- Prepare to reset to defaults.
        newinputtype = nil
        newinputcode = nil
        newinputsgn = nil
        new_combo = ""
        if debug.print_keynames then
            DebugError("Deleting key combo: "..old_combo)
        end
        if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Delete key detected, resetting input") end -- Debug: Log delete key
    else
        -- Get the new combo string.
        new_combo = string.format("code %d %d %d", newinputtype, newinputcode, newinputsgn)
        if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: New combo: " .. tostring(new_combo)) end -- Debug: Log new combo

            -- -Removed, updated 3.0 makes ego's version too hard to use since
        --  it uses some special escape character and icon code for modifiers.
        ---- Start with ego's key name.
        ---- TODO: probably not robust across languages.
        ---- TODO: try out GetLocalizedRawKeyName
        --local ego_key_name, icon = menu.getInputName(newinputtype, newinputcode, newinputsgn)
        --
        ---- These are uppercase and with "+" for modified keys.
        ---- Translate to the combo form: space separated lowercase.
        --new_combo = string.lower( string.gsub(ego_key_name, "+", " ") )
        --if debug.print_keynames then
        --    DebugError(string.format("Ego key %s translated to combo %s", ego_key_name, new_combo))
        --end
    end
    
    -- If the new_combo is already recorded as either of the existing inputs,
    -- and is not empty (eg. deleting binding), do nothing.
    if new_combo ~= "" and (action_keys.inputs[1].combo == new_combo or action_keys.inputs[2].combo == new_combo) then
        if debug.print_keynames then
            DebugError("Ignoring already recorded key combo: "..new_combo)
        end
        if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Ignoring duplicate combo: " .. tostring(new_combo)) end -- Debug: Log duplicate combo
        return return_func()
    end

    -- Overwrite stored key.
    action_keys.inputs[input_index] = {
        combo  = new_combo, 
        code   = newinputcode, 
        source = newinputtype, 
        signum = newinputsgn }
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Updated input " .. tostring(input_index) .. " for action ID: " .. tostring(menu.remapControl.controlcode)) end -- Debug: Log input update
        
    -- Signal lua to update if the combo changed.
    Raise_Signal("Update_Key", {
        id      = action_keys.id,
        new_key = new_combo,
        old_key = old_combo,
    })
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Signalled Update_Key for action ID: " .. tostring(action_keys.id)) end -- Debug: Log Update_Key signal

    -- Update the md to save the keys.
    -- TODO: maybe integrate into Update_Key calls.
    L.Write_Player_Keys()
    if isDebug then DebugError("[Hotkey.Interface] remapInput_wrapped: Called Write_Player_Keys") end -- Debug: Log Write_Player_Keys call

    return return_func()
end

---- Patch registration.
---- Unused currently.
--function L.registerDirectInput(ego_registerDirectInput)
--    -- Check for this being a custom key.
--    if menu.remapControl.controlcontext == 1000 then
--        C.DisableAutoMouseEmulation()
--        for event, func in pairs(L.input_event_handlers) do
--            RegisterEvent(event, func)
--        end
--        ListenForInput(true)
--    else
--        ego_registerDirectInput()
--    end
--end
--    
---- Patch unregistration.
---- Unused currently.
--function L.unregisterDirectInput(ego_unregisterDirectInput)
--    -- Check for this being a custom key.
--    if menu.remapControl.controlcontext == 1000 then
--        ListenForInput(false)
--        for event, func in pairs(L.input_event_handlers) do
--            UnregisterEvent(event, func)
--        end
--        C.EnableAutoMouseEmulation()
--    else
--        ego_unregisterDirectInput()
--    end
--end




--[[
Development notes:

The existing ui functions are in gameoptions.ui.
    
    config.input.controlsorder
    - Holds data on various keys
    - Subfields space, menus, firstperson
      - Nested tables have section titles, table of keys.
      - Each key entry's arg order appears to be:
        - [controltype, code, context, mouseovertext, allowmouseaxis]
        - Many keys leave fields 3-5 unused.
    - Local, so no way to add keys without direct overwrite.

    config.input.controlsorder.space[i]
    - Table, keyed partially by indices and partly by named fields.
    - .title, .mapable, [1-5]

    config.input.directInputHookDefinitions
      List of sublists like:
        {"keyboardInput", 1, 0}
        
    config.input.directInputHooks
        
    config.input.directInputHooks
    - Table of functions, one per directInputHookDefinition.
    - Functions take a keycode, and call menu.remapInput with info on what type of input.
    - One function for each input type: keyboard, mouse, occulus, vive, and subtypes.
    - Ex: function (_, keycode) menu.remapInput(entry[2], keycode, entry[3])
      
    config.input.forbiddenkeys
      Gives a couple examples of keycodes:
        [1]   = true, - Escape
        [211] = true, - Delete
        
    menu
    - Table that defines menu properties, registered with general gui.
    - Accessible through Menus global, so functions can potentially overwritten.
    - Since functions often reference locals, overwrites may not be very useful,
      as other files won't have access to those locals.
      
    menu.getInputName(source, code, signum)
      Translates a key code into a name.
      'source' is an integer which appears to represent input source (keyboard, mouse, ...)
      'signum' appears to add a "+" or "-" if used.
      
      Keyboard key names are from GetLocalizedRawKeyName(code).
      Mouse button names are from ffi.string(C.GetLocalizedRawMouseButtonName(code)).
      Others are from the text file.

      Text file has names of some key codes:
        Page 1018: mouse axes
        Page 1022: joystick buttons
        etc.

    menu.displayControls(string optionParameter)
    - Creates the whole controls tab, for one of space, menus, or first person.
    - Hardcoded for these three; don't bother adding a new category without
      substantial copy/paste monkeypatching.
    - Loops over "controls", eg. members of config.input.controlsorder.space
      - Makes a section label, eg. "Steering: Analog"
      - Calls menu.displayControlRow() for each key, passing args.


    menu.displayControlRow(ftable, controlsgroup, controltype, code, context, mouseovertext, mapable, isdoubleclickmode, allowmouseaxis)
        Handles drawing one row of the keybind menu.
        'code' is for a specific function being mapped.

        (controlsgroup, controltype, code, context, mouseovertext) are unpacked from config.input.controlsorder,
        often with (controlsgroup, controltype) filled and others nil.

        Current key texts are taken from menu.nameControl(), which is fed the
        name and may replace it with blinking "_"/"" for a key currently
        being remapped.

        Button onClick events call menu.buttonControl() which triggers the
        remapping.
      
      
        This will look up various data from menu.controls, which was
        set in menu.getControlsData(). This is a table of control types,
        with most being pulled from C code except for "functions"
        which is pulled from config.input.controlFunctions.

        displayControlRow will reference:
        menu.controls[controltype][code]
            .name
            .contexts
            .definingcontrol

        'controltype' needs to be "functions" else displayControlRow will
        try to read the name from config, where it isn't available.

        Each "functions" entry defines a "definingcontrol" field, which
        is a reference to another controls subtable and key.
        Eg. {"states", 22} will get redirected to menu.controls["states"][22].
        This in turn is a list of "inputs" (up to 2), where each input
        is a list of {source, code, signum}, the current input for
        that control.

        If reusing this function, the related tables need to be updated:
        "functions" with a name and definingcontrol.
        "actions" or similar with the current recorded input, originally
        saved from md.
    
      
    menu.buttonControl(row_index, data_table)
    - Called when user clicks an input remap button.
    - data_table is a list with the following fields:
      {controltype, controlcode, oldinputtype, oldinputcode, oldinputsgn, column (often set to 3 or 4), not_mapable/nokeyboard, control_context, allowmouseaxis}
    - Stores a table including data_table contents into menu.remapControl for lookup later.
      - Names all the args, and adds 'row'.
    - Sets up info for blinking button during remapping.
    - Calls menu.registerDirectInput() to listen for user key press.
      
    menu.registerDirectInput(...)
    - Runs RegisterEvent on all events in config.input.directInputHookDefinitions,
      setting functions in config.input.directInputHooks as handlers.
    - Calls ListenForInput(true).
    - So, this is where it kicks off listening for a new user key press.
    - Presumably, ListenForInput sets a mode which will raise one of these
      events, eg. "keyboardInput" on a key press.

    ListenForInput(?)
      External function; unknown behavior.
      
    menu.unregisterDirectInput()
      Undoes registerDirectInput: unregisters events, calls ListenForInput(false).
      
      
    menu.remapInput(newinputtype, newinputcode, newinputsgn)
    - Has a bunch of logic for processing the key.
    - Clears conflicts, rejects disallowed keys, etc.
    - Calls menu.unregisterDirectInput(), to stop listening for new keys.
    - Calls checkInput, presumably to clear conflicts.
    - May delete a key if 211 (delete) was pressed.
      - Calls menu.removeInput() on this path.    
    - At end calls SaveInputSettings(menu.controls.actions, menu.controls.states, menu.controls.ranges).
        - SaveInputSettings is exe level.
    - Note: this is not called directly, but indirectly through menu.registerDirectInput()
      which in turn looks it up in config.input.directInputHooks, initialized
      on lua loading. Those wrapper funcs do look it up in menu, though, so
      a direct monkey patch works.

        
                  
    menu.removeInput()
      At end calls SaveInputSettings(menu.controls.actions, menu.controls.states, menu.controls.ranges).
      
    SaveInputSettings(?,?,?)
      External function; unknown behavior.
      Presumably this transfers current key mappings to exe side for actual
      key listening and functionality.
      
      
Keycodes:
    - The example codes for escape (1) and delete (211) don't mach up with windows keycodes.
    - However, they do match this lua file, and its linked c++ file:
      - https://github.com/lukemetz/moonstone/blob/master/src/lua/utils/keycodes.lua
      - https://github.com/wgois/OIS/blob/master/includes/OISKeyboard.h
    - Using the above, can potentially translate user keys appropriately.
    
    
Possibly adding new keys:
    a) monkeypatch menu.displayControls.
      - Run the normal version first; this ends in frame:display() (worrisome).
      - Add a custom section title.
      - Call menu.displayControlRow() for each new key, matching args.
    b) patch menu.remapInput to catch user assignments.
]]

return nil,Init
end)