# Mutants.ps1 - mutation testing.
#
# "The tests pass" and "the tests check anything" are different claims. This
# script copies the repository to a temp folder, breaks one specific behaviour
# at a time, and runs the suite against the broken copy.
#
# A mutation the suite fails to notice is a blind spot: nothing is actually
# asserting that behaviour. Run it after changing the tests, not on every save -
# it runs the whole suite once per mutation.
#
#   powershell -File tests\Mutants.ps1

$src = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:TEMP ("ch-mut-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
$env:WT_SESSION = 'x'

$mutations = @(
    @{ Name = 'index recurses into subagents/'; File = 'lib\ChIndex.ps1'
       From = "[System.IO.Directory]::GetFiles(`$d, '*.jsonl')"
       To   = "[System.IO.Directory]::GetFiles(`$d, '*.jsonl', [System.IO.SearchOption]::AllDirectories)" }

    @{ Name = 'shortest path prefix wins instead of longest'; File = 'lib\ChUI.ps1'
       From = "`$ordered = @(`$candidates | Sort-Object -Property Len -Descending)"
       To   = "`$ordered = @(`$candidates | Sort-Object -Property Len)" }

    @{ Name = 'cache stamp stored as an ISO string'; File = 'lib\ChIndex.ps1'
       From = "MtimeTicks   = `$File.LastWriteTimeUtc.Ticks"
       To   = "MtimeTicks   = `$File.LastWriteTimeUtc.ToString('o')" }

    @{ Name = 'greetings accepted as titles'; File = 'lib\ChIndex.ps1'
       From = "if (`$Texto.Length -lt 25) { return `$false }"
       To   = "if (`$Texto.Length -lt 0) { return `$false }" }

    @{ Name = 'frame is one line too tall'; File = 'lib\ChUI.ps1'
       From = "`$bodyMax = `$Height - 3"
       To   = "`$bodyMax = `$Height - 2" }

    @{ Name = 'packed-refs ignored'; File = 'lib\ChRepos.ps1'
       From = "    `$packed = Join-Path `$Dir 'packed-refs'"
       To   = "    return `$null`n    `$packed = Join-Path `$Dir 'packed-refs'" }

    @{ Name = 'worktree commondir ignored'; File = 'lib\ChRepos.ps1'
       From = "    `$marker = Join-Path `$GitDir 'commondir'"
       To   = "    return `$GitDir`n    `$marker = Join-Path `$GitDir 'commondir'" }

    @{ Name = 'module root back to $script: scope'; File = 'lib\ChRepos.ps1'
       From = "`$global:ChRoot = Split-Path -Parent `$PSScriptRoot"
       To   = "`$script:ChRoot = Split-Path -Parent `$PSScriptRoot" }

    @{ Name = 'ANSI not stripped when measuring width'; File = 'lib\ChUI.ps1'
       From = "    return `$global:ChAnsiRegex.Replace(`$Text, '').Length"
       To   = "    return `$Text.Length" }

    @{ Name = 'memory hook dropped'; File = 'lib\ChMemory.ps1'
       From = "                Hook     = `$m.Groups['h'].Value.Trim()"
       To   = "                Hook     = ''" }

    @{ Name = 'session with no assistant turn not labelled'; File = 'lib\ChIndex.ps1'
       From = "    if (-not `$hasReply) {"
       To   = "    if (`$false) {" }

    @{ Name = 'caller forgets @() around the search result'; File = 'lib\ChUI.ps1'
       From = "        `$found = @(Select-ChSessions -Catalog `$catalog -Query `$query)"
       To   = "        `$found = Select-ChSessions -Catalog `$catalog -Query `$query" }
)

Write-Host ''
Write-Host ("  {0,-52} {1}" -f 'MUTATION', 'SUITE') -ForegroundColor Cyan
Write-Host ("  " + ('-' * 68)) -ForegroundColor DarkGray

$blind = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($m in $mutations) {
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
    Copy-Item -Recurse -Force $src $work
    Remove-Item -Recurse -Force (Join-Path $work '.git') -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $work 'cache') -ErrorAction SilentlyContinue

    $path = Join-Path $work $m.File
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if (-not $text.Contains($m.From)) {
        $skipped.Add($m.Name)
        Write-Host ("  {0,-52} {1}" -f $m.Name, 'NOT APPLIED (source moved)') -ForegroundColor Yellow
        continue
    }
    [System.IO.File]::WriteAllText($path, $text.Replace($m.From, $m.To), (New-Object System.Text.UTF8Encoding($true)))

    $null = & powershell -NoProfile -Command "& '$work\tests\ChTests.ps1'" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  {0,-52} {1}" -f $m.Name, 'caught') -ForegroundColor DarkGreen
    } else {
        Write-Host ("  {0,-52} {1}" -f $m.Name, 'SURVIVED - BLIND SPOT') -ForegroundColor Red
        $blind.Add($m.Name)
    }
}

if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }

$total = $mutations.Count - $skipped.Count
Write-Host ''
Write-Host ("  " + ('-' * 68)) -ForegroundColor DarkGray
Write-Host ("  {0} of {1} mutations caught" -f ($total - $blind.Count), $total)
if ($blind.Count -gt 0) {
    Write-Host ''
    Write-Host '  BLIND SPOTS:' -ForegroundColor Red
    foreach ($b in $blind) { Write-Host "    - $b" -ForegroundColor Red }
}
if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host '  not applied (the source text moved):' -ForegroundColor Yellow
    foreach ($b in $skipped) { Write-Host "    - $b" -ForegroundColor Yellow }
}
Write-Host ''
if ($blind.Count -gt 0) { exit 1 } else { exit 0 }
