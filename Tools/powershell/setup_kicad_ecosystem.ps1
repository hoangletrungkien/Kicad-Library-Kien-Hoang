<#
.SYNOPSIS
    KiCad Library Kien Hoang - Universal One-Click Setup.

.DESCRIPTION
    Tu dong tim KiCad, apply thu vien vao KiCad ngay lap tuc,
    cau hinh path variables, toi uu RAM va hieu suat, tich hop templates.
#>

[CmdletBinding()]
param(
    [ValidateSet('FULL','CUSTOM_ONLY')]
    [string]$Profile = 'FULL',
    [switch]$DryRun,
    [string]$Rollback,
    [switch]$SkipOptimize,
    [switch]$SkipTemplates
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:stepOk   = 0
$script:stepWarn = 0
$script:stepFail = 0
$script:log      = [System.Collections.Generic.List[string]]::new()

function Write-H1   { param($t) Write-Host "`n============================================================`n  $t`n============================================================" -ForegroundColor Cyan }
function Write-H2   { param($t) Write-Host "`n  -- $t" -ForegroundColor DarkCyan }
function Write-OK   { param($t) Write-Host "  [OK]   $t" -ForegroundColor Green;  $script:stepOk++;   $script:log.Add("[OK]   $t") }
function Write-WARN { param($t) Write-Host "  [WARN] $t" -ForegroundColor Yellow; $script:stepWarn++; $script:log.Add("[WARN] $t") }
function Write-FAIL { param($t) Write-Host "  [FAIL] $t" -ForegroundColor Red;    $script:stepFail++; $script:log.Add("[FAIL] $t") }
function Write-INFO { param($t) Write-Host "         $t";                      $script:log.Add("         $t") }
function Write-STEP { param($t) Write-Host "  -> $t" -ForegroundColor Gray }

$script:stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:backups = [System.Collections.Generic.List[string]]::new()

function Backup-KiCadFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $dest = "$Path.eco-backup-$($script:stamp)"
    if (-not $DryRun) { Copy-Item -LiteralPath $Path -Destination $dest -Force }
    $script:backups.Add($dest)
    Write-STEP "Backup: $(Split-Path $Path -Leaf) -> eco-backup-$($script:stamp)"
}

function Save-JsonFile {
    param([string]$Path, [object]$Obj)
    if (-not $DryRun) {
        $Obj | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "     KiCad Library Kien Hoang - Universal Auto Setup        " -ForegroundColor Cyan
Write-Host "     Tu dong tim KiCad - Cai thu vien truc tiep - Toi uu RAM" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-INFO "Thoi gian: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Mode: $(if($DryRun){'DRY RUN'}else{'APPLY'}) | Profile: $Profile"

# --- KIEM TRA TIEN TRINH KICAD DANG CHAY ---
$kicadProcs = Get-Process -Name "*kicad*" -ErrorAction SilentlyContinue
if ($kicadProcs) {
    Write-WARN "Phat hien KiCad dang mo: $($kicadProcs.Name -join ', ')"
    Write-WARN "KiCad co the ghi de lai file cau hinh khi ban dong chuong trinh."
    Write-WARN "Khuyen nghi: Hay LUU du an va DONG KICAD truoc khi setup de dat hieu qua cao nhat."
}

# --- ROLLBACK MODE ---
if ($Rollback) {
    Write-H1 "ROLLBACK - Khoi phuc backup $Rollback"
    $kicadCfg = "$env:APPDATA\kicad"
    $restored  = 0
    Get-ChildItem $kicadCfg -Recurse -Filter "*eco-backup-$Rollback" | ForEach-Object {
        $orig = $_.FullName -replace "\.eco-backup-$Rollback$", ''
        Write-STEP "Restore: $($_.Name) -> $(Split-Path $orig -Leaf)"
        if (-not $DryRun) { Copy-Item -LiteralPath $_.FullName -Destination $orig -Force }
        $restored++
    }
    if ($restored -eq 0) { Write-FAIL "Khong tim thay backup voi timestamp '$Rollback'" }
    else                 { Write-OK   "Da khoi phuc $restored files thanh cong. Hay khoi dong lai KiCad." }
    exit 0
}

# --- STEP 1: RESOLVE ECOSYSTEM ROOT ---
Write-H1 "BUOC 1 - Xac dinh Ecosystem Root"
$EcoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not (Test-Path "$EcoRoot\Libraries\Tables")) {
    Write-FAIL "Khong tim thay thu muc Tables tai: $EcoRoot\Libraries\Tables"
    exit 1
}
Write-OK "Ecosystem Root: $EcoRoot"

$TablesDir = Join-Path $EcoRoot 'Libraries\Tables'
$Models3D  = Join-Path $EcoRoot 'Libraries\3D_Models\Personal'
$TemplDir  = Join-Path $EcoRoot 'Templates'

# --- STEP 2: AUTO-DETECT KICAD ---
Write-H1 "BUOC 2 - Tu dong tim cai dat KiCad tren he thong"
$KiCadInstall = $null
$KiCadVer     = $null
$KiCadCli     = $null
$KiCadCfgDir  = $null

$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($rp in $regPaths) {
    $found = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like 'KiCad*' } |
             Sort-Object DisplayVersion -Descending |
             Select-Object -First 1
    if ($found) {
        $KiCadInstall = $found.InstallLocation.TrimEnd('\')
        $KiCadVer     = $found.DisplayVersion
        Write-STEP "Registry thay: $($found.DisplayName) v$KiCadVer tai $KiCadInstall"
        break
    }
}

$searchPaths = @()
if ($KiCadInstall) {
    $searchPaths += Join-Path $KiCadInstall 'bin\kicad-cli.exe'
}
$searchPaths += @(
    'C:\Program Files\KiCad\10.0\bin\kicad-cli.exe',
    'C:\Program Files\KiCad\9.0\bin\kicad-cli.exe',
    'C:\Program Files\KiCad\8.0\bin\kicad-cli.exe',
    'C:\Program Files (x86)\KiCad\10.0\bin\kicad-cli.exe',
    'C:\Program Files (x86)\KiCad\9.0\bin\kicad-cli.exe'
)
$fromPath = Get-Command kicad-cli -ErrorAction SilentlyContinue
if ($fromPath) { $searchPaths = @($fromPath.Source) + $searchPaths }

foreach ($p in $searchPaths) {
    if (Test-Path $p) {
        $KiCadCli = $p
        $cliVer   = try { (& $p version 2>$null | Select-Object -Last 1) } catch { "10.0" }
        if (-not $KiCadVer) { $KiCadVer = $cliVer }
        if (-not $KiCadInstall) { $KiCadInstall = Split-Path (Split-Path $p) }
        break
    }
}

if ($KiCadCli) {
    Write-OK "Phat hien KiCad CLI: $KiCadCli (Phien ban $KiCadVer)"
} else {
    Write-WARN "Khong tim thay kicad-cli.exe, tiep tuc su dung file cau hinh mac dinh."
}

$verSlot = '10.0'
if ($KiCadVer -and ($KiCadVer -match '^(\d+\.\d+)')) {
    $verSlot = $Matches[1]
}

$KiCadCfgDir = "$env:APPDATA\kicad\$verSlot"
if (-not (Test-Path $KiCadCfgDir)) {
    $existing = Get-ChildItem "$env:APPDATA\kicad" -ErrorAction SilentlyContinue |
                Where-Object PSIsContainer | Sort-Object Name -Descending | Select-Object -First 1
    if ($existing) {
        $KiCadCfgDir = $existing.FullName
        $verSlot     = $existing.Name
        Write-OK "Dung thu muc config hien co: $KiCadCfgDir (KiCad $verSlot)"
    } else {
        if (-not $DryRun) { New-Item -ItemType Directory -Path $KiCadCfgDir -Force | Out-Null }
        Write-OK "Khoi tao thu muc config moi: $KiCadCfgDir"
    }
} else {
    Write-OK "Thu muc cau hinh KiCad: $KiCadCfgDir"
}

$KiCadShareDir = $null
if ($KiCadInstall) {
    $shareDir = Join-Path $KiCadInstall 'share\kicad'
    if (Test-Path $shareDir) { $KiCadShareDir = $shareDir }
}
if (-not $KiCadShareDir) {
    @(
        "C:\Program Files\KiCad\$verSlot\share\kicad",
        "C:\Program Files\KiCad\share\kicad"
    ) | ForEach-Object { if ((Test-Path $_) -and -not $KiCadShareDir) { $KiCadShareDir = $_ } }
}
if ($KiCadShareDir) {
    Write-OK "Thu muc KiCad share: $KiCadShareDir"
}

# --- STEP 3: CONFIGURE PATH VARIABLES & COMMON JSON ---
Write-H1 "BUOC 3 - Dang ky Path Variables vao KiCad (kicad_common.json)"
$commonPath = Join-Path $KiCadCfgDir 'kicad_common.json'
$json = $null

if (Test-Path $commonPath) {
    Backup-KiCadFile $commonPath
    try {
        $json = Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-WARN "kicad_common.json khong hop le, khoi tao lai JSON sach."
        $json = [pscustomobject]@{}
    }
} else {
    $json = [pscustomobject]@{}
}

if (@($json.PSObject.Properties.Name) -notcontains 'environment') {
    $json | Add-Member -NotePropertyName 'environment' -NotePropertyValue ([pscustomobject]@{ vars = [pscustomobject]@{} })
}
if (@($json.environment.PSObject.Properties.Name) -notcontains 'vars' -or $null -eq $json.environment.vars) {
    $json.environment | Add-Member -NotePropertyName 'vars' -NotePropertyValue ([pscustomobject]@{}) -Force
}
$vars = $json.environment.vars

$vars | Add-Member -NotePropertyName 'KICAD_ECO_ROOT' -NotePropertyValue $EcoRoot -Force
Write-OK "KICAD_ECO_ROOT = $EcoRoot"

if (Test-Path $Models3D) {
    $vars | Add-Member -NotePropertyName 'KICAD_LIBRARY' -NotePropertyValue $Models3D -Force
    Write-OK "KICAD_LIBRARY  = $Models3D"
}

if (@($json.PSObject.Properties.Name) -notcontains 'session') {
    $json | Add-Member -NotePropertyName 'session' -NotePropertyValue ([pscustomobject]@{})
}
$json.session | Add-Member -NotePropertyName 'remember_open_files' -NotePropertyValue $false -Force
Write-OK "Toi uu session: remember_open_files = false (giam load RAM khi khoi dong)"

if (@($json.PSObject.Properties.Name) -notcontains 'system') {
    $json | Add-Member -NotePropertyName 'system' -NotePropertyValue ([pscustomobject]@{})
}
$json.system | Add-Member -NotePropertyName 'clear_3d_cache_interval' -NotePropertyValue 7 -Force
$json.system | Add-Member -NotePropertyName 'file_history_size' -NotePropertyValue 5 -Force
$json.system | Add-Member -NotePropertyName 'working_dir' -NotePropertyValue $EcoRoot -Force
Write-OK "Toi uu system: auto clear 3D cache = 7 days, working_dir = Ecosystem"

if (@($json.PSObject.Properties.Name) -notcontains 'graphics') {
    $json | Add-Member -NotePropertyName 'graphics' -NotePropertyValue ([pscustomobject]@{})
}
$json.graphics | Add-Member -NotePropertyName 'antialiasing_mode' -NotePropertyValue 0 -Force
Write-OK "Toi uu graphics: antialiasing_mode = 0 (tiet kiem RAM va GPU VRAM)"

Save-JsonFile $commonPath $json
Write-OK "Da apply cau hinh vao kicad_common.json"

# --- STEP 4: APPLY THU VIEN TRUC TIEP VAO KICAD ---
Write-H1 "BUOC 4 - Apply truc tiep cac thu vien vao KiCad ($Profile)"

$symSrc = Join-Path $TablesDir "sym-lib-table.$Profile"
$fpSrc  = Join-Path $TablesDir "fp-lib-table.$Profile"

if ((-not (Test-Path $symSrc)) -or (-not (Test-Path $fpSrc))) {
    Write-FAIL "Khong tim thay file table goc cho profile $Profile tai $TablesDir"
    exit 2
}

$symContent = Get-Content -LiteralPath $symSrc -Raw -Encoding UTF8
$fpContent  = Get-Content -LiteralPath $fpSrc  -Raw -Encoding UTF8

if ($verSlot -ne '10.0') {
    $symVarTarget = "KICAD$($verSlot.Replace('.',''))_SYMBOL_DIR"
    $fpVarTarget  = "KICAD$($verSlot.Replace('.',''))_FOOTPRINT_DIR"
    $symContent = $symContent -replace 'KICAD10_SYMBOL_DIR', $symVarTarget
    $fpContent  = $fpContent  -replace 'KICAD10_FOOTPRINT_DIR', $fpVarTarget
    Write-STEP "Chuyen doi ten bien theo KiCad $verSlot ($symVarTarget, $fpVarTarget)"
}

$symDst = Join-Path $KiCadCfgDir 'sym-lib-table'
$fpDst  = Join-Path $KiCadCfgDir 'fp-lib-table'

Backup-KiCadFile $symDst
Backup-KiCadFile $fpDst

$symCount = ([regex]::Matches($symContent, '\(lib ')).Count
$fpCount  = ([regex]::Matches($fpContent,  '\(lib ')).Count

if (-not $DryRun) {
    Set-Content -LiteralPath $symDst -Value $symContent -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath $fpDst  -Value $fpContent  -Encoding UTF8 -NoNewline
}

Write-OK "sym-lib-table: Da ghi truc tiep $symCount thu vien Symbol vao KiCad"
Write-OK "fp-lib-table:  Da ghi truc tiep $fpCount thu vien Footprint vao KiCad"

# --- STEP 5: TOI UU RAM VA HIEU SUAT TOAN DIEN ---
if (-not $SkipOptimize) {
    Write-H1 "BUOC 5 - Toi uu RAM, GPU va Hieu suat KiCad toan dien"

    # 5a. pcbnew.json
    $pcbnewPath = Join-Path $KiCadCfgDir 'pcbnew.json'
    if (Test-Path $pcbnewPath) {
        Backup-KiCadFile $pcbnewPath
        try {
            $pcb = Get-Content -LiteralPath $pcbnewPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($pcb.PSObject.Properties.Name) -contains 'ratsnest') {
                $pcb.ratsnest | Add-Member -NotePropertyName 'curved_ratsnest_lines' -NotePropertyValue $false -Force
            }
            Save-JsonFile $pcbnewPath $pcb
            Write-OK "pcbnew.json: Toi uu ratsnest thang (giam tai tinh toan GPU)"
        } catch {
            Write-WARN "Bo qua pcbnew.json: $_"
        }
    }

    # 5b. 3d_viewer.json
    $viewer3dPath = Join-Path $KiCadCfgDir '3d_viewer.json'
    if (Test-Path $viewer3dPath) {
        Backup-KiCadFile $viewer3dPath
        try {
            $v3d = Get-Content -LiteralPath $viewer3dPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($v3d.PSObject.Properties.Name) -contains 'camera') {
                $v3d.camera | Add-Member -NotePropertyName 'animation_enabled' -NotePropertyValue $false -Force
            }
            if (@($v3d.PSObject.Properties.Name) -contains 'render') {
                $v3d.render | Add-Member -NotePropertyName 'opengl_AA_mode' -NotePropertyValue 0 -Force
                $v3d.render | Add-Member -NotePropertyName 'raytrace_anti_aliasing' -NotePropertyValue $false -Force
                $v3d.render | Add-Member -NotePropertyName 'raytrace_shadows' -NotePropertyValue $false -Force
                $v3d.render | Add-Member -NotePropertyName 'raytrace_reflections' -NotePropertyValue $false -Force
                $v3d.render | Add-Member -NotePropertyName 'raytrace_refractions' -NotePropertyValue $false -Force
            }
            Save-JsonFile $viewer3dPath $v3d
            Write-OK "3d_viewer.json: Tat animation ngam va tat raytracing nang (tiet kiem RAM & VRAM)"
        } catch {
            Write-WARN "Bo qua 3d_viewer.json: $_"
        }
    }

    # 5c. kicad.json
    $kicadJsonPath = Join-Path $KiCadCfgDir 'kicad.json'
    if (Test-Path $kicadJsonPath) {
        Backup-KiCadFile $kicadJsonPath
        try {
            $kj = Get-Content -LiteralPath $kicadJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($kj.PSObject.Properties.Name) -contains 'system') {
                $kj.system | Add-Member -NotePropertyName 'check_for_kicad_updates' -NotePropertyValue $false -Force
            }
            if (@($kj.PSObject.Properties.Name) -contains 'pcm') {
                $kj.pcm | Add-Member -NotePropertyName 'check_for_updates' -NotePropertyValue $false -Force
            }
            Save-JsonFile $kicadJsonPath $kj
            Write-OK "kicad.json: Tat auto-update de tang toc khoi dong va giam background I/O"
        } catch {
            Write-WARN "Bo qua kicad.json: $_"
        }
    }
}

# --- STEP 6: DANG KY TEMPLATES ---
if (-not $SkipTemplates) {
    Write-H1 "BUOC 6 - Tich hop Worksheets va Project Templates"
    $userTemplDir = "$env:APPDATA\kicad\$verSlot\template"
    if (-not (Test-Path $userTemplDir)) {
        if (-not $DryRun) { New-Item -ItemType Directory -Path $userTemplDir -Force | Out-Null }
    }

    $wksSrc = Join-Path $TemplDir 'Local_Archive\Layout\Layout.kicad_wks'
    if (Test-Path $wksSrc) {
        $wksDst = Join-Path $userTemplDir 'Layout.kicad_wks'
        if (-not $DryRun) { Copy-Item -LiteralPath $wksSrc -Destination $wksDst -Force }
        Write-OK "Da copy Layout.kicad_wks vao user template folder"
    }

    $blocksSrc = Join-Path $TemplDir 'Local_Archive\Design-Blocks'
    if (Test-Path $blocksSrc) {
        if (-not $DryRun) { Copy-Item -Path "$blocksSrc\*" -Destination "$userTemplDir\" -Recurse -Force }
        Write-OK "Da copy design blocks vao user template folder"
    }
}

# --- SUMMARY ---
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                    KET QUA CAI DAT                         " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  [+] Da apply truc tiep vao KiCad thanh cong!" -ForegroundColor Green
Write-Host "  - KiCad config : $KiCadCfgDir" -ForegroundColor White
Write-Host "  - Symbol libs  : $symCount thu vien da apply vao sym-lib-table" -ForegroundColor White
Write-Host "  - Footprint libs: $fpCount thu vien da apply vao fp-lib-table" -ForegroundColor White
Write-Host "  - 3D Models    : Da dang ky KICAD_LIBRARY" -ForegroundColor White
Write-Host "  - Toi uu RAM   : Da bat antialiasing 0, giam cache, giam idle load, tat raytrace nang" -ForegroundColor White
Write-Host "  - Backup       : Timestamp $script:stamp" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  >>> LUU Y: Ban chi can RESTART KICAD la dung duoc ngay! <<<" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

exit 0

