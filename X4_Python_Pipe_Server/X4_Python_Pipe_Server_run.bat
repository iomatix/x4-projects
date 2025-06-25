@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ----------------------------------------------------------------------------
:: run.bat – Dev helper for X4_Python_Pipe_Server
:: Actions: build | test | launch | debug
:: ----------------------------------------------------------------------------

:: 1) Jump to script folder
cd /d "%~dp0"

:: 2) Activate venv if it exists
if exist "venv\Scripts\activate.bat" (
    call "venv\Scripts\activate.bat" >nul
    echo [venv] activated.
)

:: 3) Parse action
if "%~1"=="" goto :usage
set "ACTION=%~1"
shift

:: 4) BUILD: compile .exe
if /I "%ACTION%"=="build" (
    echo [*] Building X4_Python_Pipe_Server.exe…
    python Make_Executable.py -preclean -postclean
    exit /b %ERRORLEVEL%
)

:: 5) TEST: run single module in test mode
if /I "%ACTION%"=="test" (
    if "%~1"=="" (
        echo Usage: %~nx0 test ^<X4_INSTALL_PATH^> ^<MODULE_REL_PATH^>
        exit /b 1
    )
    set "X4PATH=%~1"
    set "MODULE=%~2"
    echo [*] Testing module !MODULE! against X4 at !X4PATH!…
    X4_Python_Pipe_Server.exe --test --x4-path "!X4PATH!" --module "!MODULE!"
    exit /b %ERRORLEVEL%
)

:: ---------------------------------------------------------------------------
:: 6) LAUNCH / LAUNCH_BG / LAUNCH_V: start server + game for live testing
::    launch             → server in foreground (console visible)
::    launch_bg          → server in background
::    launch-background  → alias for launch_bg
::    launch_v           → server in verbose mode (foreground)
::    launch-verbose     → alias for launch_v
:: ---------------------------------------------------------------------------

:: reset flags
set "BGFLAG="
set "VERBOSE_FLAG="

:: pick your mode
if /I "%ACTION%"=="launch" (
    set "BGFLAG="
) else if /I "%ACTION%"=="launch_bg" (
    set "BGFLAG=/B"
) else if /I "%ACTION%"=="launch-background" (
    set "BGFLAG=/B"
) else if /I "%ACTION%"=="launch_v" (
    set "BGFLAG="
    set "VERBOSE_FLAG=-v"
) else if /I "%ACTION%"=="launch-verbose" (
    set "BGFLAG="
    set "VERBOSE_FLAG=-v"
) else goto :after_launch

:: resolve X4.exe path (default = .\X4.exe)
if "%~1"=="" (
    set "GAMEEXE=%~dp0X4.exe"
) else (
    set "GAMEEXE=%~1"
)

echo [*] Launch target is: !GAMEEXE!
if not exist "!GAMEEXE!" (
    echo ERROR: Game executable not found: !GAMEEXE!
    exit /b 1
)

echo [*] Starting pipe server %BGFLAG% %VERBOSE_FLAG%...
start "" %BGFLAG% X4_Python_Pipe_Server.exe %VERBOSE_FLAG%

timeout /T 2 >nul

echo [*] Launching X4 Foundations...
start "" "!GAMEEXE!"

exit /b 0
:after_launch

:: 7) DEBUG: run Python under pdb
if /I "%ACTION%"=="debug" (
    echo [*] Debugging Main.py…
    python -m pdb Main.py %*
    exit /b %ERRORLEVEL%
)

:usage
echo.
echo Usage: %~nx0 ^<action^> [parameters]
echo.
echo   build
echo     – Compile the executable via Make_Executable.py
echo.
echo   test ^<X4_INSTALL_PATH^> ^<MODULE_REL_PATH^>
echo     – e.g. %~nx0 test "C:\Games\X4" "extensions\foo\bar.py"
echo.
echo   launch [^<X4_EXE_PATH^>]
echo     – Starts pipe-server + X4.exe (default .\X4.exe)
echo.
echo   debug [flags…]
echo     – Runs Main.py under pdb, passing any flags through
echo.
exit /b 1