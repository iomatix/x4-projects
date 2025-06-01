Lua_Loader.define("extensions.sn_mod_support_apis.lua.c_library.winpipe", function(require)
    --[[
        Wrapper for loading the winpipe DLL, supporting Windows named pipe operations.
        Dynamically selects the appropriate DLL based on the X4 game version and
        mod configuration for Python Pipe Server compatibility:
        - pre-3.3 hotfix 1: winpipe_64_pre3p3hf1.dll (bidirectional pipes).
        - 3.3 hotfix 1+: winpipe_64.dll (bidirectional by default, updated for "r"/"w" modes).
        - 2.1.0+ Python Server: Requires winpipe_64.dll with "r"/"w" mode support.

        Note: The mod must set `use_unidirectional_pipes` in its configuration
        (e.g., via a global variable or file) to true for 2.1.0+ compatibility.
        If unset, defaults to bidirectional mode for backward compatibility.
    ]]

    -- Verify this is running on Windows.
    if package and package.config:sub(1,1) == "\\" then
        -- Log the loading attempt for debugging.
        DebugError("winpipe.lua: Loading DLL at " .. os.date())

        -- Get X4 version to determine base DLL compatibility.
        local version = GetVersionString()
        DebugError("winpipe.lua: X4 version string: " .. version)

        -- Check for 3.3 hotfix 1 or later (build code "406216" is pre-hotfix).
        local is_post_3_3_hf1 = not string.find(version, "406216")

        -- Determine if unidirectional pipes (2.1.0+) are required.
        -- TODO: Replace with actual config check (e.g., global variable or file).
        -- For now, assume false unless explicitly set by the mod.
        local use_unidirectional_pipes = true  -- Set to true for 2.1.0+ testing
        DebugError("winpipe.lua: Unidirectional pipes enabled: " .. tostring(use_unidirectional_pipes))

        if is_post_3_3_hf1 and use_unidirectional_pipes then
            -- Load the updated DLL with "r"/"w" mode support for 2.1.0+.
            DebugError("winpipe.lua: Loading winpipe_64.dll for 2.1.0+ unidirectional pipes")
            return package.loadlib(
                ".\\extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64.dll",
                "luaopen_winpipe")()
        elseif is_post_3_3_hf1 then
            -- Load the updated DLL in bidirectional mode for 3.3 hf1+ pre-2.1.0.
            DebugError("winpipe.lua: Loading winpipe_64.dll for 3.3 hf1+ bidirectional pipes")
            return package.loadlib(
                ".\\extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64_post3p3hf1.dll",
                "luaopen_winpipe")()
        else
            -- Load the original DLL for pre-3.3 hotfix 1 (bidirectional).
            DebugError("winpipe.lua: Loading winpipe_64_pre3p3hf1.dll for pre-3.3 hf1")
            return package.loadlib(
                ".\\extensions\\sn_mod_support_apis\\ui\\c_library\\winpipe_64_pre3p3hf1.dll",
                "luaopen_winpipe")()
        end
    else
        DebugError("winpipe.lua: Not on Windows, skipping DLL load")
        return nil
    end
end)