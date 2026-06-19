@echo off
rem Double-click to register mpv as a handler for media files (current user).
rem You'll be asked for mpv.exe if it isn't on your PATH.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-FileAssociations.ps1"
echo.
pause
