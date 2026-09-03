# ch.ps1 - Claude Hub entry point.
#
#   ch                open the repository you are in, or the list
#   ch <text>         open the list already filtered
#   ch --selftest     run the self-test
#   ch --reindex      drop the caches and rebuild
#   ch --preview      draw one frame of each screen without entering
#                     interactive mode (handy to check layout anywhere)
#   ch --help         this help

[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ChArgs)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Show-ChHelp {
    if (-not (Test-Path Function:\Get-ChText)) { . (Join-Path $root 'lib\ChText.ps1') }
    if (-not $global:T) { [void](Initialize-ChText) }
    $t = $global:T
    $e = [char]27
    $c = "$e[36m"; $d = "$e[90m"; $r = "$e[0m"; $b = "$e[1m"
    Write-Host ''
    Write-Host "  ${b}Claude Hub${r}  ${d}$($t.hTag)${r}"
    Write-Host ''
    Write-Host "    ${c}ch${r}                $($t.hCh)"
    Write-Host "    ${c}ch <text>${r}         $($t.hChText)"
    Write-Host "    ${c}ch --lista${r}        $($t.hList)"
    Write-Host "    ${c}ch -s <text>${r}      $($t.hSearch)"
    Write-Host "    ${c}ch --reindex${r}      $($t.hReindex)"
    Write-Host "    ${c}ch --selftest${r}     $($t.hSelftest)"
    Write-Host "    ${c}ch --preview${r}      $($t.hPreview)"
    Write-Host "    ${c}ch --diag${r}         $($t.hDiag)"
    Write-Host "    ${c}ch --help${r}         $($t.hHelp)"
    Write-Host ''
    Write-Host "  ${d}$($t.hInPanel)${r}"
    Write-Host "    ${d}list   ${r}${c}up/dn${r} $($t.kNavigate)  ${c}Enter${r} $($t.kOpen)  ${c}/${r} $($t.kRepoFilter)  ${c}s${r} $($t.kSearch)  ${c}r${r} $($t.kReload)"
    Write-Host "    ${d}repo   ${r}${c}Enter${r} $($t.kResume)  ${c}n${r} $($t.kNew)  ${c}c${r} $($t.kContinue)  ${c}m${r} $($t.kMemory)  ${c}e${r} $($t.kFolder)  ${c}v${r} $($t.kEditor)  ${c}g${r} $($t.kGitHub)"
    Write-Host "    ${d}search ${r}$($t.searchType)  ${c}Enter${r} $($t.kResume)  ${c}Esc${r} $($t.kBack)"
    Write-Host ''
    Write-Host "  ${d}$($t.hMarkers)${r}"
    Write-Host "    ${d}$($t.hMarkerLine)${r}"
    Write-Host ''
    Write-Host "  ${d}$($t.hConfig) $root\config.json${r}"
    Write-Host ''
}

$first = ''
if ($ChArgs -and $ChArgs.Count -gt 0) { $first = [string]$ChArgs[0] }

switch -Regex ($first) {
    '^(--help|-h|/\?)$' {
        Show-ChHelp
        return
    }
    '^--selftest$' {
        & (Join-Path $root 'tests\ChTests.ps1')
        return
    }
    '^--reindex$' {
        . (Join-Path $root 'lib\ChIndex.ps1')
        . (Join-Path $root 'lib\ChRepos.ps1')
        Clear-ChSessionCache
        Clear-ChReposCache
        Write-Host $global:T.msgDropped -ForegroundColor DarkGray
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $s = Get-ChSessionIndex
        $r = Get-ChRepoInventory -Force
        $sw.Stop()
        Write-Host ($global:T.msgRebuilt -f $s.Count, $r.Count, [math]::Round($sw.Elapsed.TotalSeconds, 2)) -ForegroundColor Green
        return
    }
    '^--preview$' {
        . (Join-Path $root 'lib\ChUI.ps1')
        $script:ChAltScreen = $false
        $w = (Get-ChConsoleSize).Width
        if ($ChArgs.Count -gt 1) { $w = [int]$ChArgs[1] }
        $h = 24
        $rows = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos (Get-ChRepoInventory)
        $owner = ($rows | Where-Object { $_.Owner } | Group-Object Owner | Sort-Object Count -Descending | Select-Object -First 1).Name
        Write-Host ''
        foreach ($l in (Build-ChListLines -Rows $rows -Index 0 -Scroll 0 -Filter '' -Width ($w - 1) -Height $h -Owner $owner -Status '')) {
            Write-Host $l
        }
        $top = $rows | Where-Object { $_.Sessions.Count -gt 0 } | Select-Object -First 1
        if ($top) {
            $mem = @()
            if ($top.Path) { $mem = @(Get-ChMemoryEntries -Path $top.Path) }
            Write-Host ''
            foreach ($l in (Build-ChDetailLines -Row $top -Index 0 -Scroll 0 -Width ($w - 1) -Height $h -Memory $mem -Status '')) {
                Write-Host $l
            }
        }
        $cat = @(Get-ChSessionCatalog -Rows $rows)
        $q = 'design'
        Write-Host ''
        foreach ($l in (Build-ChSearchLines -Results @(Select-ChSessions -Catalog $cat -Query $q) `
                        -Total $cat.Count -Query $q -Index 0 -Scroll 0 -Width ($w - 1) -Height $h)) {
            Write-Host $l
        }
        Write-Host ''
        return
    }
    '^(-s|--sessoes|--buscar)$' {
        if (-not (Test-Path Function:\Show-ChPanel)) { . (Join-Path $root 'lib\ChUI.ps1') }
        $q = ''
        if ($ChArgs.Count -gt 1) { $q = (($ChArgs | Select-Object -Skip 1) -join ' ').Trim() }
        Show-ChPanel -BuscarSessao $q
        return
    }
    '^--diag$' {
        if (-not (Test-Path Function:\Show-ChPanel)) { . (Join-Path $root 'lib\ChUI.ps1') }
        foreach ($n in @('ChRoot', 'ChProjectsRoot', 'ChIndexCacheDir', 'ChReposCacheDir', 'ChMemProjectsRoot')) {
            $v = Get-Variable -Name $n -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            Write-Host ("    {0,-18} = '{1}'" -f $n, $v)
        }
        foreach ($etapa in @('Get-ChConfig', 'Get-ChSessionIndex', 'Get-ChRepoInventory')) {
            try {
                $r = & $etapa
                Write-Host ("    {0,-20} OK ({1} itens)" -f $etapa, @($r).Count) -ForegroundColor Green
            } catch {
                Write-Host ("    {0,-20} FALHOU: {1}" -f $etapa, $_.Exception.Message) -ForegroundColor Red
                Write-Host ("      em: {0}" -f $_.InvocationInfo.PositionMessage) -ForegroundColor DarkRed
            }
        }
        # drawing a frame exercises the colour and glyph tables, which are module
        # state too and would vanish in the wrong scope
        try {
            $lines = Build-ChListLines -Rows (Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos (Get-ChRepoInventory)) `
                        -Index 0 -Scroll 0 -Filter '' -Width 80 -Height 20 -Owner 'diag' -Status ''
            $larguras = @($lines | ForEach-Object { Get-ChVisibleLength $_ } | Sort-Object -Unique)
            Write-Host ("    {0,-20} OK ({1} linhas, largura {2})" -f 'desenhar quadro', $lines.Count, ($larguras -join ',')) -ForegroundColor Green
        } catch {
            Write-Host ("    {0,-20} FALHOU: {1}" -f 'desenhar quadro', $_.Exception.Message) -ForegroundColor Red
        }
        return
    }
    default {
        # The modules are reloaded on every call, and that is fine: after the first
        # `ch` of a window .NET and the disk cache are warm and the reread costs
        # about 114ms. The guard only avoids duplicate work if someone loaded the
        # modules from outside.
        if (-not (Test-Path Function:\Show-ChPanel)) { . (Join-Path $root 'lib\ChUI.ps1') }

        # `ch` run from inside a repository opens that repository; `ch --lista`
        # forces the full list anyway.
        $repoAtual = ''
        $lista = $false
        $filtro = ''
        $restantes = New-Object System.Collections.Generic.List[string]
        foreach ($a in @($ChArgs)) {
            if ($a -eq '--lista' -or $a -eq '-l') { $lista = $true; continue }
            if ($a) { $restantes.Add([string]$a) }
        }
        if ($restantes.Count -gt 0) { $filtro = ($restantes -join ' ').Trim() }
        if (-not $lista -and -not $filtro) { $repoAtual = (Get-Location).Path }

        Show-ChPanel -InitialFilter $filtro -InitialRepoPath $repoAtual
    }
}
