--[[
Simple api for loading in mod lua files, and for accessing ui userdata.
This works around a bug in the x4 ui.xml style lua loading which fails
to initialize the globals table.

Usage is kept simple:
    When the ui reloads or a game is loaded, a ui event is raised.
    User MD code will set up a cue to trigger on this event and signal to
    lua which file to load.
    Lua will then "require" the file, effectively loading it into the game.

This lua file is itself included by modding an official ui.xml. Lua added
in this way is imported correctly into X4, though there are limited
official ui.xml files which can be modified in this way.
    
Example from MD:
    <cue name="Load_Lua_Files" instantiate="true">
    <conditions>
        <event_ui_triggered screen="'Lua_Loader'" control="'Ready'" />
    </conditions>
    <actions>
        <raise_lua_event name="'Lua_Loader.Load'" 
            param="'extensions.sn_named_pipes_api.Named_Pipes'"/>
    </actions>
    </cue>
  
Here, the cue name can be anything, and the param is the specific
path to the lua file to load, without extension.
The file extension may be ".lua" or ".txt", where the latter may be
needed to distribute lua files through steam workshop.
The lua file needs to be loose, not packed in a cat/dat.

When a loading is complete, a message is printed to the debuglog, and
a ui signal is raised. The "control" field will be "Loaded " followed
by the original file_path. This can be used to set up loading
dependencies, so that one lua file only loads after a prior one.

Example dependency condition:
    <conditions>
        <event_ui_triggered screen="'Lua_Loader'" 
            control="'Loaded extensions.sn_named_pipes_api.Named_Pipes'" />
    </conditions>
    
This api also provides for saving data into the uidata.xml file.
All such saved data is in the __MOD_USERDATA global table.
Each individual mod should add a unique key to this table, and save its
data under that key. Nested tables are supported.
Care should be used in the top level key, to avoid cross-mod conflicts.

To enable early loading of the Userdata handler, this will also support
an early ready signal, which resolves before the normal ready.
- On reloadui or md signalling Priority_Signal, send Priority_Ready.
- Next frame, md cues which listen to this may signal to load their lua.
- Md side will see Priority_Ready, and send Signal.
- Back end of frame, priority lua files load, and api signals standard Ready.
- Next frame, md cues which listen to Ready may signal to load their lua.

TODO: allow for more md arguments, including specifying dependendencies
which are resolved at this level (eg. store and delay the require until
all dependencies are met).
]]

Lua_Loader = {}

local modules = {}

local function Send_Priority_Ready()
    --DebugError("LUA Loader API: Signalling 'Lua_Loader, Priority_Ready'")
    DebugError("[Lua_Loader] Send_Priority_Ready: Signalling Priority_Ready") -- Debug: Log Priority_Ready signal
    -- Send a ui signal, telling all md cues to rerun.
    AddUITriggeredEvent("Lua_Loader", "Priority_Ready")
end

local function Send_Ready()
    --DebugError("LUA Loader API: Signalling 'Lua_Loader, Ready'")
    DebugError("[Lua_Loader] Send_Ready: Signalling Ready") -- Debug: Log Ready signal
    -- Send a ui signal, telling all md cues to rerun.
    AddUITriggeredEvent("Lua_Loader", "Ready")
end

local function IsWhitelistedInProtectedUI(name)
    DebugError("[Lua_Loader] IsWhitelistedInProtectedUI: Checking if module " .. tostring(name) .. " is whitelisted") -- Debug: Log whitelist check
    local is_whitelisted = name == "ffi" or name == "utf8"
    DebugError("[Lua_Loader] IsWhitelistedInProtectedUI: Module " .. tostring(name) .. " is whitelisted: " .. tostring(is_whitelisted)) -- Debug: Log whitelist result
    return is_whitelisted
end

local function IsReserved(name)
    DebugError("[Lua_Loader] IsReserved: Checking if module " .. tostring(name) .. " is reserved") -- Debug: Log reserved check
    local is_reserved = name ~= nil and type(name) == "string" and (name == "bit" or name == "Color" or name == "coroutine" or name == "debug" or name == "ffi" or name == "math" or name == "Matrix" or name == "package" or name == "Rotation" or name == "string" or name == "table" or name == "utf8" or name == "Vector" or name == "_G" or string.find(name, "^jit%."))
    DebugError("[Lua_Loader] IsReserved: Module " .. tostring(name) .. " is reserved: " .. tostring(is_reserved)) -- Debug: Log reserved result
    return is_reserved
end

local function Lua_Loader_Require_Helper(name, methodName, requestorName)
    DebugError("[Lua_Loader] Lua_Loader_Require_Helper: Attempting to require module: " .. tostring(name) .. ", called by: " .. tostring(methodName) .. ", requestor: " .. tostring(requestorName)) -- Debug: Log require attempt
    if type(name) ~= "string" then
        error("Invalid call to "..methodName..". Given name must be a string but is '"..type(name).."''")
    end
    if requestorName ~= nil and type(requestorName) ~= "string" then
        error("Invalid call to "..methodName..". Given requestorName must be nil or a string but is '"..type(requestorName).."''")
    end

    local module = modules[name]
    if module == nil then
        DebugError("[Lua_Loader] Lua_Loader_Require_Helper: Module " .. tostring(name) .. " not found in modules table") -- Debug: Log module not found
        return false
    end

    local status = module.status
    DebugError("[Lua_Loader] Lua_Loader_Require_Helper: Module " .. tostring(name) .. " status: " .. tostring(status)) -- Debug: Log module status

    if status ~= "defined" then
        if status == "executing" then
            if requestorName == nil and type(requestorName) == "string" then
                error("Invalid call to "..methodName..". Cyclical dependency detected in '"..requestorName.."' and '"..name.."''")
            end
        elseif status == "faulted" then
            error("Failed to require the module '"..name.."' as it encountered an error whilst being defined.\n"..module.exports)
        end

        error("Invalid call to "..methodName..". Required module whilst is was being defined '"..name.."''")
    end

    local moduleInit = module.init
    DebugError("[Lua_Loader] Lua_Loader_Require_Helper: Module " .. tostring(name) .. " found, returning exports and init function") -- Debug: Log successful module retrieval
    return true, module.exports, module.init
end

local function on_Load_Lua_File(_, file_path)
    DebugError("[Lua_Loader] on_Load_Lua_File: Attempting to load file: " .. tostring(file_path)) -- Debug: Log file load attempt
    -- First look for our modules
    local success, exports, init = Lua_Loader_Require_Helper(file_path, "Lua_Loader.Load")

    if success then
        if init ~= nil and type(init) == "function" then
            init()
            DebugError("[Lua_Loader] on_Load_Lua_File: Initialized module: " .. tostring(file_path)) -- Debug: Log module initialization
        end
        DebugError("[Lua_Loader] on_Load_Lua_File: Successfully loaded module: " .. tostring(file_path)) -- Debug: Log successful module load
    else
        local localPackage = package
        local packagePath = nil

        -- When Protected UI is enabled it seems that the `package` global is nil, but we want the actual error from require as it might be something else.
        if localPackage ~= nil then
            local packagePath = localPackage.path

            local customPackagePath = "?.txt"
            DebugError("[Lua_Loader] on_Load_Lua_File: Setting package.path to " .. tostring(customPackagePath) .. " for file: " .. tostring(file_path)) -- Debug: Log package path change
            -- Since lua files cannot be distributed with steam workshop stuff,
            -- but txt can, use a trick to change the package search path to
            -- also look for txt files (which can be put on steam).
            -- This is done on every load, since the package.path was observed to
            -- get reset after Init runs (noticed in x4 3.3hf1).
            localPackage.path = customPackagePath
        end
    
        success, exports = pcall(baseRequire, file_path)
        DebugError("[Lua_Loader] on_Load_Lua_File: Require attempt for " .. tostring(file_path) .. " resulted in success: " .. tostring(success)) -- Debug: Log require result

        -- Restore package.path to the original value
        if localPackage ~= nil then
            localPackage.path = packagePath
            DebugError("[Lua_Loader] on_Load_Lua_File: Restored package.path to " .. tostring(packagePath) .. " for file: " .. tostring(file_path)) -- Debug: Log package path restoration
        elseif not IsWhitelistedInProtectedUI(file_path) and success and exports == nil then
            local protectedUIError = "require(\""..file_path.."\") : Only whitelisted modules are allowed in Protected UI Mode."
            DebugError("[Lua_Loader] on_Load_Lua_File: " .. protectedUIError) -- Debug: Log Protected UI error
            DebugError("If you see the following error, then a lua file for a mod has failed to load:\n"..protectedUIError.."\n\nIf you're confident about the source of ALL of your mods then you will need to disable Protected UI Mode for this mod to function.\n\nAdvice for mod developers: You need to load your mod via 'ui.xml' and update your lua files to using Lua_Loader.define(\""..file_path.."\", function(require)\n    ...\nend)")
        end

        if not success then
            DebugError("[Lua_Loader] on_Load_Lua_File: Failed to load file: " .. tostring(file_path) .. ", error: " .. tostring(exports)) -- Debug: Log load failure
            error(exports)
        end

        DebugError("[Lua_Loader] on_Load_Lua_File: Successfully loaded file: " .. tostring(file_path)) -- Debug: Log successful file load
        -- Generic signal that the load completed, for use when there
        -- are inter-lua dependencies (to control loading order).
    end

    AddUITriggeredEvent("Lua_Loader", "Loaded "..file_path)
    DebugError("[Lua_Loader] on_Load_Lua_File: Signalled Loaded for file: " .. tostring(file_path)) -- Debug: Log Loaded signal
end

local function Init()
    --DebugError("LUA Loader API: Running Init()")
    DebugError("[Lua_Loader] Init: Starting initialization") -- Debug: Log initialization start
    -- Hook up an md->lua signal.
    RegisterEvent("Lua_Loader.Load", on_Load_Lua_File)
    DebugError("[Lua_Loader] Init: Registered Lua_Loader.Load event") -- Debug: Log Load event registration
    -- Listen to md side timing on when to send Ready signals.
    -- Priority ready is triggered on game start/load.
    RegisterEvent("Lua_Loader.Send_Priority_Ready", Send_Priority_Ready)
    DebugError("[Lua_Loader] Init: Registered Lua_Loader.Send_Priority_Ready event") -- Debug: Log Priority_Ready event registration
    RegisterEvent("Lua_Loader.Send_Ready", Send_Ready)
    DebugError("[Lua_Loader] Init: Registered Lua_Loader.Send_Ready event") -- Debug: Log Ready event registration
    -- Also call the function once on ui reload itself, to catch /reloadui
    -- commands while the md is running.
    -- Only triggers priority ready; md will then signal Send_Ready for
    -- the second part.
    Send_Priority_Ready()
    DebugError("[Lua_Loader] Init: Triggered initial Priority_Ready signal") -- Debug: Log initial Priority_Ready signal
end

Lua_Loader.IsReserved = IsReserved
Lua_Loader.IsWhitelistedInProtectedUI = IsWhitelistedInProtectedUI

function Lua_Loader.require(name)
    DebugError("[Lua_Loader] require: Attempting to require module: " .. tostring(name)) -- Debug: Log require attempt
    local success, exports, init = Lua_Loader_Require_Helper(name, "Lua_Loader.require()")

    if init == nil then
        init = function()
        end
    end

    if success then
        if init ~= nil and type(init) == "function" then
            init()
            DebugError("[Lua_Loader] require: Initialized module: " .. tostring(name)) -- Debug: Log module initialization
        end
        DebugError("[Lua_Loader] require: Successfully required module: " .. tostring(name)) -- Debug: Log successful require
    else
        local base_success, base_exports = pcall(baseRequire, name)
        DebugError("[Lua_Loader] require: Base require attempt for " .. tostring(name) .. " resulted in success: " .. tostring(base_success)) -- Debug: Log base require result
        if not base_success then
            DebugError("[Lua_Loader] require: Failed to require module: " .. tostring(name) .. ", error: " .. tostring(base_exports)) -- Debug: Log base require failure
            error(base_exports)
        end
        DebugError("[Lua_Loader] require: Successfully required module " .. tostring(name) .. " via base require") -- Debug: Log successful base require
        return base_exports
    end

    return success, exports, init
end

local baseRequire = require
require = function(name)
    DebugError("[Lua_Loader] require (global): Attempting to require module: " .. tostring(name)) -- Debug: Log global require attempt
    local success, exports, init = Lua_Loader_Require_Helper(name, "Lua_Loader.require()")
    
    if not success then
        local base_success, base_exports = pcall(baseRequire, name)
        DebugError("[Lua_Loader] require (global): Base require attempt for " .. tostring(name) .. " resulted in success: " .. tostring(base_success)) -- Debug: Log global base require result
        if not base_success then
            DebugError("[Lua_Loader] require (global): Failed to require module: " .. tostring(name) .. ", error: " .. tostring(base_exports)) -- Debug: Log global base require failure
            error(base_exports)
        end
        DebugError("[Lua_Loader] require (global): Successfully required module " .. tostring(name) .. " via base require") -- Debug: Log successful global base require
        return base_exports
    end

    if init ~= nil and type(init) == "function" then
        init()
        DebugError("[Lua_Loader] require (global): Initialized module: " .. tostring(name)) -- Debug: Log global module initialization
    end

    DebugError("[Lua_Loader] require (global): Successfully required module: " .. tostring(name)) -- Debug: Log successful global require
    return exports
end

function Lua_Loader.define(name, moduleFunction)
    DebugError("[Lua_Loader] define: Defining module: " .. tostring(name)) -- Debug: Log module definition start
    if type(name) ~= "string" then
        DebugError("[Lua_Loader] define: Invalid module name type: " .. tostring(type(name))) -- Debug: Log invalid name type
        error("Invalid call to Lua_Loader.define(). Given name must be a string but is '"..type(name).."''")
    end
    if type(moduleFunction) ~= "function" then
        DebugError("[Lua_Loader] define: Invalid module function type: " .. tostring(type(moduleFunction))) -- Debug: Log invalid function type
        error("Invalid call to Lua_Loader.define(). Given moduleFunction must be a function but is '"..type(moduleFunction).."''")
    end

    local module = modules[name]
    if module ~= nil then
        DebugError("Redefining the module '"..name.."'")
    elseif package ~= nil then
        if IsReserved(name) then
            DebugError("Redefining the build-in module '"..name.."'")
        end
    elseif IsWhitelistedInProtectedUI(name) then
        DebugError("Redefining the build-in module '"..name.."'")
    end
    
    module = {
        status = "executing",
        exports = nil,
        init = nil,
    }
    DebugError("[Lua_Loader] define: Created module entry for: " .. tostring(name) .. ", status: executing") -- Debug: Log module entry creation

    modules[name] = module

    local ambientName = name
    local dependencies = nil
    local moduleFunctionRan = false

    local function moduleRequire(name)
        DebugError("[Lua_Loader] moduleRequire: Requiring dependency: " .. tostring(name) .. " for module: " .. tostring(ambientName)) -- Debug: Log dependency require
        if moduleFunctionRan then
            DebugError("[Lua_Loader] moduleRequire: Invalid require call outside define for module: " .. tostring(ambientName)) -- Debug: Log invalid require call
            error("Invalid call to require() function in Lua_Loader.define(function(require). Call to moduleRequire method outside of define in '"..ambientName.."''")
        end

        local success, exports, init = Lua_Loader_Require_Helper(name, "require() function in Lua_Loader.define(function(require)", ambientName)
        DebugError("[Lua_Loader] moduleRequire: Require helper for dependency " .. tostring(name) .. " in module " .. tostring(ambientName) .. " succeeded: " .. tostring(success)) -- Debug: Log dependency require result

        if not success then
            local base_success, base_exports = pcall(baseRequire, name)
            DebugError("[Lua_Loader] moduleRequire: Base require for dependency " .. tostring(name) .. " in module " .. tostring(ambientName) .. " succeeded: " .. tostring(base_success)) -- Debug: Log base require result
            if not base_success then
                DebugError("[Lua_Loader] moduleRequire: Failed to require dependency: " .. tostring(name) .. ", error: " .. tostring(base_exports)) -- Debug: Log base require failure
                error(base_exports)
            end
            DebugError("[Lua_Loader] moduleRequire: Successfully required dependency " .. tostring(name) .. " via base require") -- Debug: Log successful base require
            return base_exports
        end

        if module.status == "executing" and init ~= nil and type(init) == "function" then
            dependencies = dependencies or {}
            table.insert(dependencies, init)
            DebugError("[Lua_Loader] moduleRequire: Added dependency init function for " .. tostring(name) .. " to module " .. tostring(ambientName)) -- Debug: Log dependency addition
        end

        DebugError("[Lua_Loader] moduleRequire: Successfully required dependency: " .. tostring(name) .. " for module: " .. tostring(ambientName)) -- Debug: Log successful dependency require
        return exports, init
    end

    local success, exports, initFunction = pcall(moduleFunction, moduleRequire)
    DebugError("[Lua_Loader] define: Module function execution for " .. tostring(name) .. " succeeded: " .. tostring(success)) -- Debug: Log module function execution
    
    -- Prevent future 'require' from attempting to update the dependency list.
    module.status = "executed"
    DebugError("[Lua_Loader] define: Set module " .. tostring(name) .. " status to executed") -- Debug: Log status update to executed

    if not success then
        module.status = "faulted"
        module.exports = exports
        DebugError("[Lua_Loader] define: Failed to define module " .. tostring(name) .. ", error: " .. tostring(exports)) -- Debug: Log module definition failure
        error("Failed to define module '"..name.."' due because of the following error: "..exports)
    end

    if initFunction ~= nil and type(initFunction) ~= "function" then
        local err = "Invalid call to Lua_Loader.define(). Second return must be nil or the init function but is '"..type(initFunction).."''"
        module.status = "faulted"
        module.exports = err
        DebugError("[Lua_Loader] define: Invalid init function type for module " .. tostring(name) .. ": " .. tostring(type(initFunction))) -- Debug: Log invalid init function
        error("Failed to define module '"..name.."' due because of the following error: "..err)
    end

    local init = nil
    if type(initFunction) == "function" or dependencies ~= nil then
        local initialized = false
        init = function()
            if not initialized then
                if dependencies ~= nil then
                    for _, dependencyInit in ipairs(dependencies) do
                        dependencyInit()
                        DebugError("[Lua_Loader] define: Initialized dependency for module: " .. tostring(name)) -- Debug: Log dependency initialization
                    end
                end
                if initFunction ~= nil and type(initFunction) == "function" then
                    initFunction()
                    DebugError("[Lua_Loader] define: Initialized module: " .. tostring(name)) -- Debug: Log module initialization
                end
                initialized = true
                DebugError("[Lua_Loader] define: Module " .. tostring(name) .. " fully initialized") -- Debug: Log full initialization
            end
        end
    end

    module.exports = exports
    module.init = init
    module.status = "defined"
    DebugError("[Lua_Loader] define: Successfully defined module: " .. tostring(name) .. ", status: defined") -- Debug: Log successful module definition

    return exports, init
end

-- This script kicks everything off, so we actually need to run its init now.
Init()
DebugError("[Lua_Loader] Script: Initialization complete") -- Debug: Log script initialization complete