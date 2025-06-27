-- extensions/sn_mod_support_apis/ui/named_pipes/NamedPipeClient.lua
-- Signal-driven frontend interface to `Pipes.lua`, production-grade with callbacks and safe performance behavior
-------------------------------------------------------------------------------
-- Imports
-------------------------------------------------------------------------------
-- This module provides a client interface for named pipes, allowing Lua scripts
-- to connect, read, write, and manage named pipes with callbacks for various events.
-------------------------------------------------------------------------------
local M = {}

isDebug = false -- Set to true for debug messages, false for production

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
    if isDebug then DebugError("[NamedPipeClient] ensure_callback_table: Initialized or retrieved callback table for pipe: " .. tostring(pipe)) end -- Debug: Log callback table initialization
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
        if isDebug then DebugError("[NamedPipeClient] register_pipe_signals: Read complete for pipe: " .. tostring(pipe) .. ", data: " .. tostring(data)) end -- Debug: Log read complete signal
        for _, f in ipairs(cb.on_read) do
            pcall(f, data)
        end
    end)

    Lib.Subscribe("pipeWrite_complete_" .. pipe, function(status)
        if isDebug then DebugError("[NamedPipeClient] register_pipe_signals: Write complete for pipe: " .. tostring(pipe) .. ", status: " .. tostring(status)) end -- Debug: Log write complete signal
        for _, f in ipairs(cb.on_write) do
            pcall(f, status)
        end
    end)

    Lib.Subscribe(pipe .. "_disconnected", function()
        if isDebug then DebugError("[NamedPipeClient] register_pipe_signals: Disconnect signal for pipe: " .. tostring(pipe)) end -- Debug: Log disconnect signal
        for _, f in ipairs(cb.on_disconnect) do
            pcall(f)
        end
    end)

    Lib.Subscribe("pipe_failed_" .. pipe, function()
        if isDebug then DebugError("[NamedPipeClient] register_pipe_signals: Failure signal for pipe: " .. tostring(pipe)) end -- Debug: Log failure signal
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
    if isDebug then DebugError("[NamedPipeClient] OnRead: Registered read callback for pipe: " .. tostring(pipe)) end -- Debug: Log read callback registration
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when a write operation completes
-- This will be called with the status of the write operation.
function M.OnWrite(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_write, callback)
    if isDebug then DebugError("[NamedPipeClient] OnWrite: Registered write callback for pipe: " .. tostring(pipe)) end -- Debug: Log write callback registration
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when the pipe fails
-- This will be called when the pipe encounters an error or fails to connect.
function M.OnFailure(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_failure, callback)
    if isDebug then DebugError("[NamedPipeClient] OnFailure: Registered failure callback for pipe: " .. tostring(pipe)) end -- Debug: Log failure callback registration
end

-------------------------------------------------------------------------------
-- Public API: Register Callbacks
-------------------------------------------------------------------------------
-- Register a callback for when the pipe disconnects
-- This will be called when the pipe is disconnected, either by the server or client.
function M.OnDisconnect(pipe, callback)
    local cb = ensure_callback_table(pipe)
    table.insert(cb.on_disconnect, callback)
    if isDebug then DebugError("[NamedPipeClient] OnDisconnect: Registered disconnect callback for pipe: " .. tostring(pipe)) end -- Debug: Log disconnect callback registration
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Connect to a named pipe
function M.Connect(pipe)
    local success = Pipes.Connect_Pipe(pipe)
    if success then
        register_pipe_signals(pipe)
        if isDebug then DebugError("[NamedPipeClient] Connect: Successfully connected to pipe: " .. tostring(pipe)) end -- Debug: Log successful connection
        return true
    end
    if isDebug then DebugError("[NamedPipeClient] Connect: Failed to connect to pipe: " .. tostring(pipe)) end -- Debug: Log connection failure
    return false
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Disconnect from a named pipe
function M.Disconnect(pipe)
    Pipes.Disconnect_Pipe(pipe)
    if isDebug then DebugError("[NamedPipeClient] Disconnect: Disconnected pipe: " .. tostring(pipe)) end -- Debug: Log disconnection
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Write a message to a named pipe
-- This will schedule the write operation.
function M.Send(pipe, message)
    Pipes.Schedule_Write(pipe, pipe, message)
    if isDebug then DebugError("[NamedPipeClient] Send: Scheduled write for pipe: " .. tostring(pipe) .. ", message: " .. tostring(message)) end -- Debug: Log write scheduling
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Read from a named pipe
-- This will schedule the read operation.
function M.Listen(pipe, continuous)
    Pipes.Schedule_Read(pipe, pipe, continuous)
    if isDebug then DebugError("[NamedPipeClient] Listen: Scheduled read for pipe: " .. tostring(pipe) .. ", continuous: " .. tostring(continuous)) end -- Debug: Log read scheduling
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Flush the read and write FIFOs for a named pipe
-- This will clear any pending reads and reset the pipe state.
function M.Flush(pipe)
    Pipes.Flush_Pipe(pipe)
    if isDebug then DebugError("[NamedPipeClient] Flush: Flushed read and write FIFOs for pipe: " .. tostring(pipe)) end -- Debug: Log FIFO flush
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Suppress reads when the game is paused
-- This will prevent reads from being processed while the game is paused.
function M.SetSuppressPausedReads(pipe, bool)
    Pipes.Set_Suppress_Paused_Reads(pipe, bool)
    if isDebug then DebugError("[NamedPipeClient] SetSuppressPausedReads: Set suppress paused reads to " .. tostring(bool) .. " for pipe: " .. tostring(pipe)) end -- Debug: Log suppress setting
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Check if a named pipe is connected
-- Returns true if the pipe is connected, false otherwise.
function M.IsConnected(pipe)
    local connected = Pipes.Is_Connected(pipe)
    if isDebug then DebugError("[NamedPipeClient] IsConnected: Pipe " .. tostring(pipe) .. " connected: " .. tostring(connected)) end -- Debug: Log connection status
    return connected
end

-------------------------------------------------------------------------------
-- Public API: Pipe Usage
-------------------------------------------------------------------------------
-- Clear all callbacks for a named pipe
-- This will remove all registered callbacks for the specified pipe.
function M.ClearCallbacks(pipe)
    client_callbacks[pipe] = nil
    if isDebug then DebugError("[NamedPipeClient] ClearCallbacks: Cleared all callbacks for pipe: " .. tostring(pipe)) end -- Debug: Log callback clearing
end

return M