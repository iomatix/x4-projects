Lua_Loader.define("extensions.sn_mod_support_apis.ui.chat_window.Interface", function(require)
    --[[
    Lua interface between Mod Director (MD) and the X4 chat window.
    Primary goal is to intercept chat text, parse it for custom commands starting with '/',
    and pass it to MD for processing, while displaying responses in the chat window.
    
    Key Features:
    - Integrates with X4 Foundations 7.6 chat window (`chatwindow.lua`) by adding responses as announcements.
    - Processes commands locally without duplicating game-handled chat messages.
    - Robust widget identification to adapt to potential menu structure changes.
    - Includes debug logging for troubleshooting.
    
    Integration Notes:
    - Hooks into `View.registerMenu` to patch the chat window menu.
    - Uses `SetScript` on the editbox to intercept user input alongside the game's handler.
    - Adds custom messages to `__CORE_CHAT_WINDOW.announcements` for display in the native chat UI.
    - Avoids direct manipulation of the text table to prevent conflicts with game logic.
    ]]

    -- FFI setup for native function calls.
    local ffi = require("ffi")
    local C = ffi.C
    ffi.cdef[[
        void SetEditBoxText(const int editboxid, const char* text);
    ]]

    -- Imports from mod support APIs.
    local Lib = require("extensions.sn_mod_support_apis.ui.Library")
    local Time = require("extensions.sn_mod_support_apis.ui.time.Interface")
    local T = require("extensions.sn_mod_support_apis.ui.Text")

    -- Configuration mirroring game settings with custom text colors.
    local config = {
        maxOutputLines = 8,
        textColor = {
            ["command"]       = "#FFFFFFFF", -- White
            ["directMessage"] = "#FFFF2B2B", -- Bright red
            ["otherMessage"]  = "#FFF2F200", -- Yellow
            ["ownMessage"]    = "#FF1B893C", -- Dark green
            ["serverMessage"] = "#FFAE02AE"  -- Bright purple
        },
    }

    -- Local state and function table.
    local L = {
        -- Original Egosoft callback for menu creation.
        ego_onChatWindowCreated = nil,

        -- Editbox widget reference.
        edit_box = nil,

        -- Shortened command aliases for user convenience.
        short_commands = {
            rui = "reloadui",
            rai = "refreshai",
            rmd = "refreshmd",
        },
    }

    
    -- Raises a signal to MD with the specified name and arguments.
    -- @param name (string) - The signal name (e.g., "text_entered").
    -- @param args (table|nil) - Arguments to pass with the signal.
    function L.Raise_Signal(name, args)
        AddUITriggeredEvent("Chat_Window_API", name, args)
    end


    -- Initializes the chat window interface by registering events and patching the menu.
    -- Runs at mod load to ensure existing or future chat windows are intercepted.
    function L.Init()
        -- Register MD print event and compatibility event.
        RegisterEvent("Chat_Window_API.Print", L.onPrint)
        RegisterEvent("directChatMessageReceived", L.onPrint)

        -- Intercept View.registerMenu to patch new chat windows.
        local ego_registerMenu = View.registerMenu
        View.registerMenu = function(id, ...)
            ego_registerMenu(id, ...)
            if id == "chatWindow" then
                L.Patch_New_Menu()
            end
        end

        -- Patch any existing chat window.
        L.Patch_New_Menu()
    end

    --[[
    Searches View.menus for the chat window and patches its callback if found.
    Handles both pre-existing and newly created chat windows.
    ]]
    function L.Patch_New_Menu()
        local chat_menu = nil
        for i, menu in ipairs(View.menus) do
            if menu.id == "chatWindow" then
                chat_menu = menu
                break
            end
        end

        if not chat_menu then
            DebugError("[Chat_Window_API] No chat window found during Patch_New_Menu; may be called before menu exists.")
            return
        end

        -- Store and replace the original callback.
        L.ego_onChatWindowCreated = chat_menu.callback
        chat_menu.callback = L.onChatWindowCreated

        -- Update the menu if already open.
        if View.hasMenu({chatWindow = true}) then
            View.updateMenu(chat_menu)
        end
    end

    --[[
    Callback triggered when the chat window is created or updated.
    Identifies the editbox widget and sets up the input interception script.
    @param frames (table) - Array of frame IDs passed by the game.
    ]]
    function L.onChatWindowCreated(frames)
        -- Execute the original callback to maintain game functionality.
        L.ego_onChatWindowCreated(frames)

        -- Identify the editbox by searching frame children.
        for _, child in ipairs(GetChildren(frames[1])) do
            if GetWidgetType(child) == "table" then
                local cell = GetCellContent(child, 1, 1)
                if cell and GetWidgetType(cell) == "editbox" then
                    L.edit_box = cell
                    break
                end
            end
        end

        if L.edit_box then
            -- Set our script to run alongside the game's handler.
            SetScript(L.edit_box, "onEditBoxDeactivated", L.onCommandBarDeactivated)
            DebugError("[Chat_Window_API] Editbox found and script set successfully.")
        else
            DebugError("[Chat_Window_API] Failed to find editbox in chat window frame.")
        end
    end

    -- Handles editbox deactivation (e.g., Enter key press) to process user input.
    -- @param _ (any) - Unused parameter.
    -- @param text (string) - Text entered in the editbox.
    -- @param _ (any) - Unused parameter.
    -- @param wasConfirmed (boolean) - True if deactivation was via confirmation (e.g., Enter).
    function L.onCommandBarDeactivated(_, text, _, wasConfirmed)
        if not wasConfirmed then return end
        L.Process_Text(text)
    end

    -- Processes the entered text, handling commands and signaling MD.
    -- Regular chat messages are left to the game; commands are intercepted.
    -- @param text (string) - Raw text input from the editbox.
    function L.Process_Text(text)
        if text == "" then return end

        local terms = Lib.Split_String_Multi(text, " ")
        if #terms == 0 then return end

        -- Only process commands starting with '/'.
        if string.sub(terms[1], 1, 1) == "/" then
            DebugError("[Chat_Window_API] Processing command: " .. text)
            L.Add_Line(text) -- Display the command in the chat.

            local command = string.sub(terms[1], 2)
            local param = table.concat(terms, " ", 2)

            -- Handle short command aliases.
            if L.short_commands[command] then
                command = L.short_commands[command]
                ExecuteDebugCommand(command, param)
            end

            -- Signal MD with the parsed input.
            L.Raise_Signal("text_entered", {terms = terms, text = text})
        end
    end

    -- Adds a line to the chat window as a local announcement.
    -- Uses the game's announcement system for native integration.
    -- @param line (string) - Text to display in the chat window.
    function L.Add_Line(line)
        table.insert(__CORE_CHAT_WINDOW.announcements, {
            text = line,
            prefix = ColorText["text_chat_message_server"] .. "Mod: ",
            timestamp = tostring(os.time() * 1000),
            announcement = true
        })
        -- Mark messages as outdated and refresh the menu.
        menu.messagesOutdated = true
        menu.onShowMenu()
        DebugError("[Chat_Window_API] Added line to announcements: " .. line)
    end

    -- Handles print events from MD, displaying the text in the chat window.
    -- @param _ (any) - Unused event ID.
    -- @param text (string) - Text to print.
    function L.onPrint(_, text)
        L.Add_Line(text)
    end

    return nil, L.Init
end)