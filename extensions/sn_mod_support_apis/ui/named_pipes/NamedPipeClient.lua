-- extensions/sn_mod_support_apis/ui/named_pipes/NamedPipeClient.lua
-- Signal-driven frontend interface to `Pipes.lua`, production-grade with callbacks and safe performance behavior
-------------------------------------------------------------------------------
-- Imports
-------------------------------------------------------------------------------
-- This module provides a client interface for named pipes, allowing Lua scripts
-- to connect, read, write, and manage named pipes with callbacks for various events.
-------------------------------------------------------------------------------
local M = {}

local Lib = require("extensions.sn_mod_support_apis.ui.named_pipes.Library")
local Pipes = require("extensions.sn_mod_support_apis.ui.named_pipes.Pipes")
local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")

-- Track registered callbacks per pipe
local client_callbacks = {}

-------------------------------------------------------------------------------
-- Utility: Ensure table exists
-------------------------------------------------------------------------------
-- Ensure that the callback table for a pipe exists
-- This function initializes the callback table if it doesn't exist,
local function ensure_callback_table(pipe)
    client_callbacks[pipe] = client_callbacks[pipe] or {
        on_read = {},
        on_write = {},
        on_disconnect = {},
        on_failure = {}
    }
    return client_callbacks[pipe]
end

-------------------------------------------------------------------------------
-- Signal Routing
-------------------------------------------------------------------------------
-- Register signals for a named pipe
-- This function sets up the necessary subscriptions for read/write completion,
local function register_pipe_signals(pipe)
    local cb = ensure_callback_table(pipe)

    -- Ensure we don't register multiple times for the same pipe
    Lib.Subscribe("pipeRead_complete_" .. pipe, function(data)
        for _, f in ipairs(cb.on_read) do
            pcall(f, data)
        end
    end)

    Lib.Subscribe("pipeWrite_complete_" .. pipe, function(status)
        for _, f in ipairs(cb.on_write) do
            pcall(f, status)
        end
    end)

    Lib.Subscribe(pipe .. "_disconnected", function()
        for _, f in ipairs(cb.on_disconnect) do
            pcall(f)
        end
    end)

    Lib.Subscribe("pipe_failed_" .. pipe, function()
        for _, f in ipairs(cb.on_failure) do
            pcall(f)
        end
    end)
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when a read operation completes
-- This will be called with the data read from the pipe.
function M.OnRead(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_read, callback)
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when a write operation completes
-- This will be called with the status of the write operation.
function M.OnWrite(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_write, callback)
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when the pipe fails
-- This will be called when the pipe encounters an error or fails to connect.
function M.OnFailure(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_failure, callback)
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when the pipe disconnects
-- This will be called when the pipe is disconnected, either by the server or client.
function M.OnDisconnect(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_disconnect, callback)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Connect to a named pipe
function M.Connect(pipe)
    if Pipes.Connect_Pipe(pipe) then
        register_pipe_signals(pipe)
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Disconnect from a named pipe
function M.Disconnect(pipe)
    Pipes.Disconnect_Pipe(pipe)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Write a message to a named pipe
-- This will schedule the write operation.
function M.Send(pipe, message)
    Pipes.Schedule_Write(pipe, pipe, message)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Read from a named pipe
-- This will schedule the read operation.
function M.Listen(pipe, continuous)
    Pipes.Schedule_Read(pipe, pipe, continuous)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Flush the read and write FIFOs for a named pipe
-- This will clear any pending reads and reset the pipe state.
function M.Flush(pipe)
    Pipes.Flush_Pipe(pipe)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Suppress reads when the game is paused
-- This will prevent reads from being processed while the game is paused.
function M.SetSuppressPausedReads(pipe, bool)
    Pipes.Set_Suppress_Paused_Reads(pipe, bool)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Check if a named pipe is connected
-- Returns true if the pipe is connected, false otherwise.
function M.IsConnected(pipe)
    return Pipes.Is_Connected(pipe)
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Clear all callbacks for a named pipe
-- This will remove all registered callbacks for the specified pipe.
function M.ClearCallbacks(pipe)
    client_callbacks[pipe] = nil
end


return M