@echo off
REM Launches the local Mission Restore web UI (PowerShell + built-in HttpListener).
REM No installation required. Binds to http://localhost:<port>/ (loopback only).
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%Serve-RestoreUI.ps1" %*
endlocal
