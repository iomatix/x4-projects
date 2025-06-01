@echo off

rem !!--- Please change this to where your game is installed. Do not add any spacing around the equals operator.
set X4_EXE_PATH="D:\SteamLibrary\steamapps\common\X4 Foundations\X4.exe"

rem !!--- Set the date and time for logfile in year-month-day__hh-mm-ss format
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /format:list') do set "datetime=%%I"
set "datetime=%datetime:~0,4%-%datetime:~4,2%-%datetime:~6,2%__%datetime:~8,2%-%datetime:~10,2%-%datetime:~12,2%"
echo Date & Time test = %datetime% (year-month-day__hh-mm-ss)

rem Set log file names based on datetime
set "LOG_FILE_NAME=x4-game-%datetime%.log"
set "SCRIPT_LOG_FILE_NAME=x4-script-%datetime%.log"

rem Define the full command
set "exec=%X4_EXE_PATH% -showfps -debug all -logfile "%LOG_FILE_NAME%" -scriptlogfile "%SCRIPT_LOG_FILE_NAME%""

rem Log the command being executed
echo Executing: %exec%

rem Execute the game without opening a new console window
%exec%

rem
pause