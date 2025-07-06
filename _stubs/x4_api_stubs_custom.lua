---@diagnostic disable: undefined-global, lowercase-global

--- Logs an error message to the in-game debug console and log file.
--- Use this to surface runtime errors or unexpected states.
---@param message string  -- text of the error to display
function DebugError(message) end

--- Converts a decimal string into a 64-bit integer.
--- Useful when you need the numeric EntityID from C.GetPlayerID(), which returns a string.
---@param str string    -- decimal string representation of a 64-bit number
---@return integer      -- the parsed 64-bit integer value
function ConvertStringTo64Bit(str) 
	return 0
end

--- Subscribes to a UI control event; when the player interacts with `controlname` on `screenname`,
--- the specified Lua event is raised with `param` as its payload.
---@param screenname string  -- identifier of the UI screen (e.g. "HUD", "StationMenu")
---@param controlname string -- name of the control element (e.g. "ButtonOK", "SliderVolume")
---@param param     any      -- optional data passed through to the event handler
function AddUITriggeredEvent(screenname, controlname, param) end

--- Retrieves a value (or table) previously stored on an NPC’s “blackboard.”
---
---@param entityID integer  -- 64-bit EntityID of the NPC or ship  
---@param key     string    -- the name of the slot set with SetNPCBlackboard  
---@return any             -- whatever pushed there (number/string/table), or nil if unset  
function GetNPCBlackboard(entityID, key) end

--- Stores a value (any Lua type) on an NPC’s blackboard under `key`.  
--- Passing `nil` will erase that entry.  
---
---@param entityID integer  -- 64-bit EntityID of the NPC or ship  
---@param key     string    -- the slot name to write to  
---@param value   any       -- any Lua value (table, number, string, etc.), or nil to clear  
function SetNPCBlackboard(entityID, key, value) end