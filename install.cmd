@echo off
setlocal enabledelayedexpansion

rem  install.cmd - the installer. Double-click this.
rem
rem  It wraps tools\deploy.ps1, which does the actual work. That script is kept
rem  out of the root, and not called install.ps1, so there is exactly one file
rem  here that looks like something to run - .ps1 does not work on double-click
rem  anyway.
rem
rem  Windows does not run .ps1 on double-click (it opens in an editor), and the
rem  default LocalMachine execution policy is RemoteSigned, which refuses an
rem  unsigned script that carries the Mark of the Web - which everything
rem  extracted from a downloaded zip does. A .cmd shim is the usual answer:
rem  Explorer will execute it, and it launches PowerShell with the right flags.
rem
rem  Arguments are passed straight through:
rem      install.cmd -WhatIf
rem      install.cmd -All
rem      install.cmd -Uninstall

set "PS1=%~dp0tools\deploy.ps1"

if not exist "%PS1%" (
    echo.
    echo ERROR: tools\deploy.ps1 was not found.
    echo Keep install.cmd next to the tools folder from the download.
    echo.
    goto :finish
)

rem Prefer PowerShell 7+ if present, else Windows PowerShell.
where pwsh.exe >nul 2>&1 && (set "PSEXE=pwsh.exe") || (set "PSEXE=powershell.exe")

rem Clear the Mark of the Web from the extracted files, so the deployed copies
rem do not inherit it. Failures here are not fatal.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo deploy.ps1 exited with code %RC%.
)

:finish
rem Pause only when there is nobody to read the output otherwise: launched with
rem no arguments AND started from Explorer rather than an existing console.
if not "%~1"=="" goto :eof
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 (
    echo.
    pause
)
