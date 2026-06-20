@echo off
rem Double-click to register mpv AND take over media types that another program
rem already owns (overwrites their defaults). The displaced associations are
rem backed up and restored if you run the Unregister script.
rem Prefer the plain "Register-File-Associations.cmd" unless you specifically
rem want to replace existing associations.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-FileAssociations.ps1" -OverrideExisting
echo.
pause
