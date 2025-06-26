-- extensions/sn_mod_support_apis/ui/named_pipes/Pipes.lua
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

    Internals:
      - Uses winpipe.open_pipe, winpipe.peek_pipe, file:read_pipe(), file:write_pipe()
      - Polls once per frame only while work remains.
      - Cleans up resources via a __gc proxy on each pipe state table.
    ]]

    local ffi = require("ffi")
    ffi.cdef [[ bool IsGamePaused(void); ]]

    -- Load our compiled C binding; must export luaopen_winpipe
    local winpipe = require("extensions.sn_mod_support_apis.ui.c_library.winpipe")
    assert(winpipe and winpipe.open_pipe, "[Pipes] winpipe.open_pipe missing")

    local Lib = require("extensions.sn_mod_support_apis.ui.named_pipes.Library")
    local FIFO = Lib.FIFO
    Lib.debug.print_to_log = true

    local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")

    -- Module table
    local M = {
        prefix = "\\\\.\\pipe\\",
        pipes = {}, -- [pipe_name] = { write_file, read_file, ... }
        _reading = false, -- guard for frame callback
        _writing = false
    }

    -- --------------------------------------------------------------------------
    -- Internal: clean up both file handles on a pipe-state table
    -- --------------------------------------------------------------------------
    local function cleanup(p)
        if p.write_file then
            if Lib.debug.print_to_log then DebugError("Closing write pipe for " .. p.name) end
            p.write_file:close_pipe()
        end
        if p.read_file then
            if Lib.debug.print_to_log then DebugError("Closing read pipe for " .. p.name) end
            p.read_file:close_pipe()
        end
    end

    -- --------------------------------------------------------------------------
    -- Internal: attach a __gc handler to a table so cleanup runs on collect
    -- --------------------------------------------------------------------------
    local function attach_gc(p)
        local proxy = newproxy(true)
        getmetatable(proxy).__gc = function()
            cleanup(p)
        end
        p.gc_proxy = proxy -- Keep reference to ensure GC works
    end

    -- --------------------------------------------------------------------------
    -- Ensure state exists for named pipe; returns the table
    -- --------------------------------------------------------------------------
    function M.Declare_Pipe(name)
        local p = M.pipes[name]
        if type(p) ~= "table" or not p.read_fifo or not p.write_fifo then
            p = {
                name = name, -- Store name for logging
                write_file = nil, -- WinPipe.File userdata
                read_file = nil, -- WinPipe.File userdata
                suppress_reads_when_paused = false,
                read_fifo = FIFO.new(),
                write_fifo = FIFO.new()
            }
            attach_gc(p)
            M.pipes[name] = p
        end
        return p
    end

    -- --------------------------------------------------------------------------
    -- Public: Open both ends of the pipe in overlapped (non-blocking) mode
    -- Returns true on success, errors on failure after retries
    -- --------------------------------------------------------------------------
    function M.Connect_Pipe(name)
        local p = M.Declare_Pipe(name)
        if p.write_file and p.read_file then
            return true
        end

        local max_attempts = 3
        local delay = 1 -- seconds
        local attempt_counter = 0
        for attempt = 0, max_attempts, 1 do
            attempt_counter = attempt_counter + 1
            if Lib.debug.print_to_log then DebugError(("Attempt %d to open pipes for '%s'"):format(attempt_counter, name)) end
            local pipe_write = winpipe.open_pipe(M.prefix .. name .. "_in", "w")
            local pipe_read = winpipe.open_pipe(M.prefix .. name .. "_out", "r")
            if Lib.debug.print_to_log then DebugError(("Client tried open pipes for '%s': write='%s', read='%s'"):format(name, pipe_write and pipe_write.name or "nil", pipe_read and pipe_read.name or "nil")) end

            if pipe_write and pipe_read then
                p.write_file = pipe_write.write_file
                p.read_file = pipe_read.read_file
                if Lib.debug.print_to_log then DebugError(("Named_Pipes: pipe '%s' connected (non-blocking)"):format(name)) end
            else
                if pipe_write then pipe_write:close() end
                if pipe_read then pipe_read:close() end
                if attempt_counter < max_attempts then
                    if Lib.debug.print_to_log then DebugError(("Retrying in %d seconds..."):format(delay)) end
                    os.execute("ping 127.0.0.1 -n " .. delay + 1 .. " >nul") -- Sleep for delay seconds
                else
                    error(("Named_Pipes: failed to open both ends for '%s' after %d attempts"):format(name, max_attempts), 2)
                end
            end
        end
    end

    -- --------------------------------------------------------------------------
    -- Public: Close both handles and signal a disconnect event
    -- --------------------------------------------------------------------------
    function M.Disconnect_Pipe(name)
        local p = M.pipes[name]
        if not p then
            return
        end

        cleanup(p)
        p.write_file = nil
        p.read_file = nil

        Lib.Raise_Signal(name .. "_disconnected")
        if Lib.debug.print_to_log then DebugError(name .. " disconnected") end
    end

    -- --------------------------------------------------------------------------
    -- Public: Fully remove and clean up the pipe state
    -- --------------------------------------------------------------------------
    function M.Close_Pipe(name)
        M.Disconnect_Pipe(name)
        M.pipes[name] = nil
    end

    -- --------------------------------------------------------------------------
    -- Public: Schedule a read. Callback id is a string event suffix,
    -- continuous = boolean to auto‐requeue each frame if data remains.
    -- --------------------------------------------------------------------------
    function M.Schedule_Read(name, callback_id, continuous)
        local p = M.Declare_Pipe(name)
        FIFO.Write(p.read_fifo, {callback_id, continuous})
        pcall(M.Connect_Pipe, name)
        M.Poll_For_Reads()
    end

    -- --------------------------------------------------------------------------
    -- Public: Schedule a write. Callback id + message string.
    -- --------------------------------------------------------------------------
    function M.Schedule_Write(name, callback_id, message)
        local p = M.Declare_Pipe(name)
        FIFO.Write(p.write_fifo, {callback_id, message})
        pcall(M.Connect_Pipe, name)
        M.Poll_For_Writes()
    end

    -- --------------------------------------------------------------------------
    -- Internal: per-frame, non-blocking read pump
    -- --------------------------------------------------------------------------
    function M.Poll_For_Reads()
        if M._reading then
            return
        end
        M._reading = true

        Time.Register_NewFrame_Callback(function()
            local more = false

            for name, p in pairs(M.pipes) do
                if p.suppress_reads_when_paused and ffi.C.IsGamePaused() then
                    goto continue
                end

                while not FIFO.Is_Empty(p.read_fifo) do
                    local cb_id, continuous = unpack(FIFO.Next(p.read_fifo))

                    -- peek bytes
                    local avail = p.read_file and p.read_file:peek_pipe() or 0
                    if avail == 0 then
                        more = more or continuous
                        break
                    end

                    -- do the actual read
                    local data, err = p.read_file:read_pipe()
                    if data then
                        FIFO.Read(p.read_fifo)
                        Lib.Raise_Signal("pipeRead_complete_" .. cb_id, data)
                        more = more or continuous
                    else
                        if Lib.debug.print_to_log then DebugError(name .. " read error: " .. tostring(err)) end
                        if err == "pipe broken" or err == 109 or err == 233 then
                            if Lib.debug.print_to_log then DebugError(name .. " pipe closed, attempting to reconnect") end
                            M.Disconnect_Pipe(name)
                            pcall(M.Connect_Pipe, name)
                        end
                        break
                    end
                end

                ::continue::
            end

            if not more then
                Time.Unregister_NewFrame_Callback(M.Poll_For_Reads)
                M._reading = false
            end
        end)
    end

    -- --------------------------------------------------------------------------
    -- Internal: per-frame, non-blocking write pump
    -- --------------------------------------------------------------------------
    function M.Poll_For_Writes()
        if M._writing then
            return
        end
        M._writing = true

        Time.Register_NewFrame_Callback(function()
            local more = false

            for name, p in pairs(M.pipes) do
                while not FIFO.Is_Empty(p.write_fifo) do
                    local cb_id, msg = unpack(FIFO.Next(p.write_fifo))
                    local ok, err = p.write_file:write_pipe(msg)

                   if ok then
                        FIFO.Read(p.write_fifo)
                        Lib.Raise_Signal("pipeWrite_complete_" .. cb_id, "SUCCESS")
                        more = more or (#p.write_fifo > 0)
                    elseif err == winpipe.ERROR_NO_DATA then
                        more = true
                        break
                    else
                        if Lib.debug.print_to_log then DebugError(name .. " write error: " .. tostring(err)) end
                        if err == "pipe broken" or err == 109 or err == 233 then
                            if Lib.debug.print_to_log then DebugError(name .. " pipe closed, attempting to reconnect") end
                            M.Disconnect_Pipe(name)
                            pcall(M.Connect_Pipe, name)
                        end
                        break
                    end
                end
            end

            if not more then
                Time.Unregister_NewFrame_Callback(M.Poll_For_Writes)
                M._writing = false
            end
        end)
    end

    -- --------------------------------------------------------------------------
    -- Public: Suppress reads when the game is paused
    -- --------------------------------------------------------------------------
    function M.Set_Suppress_Paused_Reads(name, state)
        M.Declare_Pipe(name).suppress_reads_when_paused = state
    end

    -- Return only the public API
    return {
        Schedule_Read = M.Schedule_Read,
        Schedule_Write = M.Schedule_Write,
        Connect_Pipe = M.Connect_Pipe,
        Disconnect_Pipe = M.Disconnect_Pipe,
        Close_Pipe = M.Close_Pipe,
        Set_Suppress_Paused_Reads = M.Set_Suppress_Paused_Reads
    }
end)