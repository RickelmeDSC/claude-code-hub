# ChTests.ps1 - self-test.
#
# Runs against a synthetic world built in a temp folder by ChFixtures.ps1, so it
# passes on a machine that has never run Claude Code, and it never reads your
# real sessions or touches the network.

$ErrorActionPreference = 'Continue'

$script:ChTestRoot = Split-Path -Parent $PSScriptRoot
$script:TPass = 0
$script:TFail = 0
$script:TSkip = 0
$script:TFailures = New-Object System.Collections.Generic.List[string]
$script:TBlock = ''

function Start-TBlock {
    param([string]$Name)
    $script:TBlock = $Name
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
}

function Assert-True {
    param([string]$Name, $Condition, [string]$Detail = '')
    if ($Condition) {
        $script:TPass++
        Write-Host "    ok   $Name" -ForegroundColor DarkGreen
    } else {
        $script:TFail++
        $msg = "[$script:TBlock] $Name"
        if ($Detail) { $msg += " -- $Detail" }
        $script:TFailures.Add($msg)
        Write-Host "    FAIL $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkRed }
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ($Expected -eq $Actual)
    $detail = ''
    if (-not $ok) { $detail = "expected <$Expected> got <$Actual>" }
    Assert-True -Name $Name -Condition $ok -Detail $detail
}

function Skip-Test {
    param([string]$Name, [string]$Why)
    $script:TSkip++
    Write-Host "    skip $Name  ($Why)" -ForegroundColor DarkYellow
}

# --- load the modules under test --------------------------------------------

foreach ($lib in @('ChText.ps1', 'ChIndex.ps1', 'ChRepos.ps1', 'ChMemory.ps1', 'ChUI.ps1')) {
    $path = Join-Path (Join-Path $script:ChTestRoot 'lib') $lib
    if (Test-Path -LiteralPath $path) {
        . $path
    } else {
        Write-Host "  missing module: $lib" -ForegroundColor Red
    }
}
. (Join-Path $PSScriptRoot 'ChFixtures.ps1')

$fx = New-ChFixtures
Use-ChFixtures -Fx $fx
Write-Host ''
Write-Host "  fixtures: $($fx.Root)" -ForegroundColor DarkGray

try {

# ============================================================================
Start-TBlock 'Scope - called from another script'

# Regression for the bug that broke `ch` on its first real run: the profile
# function loads the modules in one scope and ch.ps1 calls them from another.
# A module variable declared with $script: comes back $null across that jump.
$probe = Join-Path $PSScriptRoot 'ScopeProbe.ps1'
if (-not (Test-Path -LiteralPath $probe)) {
    Skip-Test 'scope probe' 'ScopeProbe.ps1 not found'
} else {
    foreach ($line in @(& $probe)) {
        $parts = $line -split '=', 2
        Assert-True "from another script: $($parts[0])" ($parts[1] -like 'OK*') $parts[1]
    }
}

# ============================================================================
Start-TBlock 'Text - localisation'

$en = Initialize-ChText -Lang 'en'
Assert-Equal 'english strings' 'SESSIONS' $en.secSessions
$pt = Initialize-ChText -Lang 'pt'
Assert-Equal 'portuguese strings' 'SESSOES' $pt.secSessions
Assert-Equal 'unknown language falls back to english' 'SESSIONS' (Initialize-ChText -Lang 'klingon').secSessions
Assert-Equal 'no key is missing from the portuguese table' 0 @($en.Keys | Where-Object { -not $pt.ContainsKey($_) }).Count
Assert-Equal 'unknown key returns the key itself' 'zzNope' (Get-ChText 'zzNope')
[void](Initialize-ChText -Lang 'en')

# ============================================================================
Start-TBlock 'Index - reading and parsing'

Assert-Equal 'unescapes backslashes' 'C:\Users\demo\a_b' (ConvertFrom-ChJsonString 'C:\\Users\\demo\\a_b')
Assert-Equal 'unescapes unicode' 'acao' (ConvertFrom-ChJsonString 'a\u0063\u0061o')
Assert-Equal 'unescapes quotes' 'says "hi"' (ConvertFrom-ChJsonString 'says \"hi\"')

$sample = '{"aiTitle":"first"}' + "`n" + '{"aiTitle":"second"}' + "`n" + '{"aiTitle":"third"}'
Assert-Equal 'last value wins' 'third' (Get-ChLastJsonValue -Text $sample -Key 'aiTitle')
Assert-Equal 'first value wins' 'first' (Get-ChFirstJsonValue -Text $sample -Key 'aiTitle')
Assert-Equal 'missing key is null' $null (Get-ChLastJsonValue -Text $sample -Key 'nope')

$noisy = @(
    '{"type":"user","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}'
    '{"type":"user","message":{"role":"user","content":"<system-reminder>ignore me</system-reminder>"}}'
    '{"type":"user","message":{"role":"user","content":"<ide_opened_file>editor noise</ide_opened_file> the actual request goes here"}}'
) -join "`n"
Assert-Equal 'harness noise is stripped' 'the actual request goes here' (Get-ChFirstUserPrompt -HeadText $noisy)

Assert-True 'a greeting is not substantive' (-not (Test-ChPromptSubstantivo 'good morning, Claude')) 'accepted a greeting'
Assert-True 'short text is not substantive' (-not (Test-ChPromptSubstantivo 'ok')) 'accepted short text'
Assert-True 'a real request is substantive' (Test-ChPromptSubstantivo 'please review the deployment pipeline for staging') 'rejected a real request'
Assert-True 'a sentence that opens with hello is substantive' (Test-ChPromptSubstantivo 'Hello Claude, I need to review the backend deployment today') 'rejected a real sentence'

Assert-True 'Greeting is a generic title' (Test-ChTituloGenerico 'Greeting conversation') 'not flagged'
Assert-True 'empty title is generic' (Test-ChTituloGenerico '') 'not flagged'
Assert-True 'a real title is not generic' (-not (Test-ChTituloGenerico 'Fix the login timeout')) 'flagged a good title'
Assert-True 'greeting in the middle is not generic' (-not (Test-ChTituloGenerico 'Adjust the greeting screen')) 'matched in the wrong place'

$prompts = @(
    '{"type":"user","message":{"role":"user","content":"good morning, Claude"}}'
    '{"type":"user","message":{"role":"user","content":"please review the deployment pipeline for staging"}}'
) -join "`n"
Assert-Equal 'prefers the request over the greeting' 'please review the deployment pipeline for staging' (Get-ChFirstUserPrompt -HeadText $prompts)
Assert-Equal 'a greeting alone is still returned' 'good morning, Claude' (Get-ChFirstUserPrompt -HeadText ($prompts -split "`n")[0])

$s = Read-ChSessionFile -File (Get-Item -LiteralPath $fx.SessionAlpha)
Assert-Equal 'session title' 'Fix the login timeout' $s.Title
Assert-Equal 'session branch' 'main' $s.Branch
Assert-Equal 'session id comes from the file name' '11111111-1111-1111-1111-111111111111' $s.SessionId
Assert-Equal 'cwd read from inside the file' $fx.Alpha $s.Cwd
Assert-True 'first prompt captured' ($s.FirstPrompt -like 'the login screen times out*') $s.FirstPrompt
Assert-True 'LastActivity is a datetime' ($s.LastActivity -is [datetime]) "$($s.LastActivity)"
Assert-Equal 'duration comes from the timestamps' '2h14' (Format-ChDuration ($s.LastActivity - $s.Started))

# The file is larger than the 64 KB head window and the real request sits past
# it. This is the case that forces the second, deeper read.
$big = Get-Item -LiteralPath $fx.SessionBig
Assert-True 'the big fixture really is past the head window' ($big.Length -gt 65536) "$($big.Length) bytes"
$sb = Read-ChSessionFile -File $big
Assert-Equal 'generic title replaced by the real request' 'please review the deployment pipeline configuration for staging' $sb.Title

$se = Read-ChSessionFile -File (Get-Item -LiteralPath $fx.SessionEmpty)
Assert-Equal 'a session with no assistant turn is labelled' '(no conversation)' $se.Title

$idx = Get-ChSessionIndex -Force
Assert-Equal 'index finds every session' 7 $idx.Count
Assert-Equal 'no subagent transcript in the index' 0 @($idx | Where-Object { $_.Path -like '*\subagents\*' }).Count
Assert-Equal 'no session is left untitled' 0 @($idx | Where-Object { $_.Title -eq '(untitled)' }).Count

$idx2 = Get-ChSessionIndex
Assert-Equal 'cache returns the same count' $idx.Count $idx2.Count
# Regression: PS 5.1 ConvertFrom-Json turns an ISO string into a DateTime, so a
# text timestamp stored in the cache never compares equal and the whole index is
# reparsed on every open. The stamp is stored as ticks for that reason.
Assert-Equal 'cache is fully reused (0 reparses)' 0 $global:ChIndexParsedCount
Assert-True 'cache preserves the title' ((@($idx2 | Where-Object { $_.SessionId -like '1111*' })[0]).Title -eq 'Fix the login timeout') 'title lost'
Assert-True 'cache rehydrates dates' ((@($idx2)[0]).LastActivity -is [datetime]) 'not a datetime'

# ============================================================================
Start-TBlock 'Repos - inventory'

Assert-Equal 'https url' 'demo-user/alpha' (ConvertTo-ChRepoSlug 'https://github.com/demo-user/alpha.git')
Assert-Equal 'scp-style ssh url' 'demo-user/beta' (ConvertTo-ChRepoSlug 'git@github.com:demo-user/beta.git')
Assert-Equal 'ssh:// url' 'demo-user/gamma' (ConvertTo-ChRepoSlug 'ssh://git@github.com/demo-user/gamma')
Assert-Equal 'url without .git' 'owner/name' (ConvertTo-ChRepoSlug 'https://github.com/owner/name')
Assert-Equal 'another host is not GitHub' $null (ConvertTo-ChRepoSlug 'https://gitlab.com/owner/name.git')
Assert-Equal 'empty url is null' $null (ConvertTo-ChRepoSlug '')

$clones = @(Get-ChLocalClones)
Assert-Equal 'finds every clone and skips the plain folder' 5 $clones.Count

$ca = @($clones | Where-Object { $_.Name -eq 'alpha' })[0]
Assert-Equal 'remote read from .git/config' 'demo-user/alpha' $ca.FullName
Assert-Equal 'branch read from .git/HEAD' 'main' $ca.Branch
Assert-Equal 'matching shas mean in sync' 'in-sync' $ca.Sync

$cb = @($clones | Where-Object { $_.Name -eq 'beta' })[0]
Assert-Equal 'refs also read from packed-refs' 'demo-user/beta' $cb.FullName
Assert-Equal 'differing shas mean diverged' 'diverged' $cb.Sync

$cg = @($clones | Where-Object { $_.Name -eq 'gamma' })[0]
Assert-Equal 'branch with a slash is read whole' 'feature/x' $cg.Branch
Assert-Equal 'no remote ref means no upstream' 'no-upstream' $cg.Sync

# A worktree keeps HEAD locally but its refs live in the main repository,
# pointed at by the commondir file.
$cw = @($clones | Where-Object { $_.Name -eq 'alpha-worktree' })
Assert-Equal 'worktree is detected' 1 $cw.Count
if ($cw.Count -eq 1) {
    Assert-Equal 'worktree branch comes from its own HEAD' 'main' $cw[0].Branch
    Assert-Equal 'worktree refs resolve through commondir' 'in-sync' $cw[0].Sync
}

Assert-Equal 'loose ref is read' $fx.ShaA (Get-ChRefSha -GitDir (Join-Path $fx.Alpha '.git') -Ref 'refs/heads/main')
Assert-Equal 'packed ref is read' $fx.ShaB (Get-ChRefSha -GitDir (Join-Path $fx.Beta '.git') -Ref 'refs/heads/main')
Assert-Equal 'ref that does not exist is null' $null (Get-ChRefSha -GitDir (Join-Path $fx.Alpha '.git') -Ref 'refs/heads/nope')

$inv = @(Get-ChRepoInventory)
Assert-True 'inventory merges GitHub and disk' ($inv.Count -ge 6) "got $($inv.Count)"
Assert-True 'the network was never touched' (-not $global:ChReposOffline) 'fell back to offline mode'
$ia = @($inv | Where-Object { $_.FullName -eq 'demo-user/alpha' })[0]
Assert-True 'a cloned repo is marked as cloned' ($ia -and $ia.HasClone) 'HasClone false'
$inc = @($inv | Where-Object { $_.Name -eq 'never-cloned' })[0]
Assert-True 'a repo with no clone still shows up' ($inc -and -not $inc.HasClone) 'missing or marked as cloned'
Assert-True 'archived repos are flagged' (@($inv | Where-Object { $_.Archived }).Count -ge 1) 'none flagged'
Assert-True 'private repos are flagged' (@($inv | Where-Object { $_.Private }).Count -ge 1) 'none flagged'

# Get-ChGitStatus shells out to git, so it needs a real repository.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Skip-Test 'git status' 'git is not on PATH'
} else {
    $real = Join-Path $fx.Root 'realrepo'
    [void][System.IO.Directory]::CreateDirectory($real)
    & git -C $real init --quiet 2>$null
    Set-Content -LiteralPath (Join-Path $real 'a.txt') -Value 'hello' -Encoding UTF8
    $gs = Get-ChGitStatus -RepoPath $real
    Assert-True 'git status reports the untracked file' ($gs -and $gs.Changed -ge 1) "got $(if ($gs) { $gs.Changed } else { 'null' })"
    Assert-True 'a fresh repo has no upstream' ($gs -and -not $gs.HasUpstream) 'claimed an upstream'
    Assert-True 'the second call is served from cache' ((Get-ChGitStatus -RepoPath $real) -eq $gs) 'recomputed instead of caching'
}

# ============================================================================
Start-TBlock 'Memory - reading'

Assert-Equal 'slug of a path' 'C--Users-demo-code-alpha' (ConvertTo-ChProjectSlug 'C:\Users\demo\code\alpha')
Assert-Equal 'slug converts dots' 'C--Users-x--local-bin' (ConvertTo-ChProjectSlug 'C:\Users\x\.local\bin')
Assert-Equal 'slug ignores a trailing separator' 'C--Users-x' (ConvertTo-ChProjectSlug 'C:\Users\x\')
Assert-Equal 'slug converts underscores' 'C--Users-my-user' (ConvertTo-ChProjectSlug 'C:\Users\my_user')

# The drive letter shows up in both cases in real project folders, so the
# lookup has to ignore case.
Assert-True 'project folder matched despite a lowercase drive letter' ($null -ne (Get-ChProjectDir -Path $fx.Beta)) 'not found'
Assert-True 'project folder of alpha found' ($null -ne (Get-ChProjectDir -Path $fx.Alpha)) 'not found'
Assert-Equal 'unknown path is null' $null (Get-ChProjectDir -Path 'C:\nowhere\at\all')

$mem = @(Get-ChMemoryEntries -Path $fx.Alpha)
Assert-Equal 'memory index is parsed' 3 $mem.Count
Assert-Equal 'entry title' 'Deploy is manual' $mem[0].Title
Assert-Equal 'entry file' 'alpha-deploy.md' $mem[0].File
Assert-Equal 'entry hook' 'the pipeline builds but never publishes' $mem[0].Hook
Assert-True 'entry that exists on disk is marked' $mem[0].Exists 'marked as missing'
Assert-True 'entry that is only referenced is marked missing' (-not $mem[1].Exists) 'marked as existing'
Assert-True 'memory body is read' ((Get-ChMemoryBody -FullPath $mem[0].FullPath).Length -gt 20) 'empty body'
Assert-Equal 'a path with no memory returns empty' 0 @(Get-ChMemoryEntries -Path $fx.Gamma).Count

# ============================================================================
Start-TBlock 'Convention - collection callers wrap with @()'

# PowerShell unrolls a one-element array on return, so a function that finds
# exactly one thing hands back the bare object and .Count comes back empty. The
# convention here is that the CALLER wraps. That is invisible to a normal test -
# the test wraps too - so it is checked against the source instead.
$guarded = @('Select-ChSessions', 'Get-ChSessionCatalog', 'Get-ChMemoryEntries')
$offenders = New-Object System.Collections.Generic.List[string]
foreach ($file in @('lib\ChUI.ps1', 'lib\ChMemory.ps1', 'lib\ChRepos.ps1', 'lib\ChIndex.ps1', 'ch.ps1')) {
    $full = Join-Path $script:ChTestRoot $file
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $srcLines = [System.IO.File]::ReadAllLines($full, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $srcLines.Count; $i++) {
        $line = $srcLines[$i]
        if ($line -match '^\s*#') { continue }
        # a module-load guard mentions the name without calling it
        if ($line -match 'Test-Path Function:') { continue }
        foreach ($fn in $guarded) {
            if ($line -notmatch [regex]::Escape($fn)) { continue }
            if ($line -match ('^\s*function\s+' + [regex]::Escape($fn))) { continue }
            if ($line -match ('@\(\s*' + [regex]::Escape($fn))) { continue }
            $offenders.Add("$file`:$($i + 1)  $($line.Trim())")
        }
    }
}
Assert-Equal 'every guarded call is wrapped in @()' 0 $offenders.Count
foreach ($o in $offenders) { Write-Host "         $o" -ForegroundColor DarkRed }

# ============================================================================
Start-TBlock 'UI - pure functions'

$esc = [char]27
Assert-Equal 'visible length ignores ANSI' 3 (Get-ChVisibleLength "$esc[31mabc$esc[0m")
Assert-Equal 'visible length of plain text' 5 (Get-ChVisibleLength 'abcde')
Assert-Equal 'visible length of empty' 0 (Get-ChVisibleLength '')

$now = Get-Date
Assert-True 'today shows a time' ((Format-ChRelativeDate $now) -match '\d{2}:\d{2}$') (Format-ChRelativeDate $now)
Assert-True 'yesterday shows a time' ((Format-ChRelativeDate $now.AddDays(-1)) -match '\d{2}:\d{2}$') (Format-ChRelativeDate $now.AddDays(-1))
Assert-Equal 'another year is a plain date' '13/11/25' (Format-ChRelativeDate (Get-Date '2025-11-13 21:18'))

Assert-Equal 'duration in minutes' '8min' (Format-ChDuration ([timespan]::FromMinutes(8)))
Assert-Equal 'duration in hours' '2h14' (Format-ChDuration ([timespan]::FromMinutes(134)))
Assert-Equal 'duration in days' '11d' (Format-ChDuration ([timespan]::FromDays(11)))
Assert-Equal 'very short duration' '<1min' (Format-ChDuration ([timespan]::FromSeconds(20)))

# the ellipsis is a glyph, so the assertion checks the shape, not the character
$cut = Limit-ChText 'abcdefghijklmno' 11
Assert-Equal 'truncation fits the width exactly' 11 $cut.Length
Assert-True 'truncation keeps the start' ($cut.StartsWith('abcdefgh')) $cut
Assert-True 'truncation ends with the ellipsis' ($cut.EndsWith([string]$global:G.Ellipsis)) $cut
Assert-Equal 'short text is untouched' 'abc' (Limit-ChText 'abc' 11)
$colored = "$esc[36mabcdefghij$esc[0m"
Assert-Equal 'ANSI truncation counts only visible chars' 4 (Get-ChVisibleLength (Limit-ChAnsi $colored 4))
# -like would read [36m as a wildcard character class, so this uses Contains
Assert-True 'ANSI truncation keeps the colour' ((Limit-ChAnsi $colored 4).Contains("$esc[36m")) 'colour sequence lost'
Assert-Equal 'ANSI truncation leaves what fits alone' $colored (Limit-ChAnsi $colored 50)

# --- session to repository matching ---
$rows = @(Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos (Get-ChRepoInventory))

# Three sessions have cwd = alpha and one has cwd = alpha\src\api. The subfolder
# rolls up into the parent, which is why matching uses the cwd recorded inside
# the file and not the project folder name.
Assert-Equal 'subfolder rolls up into the parent repo' 4 (@($rows | Where-Object { $_.Name -eq 'alpha' })[0]).Sessions.Count
# ui lives inside alpha. A session under ui matches both paths, and the longest
# prefix has to win - otherwise the work lands on the wrong repository. Mutation
# testing found this rule was never exercised, because every other fixture
# repository is a sibling.
$rUi = @($rows | Where-Object { $_.Name -eq 'ui' })
Assert-Equal 'the nested repository is in the list' 1 $rUi.Count
Assert-Equal 'a session inside the nested repo belongs to it' 1 $rUi[0].Sessions.Count
Assert-Equal 'and it is the right session' 'Wire the design tokens' $rUi[0].Sessions[0].Title
Assert-True 'the parent repo does not swallow it' (@($rows | Where-Object { $_.Name -eq 'alpha' })[0].Sessions.Title -notcontains 'Wire the design tokens') 'alpha took the nested session'
Assert-Equal 'the nested path resolves to the nested repo' 'ui' (Find-ChRowForPath -Rows $rows -Path (Join-Path $fx.Nested 'src')).Name
Assert-Equal 'beta keeps its own session' 1 (@($rows | Where-Object { $_.Name -eq 'beta' })[0]).Sessions.Count
$rOther = @($rows | Where-Object { $_.Kind -eq 'other' })
Assert-Equal 'a session outside any repo becomes another place' 1 $rOther.Count
Assert-Equal 'and it carries its session' 1 $rOther[0].Sessions.Count
Assert-Equal 'a repo with no clone stays in the list' 0 (@($rows | Where-Object { $_.Name -eq 'never-cloned' })[0]).Sessions.Count
Assert-True 'ordered by most recent activity' ($rows[0].LastActivity -ge $rows[1].LastActivity) 'out of order'

# --- global session search ---
$cat = @(Get-ChSessionCatalog -Rows $rows)
Assert-Equal 'catalog covers every session' 7 $cat.Count
Assert-Equal 'every entry knows its repository' 0 @($cat | Where-Object { -not $_.RepoName }).Count
Assert-Equal 'empty query returns everything' $cat.Count @(Select-ChSessions -Catalog $cat -Query '').Count
# Regression: `return @(...)` with a single match hands back the object instead
# of a list, .Count came out empty, and the screen said "nothing found" with the
# match sitting right there.
$hits = @(Select-ChSessions -Catalog $cat -Query 'pagination')
Assert-Equal 'a single match is still a list' 1 $hits.Count
Assert-Equal 'and it knows which repository it came from' 'beta' $hits[0].RepoName
Assert-Equal 'search ignores case' 1 @(Select-ChSessions -Catalog $cat -Query 'PAGINATION').Count
Assert-Equal 'search also matches the first prompt' 1 @(Select-ChSessions -Catalog $cat -Query 'cursor pagination').Count
Assert-Equal 'search also matches the repository name' 4 @(Select-ChSessions -Catalog $cat -Query 'alpha').Count
Assert-Equal 'text that matches nothing' 0 @(Select-ChSessions -Catalog $cat -Query 'zzzznothingzzzz').Count

# --- ch from inside a repository ---
Assert-Equal 'a subfolder resolves to its repository' 'alpha' (Find-ChRowForPath -Rows $rows -Path $fx.AlphaSub).Name
Assert-Equal 'the repository root resolves' 'alpha' (Find-ChRowForPath -Rows $rows -Path $fx.Alpha).Name
Assert-Equal 'a path outside everything resolves to nothing' $null (Find-ChRowForPath -Rows $rows -Path 'C:\Windows\System32')

# --- the box has to close at every size ---
# Impossible to check by eye: the ANSI sequences hide the misalignment. Here the
# width is measured with the escapes stripped.
$top = @($rows | Where-Object { $_.Sessions.Count -gt 0 })[0]
$memTop = @(Get-ChMemoryEntries -Path $top.Path)
foreach ($dim in @(@(60, 16), @(60, 40), @(84, 24), @(120, 40), @(200, 30))) {
    $w = $dim[0]; $h = $dim[1]
    $L = Build-ChListLines -Rows $rows -Index 0 -Scroll 0 -Filter '' -Width ($w - 1) -Height $h -Owner 'demo' -Status ''
    $wl = @($L | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
    Assert-True "list closes the box at ${w}x${h}" ($wl.Count -eq 1 -and $wl[0] -eq ($w - 1)) "widths: $($wl -join ',')"
    Assert-Equal "list fills the height at ${w}x${h}" ($h - 1) $L.Count

    $D = Build-ChDetailLines -Row $top -Index 0 -Scroll 0 -Width ($w - 1) -Height $h -Memory $memTop -Status ''
    $wd = @($D | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
    Assert-True "detail closes the box at ${w}x${h}" ($wd.Count -eq 1 -and $wd[0] -eq ($w - 1)) "widths: $($wd -join ',')"
    Assert-Equal "detail fills the height at ${w}x${h}" ($h - 1) $D.Count

    $M = Build-ChMemoryLines -Row $top -Memory $memTop -Index 0 -Scroll 0 -Width ($w - 1) -Height $h
    $wm = @($M | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
    Assert-True "memory closes the box at ${w}x${h}" ($wm.Count -eq 1 -and $wm[0] -eq ($w - 1)) "widths: $($wm -join ',')"

    $B = Build-ChSearchLines -Results $cat -Total $cat.Count -Query 'demo' -Index 0 -Scroll 0 -Width ($w - 1) -Height $h
    $wb = @($B | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
    Assert-True "search closes the box at ${w}x${h}" ($wb.Count -eq 1 -and $wb[0] -eq ($w - 1)) "widths: $($wb -join ',')"
    Assert-Equal "search fills the height at ${w}x${h}" ($h - 1) $B.Count
}

# Portuguese labels are longer than the English ones: the box has to close in
# both, at a width where the key bar is tight.
foreach ($lang in @('en', 'pt')) {
    [void](Initialize-ChText -Lang $lang)
    $L = Build-ChListLines -Rows $rows -Index 0 -Scroll 0 -Filter '' -Width 79 -Height 20 -Owner 'demo' -Status ''
    $wl = @($L | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
    Assert-True "list closes the box in '$lang'" ($wl.Count -eq 1 -and $wl[0] -eq 79) "widths: $($wl -join ',')"
    $D = Build-ChDetailLines -Row $top -Index 0 -Scroll 0 -Width 79 -Height 20 -Memory $memTop -Status ''
    $wd = @($D | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
    Assert-True "detail closes the box in '$lang'" ($wd.Count -eq 1 -and $wd[0] -eq 79) "widths: $($wd -join ',')"
}
[void](Initialize-ChText -Lang 'en')

} finally {
    Remove-ChFixtures -Fx $fx
}

# ============================================================================

Write-Host ''
Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
if ($script:TFail -eq 0) {
    Write-Host "  $script:TPass passed, $script:TSkip skipped, 0 failures" -ForegroundColor Green
} else {
    Write-Host "  $script:TPass passed, $script:TSkip skipped, $script:TFail FAILURES" -ForegroundColor Red
    Write-Host ''
    foreach ($f in $script:TFailures) { Write-Host "    - $f" -ForegroundColor Red }
}
Write-Host ''

if ($script:TFail -gt 0) { exit 1 } else { exit 0 }
