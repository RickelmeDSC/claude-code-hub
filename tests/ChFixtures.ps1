# ChFixtures.ps1 - builds a synthetic world in a temp folder.
#
# The test suite must pass on a machine that has never run Claude Code, so it
# cannot read the author's real sessions. This file writes fake .jsonl
# transcripts and fake .git directories, and the tests point the module globals
# at them. Nothing here touches the real ~/.claude folder or the network.

function New-ChFxJsonl {
    # One JSONL record. Going through ConvertTo-Json keeps the escaping honest
    # (backslashes in Windows paths, accents, quotes inside prompts).
    param([hashtable]$Record)
    return ($Record | ConvertTo-Json -Depth 6 -Compress)
}

function New-ChFxUserMessage {
    param([string]$Text, [string]$Timestamp, [string]$Cwd, [string]$Branch)
    return New-ChFxJsonl @{
        type      = 'user'
        timestamp = $Timestamp
        cwd       = $Cwd
        gitBranch = $Branch
        version   = '2.1.247'
        message   = @{ role = 'user'; content = @(@{ type = 'text'; text = $Text }) }
    }
}

function New-ChFxAssistantMessage {
    param([string]$Text, [string]$Timestamp, [string]$Cwd, [string]$Branch)
    return New-ChFxJsonl @{
        type      = 'assistant'
        timestamp = $Timestamp
        cwd       = $Cwd
        gitBranch = $Branch
        version   = '2.1.247'
        message   = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $Text }) }
    }
}

function New-ChFxSession {
    <#
      Writes one fake session file.
      Turns is an array of @{ Role = 'user'|'assistant'; Text = '...' }.
      AiTitle is written as the state record Claude Code appends near the end.
    #>
    param(
        [string]$Path,
        [string]$Cwd,
        [string]$Branch = 'main',
        [string]$AiTitle = $null,
        [datetime]$Start,
        [int]$MinutesLong = 30,
        [object[]]$Turns = @(),
        [int]$FillerLines = 0,
        [int]$FillerAfterTurn = -1
    )
    $lines = New-Object System.Collections.Generic.List[string]

    # real files begin with state records that carry no timestamp
    $lines.Add((New-ChFxJsonl @{ type = 'mode'; mode = 'normal' }))

    # filler pushes the file past the 64 KB head window. FillerAfterTurn says
    # where it goes: put it before a later prompt and that prompt lands beyond
    # the window, which is what forces the deeper second read.
    $t = $Start
    $idx = 0
    foreach ($turn in $Turns) {
        $stamp = $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        if ($turn.Role -eq 'assistant') {
            $lines.Add((New-ChFxAssistantMessage -Text $turn.Text -Timestamp $stamp -Cwd $Cwd -Branch $Branch))
        } else {
            $lines.Add((New-ChFxUserMessage -Text $turn.Text -Timestamp $stamp -Cwd $Cwd -Branch $Branch))
        }
        $t = $t.AddMinutes(1)
        $idx++
        if ($idx -eq $FillerAfterTurn) {
            for ($i = 0; $i -lt $FillerLines; $i++) {
                $stamp = $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                $lines.Add((New-ChFxAssistantMessage -Text ('filler ' + ('x' * 600)) -Timestamp $stamp -Cwd $Cwd -Branch $Branch))
                $t = $t.AddSeconds(5)
            }
        }
    }
    if ($FillerAfterTurn -lt 0) {
        for ($i = 0; $i -lt $FillerLines; $i++) {
            $stamp = $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $lines.Add((New-ChFxAssistantMessage -Text ('filler ' + ('x' * 600)) -Timestamp $stamp -Cwd $Cwd -Branch $Branch))
            $t = $t.AddSeconds(5)
        }
    }

    $fim = $Start.AddMinutes($MinutesLong)
    $stampFim = $fim.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $lines.Add((New-ChFxAssistantMessage -Text 'done' -Timestamp $stampFim -Cwd $Cwd -Branch $Branch))
    if ($AiTitle) {
        $lines.Add((New-ChFxJsonl @{ type = 'ai-title'; aiTitle = $AiTitle }))
    }

    $dir = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllLines($Path, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

function New-ChFxGitRepo {
    <#
      A .git directory made of plain text files. That is all the panel reads for
      the cheap path, so no real git is needed to exercise it.
      RefStyle: 'loose' | 'packed'
    #>
    param(
        [string]$Path,
        [string]$RemoteUrl,
        [string]$Branch = 'main',
        [string]$LocalSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        [string]$RemoteSha = $null,
        [string]$RefStyle = 'loose'
    )
    $git = Join-Path $Path '.git'
    [void][System.IO.Directory]::CreateDirectory($git)
    [System.IO.File]::WriteAllText((Join-Path $git 'HEAD'), "ref: refs/heads/$Branch`n")

    $cfg = "[core]`n`trepositoryformatversion = 0`n"
    if ($RemoteUrl) { $cfg += "[remote `"origin`"]`n`turl = $RemoteUrl`n`tfetch = +refs/heads/*:refs/remotes/origin/*`n" }
    [System.IO.File]::WriteAllText((Join-Path $git 'config'), $cfg)

    if ($RefStyle -eq 'packed') {
        $pk = "# pack-refs with: peeled fully-peeled sorted`n"
        $pk += "$LocalSha refs/heads/$Branch`n"
        if ($RemoteSha) { $pk += "$RemoteSha refs/remotes/origin/$Branch`n" }
        [System.IO.File]::WriteAllText((Join-Path $git 'packed-refs'), $pk)
    } else {
        $hd = Join-Path $git ('refs\heads\' + ($Branch -replace '/', '\'))
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $hd))
        [System.IO.File]::WriteAllText($hd, "$LocalSha`n")
        if ($RemoteSha) {
            $rd = Join-Path $git ('refs\remotes\origin\' + ($Branch -replace '/', '\'))
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $rd))
            [System.IO.File]::WriteAllText($rd, "$RemoteSha`n")
        }
    }
    # index is only read for its timestamp, by the git-status cache key
    [System.IO.File]::WriteAllText((Join-Path $git 'index'), 'fake')
}

function New-ChFxWorktree {
    # A worktree: .git is a FILE, HEAD is local, refs live in the main repo.
    param([string]$Path, [string]$MainRepoPath, [string]$Name, [string]$Branch)
    [void][System.IO.Directory]::CreateDirectory($Path)
    $mainGit = Join-Path $MainRepoPath '.git'
    $wtDir = Join-Path $mainGit ('worktrees\' + $Name)
    [void][System.IO.Directory]::CreateDirectory($wtDir)
    [System.IO.File]::WriteAllText((Join-Path $wtDir 'HEAD'), "ref: refs/heads/$Branch`n")
    [System.IO.File]::WriteAllText((Join-Path $wtDir 'commondir'), "../..`n")
    [System.IO.File]::WriteAllText((Join-Path $wtDir 'index'), 'fake')
    [System.IO.File]::WriteAllText((Join-Path $Path '.git'), "gitdir: $wtDir`n")
}

function New-ChFixtures {
    param([string]$Root = $null)
    <#
      Builds the whole synthetic world and returns the paths and the facts the
      tests assert against.
    #>
    $root = $Root
    if (-not $root) { $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ch-fx-' + [System.Diagnostics.Process]::GetCurrentProcess().Id) }
    if ([System.IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
    [void][System.IO.Directory]::CreateDirectory($root)

    $projects = Join-Path $root 'projects'
    $code = Join-Path $root 'code'
    $cache = Join-Path $root 'cache'
    $homeDir = Join-Path $root 'home'
    foreach ($d in @($projects, $code, $cache, $homeDir)) { [void][System.IO.Directory]::CreateDirectory($d) }

    $alpha = Join-Path $code 'alpha'
    $beta = Join-Path $code 'beta'
    $gamma = Join-Path $code 'gamma'
    $wt = Join-Path $code 'alpha-worktree'
    # A repository nested inside another one. This is the only arrangement in
    # which the longest-prefix rule actually decides anything, so without it
    # the rule is untested.
    $nested = Join-Path $alpha 'packages\ui'
    $naoRepo = Join-Path $code 'not-a-repo'
    [void][System.IO.Directory]::CreateDirectory($naoRepo)

    $shaA = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1'
    $shaB = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2'
    $shaC = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3'

    # alpha: loose refs, in sync with origin
    New-ChFxGitRepo -Path $alpha -RemoteUrl 'https://github.com/demo-user/alpha.git' `
        -Branch 'main' -LocalSha $shaA -RemoteSha $shaA -RefStyle 'loose'
    # beta: packed refs, local different from remote
    New-ChFxGitRepo -Path $beta -RemoteUrl 'git@github.com:demo-user/beta.git' `
        -Branch 'main' -LocalSha $shaB -RemoteSha $shaC -RefStyle 'packed'
    # gamma: no origin ref at all
    New-ChFxGitRepo -Path $gamma -RemoteUrl 'ssh://git@github.com/demo-user/gamma' `
        -Branch 'feature/x' -LocalSha $shaA -RemoteSha $null -RefStyle 'loose'
    # a worktree of alpha: local HEAD, refs in the main repository
    New-ChFxWorktree -Path $wt -MainRepoPath $alpha -Name 'alpha-worktree' -Branch 'main'
    # nested inside alpha, with a remote of its own
    New-ChFxGitRepo -Path $nested -RemoteUrl 'https://github.com/demo-user/ui.git' `
        -Branch 'main' -LocalSha $shaA -RemoteSha $shaA -RefStyle 'loose'

    # --- sessions ---
    # The project folder name is the slug of the real path, the same way Claude
    # Code derives it. Deriving it here from a made-up path would never match.
    $slugAlpha = ConvertTo-ChProjectSlug $alpha
    $slugBeta = ConvertTo-ChProjectSlug $beta
    # lowercase drive letter on purpose: real folders come in both cases
    $slugBeta = $slugBeta.Substring(0, 1).ToLowerInvariant() + $slugBeta.Substring(1)
    $slugHome = ConvertTo-ChProjectSlug $homeDir
    $base = Get-Date '2026-08-10 09:00:00'

    New-ChFxSession -Path (Join-Path $projects "$slugAlpha\11111111-1111-1111-1111-111111111111.jsonl") `
        -Cwd $alpha -Branch 'main' -AiTitle 'Fix the login timeout' -Start $base -MinutesLong 134 -Turns @(
            @{ Role = 'user'; Text = 'the login screen times out after thirty seconds, please investigate' }
            @{ Role = 'assistant'; Text = 'looking into it' }
        )

    # runs in a subfolder: has to roll up into alpha
    New-ChFxSession -Path (Join-Path $projects "$slugAlpha\22222222-2222-2222-2222-222222222222.jsonl") `
        -Cwd (Join-Path $alpha 'src\api') -Branch 'main' -AiTitle 'Refactor the parser' -Start $base.AddDays(1) -MinutesLong 8 -Turns @(
            @{ Role = 'user'; Text = 'refactor the parser so the token table is built once' }
            @{ Role = 'assistant'; Text = 'ok' }
        )

    # comeca com cumprimento e o titulo ficou preso nele
    New-ChFxSession -Path (Join-Path $projects "$slugAlpha\33333333-3333-3333-3333-333333333333.jsonl") `
        -Cwd $alpha -Branch 'main' -AiTitle 'Greeting conversation' -Start $base.AddDays(2) -MinutesLong 20 -Turns @(
            @{ Role = 'user'; Text = 'good morning, Claude' }
            @{ Role = 'assistant'; Text = 'good morning' }
            @{ Role = 'user'; Text = 'please review the deployment pipeline configuration for staging' }
            @{ Role = 'assistant'; Text = 'on it' }
        ) -FillerLines 130 -FillerAfterTurn 2

    # only a system command, no assistant turn at all
    $semConversa = Join-Path $projects "$slugAlpha\44444444-4444-4444-4444-444444444444.jsonl"
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $semConversa))
    [System.IO.File]::WriteAllLines($semConversa, @(
        (New-ChFxJsonl @{ type = 'mode'; mode = 'normal' })
        (New-ChFxUserMessage -Text '<command-name>/model</command-name>' -Timestamp '2026-08-09T10:00:00.000Z' -Cwd $alpha -Branch 'main')
    ), (New-Object System.Text.UTF8Encoding($false)))

    # nested subagent transcript: must NOT enter the index
    $sub = Join-Path $projects "$slugAlpha\33333333-3333-3333-3333-333333333333\subagents\agent-deadbeef.jsonl"
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $sub))
    [System.IO.File]::WriteAllLines($sub, @((New-ChFxJsonl @{ type = 'ai-title'; aiTitle = 'I am a subagent' })),
        (New-Object System.Text.UTF8Encoding($false)))

    # runs inside the nested repository: has to land on ui, not on alpha
    New-ChFxSession -Path (Join-Path $projects ((ConvertTo-ChProjectSlug $nested) + '\77777777-7777-7777-7777-777777777777.jsonl')) `
        -Cwd (Join-Path $nested 'src') -Branch 'main' -AiTitle 'Wire the design tokens' -Start $base.AddDays(5) -MinutesLong 25 -Turns @(
            @{ Role = 'user'; Text = 'wire the design tokens into the component library build' }
            @{ Role = 'assistant'; Text = 'ok' }
        )

    New-ChFxSession -Path (Join-Path $projects "$slugBeta\55555555-5555-5555-5555-555555555555.jsonl") `
        -Cwd $beta -Branch 'main' -AiTitle 'Add pagination to the API' -Start $base.AddDays(3) -MinutesLong 45 -Turns @(
            @{ Role = 'user'; Text = 'add cursor pagination to the list endpoint of the public API' }
            @{ Role = 'assistant'; Text = 'sure' }
        )

    # ran outside any repository: becomes "other places"
    New-ChFxSession -Path (Join-Path $projects "$slugHome\66666666-6666-6666-6666-666666666666.jsonl") `
        -Cwd $homeDir -Branch $null -AiTitle 'Sort out the backup script' -Start $base.AddDays(4) -MinutesLong 11 -Turns @(
            @{ Role = 'user'; Text = 'help me sort out the nightly backup script on this machine' }
            @{ Role = 'assistant'; Text = 'ok' }
        )

    # --- alpha's memory ---
    $mem = Join-Path $projects "$slugAlpha\memory"
    [void][System.IO.Directory]::CreateDirectory($mem)
    [System.IO.File]::WriteAllText((Join-Path $mem 'MEMORY.md'), @"
# MEMORY

- [Deploy is manual](alpha-deploy.md) — the pipeline builds but never publishes
- [No staging database](alpha-staging.md) — every test runs against a local copy
- [Parser owns tokenization](alpha-parser.md) — do not tokenize in the reader
"@, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $mem 'alpha-deploy.md'), @"
---
name: alpha-deploy
description: Deploy is manual
---

The pipeline builds and runs the tests but does not publish. Publishing is a
button someone presses.
"@, (New-Object System.Text.UTF8Encoding($false)))

    # --- GitHub inventory, served from cache: no test ever touches the network ---
    $repos = @(
        @{ FullName = 'demo-user/alpha'; Name = 'alpha'; Owner = 'demo-user'; Private = $false; Archived = $false; PushedAt = '2026-08-14T12:00:00Z'; Url = 'https://github.com/demo-user/alpha'; Description = 'Demo repository' }
        @{ FullName = 'demo-user/beta'; Name = 'beta'; Owner = 'demo-user'; Private = $false; Archived = $false; PushedAt = '2026-08-13T12:00:00Z'; Url = 'https://github.com/demo-user/beta'; Description = $null }
        @{ FullName = 'demo-user/gamma'; Name = 'gamma'; Owner = 'demo-user'; Private = $false; Archived = $false; PushedAt = '2026-08-12T12:00:00Z'; Url = 'https://github.com/demo-user/gamma'; Description = $null }
        @{ FullName = 'demo-user/ui'; Name = 'ui'; Owner = 'demo-user'; Private = $false; Archived = $false; PushedAt = '2026-08-15T12:00:00Z'; Url = 'https://github.com/demo-user/ui'; Description = $null }
        @{ FullName = 'demo-user/never-cloned'; Name = 'never-cloned'; Owner = 'demo-user'; Private = $false; Archived = $false; PushedAt = '2026-08-11T12:00:00Z'; Url = 'https://github.com/demo-user/never-cloned'; Description = $null }
        @{ FullName = 'demo-user/old-thing'; Name = 'old-thing'; Owner = 'demo-user'; Private = $false; Archived = $true; PushedAt = '2025-01-01T12:00:00Z'; Url = 'https://github.com/demo-user/old-thing'; Description = $null }
        @{ FullName = 'demo-user/secret-lab'; Name = 'secret-lab'; Owner = 'demo-user'; Private = $true; Archived = $false; PushedAt = '2026-01-01T12:00:00Z'; Url = 'https://github.com/demo-user/secret-lab'; Description = $null }
    )
    [void][System.IO.Directory]::CreateDirectory($cache)
    $payload = @{ FetchedAt = (Get-Date).ToString('o'); Repos = $repos }
    [System.IO.File]::WriteAllText((Join-Path $cache 'repos.json'),
        ($payload | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Root         = $root
        Projects     = $projects
        Code         = $code
        Cache        = $cache
        Home         = $homeDir
        Alpha        = $alpha
        AlphaSub     = (Join-Path $alpha 'src\api')
        Beta         = $beta
        Gamma        = $gamma
        Worktree     = $wt
        Nested       = $nested
        NotARepo     = $naoRepo
        SlugAlpha    = $slugAlpha
        SlugBeta     = $slugBeta
        ShaA         = $shaA
        ShaB         = $shaB
        ShaC         = $shaC
        SessionAlpha = (Join-Path $projects "$slugAlpha\11111111-1111-1111-1111-111111111111.jsonl")
        SessionBig   = (Join-Path $projects "$slugAlpha\33333333-3333-3333-3333-333333333333.jsonl")
        SessionEmpty = $semConversa
        MemoryDir    = $mem
    }
}

function Use-ChFixtures {
    # Points the module globals at the synthetic world. Every path the tool
    # reads becomes a temp path, so the suite never sees real data.
    param($Fx)
    $global:ChProjectsRoot = $Fx.Projects
    $global:ChMemProjectsRoot = $Fx.Projects
    $global:ChIndexCacheDir = $Fx.Cache
    $global:ChReposCacheDir = $Fx.Cache
    $global:ChProjectDirIndex = $null
    $global:ChGitStatusCache = @{}
    $global:ChConfigCached = [pscustomobject]@{
        # Two scan roots, the second pointing inside the first repository. Clone
        # discovery is one level deep per root, so this is how a monorepo with
        # nested repositories is actually configured - and it is the only way
        # two candidate paths can both match one session, which is what the
        # longest-prefix rule exists to settle.
        ScanRoots          = @($Fx.Code, (Split-Path -Parent $Fx.Nested))
        CloneRoot          = $Fx.Code
        RepoCacheMinutes   = 600
        MemoryPreviewLines = 4
        Language           = 'en'
    }
    [void](Initialize-ChText -Lang 'en')
}

function Remove-ChFixtures {
    param($Fx)
    if ($Fx -and $Fx.Root -and [System.IO.Directory]::Exists($Fx.Root)) {
        Remove-Item -LiteralPath $Fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
