
@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
title KiCad Library Kien Hoang - Auto Setup
color 0B

set "ROOT=%~dp0"
set "PS1=%ROOT%Tools\powershell\setup_kicad_ecosystem.ps1"
set "EXITCODE=1"

:menu
cls
echo.
echo  ==============================================================
echo       KiCad Library Kien Hoang - Universal Auto Setup
echo       Safe Integration ^| Backup ^| Rollback
echo  ==============================================================
echo.
echo  Library: "%ROOT%"
echo.
echo  MAIN MENU
echo  --------------------------------------------------------------
echo.
echo    [1] FULL SETUP
echo        Complete library collection + Performance Optimization
echo.
echo    [2] CUSTOM SETUP
echo        Personal and additional libraries + Optimization
echo.
echo    [3] MAINTENANCE
echo        Optimize / Dry Run / Rollback
echo.
echo    [0] EXIT
echo.
echo  --------------------------------------------------------------

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo  [ERROR] Windows PowerShell was not found.
    pause
    exit /b 1
)

if not exist "%PS1%" (
    echo.
    echo  [ERROR] Setup script not found:
    echo  "%PS1%"
    echo.
    echo  Expected:
    echo  Tools\powershell\setup_kicad_ecosystem.ps1
    pause
    exit /b 1
)

choice /C 1230 /N /M "  Select an option [0-3]: "

if errorlevel 4 goto :end
if errorlevel 3 goto :maintenance
if errorlevel 2 goto :custom
if errorlevel 1 goto :full

goto :end


:full
set "ARGS=-Profile FULL -OptimizePerformance"
echo.
echo  [INFO] FULL SETUP selected.
goto :run


:custom
set "ARGS=-Profile CUSTOM_ONLY -OptimizePerformance"
echo.
echo  [INFO] CUSTOM SETUP selected.
goto :run


:maintenance
cls
echo.
echo  ==============================================================
echo                   MAINTENANCE CENTER
echo  ==============================================================
echo.
echo    [1] OPTIMIZE ONLY
echo        RAM and KiCad performance optimization
echo.
echo    [2] DRY RUN
echo        Validate setup without changing files
echo.
echo    [3] ROLLBACK
echo        Restore a previous setup backup
echo.
echo    [0] BACK TO MAIN MENU
echo.
echo  --------------------------------------------------------------

choice /C 1230 /N /M "  Select an option [0-3]: "

if errorlevel 4 goto :menu
if errorlevel 3 goto :rollback
if errorlevel 2 goto :dryrun
if errorlevel 1 goto :optimize

goto :menu


:optimize
set "ARGS=-OptimizeOnly"
echo.
echo  [INFO] PERFORMANCE OPTIMIZATION selected.
goto :run


:dryrun
set "ARGS=-Profile FULL -DryRun -OptimizePerformance"
echo.
echo  [INFO] DRY RUN selected.
goto :run


:rollback
cls
echo.
echo  ==============================================================
echo                       ROLLBACK
echo  ==============================================================
echo.
echo  Backup directory:
echo  %LOCALAPPDATA%\KiCad Library Kien Hoang\Backups
echo.
echo  Enter the backup timestamp (YYYYMMDD-HHMMSS).
echo.
set "ROLLBACK_ID="
set /p "ROLLBACK_ID=  Backup timestamp: "

if not defined ROLLBACK_ID (
    echo.
    echo  [WARNING] No backup timestamp provided.
    pause
    goto :maintenance
)

set "ARGS=-Rollback "%ROLLBACK_ID%""
echo.
echo  [INFO] Rollback selected.
goto :run


:run
echo.
echo  --------------------------------------------------------------
echo  Starting KiCad Library Kien Hoang...
echo  --------------------------------------------------------------
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
set "EXITCODE=%ERRORLEVEL%"

goto :finish


:finish
echo.
echo  --------------------------------------------------------------

if "%EXITCODE%"=="0" (
    echo  [SUCCESS] Operation completed successfully.
) else (
    echo  [WARNING] Operation ended with exit code %EXITCODE%.
    echo  Review the messages above before using KiCad.
)

echo  --------------------------------------------------------------
echo.
pause
goto :menu


:end
echo.
echo  Exiting KiCad Library Setup.
exit /b 0
