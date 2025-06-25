@echo off
setlocal

REM — run the launch script with -v flag and then return here
call "%~dp0X4_Python_Pipe_Server_run.bat" launch_v

echo.
echo [+] Launch finished with exit code %ERRORLEVEL%.

pause