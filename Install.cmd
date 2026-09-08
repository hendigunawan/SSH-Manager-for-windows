@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -Force -LaunchAfterInstall
if errorlevel 1 pause
