<#
.SYNOPSIS
    KiCad RAM and Performance Optimizer.

.DESCRIPTION
    Quickly optimizes KiCad memory usage and rendering performance
    without modifying library tables or path variables.
    Compatible with KiCad 7.x through 10.x.

    Optimizations applied:
      1. kicad_advanced: Disable in-memory 3D model cache (Skip3DModelMemoryCache=1)
         and disable debug overlays/counters to free system RAM.
      2. eeschema.json: Disable footprint/3D auto-preview in symbol chooser
         to prevent freezing and RAM surges when placing schematic components.
      3. pcbnew.json: Disable live_3d_refresh to stop background 3D ray-tracing
         while routing or editing PCB.
      4. 3d_viewer.json: Enable bounding-box mode during motion (60 FPS navigation),
         disable heavy raytracing anti-aliasing & procedural textures.
      5. kicad_common.json: Set 3D model cache purge interval to 1 day.
      6. fp-lib-table: Disable raw uncompiled recursive folders if present.

.EXAMPLE
    .\optimize_kicad_performance.ps1
    .\optimize_kicad_performance.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [switch]$DryRun,

    [ValidatePattern('^\d+\.\d+$')]
    [string]$KiCadVersion
)

$setupScript = Join-Path $PSScriptRoot 'setup_kicad_ecosystem.ps1'
if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    Write-Error "Core setup script not found at: $setupScript"
    exit 1
}

$params = @{
    OptimizeOnly = $true
}

if ($DryRun) {
    $params['DryRun'] = $true
}

if ($KiCadVersion) {
    $params['KiCadVersion'] = $KiCadVersion
}

& $setupScript @params
exit $LASTEXITCODE
