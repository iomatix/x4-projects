
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

## 2.1.0 Changelog

- **Complete rewrite of core logic** in `main.py` and compiler methods, introducing a clearer and more modular architecture.
- **Switched to `pathlib`** for all file system operations, replacing `os.path` to improve readability and reduce errors.
- **Improved error handling**:
  - Used more specific exceptions like `ImportError`.
  - Enhanced safety when loading external files or modules.
- **Applied consistency to path manipulations**, retaining `shutil` only where necessary for operations like recursive deletion or file copying.
- **Used context managers and `Path` objects** to manage file I/O more securely and idiomatically.
- **Removed redundant `build_folder.mkdir()`** calls, as PyInstaller handles folder creation automatically.
- **Added sandboxing mechanisms** for executing `.py` modules:
  - Introduced `Server_Process` based on `multiprocessing.Process`.
  - Isolated execution environments to prevent modules from accessing shared server resources directly.
- **Introduced hybrid permission system**:
  - `check_permission` supports both extension IDs and folder names.
  - Prioritizes IDs for deterministic and secure access control.
- **Maintained JSON as the config format** for permissions and metadata due to its readability, lightweight structure, and wide support.
- **Retained threading over multiprocessing** for the main server:
  - Threading is more efficient for I/O-bound tasks with shared state.
  - Simplifies design compared to multiprocessing queues or shared memory.
- **Added cleanup logic** to prevent orphaned threads if the parent process fails unexpectedly.
- **Added `--no-restart` CLI flag** to disable automatic server restarts:
  - Improves developer testing flexibility.
  - Auto-restart remains the default for player-facing environments.
- **Improved thread management**:
  - Subclassed `threading.Thread` for better encapsulation.
  - Added `threading.Event` (`stop_event`) to coordinate shutdown signals.
  - Implemented timeout-enabled `Join` with a default of 5 seconds.
- **Implemented paired named pipes** (`_in` and `_out`) to improve concurrency and Linux compatibility.
- **Replaced `print` statements** with `logging.info` and `logging.warning` for structured, level-based logging.
- **Added docstrings and inline comments** throughout the codebase to improve documentation and readability.
- **Added type hints** to all major functions and methods for clarity and static analysis support.
- **Enhanced `Read` and `Write` methods**:
  - Integrated logging of pipe activity.
  - Added optional `timeout` to avoid indefinite blocking on read operations.
- **Implemented `__enter__` and `__exit__` methods** to enable use of context managers for pipe objects and resources.
- **Introduced `trim_log` method** for log rotation:
  - Trims old log content once file exceeds a maximum size.
  - Optimized with `seek(0, 2)` to move to end of file directly.
- **Added unit test for `Log_Reader`**:
  - Validated log writing and reading behavior with short timeouts.
  - Confirmed `trim_log` works as expected in log size control.
- **Finalized flexible argument parsing**:
  - Accepted command-line `args` for path overrides and test harnessing.
  - Improved testability and CLI behavior consistency.

## 2.2.0 Changelog

- **Refactored main server and worker logging** to use `logging.handlers.QueueHandler` and `QueueListener` for thread/process-safe logging with a centralized queue, improving log reliability and formatting consistency across processes.
- **Improved signal handling** by adding handlers for SIGINT and SIGTERM to enable graceful shutdown with proper logging and clean exit.
- **Unified imports and removed duplicates** across files for better maintainability and consistency.
- **Standardized logging format and levels** in both main and worker processes, allowing easier debugging and developer mode verbosity.
- **Refined `Server_Process` class** to:
  - Support passing a `stop_event` to target functions for cooperative shutdown.
  - Add explicit `Close` and `Join` methods with timeout and forced termination fallback.
  - Log lifecycle events for better observability.
- **Enhanced permission system**:
  - Made the permissions file path configurable via command line arguments.
  - Improved JSON loading with error handling and fallback to default permissions.
  - Implemented hybrid permission checking that supports both extension IDs and folder names for better security and flexibility.
- **Improved module import handling** with better error reporting and developer mode tracebacks.
- **Added command-line argument parsing** for test mode, verbosity, permissions path, module path, and disabling auto-restart, improving usability for development and testing.
- **Path management improvements** using `pathlib` to handle relative paths and Python frozen (PyInstaller) environments seamlessly.
- **Documentation and inline comments** added for clarity and maintainability.
- **Code quality improvements**:
  - Added type hints for better code clarity and type checking.
  - Replaced `print` statements with structured logging.
  - Removed redundant code fragments and cleaned up duplicated code.
- **General stability improvements and preparations** for further modularization and sandboxing.
