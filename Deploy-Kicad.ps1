#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoPath = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }),
    [ValidateRange(3,120)]
    [int]$RemoteTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$script:Root = $null
$script:Log = New-Object 'System.Collections.Generic.List[string]'
$script:BackupPath = $null
$script:Failure = $null
$script:MovedMetadata = New-Object 'System.Collections.Generic.List[object]'

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = "$(Get-Date -Format 'HH:mm:ss') $Message"
    [void]$script:Log.Add($line)
    Write-Host $Message -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Log ''
    Write-Log ('=' * 75) Cyan
    Write-Log " $Title" Cyan
    Write-Log ('=' * 75) Cyan
}

function Invoke-Git {
    param([string[]]$GitArgs)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw  = @(& git -C $script:Root @GitArgs 2>&1)
        $code = $LASTEXITCODE
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $raw) { [void]$lines.Add($item.ToString()) }
        return [PSCustomObject]@{ ExitCode = $code; Output = $lines.ToArray() }
    }
    catch {
        return [PSCustomObject]@{ ExitCode = 1; Output = @($_.Exception.Message) }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Get-GitOutput {
    param([string[]]$GitArgs)
    $result = Invoke-Git -GitArgs $GitArgs
    if ($result.ExitCode -ne 0) {
        throw "Git command failed: $($GitArgs -join ' ') | $($result.Output -join ' ')"
    }
    return $result.Output
}

function Assert-Git {
    param([string[]]$GitArgs, [string]$Description)
    Write-Log "[GIT] $Description" Cyan
    $result = Invoke-Git -GitArgs $GitArgs
    foreach ($line in $result.Output) { Write-Log "  $line" }
    if ($result.ExitCode -ne 0) {
        throw "$Description failed. Exit code: $($result.ExitCode)"
    }
    return $result
}

function Get-RelativePath {
    param([string]$Base, [string]$Path)
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\','/')
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $baseFull + '\'
    if (-not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $Path"
    }
    return $pathFull.Substring($prefix.Length).Replace('\','/')
}

function Find-NestedGitMetadata {
    param([string]$StartPath)
    $found = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($StartPath)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if ($child.Name -ieq '.git') {
                [void]$found.Add($child)
                continue
            }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) }
        }
    }
    return $found.ToArray()
}

function Backup-NestedRepositories {
    param([string]$OfficialPath)

    Write-Section 'BACKUP NESTED GIT REPOSITORIES'

    $nested = @(Find-NestedGitMetadata -StartPath $OfficialPath)
    Write-Log "Nested Git metadata found: $($nested.Count)" Yellow

    if ($nested.Count -eq 0) {
        Write-Log 'No nested Git repositories found.' Green
        return
    }

    foreach ($item in $nested) {
        if (-not $item.PSIsContainer) {
            throw "Nested .git file detected: $($item.FullName). Manual worktree metadata review is required."
        }
    }

    $parent = Split-Path $script:Root -Parent
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:BackupPath = Join-Path $parent "Kicad_NestedGit_Backup_$stamp"

    if (Test-Path -LiteralPath $script:BackupPath) {
        throw 'Backup destination already exists. Refusing to overwrite it.'
    }

    New-Item -ItemType Directory -Path $script:BackupPath -Force | Out-Null
    Write-Log "Backup folder: $script:BackupPath" Green

    try {
        foreach ($item in $nested) {
            $relative = Get-RelativePath -Base $OfficialPath -Path $item.FullName
            $destination = Join-Path $script:BackupPath $relative
            $destinationParent = Split-Path $destination -Parent
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null

            Write-Log "[BACKUP] $relative" Yellow
            Move-Item -LiteralPath $item.FullName -Destination $destination -ErrorAction Stop

            [void]$script:MovedMetadata.Add([PSCustomObject]@{
                Original = $item.FullName
                Backup   = $destination
            })
        }
    }
    catch {
        Write-Log 'Backup interrupted. Restoring already moved metadata.' Red
        for ($i = $script:MovedMetadata.Count - 1; $i -ge 0; $i--) {
            $entry = $script:MovedMetadata[$i]
            try {
                Move-Item -LiteralPath $entry.Backup -Destination $entry.Original -ErrorAction Stop
                Write-Log "[RESTORED] $($entry.Original)" Green
            }
            catch {
                Write-Log "[RESTORE ERROR] $($_.Exception.Message)" Red
            }
        }
        throw
    }

    $remaining = @(Find-NestedGitMetadata -StartPath $OfficialPath)
    if ($remaining.Count -gt 0) {
        throw 'Nested Git repositories still remain after backup.'
    }

    Write-Log 'All nested Git metadata safely backed up.' Green
}

function Get-RemoteRefs {
    param([string]$RemoteNameOrUrl)
    Write-Log '[REMOTE] Checking GitHub repository...' Cyan
    $result = Invoke-Git -GitArgs @('ls-remote', '--refs', $RemoteNameOrUrl)
    if ($result.ExitCode -ne 0) {
        throw "Cannot read GitHub repository: $($result.Output -join ' ')"
    }
    return $result.Output
}

function Test-RemoteBranch {
    param([string[]]$Refs, [string]$Branch, [string]$LocalHead)

    $targetSha = $null
    $otherBranches = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in $Refs) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -ne 2) { continue }
        $sha = $parts[0]
        $refName = $parts[1]
        if ($refName -like 'refs/heads/*') {
            if ($refName -eq "refs/heads/$Branch") { $targetSha = $sha }
            else { [void]$otherBranches.Add($refName) }
        }
    }

    if ($otherBranches.Count -gt 0) {
        throw "Remote contains other branches: $($otherBranches -join ', '). Refusing automatic deployment."
    }

    if (-not $targetSha) {
        return [PSCustomObject]@{ State = 'EMPTY'; Sha = $null }
    }

    $ancestor = Invoke-Git -GitArgs @('merge-base', '--is-ancestor', $targetSha, $LocalHead)
    if ($ancestor.ExitCode -ne 0) {
        throw 'GitHub branch is not an ancestor of local HEAD. Refusing non-fast-forward push.'
    }

    $state = if ($targetSha -eq $LocalHead) { 'MATCH' } else { 'ANCESTOR' }
    return [PSCustomObject]@{ State = $state; Sha = $targetSha }
}

function Get-GitHubUrl {
    param([string]$Url)
    if (
        $Url -match '^https://github\.com/[^/\s]+/[^/\s]+(?:\.git)?$' -or
        $Url -match '^git@github\.com:[^/\s]+/[^/\s]+(?:\.git)?$' -or
        $Url -match '^ssh://git@github\.com/[^/\s]+/[^/\s]+(?:\.git)?$'
    ) { return $true }
    return $false
}

function Check-Repository {
    Write-Section 'CHECK LOCAL GIT REPOSITORY'

    $branch = @(Get-GitOutput @('branch','--show-current'))
    if ($branch.Count -eq 0 -or [string]::IsNullOrWhiteSpace($branch[0])) {
        throw 'Detached HEAD detected.'
    }

    $head = @(Get-GitOutput @('rev-parse','HEAD'))
    if ($head.Count -eq 0) { throw 'Cannot determine current HEAD.' }

    $branchName = $branch[0].Trim()
    $headSha = $head[0].Trim()

    $staged = @(Get-GitOutput @('diff','--cached','--name-only'))
    foreach ($path in $staged) {
        if ($path -ne '.gitattributes' -and -not $path.StartsWith('Official/')) {
            throw "Unrelated staged change detected: $path"
        }
    }

    $submodules = @(Get-GitOutput @('ls-files','--stage'))
    foreach ($entry in $submodules) {
        if ($entry -match '^160000 ') {
            throw "Existing Git submodule detected: $entry. Manual submodule conversion is required."
        }
    }

    $gitmodules = Join-Path $script:Root '.gitmodules'
    if ((Test-Path -LiteralPath $gitmodules) -and (Get-Item -LiteralPath $gitmodules).Length -gt 0) {
        throw 'Root .gitmodules exists. Review existing submodule configuration before deployment.'
    }

    $name  = @(Get-GitOutput @('config','--get','user.name'))
    $email = @(Get-GitOutput @('config','--get','user.email'))
    if ($name.Count -eq 0 -or $email.Count -eq 0) {
        throw 'Git user.name or user.email is not configured.'
    }

    Write-Log "Branch: $branchName" Green
    Write-Log "HEAD: $headSha" Green
    Write-Log "Git author: $($name[0])" Green

    return [PSCustomObject]@{ Branch = $branchName; Head = $headSha }
}

function Configure-GitLFS {
    param([string]$OfficialPath, [array]$Files)

    Write-Section 'CONFIGURE GIT LFS'

    $lfs = Invoke-Git -GitArgs @('lfs','version')
    if ($lfs.ExitCode -ne 0) { throw 'Git LFS is not installed.' }
    Write-Log "Git LFS: $($lfs.Output -join ' ')" Green

    Assert-Git -GitArgs @('lfs','install','--local') -Description 'Install local Git LFS hooks' | Out-Null

    $patterns = @('*.step','*.stp','*.wrl','*.STEP','*.STP','*.WRL')
    foreach ($pattern in $patterns) {
        Assert-Git -GitArgs @('lfs','track',$pattern) -Description "Configure LFS $pattern" | Out-Null
    }

    $modelExtensions = @('.step','.stp','.wrl')
    $lfsFiles = New-Object 'System.Collections.Generic.List[object]'
    $largeFiles = New-Object 'System.Collections.Generic.List[object]'

    foreach ($file in $Files) {
        $ext = $file.Extension.ToLowerInvariant()
        $isModel = $modelExtensions -contains $ext
        $isLarge = $file.Length -gt 90MB

        if ($file.Length -gt 1.9GB) {
            throw "File exceeds the conservative Git LFS single-file safety limit: $($file.FullName)"
        }
        if ($isModel -or $isLarge) { [void]$lfsFiles.Add($file) }
        if ($isLarge -and -not $isModel) { [void]$largeFiles.Add($file) }
    }

    foreach ($file in $largeFiles) {
        $relative = Get-RelativePath -Base $script:Root -Path $file.FullName
        Assert-Git -GitArgs @('lfs','track',$relative) -Description "Track oversized file $relative" | Out-Null
    }

    $lfsBytes = 0
    foreach ($file in $lfsFiles) { $lfsBytes += $file.Length }
    $lfsGiB = [math]::Round($lfsBytes / 1GB, 3)

    Write-Log "Total Official files: $($Files.Count)" Green
    Write-Log "LFS candidate files: $($lfsFiles.Count)" Green
    Write-Log "Estimated LFS size: $lfsGiB GiB" Green

    if ($lfsGiB -gt 8) {
        Write-Log 'WARNING: Check GitHub LFS quota and billing before upload.' Yellow
    }

    $samples = @()
    foreach ($extension in $modelExtensions) {
        $sample = $Files | Where-Object { $_.Extension -ieq $extension } | Select-Object -First 2
        foreach ($item in $sample) { $samples += $item }
    }
    foreach ($file in $largeFiles) { $samples += $file }

    foreach ($file in $samples) {
        $relative = Get-RelativePath -Base $script:Root -Path $file.FullName
        $attribute = Invoke-Git -GitArgs @('check-attr','filter','--',$relative)
        if ($attribute.ExitCode -ne 0 -or ($attribute.Output -join ' ') -notmatch 'filter:\s*lfs') {
            throw "LFS filter verification failed: $relative"
        }
        Write-Log "[LFS PASS] $relative" Green
    }

    if ($lfsFiles.Count -gt 0 -and $samples.Count -eq 0) {
        throw 'LFS candidates exist but no verification sample could be tested.'
    }

    $hooks = @(Get-GitOutput @('rev-parse','--git-path','hooks'))
    if ($hooks.Count -eq 0) { throw 'Cannot locate Git hooks directory.' }

    $hookDir = $hooks[0].Trim()
    if (-not [IO.Path]::IsPathRooted($hookDir)) {
        $hookDir = Join-Path $script:Root $hookDir
    }

    $prePush = Join-Path $hookDir 'pre-push'
    if (-not (Test-Path -LiteralPath $prePush)) {
        throw "Git LFS pre-push hook is missing: $prePush"
    }

    $hookContent = Get-Content -LiteralPath $prePush -Raw
    if ($hookContent -notmatch 'git-lfs') {
        throw 'Git pre-push hook does not reference Git LFS.'
    }

    Write-Log 'Git LFS pre-push hook verified.' Green

    return [PSCustomObject]@{ LfsCount = $lfsFiles.Count; LfsBytes = $lfsBytes }
}

function Validate-OfficialDirectory {
    param([string]$OfficialPath)

    Write-Section 'VALIDATE OFFICIAL DIRECTORY'

    $nested = @(Find-NestedGitMetadata -StartPath $OfficialPath)
    if ($nested.Count -gt 0) {
        throw "Still found $($nested.Count) nested Git metadata entries."
    }

    $files = @(Get-ChildItem -LiteralPath $OfficialPath -Recurse -File -Force -ErrorAction Stop)
    $directories = @(Get-ChildItem -LiteralPath $OfficialPath -Recurse -Directory -Force -ErrorAction Stop)

    $totalBytes = 0
    foreach ($file in $files) { $totalBytes += $file.Length }

    Write-Log "File count: $($files.Count)" Green
    Write-Log "Directory count: $($directories.Count)" Green
    Write-Log "Total size: $([math]::Round($totalBytes/1GB,3)) GiB" Green

    if ($files.Count -eq 0) { throw 'Official directory contains no files.' }

    $ignored = @(Get-GitOutput @('ls-files','--others','--ignored','--exclude-standard','--','Official/'))
    if ($ignored.Count -gt 0) {
        Write-Log "Ignored Official files: $($ignored.Count)" Yellow
        foreach ($item in ($ignored | Select-Object -First 40)) {
            Write-Log "  IGNORED: $item" Yellow
        }
        throw 'Ignored files were found under Official. Review .gitignore before deploying to prevent incomplete uploads.'
    }

    return $files
}

function Stage-Official {
    param([array]$Files)

    Write-Section 'STAGE COMPLETE OFFICIAL LIBRARY'

    Assert-Git -GitArgs @('add','--','.gitattributes','Official/') -Description 'Stage Official and .gitattributes' | Out-Null

    $staged = @(Get-GitOutput @('diff','--cached','--name-only'))
    if ($staged.Count -eq 0) { throw 'Nothing was staged. Check Git status and ignore rules.' }

    foreach ($path in $staged) {
        if ($path -ne '.gitattributes' -and -not $path.StartsWith('Official/')) {
            throw "Unexpected staged path: $path"
        }
    }

    $indexedOfficial = @(Get-GitOutput @('ls-files','--cached','--','Official/'))

    Write-Log "Filesystem files: $($Files.Count)" Green
    Write-Log "Indexed Official files: $($indexedOfficial.Count)" Green
    Write-Log "Total staged paths: $($staged.Count)" Green

    if ($indexedOfficial.Count -ne $Files.Count) {
        throw "File count mismatch. Filesystem=$($Files.Count), Git index=$($indexedOfficial.Count)."
    }

    $lfsIndexed = @(Get-GitOutput @('lfs','ls-files'))
    Write-Log "Git LFS indexed files: $($lfsIndexed.Count)" Green

    if ($lfsIndexed.Count -eq 0) { throw 'Git LFS index is empty. Cannot continue.' }

    Write-Log 'All Official files are present in Git index.' Green
}

function Commit-Library {
    Write-Section 'COMMIT KICAD LIBRARY'

    $status = Invoke-Git -GitArgs @('diff','--cached','--quiet')

    if ($status.ExitCode -eq 1) {
        Assert-Git -GitArgs @('commit','-m','Add complete KiCad Official library with Git LFS') -Description 'Commit complete KiCad library' | Out-Null
    }
    elseif ($status.ExitCode -eq 0) {
        Write-Log 'Nothing new to commit. Existing local HEAD will be used.' Yellow
    }
    else {
        throw 'Cannot determine staged changes.'
    }

    $head = @(Get-GitOutput @('rev-parse','HEAD'))
    if ($head.Count -eq 0) { throw 'Cannot read HEAD after commit.' }

    Write-Log "Local HEAD: $($head[0])" Green
    return $head[0].Trim()
}

function Push-Library {
    param([string]$Branch, [string]$Head)

    Write-Section 'PUSH TO GITHUB'

    $refs = @(Get-RemoteRefs -RemoteNameOrUrl 'origin')
    $remoteState = Test-RemoteBranch -Refs $refs -Branch $Branch -LocalHead $Head

    if ($remoteState.State -eq 'MATCH' -and $remoteState.Sha -eq $Head) {
        Write-Log 'GitHub already contains this exact commit.' Green
    }
    else {
        Write-Log "Pushing branch $Branch..." Cyan
        Assert-Git -GitArgs @('push','--set-upstream','origin',$Branch) -Description 'Push library to GitHub' | Out-Null
    }

    Write-Section 'VERIFY GITHUB DEPLOYMENT'

    $verify = @(Get-RemoteRefs -RemoteNameOrUrl 'origin')
    $remoteBranch = $null

    foreach ($line in $verify) {
        $parts = $line -split '\s+',2
        if ($parts.Count -eq 2 -and $parts[1] -eq "refs/heads/$Branch") {
            $remoteBranch = $parts[0]
        }
    }

    if ($remoteBranch -ne $Head) { throw 'GitHub remote HEAD does not match local HEAD.' }

    Write-Log "Local HEAD : $Head" Green
    Write-Log "Remote HEAD: $remoteBranch" Green
    Write-Log 'GitHub verification PASSED.' Green
}

# ============================== MAIN ==============================

try {
    Write-Section 'KICAD LIBRARY DEPLOYMENT TOOL V2.0'

    $resolved = Resolve-Path -LiteralPath $RepoPath -ErrorAction Stop
    $script:Root = $resolved.Path

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCommand) { throw 'Git is not installed or not in PATH.' }

    $rootCheck = Invoke-Git -GitArgs @('rev-parse','--show-toplevel')
    if ($rootCheck.ExitCode -ne 0) { throw 'Selected folder is not a Git repository.' }

    $script:Root = $rootCheck.Output[0].Trim() -replace '/', '\'

    $official = Join-Path $script:Root 'Official'
    if (-not (Test-Path -LiteralPath $official -PathType Container)) {
        throw "Official directory does not exist: $official"
    }

    $gitVersion = & git --version
    Write-Log "Repository: $script:Root" Green
    Write-Log "Git: $gitVersion" Green
    Write-Log "PowerShell: $($PSVersionTable.PSVersion)" Green

    $repoInfo = Check-Repository
    $branch = $repoInfo.Branch
    $initialHead = $repoInfo.Head

    $lfsCheck = Invoke-Git -GitArgs @('lfs','version')
    if ($lfsCheck.ExitCode -ne 0) {
        throw 'Git LFS is not installed. Install Git LFS before proceeding.'
    }

    $origin = Invoke-Git -GitArgs @('remote','get-url','origin')

    if ($origin.ExitCode -eq 0) {
        $remoteUrl = $origin.Output[0].Trim()
        Write-Log 'Existing origin remote detected.' Green
    }
    else {
        Write-Log 'No origin remote is configured.' Yellow
        $remoteUrl = (Read-Host 'Enter EMPTY GitHub repository URL').Trim()
    }

    if (-not (Get-GitHubUrl -Url $remoteUrl)) {
        throw 'Invalid GitHub URL. Use https://github.com/USER/REPOSITORY.git or git@github.com:USER/REPOSITORY.git'
    }

    if ($origin.ExitCode -eq 0) {
        Write-Log 'Using existing origin. Script will not overwrite it.' Green
    }

    $preflight = @(Get-RemoteRefs -RemoteNameOrUrl $remoteUrl)
    $preflightState = Test-RemoteBranch -Refs $preflight -Branch $branch -LocalHead $initialHead

    Write-Log "Remote state: $($preflightState.State)" Green

    if ($preflightState.State -eq 'EMPTY') {
        Write-Log 'Target remote branch is ready for first deployment.' Green
    }
    else {
        Write-Log 'Remote branch is an ancestor of local HEAD. Fast-forward is possible.' Green
    }

    Write-Section 'DEPLOYMENT PLAN'
    Write-Log "Repository: $script:Root"
    Write-Log "Branch: $branch"
    Write-Log 'Backup nested Git metadata outside repository.'
    Write-Log 'Configure Git LFS.'
    Write-Log 'Stage complete Official directory.'
    Write-Log 'Create local commit.'
    Write-Log 'Push without force.'
    Write-Log 'Verify GitHub branch.'
    Write-Log ''
    Write-Log 'Do not use a GitHub repository initialized with a README or License.' Yellow
    Write-Log 'The remote must be empty or have a branch that is an ancestor of local HEAD.' Yellow
    Write-Log ''

    $answer = Read-Host 'Type DEPLOY to start'
    if ($answer -cne 'DEPLOY') {
        throw 'Deployment cancelled. No deployment modifications made.'
    }

    if ($origin.ExitCode -ne 0) {
        Assert-Git -GitArgs @('remote','add','origin',$remoteUrl) -Description 'Configure GitHub origin' | Out-Null
    }

    Backup-NestedRepositories -OfficialPath $official

    $files = @(Validate-OfficialDirectory -OfficialPath $official)

    $lfsInfo = Configure-GitLFS -OfficialPath $official -Files $files

    Stage-Official -Files $files

    if ($lfsInfo.LfsCount -gt 0) {
        $lfsIndex = @(Get-GitOutput @('lfs','ls-files'))
        if ($lfsIndex.Count -eq 0) {
            throw 'Expected LFS files are absent from Git LFS index.'
        }
    }

    $newHead = Commit-Library

    $newRefs = @(Get-RemoteRefs -RemoteNameOrUrl 'origin')
    [void](Test-RemoteBranch -Refs $newRefs -Branch $branch -LocalHead $newHead)

    Push-Library -Branch $branch -Head $newHead

    Write-Section 'DEPLOYMENT SUCCESS'
    Write-Log 'STATUS: SUCCESS' Green
    Write-Log "Branch: $branch" Green
    Write-Log "Commit: $newHead" Green
    Write-Log "Official files: $($files.Count)" Green
    Write-Log "LFS files: $($lfsInfo.LfsCount)" Green
    Write-Log "LFS estimated data: $([math]::Round($lfsInfo.LfsBytes/1GB,3)) GiB" Green

    if ($script:BackupPath) {
        Write-Log "Nested Git backup: $script:BackupPath" Green
    }

    $script:Failure = $null
}
catch {
    $script:Failure = $_.Exception.Message
    Write-Section 'DEPLOYMENT STOPPED / FAILED'
    Write-Log $script:Failure Red
    if ($script:BackupPath) {
        Write-Log "Backup preserved: $script:BackupPath" Yellow
    }
    Write-Log 'No reset, clean, force-push or backup deletion was performed.' Yellow
}
finally {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportPath = Join-Path $env:TEMP "KicadLibraryDeploy_$stamp.txt"
    try {
        $script:Log | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-Host ''
        Write-Host "REPORT: $reportPath" -ForegroundColor Cyan
    }
    catch {
        Write-Host "Report could not be saved: $($_.Exception.Message)" -ForegroundColor Red
    }

    if ($script:Failure) {
        Write-Host 'FINAL STATUS: FAILED / STOPPED' -ForegroundColor Red
    }
    else {
        Write-Host 'FINAL STATUS: PUSH VERIFIED' -ForegroundColor Green
    }
    Write-Host 'KICAD LIBRARY DEPLOYMENT FINISHED' -ForegroundColor Cyan
}
