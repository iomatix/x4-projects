@echo off
:: Check for administrative privileges
openfiles >nul 2>&1
if %errorlevel% NEQ 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

rem Set the executable path (adjust if necessary)
set "X4_EXE_PATH=D:\SteamLibrary\steamapps\common\X4 Foundations\X4.exe"

rem Generate date and time in year-month-day__hh-mm-ss format using PowerShell
for /f "delims=" %%I in ('powershell -Command "Get-Date -Format 'yyyy-MM-dd__HH-mm-ss'" 2^>nul') do set "datetime=%%I"
echo Date & Time = %datetime%

rem Set log file names based on the current date and time
set "LOG_FILE_NAME=x4-game-%datetime%.log"
set "SCRIPT_LOG_FILE_NAME=x4-script-%datetime%.log"

rem Display the command for verification
echo Executing: "%X4_EXE_PATH%" -showfps -scriptlogfiles %SCRIPT_LOG_FILE_NAME% -logfile %LOG_FILE_NAME%

rem Launch the game
start "" "%X4_EXE_PATH%" -showfps -scriptlogfiles %SCRIPT_LOG_FILE_NAME% -logfile %LOG_FILE_NAME%
pause
