@echo off
rem  launch-config-manager.cmd - edit your afterburner ratios. DOUBLE-CLICK THIS.
rem
rem  Named 'launch-' so it is obvious which of the two files to run: this one
rem  starts things, config-manager-gui.ps1 is the window it starts. Windows
rem  will not run a .ps1 on double-click anyway.
rem
rem  Launches the GUI through run-hidden.vbs so no console window appears.
rem  Windows PowerShell is used deliberately: it runs single-threaded
rem  apartment by default, which WinForms requires. PowerShell 7 is MTA and
rem  some dialogs misbehave there.

set "VBS=%~dp0lib\run-hidden.vbs"
set "PS1=%~dp0lib\config-manager-gui.ps1"

if not exist "%PS1%" (
    echo.
    echo ERROR: config-manager-gui.ps1 was not found next to this file.
    echo.
    pause
    exit /b 1
)

if exist "%VBS%" (
    start "" wscript.exe "%VBS%" config-manager-gui.ps1
    exit /b 0
)

rem Fallback if the shim is missing: brief console flash, same result.
start "" /B powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0
