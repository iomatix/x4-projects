Lua_Loader.define("extensions.sn_mod_support_apis.ui.named_pipes.Library", function(require)
    
    isDebug = false -- Set to true for debug messages, false for production

    -- Table holding lib functions to be returned, or lib params that can
    -- be modified.
    local L = {
        debug = {
            print_to_log = false -- Print debug messages to the log.
        }
    }



    -- Include stuff from the shared library.
    local Lib_shared = require("extensions.sn_mod_support_apis.ui.Library")
    Lib_shared.Table_Update(L, Lib_shared)

    -- Shared function to raise a named galaxy signal with an optional
    -- return value.
    function L.Raise_Signal(name, return_value)
        -- Clumsy way to lookup the galaxy.
        -- local player = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
        -- local galaxy = GetComponentData(player, "galaxyid" )
        -- SignalObject( galaxy, name, return_value)

        -- Switching to AddUITriggeredEvent
        -- This will give the return_value in event.param3
        -- Use <event_ui_triggered screen="'Named_Pipes'" control="'<name>'" />
        AddUITriggeredEvent("Named_Pipes", name, return_value)
        if return_value == nil then
            return_value = "nil"
        end
        if isDebug then DebugError("[named_pipes.Library] Event: Named_Pipes, " .. name .. " ; value: " .. return_value) end
    end

    ---- Split a string on the first semicolon.
    ---- Note: works on the MD passed arrays of characters.
    ---- Returns two substrings.
    -- function L.Split_String(this_string)
    --
    --    -- Get the position of the separator.
    --    local position = string.find(this_string, ";")
    --    if position == nil then
    --        end -- Debug error printout gets a nicer log heading.
    --        if isDebug then DebugError("No ';' separator found in: "..tostring(this_string)) end
    --        -- Hard error.
    --        error("Bad separator")
    --    end
    --
    --    -- Split into pre- and post- separator strings.
    --    local left  = string.sub(this_string, 0, position -1)
    --    local right = string.sub(this_string, position +1)
    --    
    --    return left, right
    -- end

    return L
end)
