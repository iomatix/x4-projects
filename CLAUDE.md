# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an X4: Foundations modding framework repository containing multiple interconnected components for game extension development. The project includes a Python pipe server for inter-process communication, a Windows C++ DLL for named pipe access, various X4 game extensions, and supporting tools for development and release management.

## Build and Development Commands

### Python Pipe Server (X4_Python_Pipe_Server)
- **Build executable**: `X4_Python_Pipe_Server_run.bat build` - Compiles standalone exe using PyInstaller
- **Test module**: `X4_Python_Pipe_Server_run.bat test "C:\Games\X4" "extensions\my_mod\entry.py"` - Test a specific module
- **Launch with game**: `X4_Python_Pipe_Server_run.bat launch "C:\Games\X4\X4.exe"` - Start server and game
- **Debug**: `X4_Python_Pipe_Server_run.bat debug --verbose` - Run under pdb debugger
- **Direct execution**: `python Main.py` for script mode or `X4_Python_Pipe_Server.exe` for compiled mode

### Win_Pipe_API (C++ DLL)
- **Build**: Use Visual Studio with Release/x64 configuration
- **Requirements**: Lua 5.1 headers and 64-bit import library (`lua51_64.lib`)
- **Output**: `winpipe_64.dll` for X4 integration

### Release Management
- **Generate releases**: `python Support\Make_Release.py -refresh` - Build docs, executable, and zip packages
- **Steam upload**: `python Support\Make_Release.py -steam` - Upload to Steam Workshop
- **Documentation**: `python Support\Make_Documentation.py` - Generate documentation from source

### Lua Development
- **Linting**: Uses luacheck with `.luacheckrc` configuration for Lua 5.1 standard
- **API stubs**: Located in `_stubs/` directory for IDE integration
- **Reload UI**: Use `/reloadui` in X4 chat for live Lua updates during development

## Core Architecture

### Named Pipe Communication System
The framework uses Windows named pipes for bidirectional communication between X4 and external processes:

1. **X4_Python_Pipe_Server** (`Main.py`) - Central coordinator that:
   - Listens on `\\.\pipe\x4_python_host` for messages from X4
   - Dynamically loads and executes Python modules from extensions
   - Manages subprocess isolation and lifecycle
   - Handles permissions via `bin/permissions.json`

2. **Win_Pipe_API** (`winpipe.c`) - Lua-accessible DLL providing:
   - Non-blocking named pipe client access from X4's Lua environment
   - UTF-8 message encoding/decoding
   - Windows security integration

3. **Pipe Classes** (`Classes/Pipe.py`) - Abstract pipe communication with:
   - Unidirectional read/write pipe pairs
   - Server and client implementations
   - Error handling and diagnostics

### Extension Framework
Located in `extensions/` with modular APIs:

- **sn_mod_support_apis** - Core API collection including:
  - Lua Loader API - Dynamic Lua file loading workaround
  - Simple Menu API - Custom menu generation from MD scripts
  - Interact Menu API - Right-click context menu extensions
  - Named Pipes API - MD-level pipe communication wrapper
  - Hotkey API - Custom hotkey registration and capture
  - Time API - Real-time timing functions independent of game pause

### Multi-language Integration
- **Lua**: Game scripting and UI integration (5.1 standard)
- **Python**: External process communication and module execution (3.6+)
- **C++**: Low-level Windows API access and performance-critical operations
- **XML**: X4 mission director scripts and extension definitions

## Development Workflow

1. **Extension Development**: Create modules in `extensions/your_extension/` with `content.xml`
2. **Python Integration**: Add Python scripts that implement `main()` function for pipe server execution
3. **Lua Scripting**: Use `extensions/sn_mod_support_apis` for accessing game APIs
4. **Testing**: Use test mode with specific X4 installation path and module
5. **Release**: Use `Make_Release.py` for automated packaging and distribution

## Security Configuration

- **Permissions**: Configure `bin/permissions.json` to control which modules can execute
- **Steam Integration**: Uses workshop IDs for distribution and updates
- **Isolation**: Python modules run in separate processes for stability

## Important File Patterns

- `content.xml` - X4 extension definition files
- `*.md` files in extension folders - Mission Director scripts
- `ui/` folders - Lua UI and interface code
- `python/` folders - External Python modules for pipe server
- `*.bat` files - Windows batch scripts for build automation
- Der Pfad zu MS Visual Studio ist "C:\Program Files\Microsoft Visual Studio"
- der Pfad zu MSBUILD ist "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild"
- Der Pfad zum Spiel X4: Foundations ist "F:\SteamLibrary\steamapps\common\X4 Foundations"
- Der Pfad zu den X4 extensions ist "F:\SteamLibrary\steamapps\common\X4 Foundations\extensions"
- Statt sie zu kopieren, sollen alle extensions in diesem Projekt ausschliesslich mit mklink /J zum extension Pfad "F:\SteamLibrary\steamapps\common\X4 Foundations\extensions\" verlinkt werden
- der Pfad zu den X4 logs ist "C:\Users\andre\Documents\Egosoft\X4\58011333"
- der Pfad zu der aktuellen X4 log ist "C:\Users\andre\Documents\Egosoft\X4\58011333\debug.log"