@echo off
REM Build the native mpv settings window (mpv-settings.exe).
REM Requires Visual Studio 2022 (any edition) with the C++ workload.
REM Run from anywhere; it locates vcvars64 via vswhere.

setlocal
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH (
  echo Visual Studio not found.
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul

cl /nologo /W3 /O2 /D_CRT_SECURE_NO_WARNINGS "%~dp0mpv-settings.c" ^
   /Fe:"%~dp0mpv-settings.exe" /Fo:"%~dp0mpv-settings.obj" ^
   /link user32.lib comctl32.lib gdi32.lib shell32.lib ole32.lib comdlg32.lib

if exist "%~dp0mpv-settings.obj" del "%~dp0mpv-settings.obj"
echo Built %~dp0mpv-settings.exe

REM Bundle into the script package so the Lua launcher finds it.
copy /y "%~dp0mpv-settings.exe" "%~dp0..\scripts\encore-settings\mpv-settings.exe" >nul
echo Bundled into scripts\encore-settings\
