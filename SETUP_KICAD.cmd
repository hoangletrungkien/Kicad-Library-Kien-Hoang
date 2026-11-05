@echo off
chcp 65001 >nul
title KiCad Library Kien Hoang - Universal Auto Setup
color 0B

echo.
echo  ==============================================================
echo     KiCad Library Kien Hoang - Universal Auto Setup
echo     Tu dong tim KiCad - Apply thu vien truc tiep - Toi uu RAM
echo  ==============================================================
echo.
echo  Thu muc thu vien: %~dp0
echo.

:: 1. Kiem tra PowerShell
where powershell >nul 2>&1
if errorlevel 1 (
    echo  [LOI] Khong tim thay PowerShell tren Windows!
    pause
    exit /b 1
)

:: 2. Xac dinh script PS1
set "PS1=%~dp0Tools\powershell\setup_kicad_ecosystem.ps1"

if not exist "%PS1%" (
    echo  [LOI] Khong tim thay script: %PS1%
    echo  Hay dam bao file SETUP_KICAD.cmd nam o thu muc goc Kicad_Library_KienHoang\
    pause
    exit /b 1
)

:: 3. Canh bao tien trinh KiCad dang chay
tasklist /FI "IMAGENAME eq kicad.exe" 2>nul | find /I /N "kicad.exe">nul
if "%ERRORLEVEL%"=="0" (
    echo  [CANH BAO] KiCad dang duoc mo tren may tinh!
    echo  De KiCad khong ghi de file cau hinh, ban nen DONG KICAD truoc khi tiep tuc.
    echo.
)

:: 4. Menu lua chon tu dong
echo  Chon che do cai dat:
echo.
echo    [1] FULL    - Tat ca thu vien (Chinh thuc KiCad + Antmicro + Personal) [Khuyen nghi]
echo    [2] CUSTOM  - Chi thu vien Antmicro + Personal (Khoi dong KiCad cuc nhanh)
echo    [3] DRY RUN - Chi kiem tra, KHONG ghi thay doi
echo    [4] Thoat
echo.
set /p "choice=  Nhap lua chon [1-4, mac dinh=1]: "

if "%choice%"==""  set "choice=1"
if "%choice%"=="4" exit /b 0

if "%choice%"=="1" (
    set "ARGS=-Profile FULL"
    echo.
    echo  [INFO] Che do: FULL profile (Apply toan bo 342 symbols + 256 footprints)
)
if "%choice%"=="2" (
    set "ARGS=-Profile CUSTOM_ONLY"
    echo.
    echo  [INFO] Che do: CUSTOM_ONLY profile (Apply 119 symbols + 101 footprints)
)
if "%choice%"=="3" (
    set "ARGS=-Profile FULL -DryRun"
    echo.
    echo  [INFO] Che do: DRY RUN (Kiem tra mo phong)
)

echo.
echo  Dang tu dong tim KiCad, apply thu vien va toi uu RAM...
echo  --------------------------------------------------------------
echo.

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%PS1%" %ARGS%

set "EXITCODE=%errorlevel%"

echo.
echo  --------------------------------------------------------------
if %EXITCODE%==0 (
    echo  [THANH CONG] Toan bo quy trinh da duoc thuc hien tu dong!
    if not "%choice%"=="3" (
        echo.
        echo  >>> HAY RESTART HOAC MO KICAD DE SU DUNG THU VIEN MOI NGAY! <<<
    )
) else (
    echo  [CANH BAO] Qua trinh ket thuc voi ma loi %EXITCODE%. Vui long kiem tra thong bao o tren.
)

echo.
pause
exit /b %EXITCODE%

