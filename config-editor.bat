@echo off
set "ROOT=%~dp0"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%scripts\config-editor.ps1"
exit /b 0
