# X4_Python_Pipe_Server

A named pipe server for **X4: Foundations**, designed to allow secure, asynchronous communication between the game’s Lua runtime and Python scripts.

## 🔧 Features

- Listens on `\\.\pipe\x4_python_host` for messages from Lua extensions.
- Dynamically loads Python modules located in the `extensions/` directory.
- Executes each module’s `main()` function in an isolated subprocess.
- Controlled via a `permissions.json` file.
- Includes test mode for local simulation without launching the game.

---

## 🗂️ File Placement

To work correctly:

1. **Copy `X4_Python_Pipe_Server.exe` to the same folder as `x4.exe`.**  
   Example path: `C:\Program Files (x86)\Steam\steamapps\common\X4 Foundations\`
2. Ensure your Python modules are located inside valid X4 extensions
    e.g.: `C:\Program Files (x86)\Steam\steamapps\common\X4 Foundations\extensions\your_mod\`
3. (Optional) Customize `permissions.json` to define which modules may be executed.

---

## 🚀 Running the Server

### 🟢 Production Mode (Normal Usage)

Simply run `X4_Python_Pipe_Server.exe`

The server will wait for incoming messages from the Lua runtime and handle them accordingly.

## 🧪 Test Mode (Simulated)

You can simulate pipe messages locally without launching the game:
- `X4_Python_Pipe_Server.exe --test --x4-path "C:\Path\To\X4 Foundations\" --module "extensions\your_mod\entry.py"`

Test mode:
- Loads a Lua-style package.path.
- Sends a module path as if from Lua.
- Executes the corresponding Python module if it's permitted. (Refer to `permissions.json` file)

## 🛡️ Permissions

Control what modules can be executed via `permissions.json`.

Default location: `permissions.json` in the working directory (next to the `.exe`).

Example:
```
{
  "allowed_modules": [
    "extensions/your_mod/entry.py"
  ]
}
```
You can override the file path using `--permissions-path "D:\custom\permissions.json"`

## ⚙️ Command Line Flags

| Flag                       | Description                                                         |
| -------------------------- | ------------------------------------------------------------------- |
| `-t`, `--test`             | Enables test mode (requires `--x4-path` and `--module`).            |
| `-x`, `--x4-path`          | Root folder of the X4 installation (used in test mode only).        |
| `-m`, `--module`           | Relative path to the Python module to test.                         |
| `-p`, `--permissions-path` | Path to custom `permissions.json`.                                  |
| `-v`, `--verbose`          | Enables verbose output.                                             |
| `--no-restart`             | Prevents the server from restarting after pipe disconnect or crash. |

## 🧼 Clean Build Process (For Developers)

This executable is built using Make_Executable.py, which wraps pyinstaller with:

- `--onedir`
- `--preclean` / `--postclean`

The output is placed in `dist/X4_Python_Pipe_Server/X4_Python_Pipe_Server.exe`

To build: `python Make_Executable.py`


---

## 🛠 Developer Helper: `X4_Python_Pipe_Server_run.bat`

This script (in the project root) streamlines building, testing and live-launch:

```bat
X4_Python_Pipe_Server_run.bat <action> [args]
```

- **build** `X4_Python_Pipe_Server_run.bat build` - Compiles a single‐file X4_Python_Pipe_Server.exe (all DLLs embedded). If PyInstaller reports a missing‐module error, install the needed package in your venv e.g. `pip install pynput`.
- **test** `X4_Python_Pipe_Server_run.bat test "C:\Games\X4" "extensions\my_mod\entry.py"` - Runs test "C:\Games\X4" "extensions\my_mod\entry.py"
- **launch** `X4_Python_Pipe_Server_run.bat launch "C:\Games\X4\X4.exe"` - Starts the pipe server in background, then launch X4 for live mod testing. If no path given, assumes .\X4.exe.
- **debug** `X4_Python_Pipe_Server_run.bat debug --verbose` - Runs Main.py under pdb, forwarding flags.

Place `X4_Python_Pipe_Server.exe` into your X4 install folder (next to x4.exe) for end-user deployment.

---

