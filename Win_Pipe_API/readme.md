Win_Pipe_API
------------

**Lua plugin for Windows named pipe clients (Windows only)**  
Provides non-blocking and blocking support for named pipe I/O from Lua 5.1.

This DLL plugin is derived from the legacy `winapi` plugin and heavily modified. It **only implements named pipe client access** (`\\.\pipe\...`) for use within the X4 game engine scripting environment (which uses Lua 5.1).

---

Compilation Notes
-----------------

💡 This plugin **must be compiled in 64-bit Release mode**, and linked against **Lua 5.1's 64-bit DLL**.

### Prerequisites:

1. **Lua 5.1 headers**
   - Download from: https://www.lua.org/source/5.1/
   - Place in: `Win_Pipe_API/lua/`

2. **Lua 5.1 import library (`lua51_64.lib`)**
   - Must match the `lua51_64.dll` shipped with X4.
   - If not available, you can generate it from the DLL via Visual Studio Developer Command Prompt console:

     ```
     dumpbin /EXPORTS lua51_64.dll > lua.exports
     editdef lua.def from exports
     lib /def:lua.def /machine:x64 /out:lua51_64.lib
     ```

   - Recommended: Generate `lua51.def` and `lua51_64.lib` Using PowerShell:

        Use the **Visual Studio Developer Command **Prompt:
        ```sh
        dumpbin /EXPORTS lua51_64.dll > lua.exports
        ```
        **PowerShell script**:
        1) Read your raw export dump:
        ```$raw = Get-Content lua.exports```

        2) Build up an array of clean lines:
        ```
        $lines = @(
            'LIBRARY lua51_64.dll'
            'EXPORTS'
            ''   # <— this blank line is _crucial_ so the first symbol isn’t stuck on the EXPORTS line
        )
        ```

        3) Append only the lua* names, indented:
        ```
        $raw |
          Select-String -Pattern '^\s*\d+\s+\w+\s+\w+\s+([^\s]+)' |
          Where-Object { $_.Matches[0].Groups[1].Value -match '^lua' } |
          ForEach-Object { $lines += "    " + $_.Matches[0].Groups[1].Value }
        ```

        4) Write out as ASCII (no BOM) with CRLF line endings:
        ```$lines | Set-Content lua51.def -Encoding Ascii```


        Again use the **Visual Studio Developer Command** Prompt:
        ```sh
        lib /def:lua51.def /machine:x64 /out:lua51_64.lib
        ```

   - Alternatively, follow this StackOverflow guide:  
     https://stackoverflow.com/questions/9946322/how-to-generate-an-import-library-lib-file-from-a-dll

---

Visual Studio Build Configuration
---------------------------------

Settings known to work for X4 (Lua 5.1, 64-bit):

- Configuration: **Release/x64**
- Character Set: **Not Set**
- Disable precompiled headers
- Additional Include Directories: `./lua/`
- Additional Linker Inputs:
  - `kernel32.lib`
  - `user32.lib`
  - `lua51_64.lib`
- C/C++ → Preprocessor Definitions: Add `/DPSAPI_VERSION=1`
- Linker → Command Line: Add `/EXPORT:luaopen_winpipe`
- Warning Level: set to `/W1` (to match original batch scripts)
- Security Check: `/sdl-` (disable)

---

Functionality
-------------

This module exports `winpipe.open(pipe_path, mode)` in Lua.

- Returns a file-like object supporting:
  - `:read([maxbytes])`
  - `:write(data)`
  - `:close()`

It supports:
- Overlapped (non-blocking) I/O via `FILE_FLAG_OVERLAPPED`
- Error handling with translated Windows error messages
- Safe use in sandboxed Lua 5.1 environments

---

Usage in Lua 5.1:

```lua
local pipe = require("winpipe")

local client = pipe.open("\\\\.\\pipe\\my_pipe", "rw")
client:write("hello")
local msg = client:read()
client:close()
```
