Lua_Loader.define("extensions.sn_mod_support_apis.ui.Library",function(require)
--[[
Library functions to be shared across apis.

TODO:
    - Convenience table of stock menus, keyed by name.
]]

-- Table to hold lib functions.
local L = {}

-- Retrieve a vanilla game menu by name.
function L.Get_Egosoft_Menu(name)
    DebugError("[Library] Get_Egosoft_Menu: Looking for menu: " .. tostring(name)) -- Debug: Log menu lookup
    -- These are stored in a global list.
    if Menus == nil then
        DebugError("[Library] Get_Egosoft_Menu: Menus global not initialized") -- Debug: Log Menus global error
        error("Menus global not yet initialized")
    end
    -- Search the list for the name.
    for i, ego_menu in ipairs(Menus) do
        if ego_menu.name == name then
            DebugError("[Library] Get_Egosoft_Menu: Found menu: " .. tostring(name)) -- Debug: Log menu found
            return ego_menu
        end
    end
    
    -- Something went wrong.
    DebugError("[Library] Get_Egosoft_Menu: Failed to find menu: " .. tostring(name)) -- Debug: Log menu not found
    error("Failed to find egosoft menu with name "..tostring(name))
end

-- Table of lua's pattern characters that have special meaning.
-- These need to be escaped for string.find.
-- Can check a separator based on table key; values are dummies.
local lua_pattern_special_chars = {
    ["("]=0, [")"]=0, ["."]=0, ["%"]=0, ["+"]=0, ["-"]=0, 
    ["*"]=0, ["?"]=0, ["["]=0, ["^"]=0, ["$"]=0,
}

-- Split a string on the first separator.
-- Note: works on the MD passed arrays of characters.
-- Returns two substrings, left and right of the sep.
function L.Split_String(this_string, separator)
    DebugError("[Library] Split_String: Splitting string: " .. tostring(this_string) .. ", separator: " .. tostring(separator)) -- Debug: Log split attempt
    -- Get the position of the separator.
    -- Warning: lua is kinda dumb and has its own patterning rules, which
    -- came up with '.' matched anything.
    -- Need to escape with "%" in these cases, though can't use it for
    -- alphanumeric (else it can become some other special code).
    if lua_pattern_special_chars[separator] then
        separator = "%" .. separator
        DebugError("[Library] Split_String: Escaped separator to: " .. tostring(separator)) -- Debug: Log escaped separator
    end
   
    local position = string.find(this_string, separator)
    if position == nil then
        DebugError("[Library] Split_String: No separator found in string: " .. tostring(this_string)) -- Debug: Log separator not found
        error("Bad separator")
    end

    -- Split into pre- and post- separator strings.
    -- TODO: should start point be at 1?  0 seems to work fine.
    local left  = string.sub(this_string, 0, position -1)
    local right = string.sub(this_string, position +1)
    DebugError("[Library] Split_String: Split result - left: " .. tostring(left) .. ", right: " .. tostring(right)) -- Debug: Log split result
    return left, right
end

-- Split a string as many times as possible.
-- Returns a list of substrings.
function L.Split_String_Multi(this_string, separator)
    DebugError("[Library] Split_String_Multi: Splitting string: " .. tostring(this_string) .. ", separator: " .. tostring(separator)) -- Debug: Log multi-split attempt
    substrings = {}
    
    -- Early return for empty string.
    if this_string == "" then
        DebugError("[Library] Split_String_Multi: Empty string, returning empty table") -- Debug: Log empty string case
        return substrings
    end
    
    -- Use Split_String to iteratively break apart the args in a loop.
    local remainder = this_string
    local left, right
    
    -- Loop until Split_String fails to find the separator.
    local success = true
    while success do
        DebugError("[Library] Split_String_Multi: Processing remainder: " .. tostring(remainder)) -- Debug: Log current remainder
        -- pcall will error and set sucess=false if no separators remaining.
        success, left, right = pcall(L.Split_String, remainder, separator)
        
        -- On success, the next substring is in left.
        -- On failure, the final substring is still in remainder.
        local substring
        if success then
            substring = left
            remainder = right
            DebugError("[Library] Split_String_Multi: Split success, substring: " .. tostring(substring) .. ", new remainder: " .. tostring(remainder)) -- Debug: Log successful split
        else
            substring = remainder
            DebugError("[Library] Split_String_Multi: No more separators, final substring: " .. tostring(substring)) -- Debug: Log final substring
        end
        
        -- Add to the running list.
        table.insert(substrings, substring)
        DebugError("[Library] Split_String_Multi: Added substring: " .. tostring(substring) .. ", current substrings count: " .. tostring(#substrings)) -- Debug: Log substring addition
    end
    DebugError("[Library] Split_String_Multi: Completed, returning " .. tostring(#substrings) .. " substrings") -- Debug: Log completion
    return substrings
end

-- Take an arg string and convert to a table.
function L.Tabulate_Args(arg_string)
    DebugError("[Library] Tabulate_Args: Converting arg string: " .. tostring(arg_string)) -- Debug: Log arg string conversion
    local args = {}    
    -- Start with a full split on semicolons.
    local named_args = L.Split_String_Multi(arg_string, ";")
    DebugError("[Library] Tabulate_Args: Split into " .. tostring(#named_args) .. " named args") -- Debug: Log named args split
    -- Loop over each named arg.
    for i = 1, #named_args do
        -- Split the named arg on comma.
        local key, value = L.Split_String(named_args[i], ",")
        DebugError("[Library] Tabulate_Args: Split named arg " .. tostring(named_args[i]) .. " into key: " .. tostring(key) .. ", value: " .. tostring(value)) -- Debug: Log key-value split
        -- Keys have a prefixed $ due to md dumbness; remove it here.
        key = string.sub(key, 2, -1)
        args[key] = value
        DebugError("[Library] Tabulate_Args: Added key: " .. tostring(key) .. ", value: " .. tostring(value) .. " to args table") -- Debug: Log args table addition
    end
    DebugError("[Library] Tabulate_Args: Completed, returning args table with " .. tostring(#named_args) .. " entries") -- Debug: Log completion
    return args    
end

-- Function to remove $ prefixes from MD keys.
-- Recursively calls itself for subtables.
-- Note: not always needed, depending on how data was passed.
function L.Clean_MD_Keys( in_table )
    DebugError("[Library] Clean_MD_Keys: Processing table") -- Debug: Log table processing start
    -- Loop over table entries.
    for key, value in pairs(in_table) do
        -- Slice the key, starting at 2nd character to end.
        local new_key = string.sub(key, 2, -1)
        DebugError("[Library] Clean_MD_Keys: Changing key " .. tostring(key) .. " to " .. tostring(new_key)) -- Debug: Log key change
        -- Delete old, replace with new.
        in_table[key] = nil
        in_table[new_key] = value
        
        -- If the value is a table as well, give it the same treatment.
        if type(value) == "table" then
            DebugError("[Library] Clean_MD_Keys: Recursively processing subtable for key: " .. tostring(new_key)) -- Debug: Log subtable recursion
            L.Clean_MD_Keys(value)
        end
    end
    DebugError("[Library] Clean_MD_Keys: Completed table processing") -- Debug: Log completion
end

-- Update the left table with contents of the right one, overwriting
-- when needed. Any subtables are similarly updated (not directly
-- overwritten). Tables in right should always match to tables or nil in left.
-- Returns early if right side is nil.
function L.Table_Update(left, right)
    DebugError("[Library] Table_Update: Updating left table with right table") -- Debug: Log update start
    -- Similar to above, but with blind overwrites.
    if not right then 
        DebugError("[Library] Table_Update: Right table is nil, returning") -- Debug: Log nil right table
        return 
    end
    for k, v in pairs(right) do
        -- Check for left having a table (right should as well).
        if type(left[k]) == "table" then
            -- Error if right is not a table or nil.
            if type(v) ~= "table" then
                DebugError("Table_Update table type mismatch at "..tostring(k))
            end
            DebugError("[Library] Table_Update: Recursively updating subtable for key: " .. tostring(k)) -- Debug: Log subtable update
            L.Table_Update(left[k], v)
        else
            -- Direct write (maybe overwrite).
            left[k] = v
            DebugError("[Library] Table_Update: Set key: " .. tostring(k) .. ", value: " .. tostring(v)) -- Debug: Log key-value update
        end
    end
    DebugError("[Library] Table_Update: Completed table update") -- Debug: Log completion
end

-- Print a table's contents to the log.
-- Optionally give the table a name.
-- TODO: maybe recursive.
-- Note: in practice, DebugError is limited to 8192 characters, so this
-- will try to break up long prints.
function L.Print_Table(itable, name)
    if not name then name = "" end
    DebugError("[Library] Print_Table: Printing table: " .. tostring(name)) -- Debug: Log table printing start
    -- Construct a string with newlines between table entries.
    -- Start with header.
    local str = "Table "..name.." contents:\n"
    local line

    for k,v in pairs(itable) do
        line = "["..k.."] = "..tostring(v).." ("..type(v)..")\n"
        DebugError("[Library] Print_Table: Adding entry - key: " .. tostring(k) .. ", value: " .. tostring(v) .. ", type: " .. tostring(type(v))) -- Debug: Log table entry
        -- If this line will put the str over 8192, do an early str dump
        -- first.
        if #line + #str >= 8192 then
            DebugError(str)
            DebugError("[Library] Print_Table: Dumped partial table string due to size limit") -- Debug: Log partial string dump
            -- Restart the str.
            str = line
        else
            -- Append to running str.
            str = str .. line
        end
    end
    DebugError(str)
    DebugError("[Library] Print_Table: Completed printing table: " .. tostring(name)) -- Debug: Log completion
end

-- Chained table lookup, using a series of key names.
-- If any key fails, returns nil.
-- 'itable' is the top level table.
-- 'keys' is a list of string or int keys, processed from index 0 up.
-- If keys is empty, the itable is returned.
function L.Multilevel_Table_Lookup(itable, keys)
    DebugError("[Library] Multilevel_Table_Lookup: Looking up table with keys: " .. tostring(table.concat(keys or {}, ","))) -- Debug: Log lookup start
    if #keys == 0 then
        DebugError("[Library] Multilevel_Table_Lookup: Empty keys, returning input table") -- Debug: Log empty keys case
        return itable
    end
    local temp = itable
    for i = 1, #keys do
        -- Dig in one level.
        temp = temp[keys[i]]
        DebugError("[Library] Multilevel_Table_Lookup: Key " .. tostring(keys[i]) .. " result: " .. tostring(temp)) -- Debug: Log key lookup
        -- If nil, quick return.
        if temp == nil then
            DebugError("[Library] Multilevel_Table_Lookup: Key " .. tostring(keys[i]) .. " not found, returning nil") -- Debug: Log lookup failure
            return nil
        end
    end
    DebugError("[Library] Multilevel_Table_Lookup: Lookup successful, returning: " .. tostring(temp)) -- Debug: Log successful lookup
    return temp
end

-- Function to take a slice of a list (table ordered from 1 and up).
function L.Slice_List(itable, start, stop)
    DebugError("[Library] Slice_List: Slicing list from " .. tostring(start) .. " to " .. tostring(stop)) -- Debug: Log slice attempt
    local otable = {}
    for i = start, stop do
        -- Stop early if ran out of table content.
        if itable[i] == nil then
            DebugError("[Library] Slice_List: Stopped at index " .. tostring(i) .. ", no more entries") -- Debug: Log early stop
            return otable
        end
        -- Else copy over one entry.
        table.insert(otable, itable[i])
        DebugError("[Library] Slice_List: Added entry at index " .. tostring(i) .. ": " .. tostring(itable[i])) -- Debug: Log entry addition
    end
    DebugError("[Library] Slice_List: Completed, returning slice with " .. tostring(#otable) .. " entries") -- Debug: Log completion
    return otable
end

-- FIFO definition, largely lifted from https://www.ui.org/pil/11.4.html
-- Adjusted for pure fifo behavior.
-- TODO: change to act as methods.
local FIFO = {}
L.FIFO = FIFO

function FIFO.new()
    DebugError("[Library] FIFO.new: Creating new FIFO") -- Debug: Log FIFO creation
    local fifo = {first = 0, last = -1}
    DebugError("[Library] FIFO.new: Created FIFO with first: " .. tostring(fifo.first) .. ", last: " .. tostring(fifo.last)) -- Debug: Log FIFO details
    return fifo
end    

function FIFO.Write(fifo, value)
    DebugError("[Library] FIFO.Write: Writing value: " .. tostring(value) .. " to FIFO") -- Debug: Log write attempt
    local last = fifo.last + 1
    fifo.last = last
    fifo[last] = value
    DebugError("[Library] FIFO.Write: Wrote value, new last: " .. tostring(fifo.last)) -- Debug: Log write completion
end

function FIFO.Read(fifo)
    DebugError("[Library] FIFO.Read: Reading from FIFO") -- Debug: Log read attempt
    local first = fifo.first
    if first > fifo.last then 
        DebugError("[Library] FIFO.Read: FIFO is empty") -- Debug: Log empty FIFO error
        error("fifo is empty") 
    end
    local value = fifo[first]
    fifo[first] = nil
    fifo.first = first + 1
    DebugError("[Library] FIFO.Read: Read value: " .. tostring(value) .. ", new first: " .. tostring(fifo.first)) -- Debug: Log read result
    return value
end

function FIFO.Next(fifo)
    DebugError("[Library] FIFO.Next: Peeking next value in FIFO") -- Debug: Log peek attempt
    local first = fifo.first
    if first > fifo.last then 
        DebugError("[Library] FIFO.Next: FIFO is empty") -- Debug: Log empty FIFO error
        error("fifo is empty") 
    end
    local value = fifo[first]
    DebugError("[Library] FIFO.Next: Next value: " .. tostring(value)) -- Debug: Log peeked value
    return value
end

function FIFO.Is_Empty(fifo)
    local is_empty = fifo.first > fifo.last
    DebugError("[Library] FIFO.Is_Empty: FIFO empty: " .. tostring(is_empty)) -- Debug: Log empty check result
    return is_empty
end

return L
end)