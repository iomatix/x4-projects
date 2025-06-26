
Change Log for overall api package.

* 1.0
  - Apis packaged together.
* 1.1
  - Fixed content.xml text nodes.
* 1.2
  - Fixing missing dll from prior release.
* 1.70
  - Start of joint change log.
  - named_pipes:
    - added continuous read requests.
  - hotkeys:
    - Suppress hotkeys when typing into text boxes.
    - Support for processing multiple keys per frame.
  - simple_options: 
    - Added $skip_initial_callback param.
    - Added Write_Option_Value and Read_Option_Value cues.
  - simple_menu:
    - Fixed column indexing for Call_Table_Method on options menus.
    - Added options menu onOpen signal param with $id, $echo, $columns.
* 1.71
  - Large expansion of the Interact Menu API, including dynamic condition checking in md to determine which actions should show, better control over action display (icons, left/right text, etc), and providing much more information on the context in which a menu is opened.
* 1.72
  - Menu api: added update support for slider values.
  - Pipes api: added extra error detection print for denied access errors.
* 1.73
  - German translation by Le Leon.
* 1.74
  - Interact api: fixed loss of action ordering.
  - Japanese translation by Arkblade.
* 1.75
  - Fixing action table error from prior version.
* 1.76
  - Added Chat_Window_API.
* 1.77
  - Adjusted Simple_Menu_Options.Write_Option_Value to support ids with and without a $ prefix.
* 1.78
  - Refinement to chat window api to better detect the window closing and reopening.
* 1.79
  - Updated pipes dll to match new lua dll in x4 3.3 hotfix 1.
* 1.80
  - Refined pipes dll loading to work with both 3.3 release and hotfix 1.
  - Fixed possible lua loader failure on txt files due to x4 resetting search paths.
* 1.81
  - Fixed possible cause of reconnect loop error in hotkey api.
* 1.82
  - Extension options submenu listing is now sorted.
  - Fixed some temporary oddities with extension options when this api is first added to a game.
* 1.83
  - Added Userdata api, for saving shared data between different save games.
  - Switched hotkeys and simple menu options to store settings in userdata.
* 1.84
  - Improved hotkey api support for non-alphanumeric keys.
* 1.85
  - Improved hotkey api support various keyboard layouts.
* 1.86
  - Hotkey pipe server bugfix.
* 1.87
  - Update/fix to interact api for x4 4.10 beta 5.
* 1.88
  - Fix in interact api for missionid cdata values failing to convert to md, which will now be passed as strings.
* 1.89
  - Update for x4 7.0.
  - Switched menu api to the new color system, replacing Helper.color references.
  - Chat api and hotkey menu integration disabled pending further updates.
* 1.90
  - Fixed interact menu bug introduced in 1.89 that prevented Get_Actions calls.

## 2.1.0 Changelog (Lua Integration)

- Added base compatibility with UI-protected mode.

## 2.1.1

- Fixed `.xml` paths to use `ui/` instead of `lua/`, aligning with new UI protection mode.
- Updated Lua loader to match revised UI paths.
- Replaced single `file` handle with paired `write_file` and `read_file` to support the new duplex pipe structure.
- Refactored `Connect_Pipe`, `Disconnect_Pipe`, and related functions to handle both input and output pipes.
- Improved garbage collection handling and clarified object lifecycle.
- Enhanced error handling for full or broken pipe states.
- Moved polling logic into `Poll_For_Reads` and `Poll_For_Writes` functions for better encapsulation and testability.
- Updated `winpipe_64.dll` to use separate `w` (write) and `r` (read) handles instead of bidirectional pipes.
- Added a `transaction` function to `Named_Pipes.xml` for structured messaging.
- Updated `Access_Handler` to support new transaction logic.

## 2.1.2

- Fixed bugs in Lua files that interfered with stable communication.
- Improved `winpipe.lua` with:
  - Better OS detection and platform safety.
  - Failsafe shutdown and cleanup logic.
  - Fallback warnings for missing components.
  - Enhanced debug logging for pipe communication.
- Finalized compatibility with the `2.1.0` Python Pipe Server.


## 2.2.0 Changelog (Lua Integration)

- **Fully integrated Lua-side communication with the 2.2.0 Python Pipe Server**:
  - Connection with named pipes now stable across both directions.
  - Verified compatibility between `winpipe.lua` and the refactored server.
- **Added automatic initialization and cleanup routines**:
  - Lua modules now initialize pipe communication during setup and shut down cleanly on exit or error.
  - Uses Lua-side equivalent of `stop_event` signaling to avoid hanging pipes.
- **Improved modular design in `winpipe.lua`**:
  - Split functionality into reusable functions and better structured callbacks.
  - Increased separation between platform detection, pipe handling, and debugging.
- **Expanded OS support and error handling**:
  - Improved detection of Windows vs unsupported platforms.
  - Added clear error messages and fallbacks for unsupported systems.
- **Enhanced logging and debugging tools**:
  - Added debug flags and log messages that mirror the Python side.
  - Made pipe failures and disconnects more transparent to Lua developers.
- **Improved file naming and path management**:
  - Synchronized naming between Lua and Python for `_in` and `_out` pipes.
  - Verified consistency with `winpipe_64.dll` update.
- **Finalized XML integration**:
  - Polished `Named_Pipes.xml` with updated transactions and bindings.
  - Validated `Access_Handler` logic for reading pipe responses.
- **Improved resilience**:
  - Handles full and broken pipe errors gracefully.
  - Ensures garbage collection does not prematurely close open pipe handles.
- **Test coverage**:
  - Connected to mock Python servers and tested polling behavior with real data.
  - Manual verification in X4 runtime environment confirms stability.

