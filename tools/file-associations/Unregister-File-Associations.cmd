@echo off
rem Double-click to remove the mpv media-file associations this tool created.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-FileAssociations.ps1" -Unregister
echo.
pause
