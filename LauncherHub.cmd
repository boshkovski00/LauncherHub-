@echo off
set "HUB_DIR=%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%HUB_DIR%LauncherHub.ps1"
