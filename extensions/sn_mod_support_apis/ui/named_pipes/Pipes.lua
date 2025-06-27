-- extensions/sn_mod_support_apis/ui/named_pipes/Pipes.lua
-- This module implements core non-blocking named pipe functionality using a C FFI module (winpipe).
-- For client usage logic, see `NamedPipeClient.lua` (to be separated out).
Lua_Loader.define("extensions.sn_mod_support_apis.ui.named_pipes.Pipes", function(require)
    --[[
    named_pipes.Pipes
    =================
    Non-blocking, paired named-pipe support for X4 Foundations using overlapped I/O.
    -------------------------------------------------------------------------------
    Public API:
      Schedule_Read(pipe_name, callback_id, continuous)
      Schedule_Write(pipe_name, callback_id, message)
      Connect_Pipe(pipe_name)
      Disconnect_Pipe(pipe_name)
      Close_Pipe(pipe_name)
      Set_Suppress_Paused_Reads(pipe_name, bool)
      Flush_Pipe(pipe_name)
      Is_Connected(pipe_name)

    Internals:
      - Uses winpipe.open_pipe, winpipe.peek_pipe, file:read_pipe(), file:write_pipe()
      - Polls once per frame only while work remains.
      - Cleans up resources via a __gc proxy on each pipe state table.
    ]]

    ------------------------------------------------------------------------------
    -- Required dependencies
    ------------------------------------------------------------------------------
    local ffi = require("ffi")
    local socket = nil
    -- try-catch style workaround
    pcall(function() socket = require("socket") end)

    ffi.cdef [[ bool IsGamePaused(void); ]]

    local winpipe = require("extensions.sn_mod_support_apis.ui.c_library.winpipe")
    assert(winpipe and winpipe.open_pipe, "[Pipes] winpipe.open_pipe missing")

    local Lib = require("extensions.sn_mod_support_apis.ui.named_pipes.Library")
    local FIFO = Lib.FIFO
    local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")

    Lib.debug.print_to_log = true

    ------------------------------------------------------------------------------
    -- Pipe Manager Object
    ------------------------------------------------------------------------------
    local M = {
        prefix = "\\\\.\\pipe\\",
        pipes = {},
        _reading = false,
        _writing = false
    }

    ------------------------------------------------------------------------------
    -- Internal Helpers
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Internal helper: clean up both file handles on a pipe-state table
    -- --------------------------------------------------------------------------
    local function cleanup(p)
        if p.write_file then
            p.write_file:close_pipe()
        end
        if p.read_file then
            p.read_file:close_pipe()
        end
    end

    ------------------------------------------------------------------------------
    -- Internal Helpers
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Internal helper: attach a __gc handler to a table so cleanup runs on collect
    -- --------------------------------------------------------------------------
    local function attach_gc(p)
        local proxy = newproxy(true)
        getmetatable(proxy).__gc = function()
            cleanup(p)
        end
        p.gc_proxy = proxy
    end

    ------------------------------------------------------------------------------
    -- Pipe State Management
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Ensure state exists for named pipe; returns the table
    -- --------------------------------------------------------------------------
    function M.Declare_Pipe(name)
        local p = M.pipes[name]
        if not p then
            p = {
                name = name,
                write_file = nil,
                read_file = nil,
                suppress_reads_when_paused = false,
                read_fifo = FIFO.new(),
                write_fifo = FIFO.new(),
                failed_attempts = 0
            }
            attach_gc(p)
            M.pipes[name] = p
            DebugError("[Pipes] Created new pipe state for: " .. name) -- Debug: Log pipe state creation
        else
            DebugError("[Pipes] Retrieved existing pipe state for: " .. name) -- Debug: Log pipe state retrieval
        end
        return p
    end

    ------------------------------------------------------------------------------
    -- Public API Functions
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Open both ends of the pipe in overlapped (non-blocking) mode
    -- Returns true on success, errors on failure after retries
    -- --------------------------------------------------------------------------
    function M.Connect_Pipe(name)
        local p = M.Declare_Pipe(name)
        if p.write_file and p.read_file then
            DebugError("[Pipes] Connect_Pipe: Already connected for pipe: " .. name) -- Debug: Log already connected
            return true
        end

        local attempts = 3
        for i = 1, attempts do
            DebugError("[Pipes] Connect_Pipe: Attempt " .. i .. " for pipe: " .. name) -- Debug: Log connection attempt
            local wpath = M.prefix .. name .. "_in"
            local rpath = M.prefix .. name .. "_out"
            p.write_file = winpipe.open_pipe(wpath, "w")
            p.read_file = winpipe.open_pipe(rpath, "r")
            
            if p.write_file and p.read_file then
                DebugError("Connected pipe: " .. name)
                return true
            else
                if p.write_file then
                    p.write_file:close_pipe()
                end
                if p.read_file then
                    p.read_file:close_pipe()
                end
                if socket then 
                    socket.sleep(3)
                end
                DebugError("[Pipes] Connect_Pipe: Failed attempt " .. i .. " for pipe: " .. name) -- Debug: Log failed attempt
            end
        end

        Lib.Raise_Signal("pipe_failed_" .. name)
        DebugError("[Pipes] Connect_Pipe: Failed to connect pipe: " .. name .. " after " .. attempts .. " attempts") -- Debug: Log final failure
        return false
    end

    ------------------------------------------------------------------------------
    -- Public API Functions
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Close both handles and signal a disconnect event
    -- --------------------------------------------------------------------------
    function M.Disconnect_Pipe(name)
        local p = M.pipes[name]
        if not p then
            DebugError("[Pipes] Disconnect_Pipe: No pipe state found for: " .. name) -- Debug: Log missing pipe
            return
        end
        cleanup(p)
        p.write_file = nil
        p.read_file = nil
        Lib.Raise_Signal(name .. "_disconnected")
        DebugError("[Pipes] Disconnect_Pipe: Disconnected pipe: " .. name) -- Debug: Log disconnection
    end

    ------------------------------------------------------------------------------
    -- Public API Functions
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Fully remove and clean up the pipe state
    -- --------------------------------------------------------------------------
    function M.Close_Pipe(name)
        M.Disconnect_Pipe(name)
        M.pipes[name] = nil
        DebugError("[Pipes] Close_Pipe: Closed and removed pipe state for: " .. name) -- Debug: Log pipe closure
    end

    ------------------------------------------------------------------------------
    -- Public API Functions
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Check if a named pipe is connected
    -- Returns true if both read and write ends are available
    -- --------------------------------------------------------------------------
    function M.Is_Connected(name)
        local p = M.pipes[name]
        return p and p.write_file and p.read_file
    end

    ------------------------------------------------------------------------------
    -- Public API Functions
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Suppress reads when the game is paused
    -- --------------------------------------------------------------------------
    function M.Set_Suppress_Paused_Reads(name, bool)
        local p = M.Declare_Pipe(name)
        p.suppress_reads_when_paused = bool
        DebugError("[Pipes] Set_Suppress_Paused_Reads: Set suppress_reads_when_paused to " .. tostring(bool) .. " for pipe: " .. name) -- Debug: Log suppress setting
    end

    ------------------------------------------------------------------------------
    -- Public API Functions
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Flush the read and write FIFOs for a named pipe on demand
    -- This is useful to reset the state without disconnecting
    -- --------------------------------------------------------------------------           
    function M.Flush_Pipe(name)
        local p = M.pipes[name]
        if p then
            p.read_fifo = FIFO.new()
            p.write_fifo = FIFO.new()
            DebugError("[Pipes] Flush_Pipe: Fl Dyke read and write FIFOs for pipe: " .. name) -- Debug: Log FIFO flush
        end
    end

    ------------------------------------------------------------------------------
    -- IO Scheduling
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Schedule a read. Callback id is a string event suffix,
    -- continuous = boolean to auto‐requeue each frame if data remains.
    -- --------------------------------------------------------------------------
    function M.Schedule_Read(name, cb_id, continuous)
        local p = M.Declare_Pipe(name)
        FIFO.Write(p.read_fifo, {cb_id, continuous})
        DebugError("[Pipes] Schedule_Read: Scheduled read for pipe: " .. name .. ", callback: " .. cb_id .. ", continuous: " .. tostring(continuous)) -- Debug: Log read scheduling
        if not p.read_file then
            M.Connect_Pipe(name)
        end
        M.Poll_For_Reads()
    end

    ------------------------------------------------------------------------------
    -- IO Scheduling
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Public: Schedule a write. Callback id + message string.
    -- --------------------------------------------------------------------------
    function M.Schedule_Write(name, cb_id, msg)
        local p = M.Declare_Pipe(name)
        FIFO.Write(p.write_fifo, {cb_id, msg})
        DebugError("[Pipes] Schedule_Write: Scheduled write for pipe: " .. name .. ", callback: " .. cb_id .. ", message: " .. tostring(msg)) -- Debug: Log write scheduling
        if not p.write_file then
            M.Connect_Pipe(name)
        end
        M.Poll_For_Writes()
    end

    ------------------------------------------------------------------------------
    -- Frame-Driven Polling
    ------------------------------------------------------------------------------
    -- --------------------------------------------------------------------------
    -- Internal: per-frame, non-blocking read pump
    -- --------------------------------------------------------------------------
    function M.Poll_For_Reads()
        if M._reading then
            return
        end
        M._reading = true
        DebugError("[Pipes] Poll_For_Reads: Started read polling") -- Debug: Log start of read polling

        Time.Register_NewFrame_Callback(function()
            local more = false
            for name, p in pairs(M.pipes) do
                if p.suppress_reads_when_paused and ffi.C.IsGamePaused() then
                    DebugError("[Pipes] Poll_For_Reads: Skipping read for pipe: " .. name .. " due to game pause") -- Debug: Log pause skip
                    goto continue
                end
                if not p.read_file then
                    DebugError("[Pipes] Poll_For_Reads: No read file handle for pipe: " .. name) -- Debug: Log missing read handle
                    goto continue
                end

                while not FIFO.Is_Empty(p.read_fifo) do
                    local cb_id, continuous = unpack(FIFO.Next(p.read_fifo))
                    DebugError("[Pipes] Poll_For_Reads: Processing read for pipe: " .. name .. ", callback: " .. cb_id .. ", continuous: " .. tostring(continuous)) -- Debug: Log read processing
                    local ok, avail = pcall(function()
                        return p.read_file:peek_pipe()
                    end)
                    if not ok or avail == 0 then
                        DebugError("[Pipes] Poll_For_Reads: No data available or error for pipe: " .. name .. ", callback: " .. cb_id) -- Debug: Log no data or error
                        if not continuous then
                            FIFO.Read(p.read_fifo)
                        end
                        more = more or continuous
                        break
                    end

                    local data, err = p.read_file:read_pipe()
                    if data then
                        FIFO.Read(p.read_fifo)
                        Lib.Raise_Signal("pipeRead_complete_" .. cb_id, data)
                        DebugError("[Pipes] Poll_For_Reads: Read successful for pipe: " .. name .. ", callback: " .. cb_id .. ", data: " .. tostring(data)) -- Debug: Log successful read
                        more = more or continuous
                    else
                        Lib.Raise_Signal("pipe_failed_" .. name)
                        DebugError("[Pipes] Poll_For_Reads: Read failed for pipe: " .. name .. ", error: " .. tostring(err)) -- Debug: Log read failure
                        break
                    end
                end
                ::continue::
            end

            if not more then
                Time.Unregister_NewFrame_Callback(M.Poll_For_Reads)
                M._reading = false
                DebugError("[Pipes] Poll_For_Reads: Stopped read polling") -- Debug: Log end of read polling
            end
        end)
    end

    ------------------------------------------------------------------------------
    -- Frame-Driven Polling
    ------------------------------------------------------------------------------  
    -- --------------------------------------------------------------------------
    -- Internal: per-frame, non-blocking write pump
    -- --------------------------------------------------------------------------
    function M.Poll_For_Writes()
        if M._writing then
            return
        end
        M._writing = true
        DebugError("[Pipes] Poll_For_Writes: Started write polling") -- Debug: Log start of write polling

        Time.Register_NewFrame_Callback(function()
            local more = false
            for name, p in pairs(M.pipes) do
                if not p.write_file then
                    DebugError("[Pipes] Poll_For_Writes: No write file handle for pipe: " .. name) -- Debug: Log missing write handle
                    goto continue
                end
                while not FIFO.Is_Empty(p.write_fifo) do
                    local cb_id, msg = unpack(FIFO.Next(p.write_fifo))
                    DebugError("[Pipes] Poll_For_Writes: Processing write for pipe: " .. name .. ", callback: " .. cb_id .. ", message: " .. tostring(msg)) -- Debug: Log write processing
                    local ok, err = p.write_file:write_pipe(msg)

                    if ok then
                        FIFO.Read(p.write_fifo)
                        Lib.Raise_Signal("pipeWrite_complete_" .. cb_id, "SUCCESS")
                        DebugError("[Pipes] Poll_For_Writes: Write successful for pipe: " .. name .. ", callback: " .. cb_id) -- Debug: Log successful write
                        more = more or (#p.write_fifo > 0)
                    elseif err == winpipe.ERROR_NO_DATA then
                        DebugError("[Pipes] Poll_For_Writes: No data written for pipe: " .. name .. ", callback: " .. cb_id .. ", retrying") -- Debug: Log no data written
                        more = true
                        break
                    else
                        Lib.Raise_Signal("pipe_failed_" .. name)
                        DebugError("[Pipes] Poll_For_Writes: Write failed for pipe: " .. name .. ", callback: " .. cb_id .. ", error: " .. tostring(err)) -- Debug: Log write failure
                        break
                    end
                end
                ::continue::
            end

            if not more then
                Time.Unregister_NewFrame_Callback(M.Poll_For_Writes)
                M._writing = false
                DebugError("[Pipes] Poll_For_Writes: Stopped write polling") -- Debug: Log end of write polling
            end
        end)
    end

    -- Return the public API
    return M
end)