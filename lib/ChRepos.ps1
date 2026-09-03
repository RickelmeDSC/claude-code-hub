# ChRepos.ps1 - repository inventory.
#
# Two sources matched by the remote URL: what GitHub says you can reach (gh)
# and what is cloned on disk. A repository can exist on only one of the two
# sides; both cases show up in the list.
#
# Building the list never invokes git.exe: it reads .git\config and .git\HEAD as
# text. A dozen git invocations would cost around a second on Windows.

$global:ChRoot = Split-Path -Parent $PSScriptRoot
$global:ChReposCacheDir = Join-Path $global:ChRoot 'cache'

# ConvertTo-ChDate lives in ChIndex. Loading it here keeps this module usable
# on its own, without depending on who loaded what first.
if (-not (Test-Path Function:\ConvertTo-ChDate)) {
    . (Join-Path $PSScriptRoot 'ChIndex.ps1')
}

$global:ChReposOffline = $false
$global:ChReposOfflineReason = ''

function Get-ChConfig {
    if ($global:ChConfigCached) { return $global:ChConfigCached }
    $defaults = [pscustomobject]@{
        ScanRoots          = @('%USERPROFILE%/Documents/GitHub', '%USERPROFILE%')
        CloneRoot          = '%USERPROFILE%/Documents/GitHub'
        RepoCacheMinutes   = 30
        MemoryPreviewLines = 4
        Language           = 'auto'
    }
    $path = Join-Path $global:ChRoot 'config.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            $user = ConvertFrom-Json $raw
            foreach ($p in $defaults.PSObject.Properties) {
                if ($user.PSObject.Properties.Match($p.Name).Count -and $null -ne $user.($p.Name)) {
                    $defaults.($p.Name) = $user.($p.Name)
                }
            }
        } catch {
            # an invalid config must never stop the tool from opening
        }
    }
    $defaults.ScanRoots = @($defaults.ScanRoots | ForEach-Object { Expand-ChPath $_ })
    $defaults.CloneRoot = Expand-ChPath $defaults.CloneRoot
    $global:ChConfigCached = $defaults
    return $defaults
}

function Expand-ChPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    return ($p -replace '/', '\').TrimEnd('\')
}

function ConvertTo-ChRepoSlug {
    # Normalises any form of GitHub URL to "owner/name".
    param([string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    $u = $RemoteUrl.Trim()
    $u = $u -replace '\.git$', ''
    $u = $u.TrimEnd('/')
    $m = [regex]::Match($u, 'github\.com[:/](?<owner>[^/:]+)/(?<name>[^/]+)$')
    if (-not $m.Success) { return $null }
    return ($m.Groups['owner'].Value + '/' + $m.Groups['name'].Value)
}

function Get-ChGitDir {
    # Returns the real .git folder, following the pointer when .git is a file
    # (worktree or submodule).
    param([string]$RepoPath)
    $dot = Join-Path $RepoPath '.git'
    if ([System.IO.Directory]::Exists($dot)) { return $dot }
    if (-not [System.IO.File]::Exists($dot)) { return $null }
    try {
        $txt = [System.IO.File]::ReadAllText($dot)
        $m = [regex]::Match($txt, 'gitdir:\s*(.+)')
        if (-not $m.Success) { return $null }
        $target = $m.Groups[1].Value.Trim() -replace '/', '\'
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path $RepoPath $target
        }
        if (Test-Path -LiteralPath $target) { return (Resolve-Path -LiteralPath $target).Path }
    } catch { }
    return $null
}

function Get-ChRemoteUrl {
    param([string]$GitDir)
    $cfg = Join-Path $GitDir 'config'
    if (-not [System.IO.File]::Exists($cfg)) { return $null }
    try {
        $txt = [System.IO.File]::ReadAllText($cfg)
    } catch { return $null }
    $sec = [regex]::Match($txt, '(?ms)^\s*\[remote\s+"origin"\]\s*$(?<body>.*?)(?=^\s*\[|\z)')
    if (-not $sec.Success) { return $null }
    $url = [regex]::Match($sec.Groups['body'].Value, '(?m)^\s*url\s*=\s*(?<u>\S+)\s*$')
    if (-not $url.Success) { return $null }
    return $url.Groups['u'].Value
}

function Get-ChCurrentBranch {
    param([string]$GitDir)
    $head = Join-Path $GitDir 'HEAD'
    if (-not [System.IO.File]::Exists($head)) { return $null }
    try {
        $txt = ([System.IO.File]::ReadAllText($head)).Trim()
    } catch { return $null }
    $m = [regex]::Match($txt, '^ref:\s*refs/heads/(?<b>.+)$')
    if ($m.Success) { return $m.Groups['b'].Value }
    if ($txt.Length -ge 7) { return $txt.Substring(0, 7) }  # detached HEAD
    return $null
}

function Get-ChCommonGitDir {
    # In a worktree, .git points at <main>\.git\worktrees\<name>, and there is
    # NO refs\heads in there: HEAD is local, but the refs live in the main
    # repository, named by the `commondir` file.
    param([string]$GitDir)
    if (-not $GitDir) { return $null }
    $marker = Join-Path $GitDir 'commondir'
    if (-not [System.IO.File]::Exists($marker)) { return $GitDir }
    try {
        $target = ([System.IO.File]::ReadAllText($marker)).Trim() -replace '/', '\'
    } catch { return $GitDir }
    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $GitDir $target }
    try {
        $resolved = [System.IO.Path]::GetFullPath($target)
        if ([System.IO.Directory]::Exists($resolved)) { return $resolved }
    } catch { }
    return $GitDir
}

function Get-ChRefSha {
    # Reads the SHA of a ref (e.g. refs/heads/main) without invoking git. The ref
    # may sit loose in .git\refs\... or packed into .git\packed-refs, and real
    # clones use both forms, so both have to work. In a worktree it also looks
    # in the common directory.
    param([string]$GitDir, [string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }

    $places = New-Object System.Collections.Generic.List[string]
    $places.Add($GitDir)
    $common = Get-ChCommonGitDir -GitDir $GitDir
    if ($common -and $common -ne $GitDir) { $places.Add($common) }

    foreach ($dir in $places) {
        $loose = Join-Path $dir ($Ref -replace '/', '\')
        if ([System.IO.File]::Exists($loose)) {
            try { return ([System.IO.File]::ReadAllText($loose)).Trim() } catch { }
        }
    }
    foreach ($dir in $places) {
        $packed = Join-Path $dir 'packed-refs'
        if (-not [System.IO.File]::Exists($packed)) { continue }
        try { $lines = [System.IO.File]::ReadAllLines($packed) } catch { continue }
        foreach ($l in $lines) {
            if ($l.Length -eq 0 -or $l[0] -eq '#' -or $l[0] -eq '^') { continue }
            $p = $l -split ' ', 2
            if ($p.Count -eq 2 -and $p[1].Trim() -eq $Ref) { return $p[0].Trim() }
        }
    }
    return $null
}

function Get-ChSyncState {
    # 'in-sync' | 'diverged' | 'no-upstream' | 'unknown'
    #
    # Comparing the two SHAs does not say HOW MANY commits apart, but it says
    # whether there is a difference - and that is free, with no process spawned.
    # The exact count is left to the detail screen, where a ~200ms `git status` pays off.
    param([string]$GitDir, [string]$Branch)
    if (-not $GitDir -or -not $Branch) { return 'unknown' }
    $local = Get-ChRefSha -GitDir $GitDir -Ref "refs/heads/$Branch"
    if (-not $local) { return 'unknown' }
    $remote = Get-ChRefSha -GitDir $GitDir -Ref "refs/remotes/origin/$Branch"
    if (-not $remote) { return 'no-upstream' }
    if ($local -eq $remote) { return 'in-sync' }
    return 'diverged'
}

function Get-ChGitStatus {
    # Exact numbers for ONE repository: how many files changed and how many
    # commits ahead/behind. Costs ~200ms because it really invokes git, so it is
    # only called on the detail screen, and the result is cached while .git
    # does not change.
    param([string]$RepoPath)
    if (-not $RepoPath -or -not [System.IO.Directory]::Exists($RepoPath)) { return $null }
    if (-not $global:ChGitStatusCache) { $global:ChGitStatusCache = @{} }

    $gitDir = Get-ChGitDir -RepoPath $RepoPath
    $stamp = 0
    if ($gitDir) {
        foreach ($f in @('HEAD', 'index')) {
            $p = Join-Path $gitDir $f
            if ([System.IO.File]::Exists($p)) { $stamp += [System.IO.File]::GetLastWriteTimeUtc($p).Ticks }
        }
    }
    $key = $RepoPath + '|' + $stamp
    if ($global:ChGitStatusCache.ContainsKey($key)) { return $global:ChGitStatusCache[$key] }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $output = $null
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $output = & git -C $RepoPath status --porcelain=v2 --branch 2>$null
    } catch {
        $output = $null
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $output) { return $null }

    $changed = 0
    $ahead = 0
    $behind = 0
    $temUpstream = $false
    foreach ($l in $output) {
        if ($l.StartsWith('# branch.ab ')) {
            $temUpstream = $true
            $m = [regex]::Match($l, '\+(\d+)\s+-(\d+)')
            if ($m.Success) { $ahead = [int]$m.Groups[1].Value; $behind = [int]$m.Groups[2].Value }
            continue
        }
        if ($l.StartsWith('#')) { continue }
        $changed++
    }

    $r = [pscustomobject]@{
        Changed   = $changed
        Ahead       = $ahead
        Behind      = $behind
        HasUpstream = $temUpstream
    }
    $global:ChGitStatusCache[$key] = $r
    return $r
}

function Get-ChLocalClones {
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($root in (Get-ChConfig).ScanRoots) {
        if (-not [System.IO.Directory]::Exists($root)) { continue }
        try { $paths = [System.IO.Directory]::GetDirectories($root) } catch { continue }
        foreach ($p in $paths) {
            if ($seen.ContainsKey($p)) { continue }
            # Looking for .git first discards almost everything with a single existence
            # check; only the survivors pay for a DirectoryInfo. A home folder can hold
            # dozens of subfolders and only a handful are repositories.
            $gitDir = Get-ChGitDir -RepoPath $p
            if (-not $gitDir) { continue }
            $d = New-Object System.IO.DirectoryInfo $p
            # Legacy Windows junctions ("My Documents", "Application Data") point at
            # folders already scanned: they would enter the list twice.
            if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $seen[$p] = $true
            $remote = Get-ChRemoteUrl -GitDir $gitDir
            $branch = Get-ChCurrentBranch -GitDir $gitDir
            $out.Add([pscustomobject]@{
                Name     = $d.Name
                Path     = $p
                Remote   = $remote
                FullName = ConvertTo-ChRepoSlug $remote
                Branch   = $branch
                Sync     = Get-ChSyncState -GitDir $gitDir -Branch $branch
                Modified = $d.LastWriteTime
            })
        }
    }
    return $out.ToArray()
}

function Get-ChGitHubRepos {
    param([switch]$Force)

    $global:ChReposOffline = $false
    $global:ChReposOfflineReason = ''
    $cachePath = Join-Path $global:ChReposCacheDir 'repos.json'
    $maxAge = [double](Get-ChConfig).RepoCacheMinutes

    $cached = $null
    if (Test-Path -LiteralPath $cachePath) {
        try {
            $raw = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8
            $cached = ConvertFrom-Json $raw
        } catch { $cached = $null }
    }

    if (-not $Force -and $cached -and $cached.FetchedAt) {
        $age = (Get-Date) - (ConvertTo-ChDate $cached.FetchedAt)
        if ($age.TotalMinutes -lt $maxAge) { return @($cached.Repos) }
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $global:ChReposOffline = $true
        $global:ChReposOfflineReason = $global:T.offNoGh
        if ($cached) { return @($cached.Repos) }
        return @()
    }

    $lines = $null
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $query = 'user/repos?affiliation=owner,collaborator,organization_member&per_page=100&sort=pushed'
        $lines = & gh api $query --paginate --jq '.[] | @json' 2>$null
    } catch {
        $lines = $null
    } finally {
        $ErrorActionPreference = $prev
    }

    if ($LASTEXITCODE -ne 0 -or -not $lines) {
        $global:ChReposOffline = $true
        $global:ChReposOfflineReason = $global:T.offNoAnswer
        if ($cached) { return @($cached.Repos) }
        return @()
    }

    $repos = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = ConvertFrom-Json $line } catch { continue }
        if (-not $o -or -not $o.full_name) { continue }
        $repos.Add([pscustomobject]@{
            FullName    = [string]$o.full_name
            Name        = [string]$o.name
            Owner       = [string]$o.owner.login
            Private     = [bool]$o.private
            Archived    = [bool]$o.archived
            PushedAt    = ConvertTo-ChDate $o.pushed_at
            Url         = [string]$o.html_url
            Description = [string]$o.description
        })
    }

    try {
        if (-not (Test-Path -LiteralPath $global:ChReposCacheDir)) {
            New-Item -ItemType Directory -Path $global:ChReposCacheDir -Force | Out-Null
        }
        $payload = [pscustomobject]@{ FetchedAt = (Get-Date).ToString('o'); Repos = $repos.ToArray() }
        Set-Content -LiteralPath $cachePath -Value ($payload | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
    } catch { }

    return $repos.ToArray()
}

function Get-ChRepoInventory {
    param([switch]$Force)

    $remote = Get-ChGitHubRepos -Force:$Force
    $clones = Get-ChLocalClones

    $byName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $order = New-Object System.Collections.Generic.List[string]

    foreach ($r in $remote) {
        $entry = [pscustomobject]@{
            Name        = $r.Name
            FullName    = $r.FullName
            Owner       = $r.Owner
            Path        = $null
            Paths       = @()
            HasClone    = $false
            Private     = $r.Private
            Archived    = $r.Archived
            PushedAt    = ConvertTo-ChDate $r.PushedAt
            Url         = $r.Url
            Description = $r.Description
            Branch      = $null
            Sync        = 'unknown'
        }
        if (-not $byName.ContainsKey($r.FullName)) {
            $byName[$r.FullName] = $entry
            $order.Add($r.FullName)
        }
    }

    foreach ($c in $clones) {
        $key = $c.FullName
        if ([string]::IsNullOrWhiteSpace($key)) { $key = 'local/' + $c.Name }
        if (-not $byName.ContainsKey($key)) {
            $byName[$key] = [pscustomobject]@{
                Name        = $c.Name
                FullName    = $key
                Owner       = ($key -split '/')[0]
                Path        = $null
                Paths       = @()
                HasClone    = $false
                Private     = $false
                Archived    = $false
                PushedAt    = $c.Modified
                Url         = $null
                Description = $null
                Branch      = $null
                Sync        = 'unknown'
            }
            $order.Add($key)
        }
        $e = $byName[$key]
        $e.HasClone = $true
        $e.Paths = @($e.Paths) + @($c.Path)
        # the same repository can be cloned in two places; the clone touched most
        # recently becomes the primary one, and both keep counting when matching
        # sessions to repositories.
        if (-not $e.Path -or $c.Modified -gt $e.PathModified) {
            $e.Path = $c.Path
            $e.Branch = $c.Branch
            $e.Sync = $c.Sync
            $e | Add-Member -NotePropertyName PathModified -NotePropertyValue $c.Modified -Force
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($k in $order) { $result.Add($byName[$k]) }
    return $result.ToArray()
}

function Clear-ChReposCache {
    $cachePath = Join-Path $global:ChReposCacheDir 'repos.json'
    if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath -Force }
}

# Language comes from the config, so the strings table is (re)built here, at the
# end of the file: Get-ChConfig calls Expand-ChPath, and in PowerShell a
# function only exists after the line that defines it.
if (-not (Test-Path Function:\Get-ChText)) { . (Join-Path $PSScriptRoot 'ChText.ps1') }
[void](Initialize-ChText -Lang (Get-ChConfig).Language)
