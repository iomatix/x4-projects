Lua_Loader.define("extensions.sn_mod_support_apis.ui.named_pipes.Pipes", function(require)
    --[[
        Provides functionality for managing named pipes in X4, including opening,
        reading, and writing. Updated to support Python Pipe Server v2.1.0 with
        paired unidirectional pipes (e.g., x4_python_host_in for writing,
        x4_python_host_out for reading).

        Note: If the winpipe DLL fails to load (e.g., on non-Windows systems),
        pipes are treated as disconnected, but the API remains functional.
    ]]

    -- Debug configuration for logging and chat output.
    local debug = {
        print_connect = true,        -- Log pipe connection events to chat.
        print_connect_errors = true, -- Log connection failures to chat.
        print_to_chat = true,        -- Log status messages to chat.
        print_to_log = true,         -- Log status messages to debug log.
    }

    -- Load FFI for C function access.
    local ffi = require("ffi")
    local C = ffi.C
    ffi.cdef[[
        bool IsGamePaused(void);  
    ]] -- Check if the game is paused.

    -- Load the winpipe DLL for Windows pipe operations.
    local winpipe = require("extensions.sn_mod_support_apis.ui.c_library.winpipe")
    -- Note: If winpipe is nil (e.g., non-Windows), pipes are treated as disconnected.

    -- Load supporting libraries.
    local Lib = require("extensions.sn_mod_support_apis.ui.named_pipes.Library")
    FIFO = Lib.FIFO
    Lib.debug.print_to_log = debug.print_to_log  -- Sync debug settings.

    local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")

    -- Local state and functions returned by this module.
    local L = {
        pipe_name = "x4_python_host",  -- Base name for pipes
        pipe_path_prefix = "\\\\.\\pipe\\",  -- Standard Windows pipe prefix.
        write_polling_active = false,        -- Tracks write polling status.
        read_polling_active = false,         -- Tracks read polling status.
        pipe_access_denied = false,          -- Flags OS access-denied errors.
    }

    --[[
        Stores pipe state objects, keyed by pipe name (without prefix).
        Each entry contains:
        - name: Pipe name (matches key).
        - write_file: Handle for writing to the server (client-to-server).
        - read_file: Handle for reading from the server (server-to-client).
        - retry_allowed: Boolean, allows one retry on failure if previously open.
        - suppress_reads_when_paused: Boolean, discards reads during game pause.
        - read_fifo: FIFO of [callback, continuous_read] for read requests.
        - write_fifo: FIFO of [callback, message] for write requests.
    ]]
    local pipes = {}
    L.pipes = pipes  -- Expose for external inspection.

    -- Initialize the module by forcing garbage collection to clean up old handles.
    local function Init()
        collectgarbage()  -- Ensure old pipe handles are closed.
        collectgarbage()  -- Double-call for Lua 5.1 reliability.
    end
    Init()

    -- Set whether reads are suppressed when the game is paused.
    function L.Set_Suppress_Paused_Reads(pipe_name, new_state)
        L.Declare_Pipe(pipe_name)
        pipes[pipe_name].suppress_reads_when_paused = new_state
    end

    -------------------------------------------------------------------------------
    -- Scheduling Functions

    -- Schedule a read operation on a pipe.
    function L.Schedule_Read(pipe_name, callback, continuous_read)
        L.Declare_Pipe(pipe_name)
        if continuous_read and debug.print_to_log then
            DebugError("Schedule_Read set for continuous_read of pipe " .. pipe_name)
        end
        FIFO.Write(pipes[pipe_name].read_fifo, {callback, continuous_read})
        L.Poll_For_Reads()  -- Trigger polling if not already active.
    end

    -- Schedule a write operation on a pipe.
    function L.Schedule_Write(pipe_name, callback, message)
        L.Declare_Pipe(pipe_name)
        FIFO.Write(pipes[pipe_name].write_fifo, {callback, message})
        L.Poll_For_Writes()  -- Trigger polling if not already active.
    end

    -- Cancel all pending reads, sending error callbacks.
    function L.Deschedule_Reads(pipe_name)
        if not pipes[pipe_name] then return end
        local read_fifo = pipes[pipe_name].read_fifo
        while not FIFO.Is_Empty(read_fifo) do
            local callback = FIFO.Read(read_fifo)[1]
            if type(callback) == "string" then
                Lib.Raise_Signal('pipeRead_complete_' .. callback, "ERROR")
            elseif type(callback) == "function" then
                callback("ERROR")
            end
        end
    end

    -- Cancel all pending writes, sending error callbacks.
    function L.Deschedule_Writes(pipe_name)
        if not pipes[pipe_name] then return end
        local write_fifo = pipes[pipe_name].write_fifo
        while not FIFO.Is_Empty(write_fifo) do
            local callback = FIFO.Read(write_fifo)[1]
            if type(callback) == "string" then
                Lib.Raise_Signal('pipeWrite_complete_' .. callback, "ERROR")
            elseif type(callback) == "function" then
                callback("ERROR")
            end
        end
    end

    -------------------------------------------------------------------------------
    -- Pipe Management

    -- Garbage collection handler for pipe tables.
    function L.Pipe_Garbage_Collection_Handler(pipe_table)
        if pipe_table.write_file then
            pcall(function() pipe_table.write_file:write("garbage_collected") end)
            pipe_table.write_file = nil
        end
        if pipe_table.read_file then
            pcall(function() pipe_table.read_file:close() end)
            pipe_table.read_file = nil
        end
        if debug.print_to_log then
            DebugError("Pipe " .. pipe_table.name .. " garbage collected.")
        end
    end

    -- Attach garbage collection to a pipe table (Lua 5.1 workaround).
    function L.Attach_Pipe_Table_GC(pipe_table)
        local mt = {__gc = L.Pipe_Garbage_Collection_Handler}
        local proxy = newproxy(true)
        getmetatable(proxy).__gc = function() mt.__gc(pipe_table) end
        pipe_table[proxy] = true
        setmetatable(pipe_table, mt)
    end

    -- Declare a pipe’s initial state without opening it.
    function L.Declare_Pipe(pipe_name)
        if not pipes[pipe_name] then
            pipes[pipe_name] = {
                name = pipe_name,
                write_file = nil,
                read_file = nil,
                retry_allowed = false,
                suppress_reads_when_paused = false,
                write_fifo = FIFO.new(),
                read_fifo = FIFO.new(),
            }
            L.Attach_Pipe_Table_GC(pipes[pipe_name])
        end
    end

    -- Open or verify a pipe connection, supporting paired pipes.
    function L.Connect_Pipe(pipe_name)
        L.Declare_Pipe(pipe_name)
        local p = pipes[pipe_name]
        if not p.write_file or not p.read_file then
        if not winpipe then
            DebugError("Pipes.lua: winpipe DLL not loaded - check winpipe.lua")
            return false
        end

            -- Open write pipe (client-to-server).
            p.write_file = winpipe.open_pipe(L.pipe_path_prefix .. pipe_name .. "_in", "w")
            if not p.write_file then
                local err = winpipe.GetLastError()
                if debug.print_connect_errors then
                    DebugError(pipe_name .. "_in; open_pipe failed, error: " .. tostring(err))
                end
                if err == 5 and not L.pipe_access_denied then
                    L.pipe_access_denied = true
                    DebugError(pipe_name .. "_in; OS access denied")
                end
            end

            -- Open read pipe (server-to-client).
            p.read_file = winpipe.open_pipe(L.pipe_path_prefix .. pipe_name .. "_out", "r")
            if not p.read_file then
                local err = winpipe.GetLastError()
                if debug.print_connect_errors then
                    DebugError(pipe_name .. "_out; open_pipe failed, error: " .. tostring(err))
                end
                if err == 5 and not L.pipe_access_denied then
                    L.pipe_access_denied = true
                    DebugError(pipe_name .. "_out; OS access denied")
                end
            end

            -- Validate both pipes opened successfully.
            if not p.write_file or not p.read_file then
                p.write_file = nil
                p.read_file = nil
                error("Failed to open pipes for " .. pipe_name)
            end

            if debug.print_connect then
                CallEventScripts("directChatMessageReceived", pipe_name .. "; Pipes connected")
            end
            if debug.print_to_log then
                DebugError(pipe_name .. " connected")
            end
        else
            p.retry_allowed = true  -- Allow retry if already open.
        end
    end

    -- Close both pipe handles and signal disconnection.
    function L.Disconnect_Pipe(pipe_name)
        local p = pipes[pipe_name]
        if p.write_file then
            pcall(function() p.write_file:close() end)
            p.write_file = nil
        end
        if p.read_file then
            pcall(function() p.read_file:close() end)
            p.read_file = nil
        end
        Lib.Raise_Signal(pipe_name .. "_disconnected")
        if debug.print_connect_errors then
            CallEventScripts("directChatMessageReceived", pipe_name .. "; Pipes disconnected")
        end
        if debug.print_to_log then
            DebugError(pipe_name .. " disconnected")
        end
    end

    -- Fully close a pipe, clearing all state.
    function L.Close_Pipe(pipe_name)
        L.Disconnect_Pipe(pipe_name)
        L.Deschedule_Writes(pipe_name)
        L.Deschedule_Reads(pipe_name)
        pipes[pipe_name] = nil
    end

    -------------------------------------------------------------------------------
    -- Polling Functions

    -- Poll all pipes for pending reads.
    function L.Poll_For_Reads()
        if not L.read_polling_active then
            Time.Register_NewFrame_Callback(L.Poll_For_Reads)
            L.read_polling_active = true
            if debug.print_to_chat then
                CallEventScripts("directChatMessageReceived", "LUA; Registered Poll_For_Reads")
            end
        end

        local pending = false
        for name, state in pairs(pipes) do
            while not FIFO.Is_Empty(state.read_fifo) do
                local success, msg = L.Read_Pipe(name)
                if success then
                    if msg then
                        local cb, cont = unpack(FIFO.Next(state.read_fifo))
                        if not cont then FIFO.Read(state.read_fifo) end
                        if debug.print_to_chat then
                            CallEventScripts("directChatMessageReceived", name .. "; Read: " .. msg)
                        end
                        if not (state.suppress_reads_when_paused and C.IsGamePaused()) then
                            if type(cb) == "string" then
                                Lib.Raise_Signal('pipeRead_complete_' .. cb, msg)
                            elseif type(cb) == "function" then
                                cb(msg)
                            end
                        end
                    else
                        pending = true
                        break
                    end
                else
                    if debug.print_to_chat then
                        CallEventScripts("directChatMessageReceived", name .. "; Read error; closing")
                    end
                    if debug.print_to_log then
                        DebugError(name .. " read error: " .. msg)
                    end
                    L.Close_Pipe(name)
                    break
                end
            end
        end

        if not pending then
            Time.Unregister_NewFrame_Callback(L.Poll_For_Reads)
            L.read_polling_active = false
            if debug.print_to_chat then
                CallEventScripts("directChatMessageReceived", "LUA; Unregistered Poll_For_Reads")
            end
        end
    end

    -- Poll all pipes for pending writes.
    function L.Poll_For_Writes()
        if not L.write_polling_active then
            Time.Register_NewFrame_Callback(L.Poll_For_Writes)
            L.write_polling_active = true
            if debug.print_to_chat then
                CallEventScripts("directChatMessageReceived", "LUA; Registered Poll_For_Writes")
            end
        end

        local pending = false
        for name, state in pairs(pipes) do
            while not FIFO.Is_Empty(state.write_fifo) do
                local cb, msg = unpack(FIFO.Next(state.write_fifo))
                local success, ret = L.Write_Pipe(name, msg)
                if success then
                    if ret then
                        FIFO.Read(state.write_fifo)
                        if debug.print_to_chat then
                            CallEventScripts("directChatMessageReceived", name .. "; Wrote: " .. msg)
                        end
                        if debug.print_to_log then
                            DebugError(name .. " wrote: '" .. msg .. "'")
                        end
                        if type(cb) == "string" then
                            Lib.Raise_Signal('pipeWrite_complete_' .. cb, "SUCCESS")
                        elseif type(cb) == "function" then
                            cb("SUCCESS")
                        end
                    else
                        pending = true
                        break
                    end
                else
                    if debug.print_to_chat then
                        CallEventScripts("directChatMessageReceived", name .. "; Write error; closing")
                    end
                    L.Close_Pipe(name)
                    break
                end
            end
        end

        if not pending then
            Time.Unregister_NewFrame_Callback(L.Poll_For_Writes)
            L.write_polling_active = false
            if debug.print_to_chat then
                CallEventScripts("directChatMessageReceived", "LUA; Unregistered Poll_For_Writes")
            end
        end
    end

    -------------------------------------------------------------------------------
    -- Read/Write Operations

    -- Raw read from the read pipe.
    function L._Read_Pipe_Raw(pipe_name)
        L.Connect_Pipe(pipe_name)
        local val, err = pipes[pipe_name].read_file:read()
        if err then
            if winpipe.GetLastError() == winpipe.ERROR_NO_DATA then
                return nil
            else
                if debug.print_to_log then
                    DebugError(pipe_name .. "; read failed, error: " .. err)
                end
                error("read failed: " .. err)
            end
        end
        return val
    end

    -- Read with retry logic.
    function L.Read_Pipe(pipe_name)
        local success, msg = pcall(L._Read_Pipe_Raw, pipe_name)
        if not success then
            L.Disconnect_Pipe(pipe_name)
            if pipes[pipe_name].retry_allowed then
                if debug.print_to_chat then
                    CallEventScripts("directChatMessageReceived", pipe_name .. "; Retrying read...")
                end
                success, msg = pcall(L._Read_Pipe_Raw, pipe_name)
                if not success then L.Disconnect_Pipe(pipe_name) end
            end
        end
        return success, msg
    end

    -- Raw write to the write pipe.
    function L._Write_Pipe_Raw(pipe_name, message)
        L.Connect_Pipe(pipe_name)
        local bytes = pipes[pipe_name].write_file:write(message)
        if bytes == 0 then
            local err = winpipe.GetLastError()
            if debug.print_to_log then
                DebugError(pipe_name .. "; write failed, error code: " .. err)
            end
            error("write failed, error code: " .. err)
        end
        return true
    end

    -- Write with retry logic.
    function L.Write_Pipe(pipe_name, message)
        local success, ret = pcall(L._Write_Pipe_Raw, pipe_name, message)
        if not success then
            L.Disconnect_Pipe(pipe_name)
            if pipes[pipe_name].retry_allowed then
                if debug.print_to_chat then
                    CallEventScripts("directChatMessageReceived", pipe_name .. "; Retrying write...")
                end
                success, ret = pcall(L._Write_Pipe_Raw, pipe_name, message)
                if not success then L.Disconnect_Pipe(pipe_name) end
            end
        end
        return success, ret
    end

    -- Test connection and disconnection (uncomment to run).
    -- local function Test_Disconnect()
    --     local pipe_name = 'x4_python_host'
    --     DebugError("Testing Connect_Pipe")
    --     L.Connect_Pipe(pipe_name)
    --     DebugError("Testing Disconnect_Pipe")
    --     L.Disconnect_Pipe(pipe_name)
    -- end
    -- Test_Disconnect()

    return L
end)