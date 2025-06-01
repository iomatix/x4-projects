--[[
Lightweight lua wrapper on some exported api functions.
Other extensions using these lua apis should 'require' this file, as its
path will be maintained between github development files and steam style
release files.
]]

Lua_Loader.define("extensions.sn_mod_support_apis.lua_interface",function(require)
	-- TODO: Need to determine if we need to Init this
	return {
		Library = require("extensions.sn_mod_support_apis.ui.Library"),
		Pipes = require("extensions.sn_mod_support_apis.ui.named_pipes.Pipes"),
		Time = require("extensions.sn_mod_support_apis.ui.time.Interface"),
	}
end)