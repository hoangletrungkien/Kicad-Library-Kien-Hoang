@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
title KiCad Library Kien Hoang - Universal Auto Setup
color 0B

set "ROOT=%~dp0"
set "PS1=%ROOT%Tools\powershell\setup_kicad_ecosystem.ps1"
set "EXITCODE=1"

cls
echo.
echo  ==============================================================
echo     KiCad Library Kien Hoang - Universal Auto Setup
echo     Safe library integration - Backup and rollback enabled
echo  ==============================================================
echo.
echo  Library directory: "%ROOT%"
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo  [ERROR] Windows PowerShell was not found.
    echo  Please enable Windows PowerShell and try again.
    pause
    exit /b 1
)

if not exist "%PS1%" (
    echo  [ERROR] Setup script not found:
    echo  "%PS1%"
    echo.
    echo  Expected structure:
    echo  KiCad_Library_KienHoang\
    echo      SETUP_KICAD.cmd
    echo      Tools\powershell\setup_kicad_ecosystem.ps1
    pause
    exit /b 1
)

echo  Select an action:
echo.
echo    [1] FULL       - Complete library collection
echo    [2] CUSTOM     - Additional and personal libraries
echo    [3] DRY RUN    - Validate without changing files
echo    [4] ROLLBACK   - Restore a previous setup backup
echo    [5] EXIT
echo.
choice /C 12345 /N /M "  Enter your choice [1-5]: "

if errorlevel 5 goto :end
if errorlevel 4 goto :rollback
if errorlevel 3 goto :dryrun
if errorlevel 2 goto :custom
if errorlevel 1 goto :full

goto :end

:full
echo.
echo  [INFO] Selected profile: FULL
set "ARGS=-Profile FULL"
goto :run

:custom
echo.
echo  [INFO] Selected profile: CUSTOM_ONLY
set "ARGS=-Profile CUSTOM_ONLY"
goto :run

:dryrun
echo.
echo  [INFO] Selected mode: DRY RUN
set "ARGS=-Profile FULL -DryRun"
goto :run

:rollback
echo.
echo  Backups are stored under:
echo  %LOCALAPPDATA%\KiCad Library Kien Hoang\Backups\
echo.
set /p "ROLLBACK_ID=  Enter backup timestamp (YYYYMMDD-HHMMSS): "
if not defined ROLLBACK_ID (
    echo  [ERROR] No backup timestamp was provided.
    goto:finish
)
set "ARGS=-Rollback "%ROLLBACK_ID%""
goto :run

:run
echo.
echo  --------------------------------------------------------------
echo  Starting KiCad Library Kien Hoang setup...
echo  --------------------------------------------------------------
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
set "EXITCODE=%ERRORLEVEL%"
goto:finish

:finish
echo.
echo  --------------------------------------------------------------
if "%EXITCODE%"=="0" (
    echo  [SUCCESS] Operation completed.
) else (
    echo  [WARNING] Operation ended with exit code %EXITCODE%.
    echo  Review the messages above before using KiCad.
)
echo  --------------------------------------------------------------
echo.
pause
exit /b %EXITCODE%

:end
exit /b 0
