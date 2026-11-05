<#
.SYNOPSIS
    Install a managed KiCad library-table profile from the professional ecosystem.

.DESCRIPTION
    Registers the ecosystem's curated library overlay with KiCad in a fully
    reversible way:

      1. backs up the live sym-lib-table / fp-lib-table / kicad_common.json
      2. registers the KICAD_ECO_ROOT path variable in kicad_common.json
      3. optionally registers KICAD_LIBRARY for the personal 3D models
      4. writes the selected profile table

    Nothing is written unless -DryRun is omitted. Every file touched is backed
    up first, and -Merge preserves unrelated entries instead of replacing the
    whole table.

    This script never edits, moves or deletes anything inside the source
    libraries, and never registers a KiCad official library a second time.

.PARAMETER Profile
    FULL            official libraries + the custom overlay
    CUSTOM_ONLY     the custom overlay only (fastest KiCad startup)

.PARAMETER DryRun
    Report every intended action and write nothing.

.PARAMETER Merge
    Keep existing entries that the ecosystem does not own, instead of
    replacing the table with the selected profile.

.PARAMETER RegisterPersonal3D
    Also set KICAD_LIBRARY to the personal 3D model root, which is the variable
    the personal footprints reference. An existing KICAD_LIBRARY with a
    different value is never overwritten; a warning is printed instead.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install_library_tables.ps1 -Profile CUSTOM_ONLY -DryRun
    powershell -ExecutionPolicy Bypass -File install_library_tables.ps1 -Profile CUSTOM_ONLY
#>
[CmdletBinding()]
param(
    [ValidateSet('FULL', 'CUSTOM_ONLY')]
    [string]$Profile = 'CUSTOM_ONLY',

    [switch]$DryRun,

    [switch]$Merge,

    [switch]$RegisterPersonal3D,

    [string]$EcoRoot,

    [string]$KiCadConfig
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step  { param([string]$m) Write-Host "  $m" }
function Write-Ok    { param([string]$m) Write-Host "  [ OK ] $m"   -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  [WARN] $m"   -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "  [FAIL] $m"   -ForegroundColor Red }

# --------------------------------------------------------------------------- #
# resolve roots
# --------------------------------------------------------------------------- #
if (-not $EcoRoot) {
    $EcoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
if (-not (Test-Path $EcoRoot)) { Write-Err "ecosystem root not found: $EcoRoot"; exit 2 }
$EcoRoot = (Resolve-Path $EcoRoot).Path

if (-not $KiCadConfig) {
    $KiCadConfig = Join-Path $env:APPDATA 'kicad\10.0'
}
$tablesDir = Join-Path $EcoRoot '03_MASTER_LIBRARY\Tables'

Write-Host "`nKiCad Ecosystem - library table installer" -ForegroundColor Cyan
Write-Host ("=" * 62)
Write-Step "ecosystem root : $EcoRoot"
Write-Step "kicad config   : $KiCadConfig"
Write-Step "profile        : $Profile"
Write-Step "mode           : $(if ($DryRun) { 'DRY RUN (no changes)' } else { 'APPLY' })"
Write-Step "merge          : $Merge"
Write-Host ""

if (-not (Test-Path $KiCadConfig)) { Write-Err "KiCad config directory not found: $KiCadConfig"; exit 2 }

$symSource = Join-Path $tablesDir "sym-lib-table.$Profile"
$fpSource  = Join-Path $tablesDir "fp-lib-table.$Profile"
foreach ($f in @($symSource, $fpSource)) {
    if (-not (Test-Path $f)) { Write-Err "profile table missing: $f"; exit 2 }
}

# --------------------------------------------------------------------------- #
# backup
# --------------------------------------------------------------------------- #
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$backups = @()

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $dest = "$Path.eco-backup-$stamp"
    if (-not $DryRun) { Copy-Item -LiteralPath $Path -Destination $dest -Force }
    $script:backups += $dest
    Write-Ok "backed up $(Split-Path $Path -Leaf) -> $(Split-Path $dest -Leaf)"
}

Backup-File (Join-Path $KiCadConfig 'sym-lib-table')
Backup-File (Join-Path $KiCadConfig 'fp-lib-table')
Backup-File (Join-Path $KiCadConfig 'kicad_common.json')

# --------------------------------------------------------------------------- #
# register the path variable
# --------------------------------------------------------------------------- #
$commonPath = Join-Path $KiCadConfig 'kicad_common.json'
if (Test-Path $commonPath) {
    try {
        $json = Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Err "kicad_common.json is not valid JSON - refusing to edit it: $_"
        exit 3
    }

    # NOTE: PSObject.Properties.Name yields $null (not an empty array) for an
    # object with no properties, so .Contains() would throw. Always wrap in @()
    # and use -contains / -notcontains.
    if (@($json.PSObject.Properties.Name) -notcontains 'environment') {
        $json | Add-Member -NotePropertyName environment -NotePropertyValue ([pscustomobject]@{ vars = [pscustomobject]@{} })
    }
    if (@($json.environment.PSObject.Properties.Name) -notcontains 'vars' -or $null -eq $json.environment.vars) {
        $json.environment | Add-Member -NotePropertyName vars -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $existing = $null
    if (@($json.environment.vars.PSObject.Properties.Name) -contains 'KICAD_ECO_ROOT') {
        $existing = $json.environment.vars.KICAD_ECO_ROOT
    }

    if ($existing -eq $EcoRoot) {
        Write-Ok "KICAD_ECO_ROOT already correct: $EcoRoot"
    } else {
        if ($existing) { Write-Warn2 "KICAD_ECO_ROOT changes: '$existing' -> '$EcoRoot'" }
        else           { Write-Step "KICAD_ECO_ROOT will be set to: $EcoRoot" }
        if (-not $DryRun) {
            $json.environment.vars | Add-Member -NotePropertyName KICAD_ECO_ROOT -NotePropertyValue $EcoRoot -Force
            $json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $commonPath -Encoding UTF8
        }
        Write-Ok "KICAD_ECO_ROOT registered"
    }
} else {
    Write-Warn2 "kicad_common.json not present; define KICAD_ECO_ROOT manually in KiCad > Configure Paths"
}

# --------------------------------------------------------------------------- #
# optional: KICAD_LIBRARY for the personal 3D models
# --------------------------------------------------------------------------- #
if ($RegisterPersonal3D -and (Test-Path $commonPath) -and $null -ne $json) {
    $personal3d = (Join-Path $EcoRoot '03_MASTER_LIBRARY\Custom_3D_Models\Personal')
    if (-not (Test-Path $personal3d)) {
        Write-Warn2 "personal 3D root not found, KICAD_LIBRARY not set: $personal3d"
    } else {
        $existingLib = $null
        if (@($json.environment.vars.PSObject.Properties.Name) -contains 'KICAD_LIBRARY') {
            $existingLib = $json.environment.vars.KICAD_LIBRARY
        }
        $normalize = { param($v) if ($null -eq $v) { '' } else { $v.ToString().Replace('/', '\').TrimEnd('\').ToLowerInvariant() } }
        if ((& $normalize $existingLib) -eq (& $normalize $personal3d)) {
            Write-Ok "KICAD_LIBRARY already correct: $personal3d"
        } elseif ($existingLib) {
            Write-Warn2 "KICAD_LIBRARY already set to '$existingLib' - NOT overwritten."
            Write-Warn2 "Personal footprints use `${KICAD_LIBRARY}/3D/...; set it manually if that path is wrong."
        } else {
            Write-Step "KICAD_LIBRARY will be set to: $personal3d"
            if (-not $DryRun) {
                $json.environment.vars | Add-Member -NotePropertyName KICAD_LIBRARY -NotePropertyValue $personal3d -Force
                $json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $commonPath -Encoding UTF8
            }
            Write-Ok "KICAD_LIBRARY registered (personal 3D)"
        }
    }
}

# --------------------------------------------------------------------------- #
# write the tables
# --------------------------------------------------------------------------- #
function Install-Table {
    param([string]$Source, [string]$TargetName, [string]$RootTag, [string]$VarName)

    $target = Join-Path $KiCadConfig $TargetName
    $new    = Get-Content -LiteralPath $Source -Raw -Encoding UTF8

    if ($Merge -and (Test-Path $target)) {
        # keep only entries the ecosystem does not own
        $kept = (Get-Content -LiteralPath $target -Encoding UTF8) |
                Where-Object { $_ -match '^\s*\(lib ' -and $_ -notmatch [regex]::Escape('${' + $VarName + '}') }
        $body = ($kept -join "`n")
        $new  = $new -replace '\)\s*$', "$body`n)"
        Write-Step "merge: preserved $($kept.Count) foreign entr(y/ies)"
    }

    $count = ([regex]::Matches($new, '\(lib ')).Count
    if ($DryRun) {
        Write-Ok "$TargetName would be written with $count entr(y/ies)"
    } else {
        Set-Content -LiteralPath $target -Value $new -Encoding UTF8 -NoNewline
        Write-Ok "$TargetName written with $count entr(y/ies)"
    }
}

Install-Table -Source $symSource -TargetName 'sym-lib-table' -RootTag 'sym' -VarName 'KICAD_ECO_ROOT'
Install-Table -Source $fpSource  -TargetName 'fp-lib-table'  -RootTag 'fp'  -VarName 'KICAD_ECO_ROOT'

# --------------------------------------------------------------------------- #
# summary
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host ("=" * 62)
if ($DryRun) {
    Write-Host "DRY RUN complete - nothing was changed." -ForegroundColor Yellow
    Write-Host "Re-run without -DryRun to apply." -ForegroundColor Yellow
} else {
    Write-Host "Installation complete." -ForegroundColor Green
    Write-Host "Restart KiCad for the library tables to take effect."
}
Write-Host ""
Write-Host "Backups created:" -ForegroundColor Cyan
if ($backups.Count -eq 0) { Write-Host "  (none - no pre-existing files)" }
else { $backups | ForEach-Object { Write-Host "  $_" } }
Write-Host ""
Write-Host "To undo: run uninstall_library_tables.ps1 -Timestamp $stamp" -ForegroundColor Cyan
exit 0
