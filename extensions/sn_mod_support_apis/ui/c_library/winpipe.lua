Lua_Loader.define("extensions.sn_mod_support_apis.lua.c_library.winpipe", function(require)
    --[[
        winpipe.lua - Handles dynamic loading of the appropriate Windows DLL for named pipe support
        in the X4 modding environment. Detects OS, game version, and compatibility requirements.

        DLL Compatibility Matrix:
        - Pre-3.3 Hotfix 1       -> winpipe_64_pre3p3hf1.dll (legacy bidirectional)
        - 3.3 Hotfix 1+          -> winpipe_64_post3p3hf1.dll (bidirectional, updated)
        - 2.1.0+ Python Pipe API -> winpipe_64.dll (unidirectional pipe mode)

        Unidirectional pipe mode (2.1.0+) must be explicitly enabled in mod config.

        Author: [Your Name / Mod Team]
    ]]

    -- === Enhanced Windows OS Detection ===
    local function is_windows_platform()
        local config_sep = package and package.config and package.config:sub(1,1)
        local env_os = os.getenv("OS") or "unknown"
        local jit_os = (jit and jit.os) or "unknown"

        DebugError("winpipe.lua: package.config: " .. tostring(package and package.config))
        DebugError("winpipe.lua: Detected path separator: " .. tostring(config_sep))
        DebugError("winpipe.lua: OS env var: " .. env_os)
        DebugError("winpipe.lua: jit.os: " .. jit_os)

        return config_sep == "\\" or env_os == "Windows_NT" or jit_os == "Windows"
    end

    if not is_windows_platform() then
        DebugError("winpipe.lua: Not detected as Windows environment. DLL loading skipped.")
        return nil
    end

    DebugError("winpipe.lua: Running on Windows. Starting DLL load at " .. os.date())

    -- === Game Version Detection ===
    local version = GetVersionString() or "unknown"
    DebugError("winpipe.lua: X4 version string: " .. version)

    local is_post_3_3_hf1 = not string.find(version, "406216")
    DebugError("winpipe.lua: Is version post 3.3 HF1? " .. tostring(is_post_3_3_hf1))

    -- === Mod Configuration (Unidirectional Pipe Mode) ===
    -- Replace this with actual config read when available
    local use_unidirectional_pipes = true -- placeholder for mod config
    DebugError("winpipe.lua: Unidirectional pipe mode: " .. tostring(use_unidirectional_pipes))

    -- === DLL Selection Logic ===
    local dll_path
    if is_post_3_3_hf1 and use_unidirectional_pipes then
        dll_path = ".\\extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64.dll"
        DebugError("winpipe.lua: Selected DLL: winpipe_64.dll (2.1.0+ unidirectional pipes)")
    elseif is_post_3_3_hf1 then
        dll_path = ".\\extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64_post3p3hf1.dll"
        DebugError("winpipe.lua: Selected DLL: winpipe_64_post3p3hf1.dll (3.3 HF1+ bidirectional)")
    else
        dll_path = ".\\extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64_pre3p3hf1.dll"
        DebugError("winpipe.lua: Selected DLL: winpipe_64_pre3p3hf1.dll (pre-3.3 HF1 legacy)")
    end

    -- === DLL Load Attempt ===
    local success, result = pcall(function()
        return package.loadlib(dll_path, "luaopen_winpipe")()
    end)

    if not success then
        DebugError("winpipe.lua: ERROR loading DLL from " .. dll_path .. ": " .. tostring(result))
        return nil
    end

    DebugError("winpipe.lua: DLL loaded successfully.")
    return result
end)
