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

    -- Handle editbox deactivation (e.g., Enter press) to process input
    -- @param _ (any) Unused
    -- @param text (string) Entered text
    -- @param _ (any) Unused
    -- @param wasConfirmed (boolean) True if confirmed (e.g., Enter)
    function L.onCommandBarDeactivated(_, text, _, wasConfirmed)
        if not wasConfirmed then
            return
        end
        L.Process_Text(text)
    end

    -- Process entered text, handling commands starting with '/'
    -- @param text (string) Raw input text
    function L.Process_Text(text)
        if text == "" then
            return
        end

        local terms = {}
        for term in text:gmatch("%S+") do
            table.insert(terms, term)
        end
        if #terms == 0 or string.sub(terms[1], 1, 1) ~= "/" then
            L.Add_Line(text, config.textColors.otherMessage)
            return
        end

        DebugLog("Processing command: " .. text)
        L.Add_Line(text, config.textColors.command)

        local command = string.sub(terms[1], 2)
        local param = table.concat(terms, " ", 2)

        if L.short_commands[command] then
            command = L.short_commands[command]
            ExecuteDebugCommand(command, param)
            L.Add_Line("Executed command: " .. command, config.textColors.serverMessage)
        else
            L.Add_Line("Unknown command: " .. command, config.textColors.serverMessage)
        end

        L.Raise_Signal("text_entered", {
            terms = terms,
            text = text
        })
    end

    -- Add a line to the chat window using the announcement system
    -- @param line (string) Text to display
    -- @param color (string) Hex color code for the text
    function L.Add_Line(line, color)
        table.insert(__CORE_CHAT_WINDOW.announcements, {
            text = line,
            prefix = (color or config.textColors.serverMessage) .. "Mod: ",
            timestamp = tostring(os.time() * 1000),
            announcement = true
        })
        if menu then
            menu.messagesOutdated = true
            menu.onShowMenu()
        end
        DebugLog("Added line: " .. line)
    end

    -- Handle print events from MD to display text in the chat
    -- @param _ (any) Unused event ID
    -- @param text (string) Text to display
    function L.onPrint(_, text)
        L.Add_Line(text, config.textColors.serverMessage)
    end

    -- Initialize the chat system
    L.Init()

    return nil, L.Init
end)
