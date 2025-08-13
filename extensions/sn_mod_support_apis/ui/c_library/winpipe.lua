Lua_Loader.define("extensions.sn_mod_support_apis.ui.c_library.winpipe", function(require)
    --[[
        winpipe.lua - Handles dynamic loading of the appropriate Windows DLL for named pipe support
        in the X4 modding environment. Detects OS, game version, and compatibility requirements.

        DLL Compatibility Matrix:
        - Pre-3.3 Hotfix 1       -> winpipe_64_pre3p3hf1.dll (legacy bidirectional)
        - 3.3 Hotfix 1+          -> winpipe_64_post3p3hf1.dll (bidirectional, updated)
        - 2.1.0+ Python Pipe API -> winpipe_64.dll (unidirectional pipe mode)

        Unidirectional pipe mode (2.1.0+) must be explicitly enabled in mod config.

        Author: X4 Modding Community
        License: MIT
    ]]

    local isDebug = true -- Set to true for debug messages, false for production
    
    -- === Enhanced Windows OS Detection ===
    local function is_windows_platform()
        local config_sep = package.config and package.config:sub(1,1) or "/"
        if isDebug then DebugError("winpipe.lua: Detected path separator: " .. tostring(config_sep)) end
        return config_sep == "\\"
    end

    if not is_windows_platform() then
        if isDebug then DebugError("winpipe.lua: Not detected as Windows environment. DLL loading skipped.") end
        return nil
    end

    if isDebug then DebugError("winpipe.lua: Running on Windows. Starting DLL load process...") end

    -- === Game Version Detection ===
    local version = GetVersionString() or "unknown"
    if isDebug then DebugError("winpipe.lua: X4 version string: " .. version) end
    local is_post_3_3_hf1 = not string.find(version, "406216")
    if isDebug then DebugError("winpipe.lua: Is version post 3.3 HF1? " .. tostring(is_post_3_3_hf1)) end

    -- === Mod Configuration (Unidirectional Pipe Mode) ===
    local use_unidirectional_pipes = true -- placeholder for mod config
    if isDebug then DebugError("winpipe.lua: Unidirectional pipe mode: " .. tostring(use_unidirectional_pipes)) end

    -- === DLL Selection Logic ===
    local dll_path
    if is_post_3_3_hf1 and use_unidirectional_pipes then
        dll_path = "extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64.dll"
        if isDebug then DebugError("winpipe.lua: Selected DLL: winpipe_64.dll (2.1.0+ unidirectional pipes)") end
    elseif is_post_3_3_hf1 then
        dll_path = "extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64_post3p3hf1.dll"
        if isDebug then DebugError("winpipe.lua: Selected DLL: winpipe_64_post3p3hf1.dll (3.3 HF1+ bidirectional)") end
    else
        dll_path = "extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64_pre3p3hf1.dll"
        if isDebug then DebugError("winpipe.lua: Selected DLL: winpipe_64_pre3p3hf1.dll (pre-3.3 HF1 legacy)") end
    end


    -- === DLL Load Attempt ===
    local success, result = pcall(function()
        local full_path = dll_path
        if isDebug then DebugError("winpipe.lua: Attempting to load DLL from: " .. full_path) end
        local lib = package.loadlib(dll_path, "luaopen_winpipe")
        if not lib then
            if isDebug then DebugError("winpipe.lua: Failed to load DLL - loadlib returned nil") end
        end
        return lib()
    end)

    if not success then
        if isDebug then DebugError("winpipe.lua: ERROR loading DLL from " .. dll_path .. ": " .. tostring(result)) end
        return nil
    end

    if isDebug then DebugError("winpipe.lua: DLL loaded successfully.") end
    return result
end)
