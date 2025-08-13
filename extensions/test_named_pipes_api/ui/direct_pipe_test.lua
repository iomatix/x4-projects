-- Direct Lua pipe test that bypasses MD system completely
Lua_Loader.define("extensions.test_named_pipes_api.ui.direct_pipe_test", function(require)
    local Pipes = require("extensions.sn_mod_support_apis.ui.named_pipes.Pipes")
    
    local function run_direct_test()
        DebugError("DIRECT PIPE TEST: Starting direct Lua pipe test...")
        
        -- Try direct pipe operations
        local success1 = pcall(Pipes.Schedule_Write, "x4_pipe", "direct_test_1", "DIRECT_LUA_TEST_MESSAGE_1")
        local success2 = pcall(Pipes.Schedule_Write, "x4_pipe", "direct_test_2", "DIRECT_LUA_TEST_MESSAGE_2")
        
        DebugError("DIRECT PIPE TEST: Write 1 success: " .. tostring(success1))
        DebugError("DIRECT PIPE TEST: Write 2 success: " .. tostring(success2))
        
        -- Try connection
        local connection_success = pcall(Pipes.Connect_Pipe, "x4_pipe")
        DebugError("DIRECT PIPE TEST: Connection success: " .. tostring(connection_success))
        
        -- Check if connected
        local is_connected = Pipes.Is_Connected("x4_pipe")
        DebugError("DIRECT PIPE TEST: Is connected: " .. tostring(is_connected))
        
        DebugError("DIRECT PIPE TEST: Test completed.")
    end
    
    -- Run test immediately when module loads
    run_direct_test()
    
    -- Also register for delayed execution
    RegisterEvent("frame", function()
        UnregisterEvent("frame", run_direct_test)
        run_direct_test()
    end)
    
    return {}
end)