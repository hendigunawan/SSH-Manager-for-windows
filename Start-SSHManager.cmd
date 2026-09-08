@echo off
setlocal
where wt.exe >nul 2>nul
if errorlevel 1 goto fallback
start "" wt.exe -w 0 new-tab --title "Proper SSH Manager" --suppressApplicationTitle powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SSHManager.ps1"
exit /b 0

:fallback
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SSHManager.ps1"
