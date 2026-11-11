<#
.SYNOPSIS
    KiCad Library Kien Hoang - Universal Safe Setup.

.DESCRIPTION
    Detects an installed KiCad version, safely merges the selected symbol and
    footprint library tables, registers only the path variables used by those
    tables, optionally copies missing templates, and creates reversible backups.

    The installer does not modify KiCad installation files, project files,
    editor preference files, graphics settings, or unrelated user settings.

.NOTES
    Compatible with Windows PowerShell 5.1 and KiCad 7.x through 10.x.
#>

[CmdletBinding()]
param(
    [ValidateSet('FULL', 'CUSTOM_ONLY')]
    [string]$Profile = 'FULL',

    [switch]$DryRun,

    [string]$Rollback,

    [switch]$SkipTemplates,

    [ValidatePattern('^\d+\.\d+$')]
    [string]$KiCadVersion
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$script:StepOK = 0
$script:StepWarn = 0
$script:StepFail = 0
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:BackupRoot = Join-Path $env:LOCALAPPDATA 'KiCad Library Kien Hoang\Backups'
$script:BackupDir = $null
$script:ManifestPath = $null
$script:Manifest = New-Object 'System.Collections.Generic.List[object]'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-H1 {
    param([string]$Text)
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Write-H2 {
    param([string]$Text)
    Write-Host "`n  -- $Text" -ForegroundColor DarkCyan
}

function Write-OK {
    param([string]$Text)
    Write-Host "  [OK]   $Text" -ForegroundColor Green
    $script:StepOK++
}

function Write-WARN {
    param([string]$Text)
    Write-Host "  [WARN] $Text" -ForegroundColor Yellow
    $script:StepWarn++
}

function Write-FAIL {
    param([string]$Text)
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
    $script:StepFail++
}

function Write-INFO {
    param([string]$Text)
    Write-Host "         $Text"
}

function Write-STEP {
    param([string]$Text)
    Write-Host "  -> $Text" -ForegroundColor Gray
}

function Get-VersionSlot {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, '(\d+\.\d+)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function Get-KiCadProcessList {
    $processNames = @(
        'kicad',
        'pcbnew',
        'eeschema',
        'gerbview',
        'pl_editor',
        'pcb_calculator',
        'bitmap2component'
    )

    return @(Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Sort-Object Id -Unique)
}

function Get-InstalledKiCadCandidates {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}

    $roots = @()
    if ($env:ProgramFiles) {
        $roots += (Join-Path $env:ProgramFiles 'KiCad')
    }
    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'KiCad')
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($versionDir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($versionDir.Name -notmatch '^\d+\.\d+$') {
                continue
            }

            $cli = Join-Path $versionDir.FullName 'bin\kicad-cli.exe'
            if (Test-Path -LiteralPath $cli -PathType Leaf) {
                $key = $versionDir.Name
                if (-not $seen.ContainsKey($key)) {
                    $items.Add([pscustomobject]@{
                        Version     = $key
                        InstallRoot = $versionDir.FullName
                        CliPath     = $cli
                        Source      = 'Installation folder'
                    })
                    $seen[$key] = $true
                }
            }
        }
    }

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($registryPath in $registryPaths) {
        $apps = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        foreach ($app in $apps) {
            if ($app.DisplayName -notmatch '^KiCad(?:\s|$)') {
                continue
            }

            $slot = Get-VersionSlot -VersionText ([string]$app.DisplayVersion)
            if (-not $slot) {
                $slot = Get-VersionSlot -VersionText ([string]$app.DisplayName)
            }
            if (-not $slot -or $seen.ContainsKey($slot)) {
                continue
            }

            $installRoot = [string]$app.InstallLocation
            if ([string]::IsNullOrWhiteSpace($installRoot)) {
                continue
            }

            $installRoot = $installRoot.Trim().Trim('"').TrimEnd('\')
            $cli = Join-Path $installRoot 'bin\kicad-cli.exe'
            if (Test-Path -LiteralPath $cli -PathType Leaf) {
                $items.Add([pscustomobject]@{
                    Version     = $slot
                    InstallRoot = $installRoot
                    CliPath     = $cli
                    Source      = 'Windows registry'
                })
                $seen[$slot] = $true
            }
        }
    }

    $pathCommand = Get-Command 'kicad-cli.exe' -ErrorAction SilentlyContinue
    if ($pathCommand -and $pathCommand.Source -and (Test-Path -LiteralPath $pathCommand.Source)) {
        $cliPath = $pathCommand.Source
        $installRoot = Split-Path -Parent (Split-Path -Parent $cliPath)
        $slot = Get-VersionSlot -VersionText (Split-Path -Leaf $installRoot)

        if (-not $slot) {
            try {
                $versionOutput = & $cliPath version 2>$null | Out-String
                $slot = Get-VersionSlot -VersionText $versionOutput
            }
            catch {
                $slot = $null
            }
        }

        if ($slot -and -not $seen.ContainsKey($slot)) {
            $items.Add([pscustomobject]@{
                Version     = $slot
                InstallRoot = $installRoot
                CliPath     = $cliPath
                Source      = 'PATH'
            })
            $seen[$slot] = $true
        }
    }

    return @($items.ToArray())
}

function Get-ConfigBaseDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:KICAD_CONFIG_HOME)) {
        return [System.IO.Path]::GetFullPath($env:KICAD_CONFIG_HOME)
    }

    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is not defined. Cannot locate the KiCad user configuration directory.'
    }

    return Join-Path $env:APPDATA 'kicad'
}

function Resolve-KiCadTarget {
    param([string]$RequestedVersion)

    $configBase = Get-ConfigBaseDirectory
    $candidates = @(Get-InstalledKiCadCandidates)
    $selected = $null

    if ($RequestedVersion) {
        $selected = $candidates | Where-Object { $_.Version -eq $RequestedVersion } | Select-Object -First 1
        if (-not $selected) {
            $requestedConfig = Join-Path $configBase $RequestedVersion
            if (-not (Test-Path -LiteralPath $requestedConfig -PathType Container)) {
                throw "KiCad $RequestedVersion was not detected and its configuration folder does not exist."
            }
        }
    }
    elseif ($candidates.Count -gt 0) {
        $selected = $candidates | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    }

    if ($selected) {
        $versionSlot = $selected.Version
        $installRoot = $selected.InstallRoot
        $cliPath = $selected.CliPath
        Write-OK "Detected KiCad $versionSlot ($($selected.Source))"
        Write-INFO "Install folder: $installRoot"
        Write-INFO "KiCad CLI: $cliPath"
    }
    else {
        if ($RequestedVersion) {
            $versionSlot = $RequestedVersion
        }
        else {
            $existingConfigs = @()
            if (Test-Path -LiteralPath $configBase -PathType Container) {
                $existingConfigs = @(Get-ChildItem -LiteralPath $configBase -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+\.\d+$' } |
                    Sort-Object { [version]$_.Name } -Descending)
            }

            if ($existingConfigs.Count -eq 0) {
                throw 'KiCad could not be detected. Install KiCad or run with -KiCadVersion <major.minor> after creating its configuration folder.'
            }

            $versionSlot = $existingConfigs[0].Name
            Write-WARN "KiCad CLI was not detected. Using existing configuration folder for KiCad $versionSlot."
        }

        $installRoot = $null
        $cliPath = $null
    }

    $configDirectory = Join-Path $configBase $versionSlot

    return [pscustomobject]@{
        Version      = $versionSlot
        InstallRoot  = $installRoot
        CliPath      = $cliPath
        ConfigBase   = $configBase
        ConfigDir    = $configDirectory
    }
}

function Read-TextFile {
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    return $text
}

function Write-TextAtomic {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = Join-Path $directory ((Split-Path -Leaf $Path) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $script:Utf8NoBom)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-Manifest {
    if ($DryRun -or -not $script:ManifestPath) {
        return
    }

    $manifestObject = [pscustomobject]@{
        Product   = 'KiCad Library Kien Hoang'
        Timestamp = $script:Stamp
        Entries   = @($script:Manifest.ToArray())
    }

    $jsonText = ConvertTo-Json -InputObject $manifestObject -Depth 12
    $manifestDirectory = Split-Path -Parent $script:ManifestPath
    if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($script:ManifestPath, $jsonText, $script:Utf8NoBom)
}

function Register-Backup {
    param([string]$Path)

    if ($DryRun) {
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($entry in $script:Manifest) {
        if ([string]::Equals($entry.OriginalPath, $fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    if (-not (Test-Path -LiteralPath $script:BackupDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }

    $existed = Test-Path -LiteralPath $fullPath -PathType Leaf
    $backupPath = $null

    if ($existed) {
        $index = $script:Manifest.Count + 1
        $backupName = '{0:D3}_{1}' -f $index, (Split-Path -Leaf $fullPath)
        $backupPath = Join-Path $script:BackupDir $backupName
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
    }

    $script:Manifest.Add([pscustomobject]@{
        OriginalPath = $fullPath
        Existed      = [bool]$existed
        BackupPath   = $backupPath
    })

    Save-Manifest
    Write-STEP "Backup recorded: $fullPath"
}

function Restore-Manifest {
    param(
        [object[]]$Entries,
        [switch]$Preview
    )

    $restored = 0
    $failed = 0

    $entryArray = @($Entries)
    if ($entryArray.Count -eq 0) {
        return [pscustomobject]@{ Restored = 0; Failed = 0 }
    }

    for ($entryIndex = $entryArray.Count - 1; $entryIndex -ge 0; $entryIndex--) {
        $entry = $entryArray[$entryIndex]
        $target = [string]$entry.OriginalPath
        try {
            if ($entry.Existed) {
                $backupPath = [string]$entry.BackupPath
                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                    throw "Backup file is missing: $backupPath"
                }

                if ($Preview) {
                    Write-STEP "Would restore: $target"
                }
                else {
                    $targetDirectory = Split-Path -Parent $target
                    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
                    }
                    $restoreTemp = $target + '.restore-' + [guid]::NewGuid().ToString('N')
                    Copy-Item -LiteralPath $backupPath -Destination $restoreTemp -Force
                    Move-Item -LiteralPath $restoreTemp -Destination $target -Force
                    Write-OK "Restored: $target"
                }
            }
            else {
                if ($Preview) {
                    Write-STEP "Would remove newly created file: $target"
                }
                elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                    Remove-Item -LiteralPath $target -Force
                    Write-OK "Removed file created by setup: $target"
                }
                else {
                    Write-INFO "No file to remove: $target"
                }
            }
            $restored++
        }
        catch {
            Write-FAIL "Could not restore $target : $_"
            $failed++
        }
    }

    return [pscustomobject]@{
        Restored = $restored
        Failed   = $failed
    }
}

function Invoke-Rollback {
    param([string]$Timestamp)

    if ($Timestamp -notmatch '^\d{8}-\d{6}$') {
        throw 'Invalid backup timestamp. Expected format: YYYYMMDD-HHMMSS.'
    }

    $backupDirectory = Join-Path $script:BackupRoot $Timestamp
    $manifestPath = Join-Path $backupDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        # Backward compatibility with backups made by the previous installer.
        $legacyRoots = @()
        if ($env:APPDATA) {
            $legacyRoots += (Join-Path $env:APPDATA 'kicad')
        }
        try {
            $legacyRoots += (Get-ConfigBaseDirectory)
        }
        catch {
            # No custom configuration root is available; continue with APPDATA.
        }

        $legacyFiles = New-Object 'System.Collections.Generic.List[object]'
        $legacySuffix = ".eco-backup-$Timestamp"
        foreach ($legacyRoot in ($legacyRoots | Select-Object -Unique)) {
            if (Test-Path -LiteralPath $legacyRoot -PathType Container) {
                foreach ($legacyFile in (Get-ChildItem -LiteralPath $legacyRoot -Recurse -File -Filter "*eco-backup-$Timestamp" -ErrorAction SilentlyContinue)) {
                    $legacyFiles.Add($legacyFile)
                }
            }
        }

        if ($legacyFiles.Count -eq 0) {
            throw "Backup manifest or legacy backup files not found for timestamp '$Timestamp'."
        }

        Write-H1 "LEGACY ROLLBACK - $Timestamp"
        if ($DryRun) {
            Write-WARN 'DRY RUN: no files will be changed.'
        }

        $restoredLegacy = 0
        $failedLegacy = 0
        foreach ($legacyFile in $legacyFiles) {
            try {
                $originalPath = $legacyFile.FullName.Substring(0, $legacyFile.FullName.Length - $legacySuffix.Length)
                if ($DryRun) {
                    Write-STEP "Would restore: $originalPath"
                }
                else {
                    Copy-Item -LiteralPath $legacyFile.FullName -Destination $originalPath -Force
                    Write-OK "Restored: $originalPath"
                }
                $restoredLegacy++
            }
            catch {
                Write-FAIL "Could not restore legacy backup $($legacyFile.FullName): $_"
                $failedLegacy++
            }
        }

        Write-Host "`nLegacy rollback summary: $restoredLegacy processed, $failedLegacy failed."
        if ($failedLegacy -gt 0) { return 1 }
        return 0
    }

    $manifestObject = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($manifestObject.Entries)
    if ($entries.Count -eq 0) {
        Write-WARN 'The selected backup contains no modified files.'
        return 0
    }

    Write-H1 "ROLLBACK - $Timestamp"
    if ($DryRun) {
        Write-WARN 'DRY RUN: no files will be changed.'
    }

    $result = Restore-Manifest -Entries $entries -Preview:$DryRun
    Write-Host "`nRollback summary: $($result.Restored) processed, $($result.Failed) failed."

    if ($result.Failed -gt 0) {
        return 1
    }

    return 0
}

function Get-KiCadTableInfo {
    param(
        [string]$Text,
        [ValidateSet('sym_lib_table', 'fp_lib_table')]
        [string]$ExpectedRoot
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "$ExpectedRoot is empty."
    }

    $rootMatch = [regex]::Match($Text, '(?s)^\s*(?:;[^\r\n]*(?:\r?\n|$)\s*)*\(\s*([A-Za-z0-9_]+)\b')
    if (-not $rootMatch.Success -or $rootMatch.Groups[1].Value -ne $ExpectedRoot) {
        throw "Invalid table root. Expected ($ExpectedRoot ...)."
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $depth = 0
    $inString = $false
    $escaped = $false
    $inComment = $false
    $entryStart = -1
    $rootCloseIndex = -1

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]

        if ($inComment) {
            if ($character -eq "`n") {
                $inComment = $false
            }
            continue
        }

        if ($inString) {
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($character -eq '\') {
                $escaped = $true
                continue
            }
            if ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq ';') {
            $inComment = $true
            continue
        }
        if ($character -eq '"') {
            $inString = $true
            continue
        }

        if ($character -eq '(') {
            if ($depth -eq 1 -and $entryStart -lt 0) {
                $remaining = $Text.Substring($i)
                if ($remaining -match '^\(\s*lib(?:\s|\))') {
                    $entryStart = $i
                }
            }
            $depth++
            continue
        }

        if ($character -eq ')') {
            if ($entryStart -ge 0 -and $depth -eq 2) {
                $depth--
                $rawEntry = $Text.Substring($entryStart, $i - $entryStart + 1)
                $nameMatch = [regex]::Match(
                    $rawEntry,
                    '(?is)^\s*\(\s*lib\b.*?\(\s*name\s+"((?:\\.|[^"\\])*)"'
                )

                if (-not $nameMatch.Success) {
                    throw 'A library table entry does not contain a readable (name "...") field.'
                }

                $libraryName = $nameMatch.Groups[1].Value -replace '\\(["\\])', '$1'
                $entries.Add([pscustomobject]@{
                    Name = $libraryName
                    Raw  = $rawEntry
                })
                $entryStart = -1
                continue
            }

            if ($depth -eq 1) {
                $rootCloseIndex = $i
                $depth--
                break
            }

            $depth--
            if ($depth -lt 0) {
                throw 'Library table contains unbalanced parentheses.'
            }
        }
    }

    if ($rootCloseIndex -lt 0 -or $depth -ne 0 -or $inString) {
        throw 'Library table is incomplete or contains unbalanced syntax.'
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if (-not $names.Add($entry.Name)) {
            throw "Duplicate library nickname in table: $($entry.Name)"
        }
    }

    return [pscustomobject]@{
        Root          = $ExpectedRoot
        Entries       = @($entries.ToArray())
        Count         = $entries.Count
        CloseIndex    = $rootCloseIndex
        Names         = $names
    }
}

function Test-ModelsVariableUsed {
    param(
        [string]$FootprintTableText,
        [string]$EcoRoot,
        [string]$FootprintDirectory
    )

    # Footprints carry their own (model "...") paths, so the footprint table
    # alone never mentions KICAD_LIBRARY.  Scan the footprint files that the
    # selected table actually points at.
    if ([string]::IsNullOrWhiteSpace($FootprintTableText)) {
        return $false
    }

    $info = Get-KiCadTableInfo -Text $FootprintTableText -ExpectedRoot 'fp_lib_table'

    foreach ($entry in $info.Entries) {
        $typeMatch = [regex]::Match($entry.Raw, '\(type\s+"((?:\\.|[^"\\])*)"')
        if ($typeMatch.Success -and $typeMatch.Groups[1].Value -eq 'Table') {
            continue
        }

        $uriMatch = [regex]::Match($entry.Raw, '\(uri\s+"((?:\\.|[^"\\])*)"')
        if (-not $uriMatch.Success) {
            continue
        }

        $uri = $uriMatch.Groups[1].Value -replace '\\(["\\])', '$1'
        $uri = $uri.Replace('${KICAD_ECO_ROOT}', $EcoRoot)
        if ($FootprintDirectory) {
            $uri = $uri.Replace('${KICAD10_FOOTPRINT_DIR}', $FootprintDirectory)
            $uri = $uri.Replace('${KISYS3DMOD}', $FootprintDirectory)
        }

        if ($uri -match '\$\{') {
            continue
        }

        $directory = $uri -replace '/', '\'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }

        $hit = Get-ChildItem -LiteralPath $directory -Filter '*.kicad_mod' -File -ErrorAction SilentlyContinue |
            Select-String -Pattern '${KICAD_LIBRARY}' -SimpleMatch -List -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($hit) {
            return $true
        }
    }

    return $false
}

function Convert-KiCadTableVersionVariables {
    param(
        [string]$Text,
        [string]$VersionSlot
    )

    $major = ([regex]::Match($VersionSlot, '^\d+')).Value
    if ([string]::IsNullOrWhiteSpace($major)) {
        throw "Cannot determine KiCad major version from '$VersionSlot'."
    }

    if ($major -ne '10') {
        $Text = $Text -replace 'KICAD10_', "KICAD${major}_"
    }

    return $Text
}

function Merge-KiCadLibraryTable {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [ValidateSet('sym_lib_table', 'fp_lib_table')]
        [string]$ExpectedRoot,
        [string]$VersionSlot
    )

    $sourceText = Read-TextFile -Path $SourcePath
    $sourceText = Convert-KiCadTableVersionVariables -Text $sourceText -VersionSlot $VersionSlot
    $sourceInfo = Get-KiCadTableInfo -Text $sourceText -ExpectedRoot $ExpectedRoot

    if ($sourceInfo.Count -eq 0) {
        throw "The source table contains no libraries: $SourcePath"
    }

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        if ($DryRun) {
            Write-STEP "Would create $ExpectedRoot with $($sourceInfo.Count) libraries."
        }
        else {
            Register-Backup -Path $TargetPath
            Write-TextAtomic -Path $TargetPath -Content $sourceText
        }

        return [pscustomobject]@{
            Added = $sourceInfo.Count
            Total = $sourceInfo.Count
            Changed = $true
        }
    }

    $targetText = Read-TextFile -Path $TargetPath
    $targetInfo = Get-KiCadTableInfo -Text $targetText -ExpectedRoot $ExpectedRoot
    $newEntries = New-Object 'System.Collections.Generic.List[object]'

    foreach ($entry in $sourceInfo.Entries) {
        if (-not $targetInfo.Names.Contains($entry.Name)) {
            $newEntries.Add($entry)
            [void]$targetInfo.Names.Add($entry.Name)
        }
    }

    if ($newEntries.Count -eq 0) {
        Write-INFO "$ExpectedRoot already contains all $($sourceInfo.Count) source nicknames. No change needed."
        return [pscustomobject]@{
            Added = 0
            Total = $targetInfo.Count
            Changed = $false
        }
    }

    $formattedEntries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $newEntries) {
        $formattedEntries.Add('  ' + $entry.Raw.Trim())
    }

    $prefix = $targetText.Substring(0, $targetInfo.CloseIndex)
    $suffix = $targetText.Substring($targetInfo.CloseIndex)
    $newline = [Environment]::NewLine
    $separator = ''
    if (-not ($prefix.EndsWith("`n") -or $prefix.EndsWith("`r"))) {
        $separator = $newline
    }

    $insertion = $separator + ($formattedEntries -join $newline) + $newline
    $mergedText = $prefix + $insertion + $suffix

    if ($DryRun) {
        Write-STEP "Would add $($newEntries.Count) entries to $ExpectedRoot."
    }
    else {
        Register-Backup -Path $TargetPath
        Write-TextAtomic -Path $TargetPath -Content $mergedText
    }

    return [pscustomobject]@{
        Added = $newEntries.Count
        Total = $targetInfo.Count + $newEntries.Count
        Changed = $true
    }
}

function Test-ObjectNode {
    param([object]$Value)
    return ($null -ne $Value -and ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary]))
}

function Set-KiCadPathVariables {
    param(
        [string]$CommonPath,
        [string]$EcoRoot,
        [string]$ModelsPath,
        [bool]$NeedsEcoRoot,
        [bool]$NeedsModelsPath
    )

    if (-not $NeedsEcoRoot -and -not $NeedsModelsPath) {
        Write-INFO 'No custom path variables are referenced by the selected tables.'
        return $false
    }

    $json = [pscustomobject]@{}
    if (Test-Path -LiteralPath $CommonPath -PathType Leaf) {
        try {
            $json = Read-TextFile -Path $CommonPath | ConvertFrom-Json
        }
        catch {
            throw "kicad_common.json is not valid JSON. It was left untouched. Details: $_"
        }

        if (-not (Test-ObjectNode -Value $json)) {
            throw 'kicad_common.json does not contain a JSON object. It was left untouched.'
        }
    }

    $changed = $false
    $environmentProperty = $json.PSObject.Properties['environment']
    if (-not $environmentProperty) {
        $json | Add-Member -NotePropertyName 'environment' -NotePropertyValue ([pscustomobject]@{})
        $environment = $json.environment
        $changed = $true
    }
    else {
        $environment = $environmentProperty.Value
        if ($null -eq $environment) {
            $environment = [pscustomobject]@{}
            $json | Add-Member -NotePropertyName 'environment' -NotePropertyValue $environment -Force
            $changed = $true
        }
        elseif (-not (Test-ObjectNode -Value $environment)) {
            throw 'The environment section in kicad_common.json is not an object. File left untouched.'
        }
    }

    $varsProperty = $environment.PSObject.Properties['vars']
    if (-not $varsProperty) {
        $environment | Add-Member -NotePropertyName 'vars' -NotePropertyValue ([pscustomobject]@{})
        $vars = $environment.vars
        $changed = $true
    }
    else {
        $vars = $varsProperty.Value
        if ($null -eq $vars) {
            $vars = [pscustomobject]@{}
            $environment | Add-Member -NotePropertyName 'vars' -NotePropertyValue $vars -Force
            $changed = $true
        }
        elseif (-not (Test-ObjectNode -Value $vars)) {
            throw 'The environment.vars section in kicad_common.json is not an object. File left untouched.'
        }
    }

    $desiredVariables = @{}
    if ($NeedsEcoRoot) {
        $desiredVariables['KICAD_ECO_ROOT'] = $EcoRoot
    }
    if ($NeedsModelsPath) {
        if (-not (Test-Path -LiteralPath $ModelsPath -PathType Container)) {
            throw "The selected tables reference KICAD_LIBRARY, but the model folder does not exist: $ModelsPath"
        }
        $desiredVariables['KICAD_LIBRARY'] = $ModelsPath
    }

    foreach ($name in $desiredVariables.Keys) {
        $property = $vars.PSObject.Properties[$name]
        if (-not $property -or [string]$property.Value -ne [string]$desiredVariables[$name]) {
            $vars | Add-Member -NotePropertyName $name -NotePropertyValue ([string]$desiredVariables[$name]) -Force
            $changed = $true
            Write-OK "$name registered."
        }
        else {
            Write-INFO "$name already points to the correct folder."
        }
    }

    if (-not $changed) {
        return $false
    }

    $jsonText = ConvertTo-Json -InputObject $json -Depth 100
    if ($DryRun) {
        Write-STEP 'Would update only the required environment.vars entries in kicad_common.json.'
    }
    else {
        Register-Backup -Path $CommonPath
        Write-TextAtomic -Path $CommonPath -Content $jsonText
    }

    return $true
}

function Copy-MissingTemplates {
    param(
        [string]$SourceTemplates,
        [string]$UserTemplateDirectory
    )

    $copied = 0
    if (-not (Test-Path -LiteralPath $SourceTemplates -PathType Container)) {
        Write-WARN "Templates source folder not found: $SourceTemplates"
        return 0
    }

    $layoutSource = Join-Path $SourceTemplates 'Local_Archive\Layout\Layout.kicad_wks'
    if (Test-Path -LiteralPath $layoutSource -PathType Leaf) {
        $layoutTarget = Join-Path $UserTemplateDirectory 'Layout.kicad_wks'
        if (Test-Path -LiteralPath $layoutTarget -PathType Leaf) {
            Write-INFO 'Layout.kicad_wks already exists; keeping the user copy.'
        }
        else {
            if ($DryRun) {
                Write-STEP "Would copy worksheet: $layoutTarget"
            }
            else {
                Register-Backup -Path $layoutTarget
                if (-not (Test-Path -LiteralPath $UserTemplateDirectory -PathType Container)) {
                    New-Item -ItemType Directory -Path $UserTemplateDirectory -Force | Out-Null
                }
                Copy-Item -LiteralPath $layoutSource -Destination $layoutTarget
            }
            $copied++
        }
    }

    $blocksSource = Join-Path $SourceTemplates 'Local_Archive\Design-Blocks'
    if (Test-Path -LiteralPath $blocksSource -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $blocksSource -File -Recurse -ErrorAction Stop)
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($blocksSource.TrimEnd('\').Length).TrimStart('\')
            $target = Join-Path $UserTemplateDirectory $relative
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                continue
            }

            if ($DryRun) {
                Write-STEP "Would copy design resource: $target"
            }
            else {
                Register-Backup -Path $target
                $targetDirectory = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
                }
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
            $copied++
        }
    }

    return $copied
}

function Invoke-Setup {
    Write-H1 'STEP 1 - Resolve library directory'
    $rootCandidate = Join-Path $PSScriptRoot '..\..'
    if (-not (Test-Path -LiteralPath $rootCandidate -PathType Container)) {
        throw "Library root folder not found: $rootCandidate"
    }
    $ecoRoot = (Resolve-Path -LiteralPath $rootCandidate).Path
    $tablesDirectory = Join-Path $ecoRoot 'Libraries\Tables'
    $modelsDirectory = Join-Path $ecoRoot 'Libraries\3D_Models\Personal'
    $templatesDirectory = Join-Path $ecoRoot 'Templates'

    if (-not (Test-Path -LiteralPath $tablesDirectory -PathType Container)) {
        throw "Library tables folder not found: $tablesDirectory"
    }
    Write-OK "Library root: $ecoRoot"

    Write-H1 'STEP 2 - Detect KiCad'
    $target = Resolve-KiCadTarget -RequestedVersion $KiCadVersion
    $script:KiCadConfigDirectory = $target.ConfigDir
    Write-OK "Target KiCad version: $($target.Version)"
    Write-INFO "Configuration folder: $($target.ConfigDir)"

    $symbolSource = Join-Path $tablesDirectory "sym-lib-table.$Profile"
    $footprintSource = Join-Path $tablesDirectory "fp-lib-table.$Profile"

    if (-not (Test-Path -LiteralPath $symbolSource -PathType Leaf)) {
        throw "Symbol source table not found: $symbolSource"
    }
    if (-not (Test-Path -LiteralPath $footprintSource -PathType Leaf)) {
        throw "Footprint source table not found: $footprintSource"
    }

    $symbolText = Convert-KiCadTableVersionVariables -Text (Read-TextFile -Path $symbolSource) -VersionSlot $target.Version
    $footprintText = Convert-KiCadTableVersionVariables -Text (Read-TextFile -Path $footprintSource) -VersionSlot $target.Version

    $needsEcoRoot = [regex]::IsMatch(($symbolText + "`n" + $footprintText), '\$\{KICAD_ECO_ROOT\}')
    $needsModelsPath = [regex]::IsMatch(($symbolText + "`n" + $footprintText), '\$\{KICAD_LIBRARY\}')

    if (-not $needsModelsPath) {
        # 3D model paths live inside the footprints, not inside the tables.
        $needsModelsPath = Test-ModelsVariableUsed `
            -FootprintTableText $footprintText `
            -EcoRoot $ecoRoot
    }

    if ($needsEcoRoot) {
        Write-INFO 'Selected tables use KICAD_ECO_ROOT; this path variable will be registered.'
    }
    if ($needsModelsPath) {
        Write-INFO 'The selected footprints use KICAD_LIBRARY; this path variable will be registered.'
    }

    Write-H1 "STEP 3 - Merge library tables ($Profile)"
    $symbolTarget = Join-Path $target.ConfigDir 'sym-lib-table'
    $footprintTarget = Join-Path $target.ConfigDir 'fp-lib-table'

    $symbolResult = Merge-KiCadLibraryTable `
        -SourcePath $symbolSource `
        -TargetPath $symbolTarget `
        -ExpectedRoot 'sym_lib_table' `
        -VersionSlot $target.Version

    $footprintResult = Merge-KiCadLibraryTable `
        -SourcePath $footprintSource `
        -TargetPath $footprintTarget `
        -ExpectedRoot 'fp_lib_table' `
        -VersionSlot $target.Version

    Write-OK "Symbol table: added $($symbolResult.Added), total $($symbolResult.Total)."
    Write-OK "Footprint table: added $($footprintResult.Added), total $($footprintResult.Total)."

    Write-H1 'STEP 4 - Register required path variables'
    $commonPath = Join-Path $target.ConfigDir 'kicad_common.json'
    $commonChanged = Set-KiCadPathVariables `
        -CommonPath $commonPath `
        -EcoRoot $ecoRoot `
        -ModelsPath $modelsDirectory `
        -NeedsEcoRoot $needsEcoRoot `
        -NeedsModelsPath $needsModelsPath

    if ($commonChanged) {
        Write-OK 'Required KiCad path variables were updated.'
    }
    else {
        Write-OK 'No unrelated KiCad preferences were changed.'
    }

    $templateCount = 0
    if (-not $SkipTemplates) {
        Write-H1 'STEP 5 - Install missing templates'
        $userTemplateDirectory = Join-Path $target.ConfigDir 'template'
        $templateCount = Copy-MissingTemplates `
            -SourceTemplates $templatesDirectory `
            -UserTemplateDirectory $userTemplateDirectory
        Write-OK "Template files copied: $templateCount. Existing user files were preserved."
    }
    else {
        Write-WARN 'Template integration skipped by request.'
    }

    Write-H1 'SETUP SUMMARY'
    Write-Host "  Product          : KiCad Library Kien Hoang" -ForegroundColor White
    Write-Host "  Profile          : $Profile" -ForegroundColor White
    Write-Host "  KiCad version    : $($target.Version)" -ForegroundColor White
    Write-Host "  Config directory : $($target.ConfigDir)" -ForegroundColor White
    Write-Host "  Symbol libraries : +$($symbolResult.Added) (total $($symbolResult.Total))" -ForegroundColor White
    Write-Host "  Footprint libs   : +$($footprintResult.Added) (total $($footprintResult.Total))" -ForegroundColor White
    Write-Host "  Templates copied : $templateCount" -ForegroundColor White

    if ($DryRun) {
        Write-Host '  Mode             : DRY RUN - no files were changed' -ForegroundColor Yellow
    }
    elseif ($script:Manifest.Count -gt 0) {
        Write-Host "  Backup timestamp : $script:Stamp" -ForegroundColor White
        Write-Host "  Backup directory : $script:BackupDir" -ForegroundColor White
    }
    else {
        Write-Host '  Backup           : Not required; no files needed changes' -ForegroundColor White
    }

    Write-Host ''
    Write-Host '  Restart KiCad before using the updated libraries.' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Cyan
}

# ------------------------------ MAIN ---------------------------------
try {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '       KiCad Library Kien Hoang - Universal Auto Setup' -ForegroundColor Cyan
    Write-Host '       Safe library integration - Backup and rollback' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-INFO "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Profile: $Profile | Mode: $(if ($DryRun) { 'DRY RUN' } else { 'APPLY' })"

    $runningProcesses = @(Get-KiCadProcessList)
    if ($runningProcesses.Count -gt 0) {
        $names = ($runningProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
        throw "KiCad is currently running ($names). Save your work and close KiCad before setup or rollback. No changes were made."
    }

    if ($Rollback) {
        $rollbackExitCode = Invoke-Rollback -Timestamp $Rollback
        exit $rollbackExitCode
    }

    $script:BackupDir = Join-Path $script:BackupRoot $script:Stamp
    $script:ManifestPath = Join-Path $script:BackupDir 'manifest.json'

    if ($DryRun) {
        Write-WARN 'DRY RUN is enabled. No configuration, table, template, or backup files will be written.'
    }

    Invoke-Setup

    Write-Host ''
    Write-Host "Completed: $($script:StepOK) OK, $($script:StepWarn) warning(s), $($script:StepFail) failure(s)." -ForegroundColor Cyan
    exit 0
}
catch {
    Write-FAIL $_.Exception.Message

    if (-not $DryRun -and $script:Manifest.Count -gt 0) {
        Write-WARN 'An error occurred after one or more files were changed. Starting automatic rollback.'
        $rollbackResult = Restore-Manifest -Entries @($script:Manifest.ToArray())
        if ($rollbackResult.Failed -gt 0) {
            Write-FAIL "Automatic rollback was incomplete. Backup files are preserved at: $script:BackupDir"
        }
        else {
            Write-OK 'Automatic rollback completed. Original files have been restored.'
        }
    }

    Write-Host ''
    Write-Host 'Setup failed. Review the error above; KiCad configuration was not intentionally reset.' -ForegroundColor Red
    exit 1
}
