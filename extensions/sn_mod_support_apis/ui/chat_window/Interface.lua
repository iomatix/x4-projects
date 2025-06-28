Lua_Loader.define("extensions.sn_mod_support_apis.ui.chat_window.Interface", function(require)
    --[[
Lua interface between Mod Director (MD) and the X4 chat window for version 7.6.
Intercepts chat text, parses commands starting with '/', and displays responses in the chat window.

Key Features:
- Integrates with the native chat system via `__CORE_CHAT_WINDOW.announcements`.
- Processes commands locally without interfering with regular chat.
- Includes debug logging and error handling.
- Avoids direct widget manipulation for compatibility.

Integration Notes:
- Patches `chatwindow.lua` by overriding the menu callback.
- Sets a script on the editbox to intercept input alongside game handling.
- Uses the announcement system to display messages natively.

Usage:
- MD scripts can listen for "text_entered" signals to process commands.
- Responses are printed via the "Chat_Window_API.Print" event.
- Debug logs (controlled by `isDebug`) aid troubleshooting.
]]

    -- FFI setup for native function calls
    local ffi = require("ffi")
    local C = ffi.C
    ffi.cdef [[
    void SetEditBoxText(const int editboxid, const char* text);
]]

    -- Local state and function table
    local L = {
        ego_onChatWindowCreated = nil,
        edit_box = nil,
        short_commands = {
            rui = "reloadui",
            rai = "refreshai",
            rmd = "refreshmd"
        },
        isDebug = true -- Set to true for debugging
    }

    -- Configuration with custom text colors
    local config = {
        textColors = {
            command = "#FFFFFFFF", -- White
            directMessage = "#FFFF2B2B", -- Bright red
            otherMessage = "#FFF2F200", -- Yellow
            ownMessage = "#FF1B893C", -- Dark green
            serverMessage = "#FFAE02AE" -- Bright purple
        }
    }

    -- Log debug messages if enabled
    local function DebugLog(message)
        if L.isDebug then
            DebugError("[Chat_Window_API] " .. message)
        end
    end

    -- Raise a signal to MD with the specified name and arguments
    -- @param name (string) Signal name (e.g., "text_entered")
    -- @param args (table|nil) Arguments to pass
    function L.Raise_Signal(name, args)
        AddUITriggeredEvent("Chat_Window_API", name, args)
    end

    -- Initialize the chat window interface by patching the menu
    function L.Init()
        RegisterEvent("Chat_Window_API.Print", L.onPrint)

        local ego_registerMenu = View.registerMenu
        View.registerMenu = function(id, ...)
            ego_registerMenu(id, ...)
            if id == "chatWindow" then
                L.Patch_New_Menu()
            end
        end

        L.Patch_New_Menu()
        DebugLog("Chat window interface initialized")
    end

    -- Patch the chat window menu if it exists
    function L.Patch_New_Menu()
        local chat_menu = nil
        for _, menu in ipairs(View.menus or {}) do
            if menu.id == "chatWindow" then
                chat_menu = menu
                break
            end
        end

        if not chat_menu then
            DebugLog("Chat window not found during patching")
            return
        end

        L.ego_onChatWindowCreated = chat_menu.callback
        chat_menu.callback = L.onChatWindowCreated
        if View.hasMenu and View.hasMenu({
            chatWindow = true
        }) then
            View.updateMenu(chat_menu)
        end
    end

    -- Callback when the chat window is created or updated
    -- Sets up the editbox for input interception
    -- @param frames (table) Array of frame IDs
    function L.onChatWindowCreated(frames)
        if L.ego_onChatWindowCreated then
            L.ego_onChatWindowCreated(frames)
        end

        for _, child in ipairs(GetChildren(frames[1]) or {}) do
            if GetWidgetType(child) == "table" then
                local cell = GetCellContent(child, 1, 1)
                if cell and GetWidgetType(cell) == "editbox" then
                    L.edit_box = cell
                    break
                end
            end
        end

        if L.edit_box then
            SetScript(L.edit_box, "onEditBoxDeactivated", L.onCommandBarDeactivated)
            DebugLog("Editbox found and script set")
        else
            DebugLog("Editbox not found")
        end
    end
end


-- Add a line to the text table.
-- Line will be formatted, and may be broken into multiple lines by word wrap.
-- Oldest lines will be removed, past the textbox line limit.
function L.Add_Line(line)

    -- Format the line; expect to maybe get newlines back.
    -- TODO: think about this. Also consider if original text has newlines.
    local f_line = line

    -- Split and add to existing text lines.
    local sublines = Lib.Split_String_Multi(f_line, "\n")
    for i, subline in ipairs(sublines) do
        table.insert(L.text_lines, subline)
    end

    -- Remove older entries.
    if #L.text_lines > config.maxOutputLines then
        local new_text_lines = {}
        for i = #L.text_lines - config.maxOutputLines + 1, #L.text_lines do
            table.insert(new_text_lines, L.text_lines[i])
        end
        L.text_lines = new_text_lines
    end

    -- Update the text window.
    L.rebuildWindowOutput()
end

-- Print a line sent from md.
function L.onPrint(_, text)
    -- Ignore if not controlling the text.
    if not L.control_text then return end
    L.Add_Line(text)
end


-- On each update, do a fresh rebuild of the window text.
-- This works somewhat differently than the ego code, aiming to fix an ego
-- problem when text wordwraps (in ego code causes it to print outside/below
-- the text window).
function L.rebuildWindowOutput()

    -- Skip if the table isn't set up yet.
    if L.text_table == nil then return end

    -- Merge the lines into one string.
    local text = ""
    for i, line in ipairs(L.text_lines) do
        text = text .. "\n" .. line
    end

    -- Jump a couple hoops to update the table cell. Copy/edit of ego code.
    local contentDescriptor = CreateFontString(text, "left", 255, 255, 255, 100, "Zekton", 10, true, 0, 0, 160)
    local success = SetCellContent(L.text_table, contentDescriptor, 1, 1)
    if not success then
        DebugError("ChatWindow error - failed to update output.")
    end
    ReleaseDescriptor(contentDescriptor)
end

-- Removed. TODO: overhaul for changes made in 6.0+.
return nil,L.Init
end)
