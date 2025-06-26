
Change Log

* pre-0.8
  - Early pipe test versions.
* 0.8
  - Overhauled to work with named_pipes_api's Pipe_Server_Host api,
    dynamically loading python servers from extensions.
* 0.9
  - More graceful shutdown if a pipe server is already running.
* 0.10
  - Servers restart on receiving 'garbage_collected' pipe client messages.
* 1.0
  - General release.
* 1.1
  - Restricted module loading to those extensions given explicit permission.
* 1.2
  - Added command line arg for enabling test mode to aid extension development.
  - Added command line arg for changing the permission file path.
  - Called module main() functions must now capture one argument.
* 1.3
  - Gave explicit pipe read/write security permission to the current user, to help avoid "access denied" errors on pipe opening in x4 for some users.
* 1.4
  - Added configparser module to exe.
* 1.4.1
  - Added "-v" ("--verbose") command line arg, which will print pipe access permission messages.
* 1.4.2
  - Added fallback to default pipe permissions when failing to look up user account name.
* 2.1.0
  - Complete rewrite of main and compiler methods.
  - Switched to pathlib from os.path.
  - Improved error handling.
  - Applied consistency for all path manipulations, keeping shutil only where necessary.
  - Used context managers and Path for file operations.
  - Removed unnecessary build_folder.mkdir() since pyinstaller creates it if needed.
  - Adjusted exception handling in the PyInstaller import check to use ImportError.
  - Kept ID-based permissions for now, because of safety reasons. Hybrid approach (folder names or IDs) in the future.
  - Kept JSON format because is lightweight, sufficient in our case and widely supported format.
  - Kept threading. Server is I/O-heavy, and threading is simpler with shared resources. Multiprocessing would add unnecessary overhead.
  - Added basic cleanup mechanism to avoid orphans if parent threads fail.
  - Added `--no-restart` flag for manual control of server restarts and kept the autorestart by default. It improves testing and development but is not important for end-user players.
  - Added docstrings and comments.
  - Applied sandboxing techniques to improve security while executing `.py` files. `Server_Process` class uses multiprocessing.Process to isolate each module in its own process - it prevents direct access to the main server's resoruces.
  - Implemented `stop_event` to allow modules to shut down with a timeout and forced termination as a fallback.
  - Implemented Hybrid aproach for permissions. Method `check_permission` checks both extension IDs and folder names. Prioritizing IDs for consistency.
  - Subclassed threading.Thread - the class inherits instead of creating a separate thread object.
  - Added threading.Event object to signal thread to stop with `stop_event`. It allows for closing threads cleanly.
  - Improved `Join` method to accept a timeout parameter with default value eq to 5 seconds.
  - Replaced `print` statements with logging.info calls.
  - Implemented paired pipes (`_in` and `_out`) for better Linux compatibility and concurrency.
  - Added type hints to all methods for clarity.
  - Replaced `print` with `logging.info`/`warning`.
  - Added `__enter__` and `__exit__` for resource management.
  - Improved in `Read` and `Write` with logging.
  - Added an optional `timeout` parameter. If exceeded, returns `None`, preventing indefinite blocking.
  - Implemented `trim_log` to address TODO for cleaning old lines, trimming the file to the last `max_size` bytes when it grows too large.
  - Replaced advance with `seek(0,2)` for efficiency, directly jumping to the end.
  - Added support for `stop_event` to allow graceful shutdown in a threaded environment.
  - Added a basic test of `Log_Reader` by writting pipe messages to a log file and reading them back with a short timeout.
  - Kept exception handling with logging.
  - Calling `trim_log` to test the file size management.
  - Structured to accept `args` for flexibility in testing setups.
* 2.2.0