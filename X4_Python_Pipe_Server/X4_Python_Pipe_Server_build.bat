@echo off
setlocal

REM — run the build script and then return here
call "%~dp0X4_Python_Pipe_Server_run.bat" build

echo.
echo [+] Build finished with exit code %ERRORLEVEL%.

pause