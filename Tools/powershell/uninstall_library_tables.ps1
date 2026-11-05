<#
.SYNOPSIS
    Undo a library-table installation performed by install_library_tables.ps1.

.DESCRIPTION
    Two modes:

      -Timestamp <stamp>   restore the exact backups taken during that install
      (default)            remove only entries the ecosystem owns, i.e. those
                           referencing ${KICAD_ECO_ROOT}, and drop the variable

    In both modes nothing is deleted from disk beyond the ecosystem-owned
    entries, and a fresh backup of the current state is taken first.

.PARAMETER Timestamp
    The timestamp reported by the installer (yyyyMMdd-HHmmss).

.PARAMETER DryRun
    Report every intended action and write nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall_library_tables.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File uninstall_library_tables.ps1 -Timestamp 20261031-113000
#>
[CmdletBinding()]
param(
    [string]$Timestamp,
    [switch]$DryRun,
    [string]$KiCadConfig
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step  { param([string]$m) Write-Host "  $m" }
function Write-Ok    { param([string]$m) Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

$VarName = 'KICAD_ECO_ROOT'

if (-not $KiCadConfig) { $KiCadConfig = Join-Path $env:APPDATA 'kicad\10.0' }
if (-not (Test-Path $KiCadConfig)) { Write-Err "KiCad config directory not found: $KiCadConfig"; exit 2 }

Write-Host "`nKiCad Ecosystem - library table uninstaller" -ForegroundColor Cyan
Write-Host ("=" * 62)
Write-Step "kicad config : $KiCadConfig"
Write-Step "mode         : $(if ($Timestamp) { "restore backup $Timestamp" } else { 'remove ecosystem-owned entries' })"
Write-Step "dry run      : $([bool]$DryRun)"
Write-Host ""

$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$restored = @()

function Restore-Backup {
    param([string]$Name)
    $src = Join-Path $KiCadConfig "$Name.eco-backup-$Timestamp"
    $dst = Join-Path $KiCadConfig $Name
    if (-not (Test-Path $src)) { Write-Warn2 "no backup found for $Name at $Timestamp"; return $false }
    if (-not $DryRun) {
        if (Test-Path $dst) { Copy-Item -LiteralPath $dst -Destination "$dst.pre-uninstall-$stamp" -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    $script:restored += $Name
    Write-Ok "restored $Name from backup"
    return $true
}

if ($Timestamp) {
    Restore-Backup 'sym-lib-table' | Out-Null
    Restore-Backup 'fp-lib-table'  | Out-Null
    Restore-Backup 'kicad_common.json' | Out-Null
} else {
    foreach ($name in @('sym-lib-table', 'fp-lib-table')) {
        $path = Join-Path $KiCadConfig $name
        if (-not (Test-Path $path)) { Write-Warn2 "$name not present"; continue }
        if (-not $DryRun) { Copy-Item -LiteralPath $path -Destination "$path.pre-uninstall-$stamp" -Force }

        $lines  = Get-Content -LiteralPath $path -Encoding UTF8
        $keep   = $lines | Where-Object { -not ($_ -match '^\s*\(lib ' -and $_ -match [regex]::Escape('${' + $VarName + '}')) }
        $removed = $lines.Count - $keep.Count

        if ($DryRun) {
            Write-Ok "$name would drop $removed ecosystem entr(y/ies), keep $($keep.Count - 2) line(s)"
        } else {
            Set-Content -LiteralPath $path -Value ($keep -join "`n") -Encoding UTF8
            Write-Ok "${name}: removed $removed ecosystem entr(y/ies)"
        }
    }

    $commonPath = Join-Path $KiCadConfig 'kicad_common.json'
    if (Test-Path $commonPath) {
        if (-not $DryRun) { Copy-Item -LiteralPath $commonPath -Destination "$commonPath.pre-uninstall-$stamp" -Force }
        try {
            $json = Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $hasVar = $json.environment -and $json.environment.vars -and
                      (@($json.environment.vars.PSObject.Properties.Name) -contains $VarName)
            $changed = $false
            if ($hasVar) {
                if (-not $DryRun) {
                    $json.environment.vars.PSObject.Properties.Remove($VarName)
                    $changed = $true
                }
                Write-Ok "$(if ($DryRun) { 'would remove' } else { 'removed' }) $VarName from kicad_common.json"
            } else {
                Write-Step "$VarName not present in kicad_common.json"
            }

            # KICAD_LIBRARY is removed only when it points at this ecosystem's
            # personal 3D root; any other value belongs to the user.
            $personal3d = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path '03_MASTER_LIBRARY\Custom_3D_Models\Personal'
            $hasLib = @($json.environment.vars.PSObject.Properties.Name) -contains 'KICAD_LIBRARY'
            if ($hasLib) {
                $normalize = { param($v) if ($null -eq $v) { '' } else { $v.ToString().Replace('/', '\').TrimEnd('\').ToLowerInvariant() } }
                if ((& $normalize $json.environment.vars.KICAD_LIBRARY) -eq (& $normalize $personal3d)) {
                    if (-not $DryRun) {
                        $json.environment.vars.PSObject.Properties.Remove('KICAD_LIBRARY')
                        $changed = $true
                    }
                    Write-Ok "$(if ($DryRun) { 'would remove' } else { 'removed' }) KICAD_LIBRARY (personal 3D) from kicad_common.json"
                } else {
                    Write-Warn2 "KICAD_LIBRARY points elsewhere ('$($json.environment.vars.KICAD_LIBRARY)') - left unchanged"
                }
            }
            if ($changed -and -not $DryRun) {
                $json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $commonPath -Encoding UTF8
            }
        } catch {
            Write-Err "could not parse kicad_common.json: $_"
        }
    }
}

Write-Host ""
Write-Host ("=" * 62)
if ($DryRun) { Write-Host "DRY RUN complete - nothing was changed." -ForegroundColor Yellow }
else         { Write-Host "Uninstall complete. Restart KiCad to take effect." -ForegroundColor Green }
Write-Host ""
exit 0
