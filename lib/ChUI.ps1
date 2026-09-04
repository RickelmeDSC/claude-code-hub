# ChUI.ps1 - the panel.
#
# The only module that writes to the screen. It uses the terminal's alternate
# buffer (ESC[?1049h), so the panel never pollutes the PowerShell scrollback and
# the Claude conversation stays in the normal buffer, where you can scroll it later.

if (-not (Test-Path Function:\Get-ChText)) { . (Join-Path $PSScriptRoot 'ChText.ps1') }
if (-not (Test-Path Function:\Get-ChSessionIndex)) { . (Join-Path $PSScriptRoot 'ChIndex.ps1') }
if (-not (Test-Path Function:\Get-ChRepoInventory)) { . (Join-Path $PSScriptRoot 'ChRepos.ps1') }
if (-not (Test-Path Function:\Get-ChMemoryEntries)) { . (Join-Path $PSScriptRoot 'ChMemory.ps1') }

$global:E = [string][char]27

$global:C = @{
    Reset   = "$global:E[0m"
    Bold    = "$global:E[1m"
    Dim     = "$global:E[90m"
    Cyan    = "$global:E[36m"
    Green   = "$global:E[32m"
    Yellow  = "$global:E[33m"
    Blue    = "$global:E[94m"
    Magenta = "$global:E[35m"
    Red     = "$global:E[31m"
    White   = "$global:E[97m"
    Sel     = "$global:E[48;5;238m$global:E[97m"
}

# Windows Terminal draws box glyphs and the check mark without breaking the
# alignment. The legacy console does not, so there it falls back to ASCII.
if ($env:WT_SESSION) {
    $global:G = @{
        TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F
        H  = [char]0x2500; V  = [char]0x2502
        Sel = [char]0x25B8; Yes = [char]0x2713; No = [char]0x00B7; Dot = [char]0x2022
        Up = [char]0x2191; Warn = [char]0x25CF
        Track = [char]0x250A; Thumb = [char]0x2503; Ellipsis = [char]0x2026
    }
} else {
    $global:G = @{
        TL = '+'; TR = '+'; BL = '+'; BR = '+'
        H  = '-'; V  = '|'
        Sel = '>'; Yes = '+'; No = '.'; Dot = '*'
        Up = '^'; Warn = 'o'
        Track = ':'; Thumb = '#'; Ellipsis = '...'
    }
}

$global:ChAnsiRegex = New-Object System.Text.RegularExpressions.Regex("$global:E\[[0-9;?]*[a-zA-Z]")

# --- pure functions ------------------------------------------------------------

function Get-ChConsoleSize {
    # [Console]::WindowWidth throws IOException when there is no real console
    # (redirected output, a pipe, a scheduled task). The panel does not run in
    # those cases, but --preview and the tests do, so a value is still needed.
    $w = 0; $h = 0
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    if ($w -le 0 -or $h -le 0) {
        try {
            $sz = $Host.UI.RawUI.WindowSize
            $w = $sz.Width; $h = $sz.Height
        } catch { }
    }
    if ($w -le 0) { $w = 100 }
    if ($h -le 0) { $h = 30 }
    return [pscustomobject]@{ Width = $w; Height = $h }
}

function Get-ChVisibleLength {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return $global:ChAnsiRegex.Replace($Text, '').Length
}

function Limit-ChText {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return '' }
    if ($Max -le 0) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $e = [string]$global:G.Ellipsis
    if ($Max -le $e.Length) { return $Text.Substring(0, $Max) }
    return ($Text.Substring(0, $Max - $e.Length) + $e)
}

function Get-ChScrollGlyph {
    # One character of a right-edge scrollbar for the row at $Row. Returns a
    # space when everything already fits, so the column width never changes and
    # the list does not jump when a scrollbar appears.
    param([int]$Row, [int]$Visible, [int]$Total, [int]$Scroll)
    if ($Total -le $Visible -or $Visible -le 0) { return ' ' }
    $size = [Math]::Max(1, [int][Math]::Round($Visible * $Visible / [double]$Total))
    $span = $Visible - $size
    $maxScroll = $Total - $Visible
    $start = 0
    if ($maxScroll -gt 0) { $start = [int][Math]::Round($span * $Scroll / [double]$maxScroll) }
    if ($Row -ge $start -and $Row -lt ($start + $size)) { return [string]$global:G.Thumb }
    return [string]$global:G.Track
}

function Get-ChDateColour {
    # Recency at a glance: what happened today stands out, what is old recedes.
    param([datetime]$When)
    if ($null -eq $When) { return $global:C.Dim }
    $days = ((Get-Date).Date - $When.Date).TotalDays
    if ($days -le 1) { return $global:C.Cyan }
    if ($days -le 7) { return $global:C.White }
    return $global:C.Dim
}

function New-ChSectionHeading {
    # A heading that carries a rule to the right edge, so sections read as
    # sections without spending an extra line on a separator.
    param([string]$Text, [int]$Inner, [string]$Count = '')
    $label = '  ' + $global:C.Bold + $Text + $global:C.Reset
    $plain = '  ' + $Text
    if ($Count) {
        $label += $global:C.Dim + ' ' + $Count
        $plain += ' ' + $Count
    }
    $fill = $Inner - $plain.Length - 3
    if ($fill -lt 1) { return $label }
    return $label + $global:C.Dim + ' ' + ([string]$global:G.H * $fill) + $global:C.Reset
}

function Limit-ChAnsi {
    # Truncates already-coloured text at a number of VISIBLE characters, copying
    # the ANSI sequences without counting them. This is the safety net that makes
    # it impossible for a line to break out of the box, however narrow the terminal.
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Max -le 0) { return '' }
    if ((Get-ChVisibleLength $Text) -le $Max) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $vis = 0
    $i = 0
    while ($i -lt $Text.Length -and $vis -lt $Max) {
        if ($Text[$i] -eq [char]27) {
            $m = $global:ChAnsiRegex.Match($Text, $i)
            if ($m.Success -and $m.Index -eq $i) {
                [void]$sb.Append($m.Value)
                $i += $m.Length
                continue
            }
        }
        [void]$sb.Append($Text[$i])
        $vis++
        $i++
    }
    [void]$sb.Append($global:C.Reset)
    return $sb.ToString()
}

function Format-ChRelativeDate {
    param([datetime]$When)
    if ($null -eq $When) { return '' }
    $now = Get-Date
    $d = $When.Date
    if ($d -eq $now.Date) { return $global:T.dToday + ' ' + $When.ToString('HH:mm') }
    if ($d -eq $now.Date.AddDays(-1)) { return $global:T.dYesterday + ' ' + $When.ToString('HH:mm') }
    if ($When.Year -eq $now.Year) { return $When.ToString('dd/MM HH:mm') }
    return $When.ToString('dd/MM/yy')
}

function Format-ChDuration {
    param([timespan]$Span)
    if ($null -eq $Span) { return '' }
    $total = $Span.TotalSeconds
    if ($total -lt 60) { return '<1min' }
    if ($total -lt 3600) { return ([int]$Span.TotalMinutes).ToString() + 'min' }
    if ($total -lt 86400) { return ([int][Math]::Floor($Span.TotalHours)).ToString() + 'h' + $Span.Minutes.ToString('00') }
    return ([int][Math]::Floor($Span.TotalDays)).ToString() + 'd'
}

function Get-ChOtherLabel {
    param([string]$Path)
    if ($Path -eq $env:USERPROFILE) { return $global:T.homeLabel }
    $leaf = Split-Path -Leaf $Path
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $Path }
    return $leaf
}

function Join-ChSessionsToRepos {
    # Matches each session to a repository by the longest prefix of the real path
    # (the cwd taken from inside the .jsonl). Whatever does not match becomes
    param($Sessions, $Repos)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Repos) {
        $paths = New-Object System.Collections.Generic.List[string]
        if ($r.PSObject.Properties.Match('Paths').Count -and $r.Paths) {
            foreach ($p in @($r.Paths)) { if ($p) { $paths.Add([string]$p) } }
        }
        if ($r.Path) { $paths.Add([string]$r.Path) }
        $uniq = @($paths | Select-Object -Unique)
        foreach ($p in $uniq) {
            $root = ([string]$p).TrimEnd('\')
            $candidates.Add([pscustomobject]@{ Key = $r.FullName; Root = $root; Len = $root.Length })
        }
    }
    $ordered = @($candidates | Sort-Object -Property Len -Descending)

    $byRepo = @{}
    $byOther = @{}
    foreach ($s in $Sessions) {
        $cwd = $s.Cwd
        if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = '(desconhecido)' }
        $cwdTrim = ([string]$cwd).TrimEnd('\')
        $matched = $null
        foreach ($c in $ordered) {
            if ($cwdTrim.Equals($c.Root, [StringComparison]::OrdinalIgnoreCase) -or
                $cwdTrim.StartsWith($c.Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $matched = $c.Key
                break
            }
        }
        if ($matched) {
            if (-not $byRepo.ContainsKey($matched)) { $byRepo[$matched] = New-Object System.Collections.Generic.List[object] }
            $byRepo[$matched].Add($s)
        } else {
            if (-not $byOther.ContainsKey($cwdTrim)) { $byOther[$cwdTrim] = New-Object System.Collections.Generic.List[object] }
            $byOther[$cwdTrim].Add($s)
        }
    }

    $repoRows = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Repos) {
        $sess = @()
        if ($byRepo.ContainsKey($r.FullName)) {
            $sess = @($byRepo[$r.FullName] | Sort-Object -Property LastActivity -Descending)
        }
        $last = $null
        if ($sess.Count -gt 0) { $last = $sess[0].LastActivity }
        if ($r.PushedAt -and (-not $last -or $r.PushedAt -gt $last)) { $last = $r.PushedAt }
        $repoRows.Add([pscustomobject]@{
            Kind         = 'repo'
            Name         = $r.Name
            FullName     = $r.FullName
            Owner        = $r.Owner
            Path         = $r.Path
            HasClone     = $r.HasClone
            Private      = $r.Private
            Archived     = $r.Archived
            Url          = $r.Url
            Description  = $r.Description
            Branch       = $r.Branch
            Sync         = $r.Sync
            Sessions     = $sess
            LastActivity = $last
        })
    }

    $otherRows = New-Object System.Collections.Generic.List[object]
    foreach ($k in $byOther.Keys) {
        $sess = @($byOther[$k] | Sort-Object -Property LastActivity -Descending)
        $otherRows.Add([pscustomobject]@{
            Kind         = 'other'
            Name         = Get-ChOtherLabel $k
            FullName     = $k
            Owner        = $null
            Path         = $k
            HasClone     = (Test-Path -LiteralPath $k)
            Private      = $false
            Archived     = $false
            Url          = $null
            Description  = $null
            Branch       = $null
            Sync         = 'unknown'
            Sessions     = $sess
            LastActivity = $sess[0].LastActivity
        })
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($repoRows | Sort-Object -Property @{Expression = { $_.LastActivity }; Descending = $true })) { $out.Add($r) }
    foreach ($r in @($otherRows | Sort-Object -Property @{Expression = { $_.LastActivity }; Descending = $true })) { $out.Add($r) }
    return $out.ToArray()
}

function Get-ChSessionCatalog {
    # Flattens the panel rows into a list of sessions that know which repository
    # they came from. This is the basis of the global search: the question "which
    # repo was I doing that in?" only has an answer if the session carries context.
    param($Rows)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        foreach ($s in @($r.Sessions)) {
            $out.Add([pscustomobject]@{
                Session      = $s
                RepoName     = $r.Name
                RepoPath     = $r.Path
                RepoKind     = $r.Kind
                Title        = $s.Title
                FirstPrompt  = $s.FirstPrompt
                LastActivity = $s.LastActivity
            })
        }
    }
    return @($out | Sort-Object -Property @{Expression = { $_.LastActivity }; Descending = $true })
}

function Select-ChSessions {
    # Searches a substring in the title, the first prompt and the repository name.
    # With no query it returns everything, so the screen opens already showing the
    # whole history in recency order.
    param($Catalog, [string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return @($Catalog) }
    $q = $Query.Trim()
    # @() at the call site is what keeps a single result a list. PowerShell
    # unrolls a one-element array on return, and .Count then comes back empty.
    return @($Catalog | Where-Object {
        ($_.Title -and $_.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($_.FirstPrompt -and $_.FirstPrompt.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($_.RepoName -and $_.RepoName.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
}

# --- drawing -------------------------------------------------------------------

function Enter-ChScreen {
    if ($global:ChAltScreen) {
        [Console]::Write("$global:E[?1049h")
        [Console]::Write("$global:E[?25l")
    } else {
        Clear-Host
    }
}

function Exit-ChScreen {
    if ($global:ChAltScreen) {
        [Console]::Write("$global:E[?25h")
        [Console]::Write("$global:E[?1049l")
    } else {
        [Console]::CursorVisible = $true
    }
    [Console]::Write($global:C.Reset)
}

function Write-ChFrame {
    param([string[]]$Lines)
    $w = (Get-ChConsoleSize).Width
    $h = (Get-ChConsoleSize).Height
    $rows = $h - 1
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$global:E[H")
    for ($i = 0; $i -lt $rows; $i++) {
        $line = ''
        if ($i -lt $Lines.Count) { $line = $Lines[$i] }
        $vis = Get-ChVisibleLength $line
        $pad = ($w - 1) - $vis
        if ($pad -lt 0) { $pad = 0 }
        [void]$sb.Append($line)
        [void]$sb.Append($global:C.Reset)
        [void]$sb.Append(' ' * $pad)
        if ($i -lt $rows - 1) { [void]$sb.Append("`r`n") }
    }
    [void]$sb.Append("$global:E[0J")
    [Console]::Write($sb.ToString())
}

function New-ChTopBorder {
    param([string]$Left, [string]$Right, [int]$Width)
    $l = ''
    if ($Left) { $l = ' ' + $Left + ' ' }
    $r = ''
    if ($Right) { $r = ' ' + $Right + ' ' }
    $fill = $Width - 2 - 1 - $l.Length - $r.Length
    if ($fill -lt 1) {
        $l = Limit-ChText $l ([Math]::Max(1, $Width - 8))
        $r = ''
        $fill = $Width - 2 - 1 - $l.Length
        if ($fill -lt 1) { $fill = 1 }
    }
    return $global:C.Dim + $global:G.TL + $global:G.H + $global:C.Reset +
           $global:C.Bold + $global:C.Cyan + $l + $global:C.Reset +
           $global:C.Dim + ([string]$global:G.H * $fill) + $r + $global:G.TR + $global:C.Reset
}

function New-ChBottomBorder {
    param([int]$Width)
    return $global:C.Dim + $global:G.BL + ([string]$global:G.H * ($Width - 2)) + $global:G.BR + $global:C.Reset
}

function Close-ChFrame {
    # The only place that decides the final size of a frame. It takes the body,
    # trims whatever exceeds the height, pads whatever is missing, then nails the
    # key bar and the bottom border on. No screen can spill out of the window.
    param($Body, [string]$KeyLine, [int]$Width, [int]$Height)
    $bodyMax = $Height - 3
    if ($bodyMax -lt 1) { $bodyMax = 1 }
    $out = New-Object System.Collections.Generic.List[string]
    $n = [Math]::Min($Body.Count, $bodyMax)
    for ($i = 0; $i -lt $n; $i++) { $out.Add($Body[$i]) }
    while ($out.Count -lt $bodyMax) { $out.Add((New-ChRow -Content '' -Width $Width)) }
    $out.Add($KeyLine)
    $out.Add((New-ChBottomBorder -Width $Width))
    return $out.ToArray()
}

function Get-ChDetailListHeight {
    # Height of the session list. It lives in its own function because drawing and
    # scrolling have to agree on the same number.
    param([int]$Height, [int]$MemShow, [bool]$HasDescription)
    $fixedTop = 4
    if ($HasDescription) { $fixedTop = 5 }
    $memBlock = 0
    if ($MemShow -gt 0) { $memBlock = 2 + $MemShow }
    $h = ($Height - 3) - $fixedTop - $memBlock - 1
    if ($h -lt 1) { $h = ($Height - 3) - $fixedTop - 1 }
    if ($h -lt 1) { $h = 1 }
    return $h
}

function New-ChRow {
    param([string]$Content, [int]$Width, [switch]$Selected, [string]$ScrollGlyph = '')
    $inner = $Width - 2
    # The scrollbar lives outside the selection highlight, so the bar stays
    # readable on the selected row instead of being swallowed by it.
    $reserve = 0
    if ($ScrollGlyph) { $reserve = 2 }
    $target = $inner - $reserve
    if ($target -lt 1) { $target = 1 }

    if ($Selected) { $Content = $global:ChAnsiRegex.Replace($Content, '') }
    $vis = Get-ChVisibleLength $Content
    if ($vis -gt $target) {
        $Content = Limit-ChAnsi -Text $Content -Max $target
        $vis = $target
    }
    $pad = $target - $vis
    if ($pad -lt 0) { $pad = 0 }
    $v = $global:C.Dim + $global:G.V + $global:C.Reset
    $body = $Content + $global:C.Reset + (' ' * $pad)
    if ($Selected) { $body = $global:C.Sel + $Content + (' ' * $pad) + $global:C.Reset }
    if ($ScrollGlyph) { $body += ' ' + $global:C.Dim + $ScrollGlyph + $global:C.Reset }
    return $v + $body + $v
}

# --- screen 1: repository list -----------------------------------------------

function Build-ChListLines {
    param($Rows, [int]$Index, [int]$Scroll, [string]$Filter, [int]$Width, [int]$Height, [string]$Owner, [string]$Status)

    $inner = $Width - 2
    $lines = New-Object System.Collections.Generic.List[string]

    $sessTotal = 0
    foreach ($r in $Rows) { $sessTotal += $r.Sessions.Count }
    $sep = ' ' + $global:G.Dot + ' '
    $word = 'sessions'
    if ($global:ChLang -eq 'pt') { $word = 'sessoes' }
    $right = "$($Rows.Count) repos$sep$sessTotal $word"
    if ($Owner) { $right = $Owner + $sep + $right }
    if ($global:ChReposOffline) { $right = $global:T.offline + $sep + $right }
    $lines.Add((New-ChTopBorder -Left 'CLAUDE HUB' -Right $right -Width $Width))

    # Column widths defined once and used by both the header and the rows: the
    # only way to keep the two genuinely aligned.
    $markW = 3; $gapW = 2; $localW = 4; $sessW = 6; $dateW = 12; $barW = 2
    # the branch column only appears when there is room; on a narrow terminal it
    # would steal from the repository name, which matters more
    $branchW = 0
    if ($inner -ge 88) { $branchW = 20 }
    $nameW = $inner - ($markW + $gapW + $localW + $branchW + $sessW + $dateW + $barW)
    if ($nameW -lt 14) { $nameW = 14 }

    $hdr = (' ' * $markW) + $global:T.colRepo.PadRight($nameW) + (' ' * $gapW) + ''.PadRight($localW)
    if ($branchW -gt 0) { $hdr += $global:T.colBranch.PadRight($branchW) }
    $hdr += $global:T.colSess.PadRight($sessW) + $global:T.colWhen
    $lines.Add((New-ChRow -Content ($global:C.Dim + (Limit-ChText $hdr ($inner - $barW))) -Width $Width -ScrollGlyph ' '))
    $lines.Add((New-ChRow -Content '' -Width $Width))

    $listHeight = $Height - 8
    if ($listHeight -lt 3) { $listHeight = 3 }

    if ($Rows.Count -eq 0) {
        $msg = '  ' + $global:T.nothingFound
        if ($Filter) { $msg = '  ' + ($global:T.nothingMatches -f $Filter) }
        $lines.Add((New-ChRow -Content ($global:C.Dim + $msg) -Width $Width))
    }

    $lastKind = 'repo'
    for ($i = $Scroll; $i -lt [Math]::Min($Rows.Count, $Scroll + $listHeight); $i++) {
        $r = $Rows[$i]
        if ($r.Kind -eq 'other' -and $lastKind -eq 'repo') {
            $lines.Add((New-ChRow -Content ($global:C.Dim + '  ' + ([string]$global:G.H * 3) + (' ' + $global:T.otherPlaces)) -Width $Width -ScrollGlyph ' '))
        }
        $lastKind = $r.Kind

        $marker = ' ' * $markW
        if ($i -eq $Index) { $marker = ' ' + $global:G.Sel + ' ' }

        $name = Limit-ChText $r.Name $nameW
        $namePart = $name.PadRight($nameW)

        # A single glyph carrying both clone state and sync state:
        #   dot    not cloned locally
        #   check  cloned and identical to origin
        #   arrow  cloned with something unsynced (local SHA != remote SHA)
        $local = [string]$global:G.No
        $cloneColor = $global:C.Dim
        if ($r.HasClone) {
            $local = [string]$global:G.Yes
            $cloneColor = $global:C.Green
            if ($r.Sync -eq 'diverged') {
                $local = [string]$global:G.Up
                $cloneColor = $global:C.Yellow
            } elseif ($r.Sync -ne 'in-sync') {
                $cloneColor = $global:C.Dim
            }
        }

        $branch = ''
        if ($branchW -gt 0) {
            if ($r.Archived) { $branch = $global:T.archived }
            elseif ($r.Branch) { $branch = Limit-ChText $r.Branch ($branchW - 1) }
        }

        $ns = ''
        if ($r.Sessions.Count -gt 0) { $ns = [string]$r.Sessions.Count }
        else { $ns = [string]$global:G.No }

        $when = ''
        if ($r.LastActivity) { $when = Format-ChRelativeDate $r.LastActivity }

        $gap = ' ' * $gapW
        $plain = $marker + $namePart + $gap + $local.PadRight($localW) +
                 $branch.PadRight($branchW) + $ns.PadRight($sessW) + $when
        $bar = Get-ChScrollGlyph -Row ($i - $Scroll) -Visible $listHeight -Total $Rows.Count -Scroll $Scroll
        if ($i -eq $Index) {
            $lines.Add((New-ChRow -Content (Limit-ChText $plain ($inner - $barW)) -Width $Width -Selected -ScrollGlyph $bar))
        } else {
            $nameColor = $global:C.White
            if ($r.Kind -eq 'other') { $nameColor = $global:C.Dim }
            elseif (-not $r.HasClone) { $nameColor = $global:C.Dim }
            elseif ($r.Archived) { $nameColor = $global:C.Dim }
            $content = $marker + $nameColor + $namePart + $global:C.Reset + $gap +
                       $cloneColor + $local.PadRight($localW) + $global:C.Reset +
                       $global:C.Dim + $branch.PadRight($branchW) + $global:C.Reset +
                       $global:C.Cyan + $ns.PadRight($sessW) + $global:C.Reset +
                       (Get-ChDateColour $r.LastActivity) + $when + $global:C.Reset
            $lines.Add((New-ChRow -Content $content -Width $Width -ScrollGlyph $bar))
        }
    }

    if ($Filter -ne $null -and $Filter -ne '') {
        $keyLine = New-ChRow -Content ('  ' + $global:C.Yellow + '/' + $Filter + $global:C.Reset + $global:C.Dim + '   ' + $global:T.escClears) -Width $Width
    } elseif ($Status) {
        $keyLine = New-ChRow -Content ('  ' + $global:C.Yellow + $Status) -Width $Width
    } else {
        $arrow = [string][char]0x2191 + [char]0x2193
        if ($inner -ge 64) {
            $keys = '  ' + $global:C.Cyan + $arrow + $global:C.Dim + ' ' + $global:T.kNavigate + '   ' +
                    $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kOpen + '   ' +
                    $global:C.Cyan + '/' + $global:C.Dim + ' ' + $global:T.kRepoFilter + '   ' +
                    $global:C.Cyan + 's' + $global:C.Dim + ' ' + $global:T.kSearch + '   ' +
                    $global:C.Cyan + 'r' + $global:C.Dim + ' ' + $global:T.kReload + '   ' +
                    $global:C.Cyan + 'q' + $global:C.Dim + ' ' + $global:T.kQuit
        } else {
            $keys = '  ' + $global:C.Cyan + $arrow + $global:C.Dim + ' ' + $global:T.kMove + '  ' +
                    $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kOpen + '  ' +
                    $global:C.Cyan + 's' + $global:C.Dim + ' ' + $global:T.kSessions + '  ' +
                    $global:C.Cyan + 'q' + $global:C.Dim + ' ' + $global:T.kQuit
        }
        $keyLine = New-ChRow -Content $keys -Width $Width
    }
    return Close-ChFrame -Body $lines -KeyLine $keyLine -Width $Width -Height $Height
}

# --- screen 2: repository detail ---------------------------------------------

function Build-ChDetailLines {
    param($Row, [int]$Index, [int]$Scroll, [int]$Width, [int]$Height, $Memory, [string]$Status)

    $inner = $Width - 2
    $lines = New-Object System.Collections.Generic.List[string]

    $right = $Row.Branch
    if (-not $right) { $right = '' }
    $left = $Row.Name
    if ($Row.Kind -eq 'repo' -and $Row.FullName) { $left = $Row.FullName }
    $lines.Add((New-ChTopBorder -Left $left -Right $right -Width $Width))

    $path = $Row.Path
    if (-not $path) { $path = $global:T.noClone }
    $pathLine = '  ' + $global:C.Dim + (Limit-ChText $path ($inner - 30))

    # Here a ~200ms `git status` is worth paying: it is a single repository, you
    # already chose to look at it, and the exact number is what helps you decide.
    if ($Row.Path) {
        $gs = Get-ChGitStatus -RepoPath $Row.Path
        if ($gs) {
            $parts = New-Object System.Collections.Generic.List[string]
            if ($gs.Changed -gt 0) { $parts.Add($global:T.gitChanged -f $gs.Changed) }
            if ($gs.Ahead -gt 0) { $parts.Add($global:T.gitAhead -f $gs.Ahead) }
            if ($gs.Behind -gt 0) { $parts.Add($global:T.gitBehind -f $gs.Behind) }
            if (-not $gs.HasUpstream) { $parts.Add($global:T.gitNoUpstream) }
            if ($parts.Count -eq 0) {
                $pathLine += '   ' + $global:C.Green + $global:T.gitClean
            } else {
                $pathLine += '   ' + $global:C.Yellow + ($parts -join ', ')
            }
        }
    }
    $lines.Add((New-ChRow -Content $pathLine -Width $Width))
    if ($Row.Description) {
        $lines.Add((New-ChRow -Content ('  ' + $global:C.Dim + (Limit-ChText $Row.Description ($inner - 2))) -Width $Width))
    }
    $lines.Add((New-ChRow -Content '' -Width $Width))

    $memCount = 0
    if ($Memory) { $memCount = @($Memory).Count }
    $memShown = [int](Get-ChConfig).MemoryPreviewLines
    if ($memCount -eq 0) { $memShown = 0 }
    if ($memShown -gt $memCount) { $memShown = $memCount }

    $listHeight = Get-ChDetailListHeight -Height $Height -MemShow $memShown -HasDescription ([bool]$Row.Description)

    $sessions = @($Row.Sessions)
    $range = "($($sessions.Count))"
    if ($sessions.Count -gt $listHeight) {
        $last = [Math]::Min($sessions.Count, $Scroll + $listHeight)
        $range = "$($Scroll + 1)-$last / $($sessions.Count)"
    }
    $lines.Add((New-ChRow -Content (New-ChSectionHeading -Text $global:T.secSessions -Inner $inner -Count $range) -Width $Width))

    if ($sessions.Count -eq 0) {
        $lines.Add((New-ChRow -Content ('  ' + $global:C.Dim + ('  ' + $global:T.noSessions)) -Width $Width))
    }

    $markW = 3
    $dateW = 14
    $durW = 7
    $titleW = $inner - $markW - 2 - $dateW - $durW
    if ($titleW -lt 16) { $titleW = 16 }

    for ($i = $Scroll; $i -lt [Math]::Min($sessions.Count, $Scroll + $listHeight); $i++) {
        $s = $sessions[$i]
        $marker = ' ' * $markW
        if ($i -eq $Index) { $marker = ' ' + $global:G.Sel + ' ' }
        $title = Limit-ChText $s.Title $titleW
        $when = ''
        if ($s.LastActivity) { $when = Format-ChRelativeDate $s.LastActivity }
        $dur = ''
        if ($s.Started -and $s.LastActivity) { $dur = Format-ChDuration ($s.LastActivity - $s.Started) }
        $plain = $marker + $title.PadRight($titleW) + '  ' + $when.PadRight($dateW) + $dur.PadLeft($durW)
        if ($i -eq $Index) {
            $lines.Add((New-ChRow -Content (Limit-ChText $plain $inner) -Width $Width -Selected))
            # when the title was derived from the first prompt, repeating it as
            # the caption just wastes a line
            if ($s.FirstPrompt -and $s.FirstPrompt -ne $s.Title) {
                $leg = '     ' + $global:C.Dim + (Limit-ChText $s.FirstPrompt ($inner - 6))
                $lines.Add((New-ChRow -Content $leg -Width $Width))
            }
        } else {
            $content = $marker + $global:C.White + $title.PadRight($titleW) + $global:C.Reset + '  ' +
                       (Get-ChDateColour $s.LastActivity) + $when.PadRight($dateW) + $global:C.Reset +
                       $global:C.Dim + $dur.PadLeft($durW) + $global:C.Reset
            $lines.Add((New-ChRow -Content $content -Width $Width))
        }
    }

    if ($memShown -gt 0) {
        $lines.Add((New-ChRow -Content '' -Width $Width))
        $lines.Add((New-ChRow -Content (New-ChSectionHeading -Text $global:T.secMemory -Inner $inner -Count "($memCount)") -Width $Width))
        $shown = @($Memory | Select-Object -First $memShown)
        foreach ($m in $shown) {
            $txt = $m.Title
            if ($m.Hook) { $txt += ' - ' + $m.Hook }
            $lines.Add((New-ChRow -Content ('   ' + $global:C.Magenta + $global:G.Dot + ' ' + $global:C.Dim + (Limit-ChText $txt ($inner - 6))) -Width $Width))
        }
    }

    if ($Status) {
        $keyLine = New-ChRow -Content ('  ' + $global:C.Yellow + $Status) -Width $Width
    } else {
        # Three widths: the full bar does not fit in 93 columns, and truncating it in
        # the middle swallows the keys at the end ('Esc back' became 'Esc ba').
        if ($inner -ge 98) {
            $keys = '  ' + $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kResume + '   ' +
                    $global:C.Cyan + 'n' + $global:C.Dim + ' ' + $global:T.kNew + '   ' +
                    $global:C.Cyan + 'c' + $global:C.Dim + ' ' + $global:T.kContinue + '   ' +
                    $global:C.Cyan + 'm' + $global:C.Dim + ' ' + $global:T.kMemory + '   ' +
                    $global:C.Cyan + 'e' + $global:C.Dim + ' ' + $global:T.kFolder + '   ' +
                    $global:C.Cyan + 'v' + $global:C.Dim + ' ' + $global:T.kEditor + '   ' +
                    $global:C.Cyan + 'g' + $global:C.Dim + ' ' + $global:T.kGitHub + '   ' +
                    $global:C.Cyan + 'Esc' + $global:C.Dim + ' ' + $global:T.kBack
        } elseif ($inner -ge 79) {
            $keys = '  ' + $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kResume + '  ' +
                    $global:C.Cyan + 'n' + $global:C.Dim + ' ' + $global:T.kNew + '  ' +
                    $global:C.Cyan + 'c' + $global:C.Dim + ' ' + $global:T.kContinue + '  ' +
                    $global:C.Cyan + 'm' + $global:C.Dim + ' ' + $global:T.kMemory + '  ' +
                    $global:C.Cyan + 'e' + $global:C.Dim + ' ' + $global:T.kFolder + '  ' +
                    $global:C.Cyan + 'v' + $global:C.Dim + ' ' + $global:T.kEditorShort + '  ' +
                    $global:C.Cyan + 'Esc' + $global:C.Dim + ' ' + $global:T.kBack
        } else {
            $keys = '  ' + $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kResume + '  ' +
                    $global:C.Cyan + 'n' + $global:C.Dim + ' ' + $global:T.kNew + '  ' +
                    $global:C.Cyan + 'm' + $global:C.Dim + ' ' + $global:T.kMemory + '  ' +
                    $global:C.Cyan + 'Esc' + $global:C.Dim + ' ' + $global:T.kBack
        }
        $keyLine = New-ChRow -Content $keys -Width $Width
    }
    return Close-ChFrame -Body $lines -KeyLine $keyLine -Width $Width -Height $Height
}

# --- screen 4: session search -------------------------------------------------

function Build-ChSearchLines {
    param($Results, [int]$Total, [string]$Query, [int]$Index, [int]$Scroll, [int]$Width, [int]$Height)

    $inner = $Width - 2
    $lines = New-Object System.Collections.Generic.List[string]
    $badge = $global:T.searchOf -f $Results.Count, $Total
    $vis = [int][Math]::Floor((($Height - 3) - 3) / 2)
    if ($Results.Count -gt $vis -and $vis -gt 0) {
        $last = [Math]::Min($Results.Count, $Scroll + $vis)
        $badge = "$($Scroll + 1)-$last $($global:G.Dot) $badge"
    }
    $lines.Add((New-ChTopBorder -Left $global:T.searchTitle -Right $badge -Width $Width))

    $caret = $global:C.Yellow + '_' + $global:C.Reset
    $lines.Add((New-ChRow -Content ('  ' + $global:C.Dim + $global:T.searchText + $global:C.White + $Query + $caret) -Width $Width))
    $lines.Add((New-ChRow -Content '' -Width $Width))

    # two rows per hit: the title, and under it where the hit came from
    $porItem = 2
    $listHeight = [int][Math]::Floor((($Height - 3) - 3) / $porItem)
    if ($listHeight -lt 1) { $listHeight = 1 }

    if ($Results.Count -eq 0) {
        $lines.Add((New-ChRow -Content ('  ' + $global:C.Dim + '  ' + $global:T.searchEmpty) -Width $Width))
    }

    for ($i = $Scroll; $i -lt [Math]::Min($Results.Count, $Scroll + $listHeight); $i++) {
        $r = $Results[$i]
        $marker = '   '
        if ($i -eq $Index) { $marker = ' ' + $global:G.Sel + ' ' }
        $title = Limit-ChText $r.Title ($inner - 4)
        if ($i -eq $Index) {
            $lines.Add((New-ChRow -Content ($marker + $title) -Width $Width -Selected))
        } else {
            $lines.Add((New-ChRow -Content ($marker + $global:C.White + $title) -Width $Width))
        }
        $when = ''
        if ($r.LastActivity) { $when = Format-ChRelativeDate $r.LastActivity }
        $context = $r.RepoName + '  ' + $global:G.Dot + '  ' + $when
        if ($r.Session.Branch) { $context += '  ' + $global:G.Dot + '  ' + $r.Session.Branch }
        $lines.Add((New-ChRow -Content ('     ' + (Get-ChDateColour $r.LastActivity) + (Limit-ChText $context ($inner - 6))) -Width $Width))
    }

    $keys = '  ' + $global:C.Dim + $global:T.searchType + '   ' +
            $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kResume + '   ' +
            $global:C.Cyan + [char]0x2191 + [char]0x2193 + $global:C.Dim + ' ' + $global:T.kNavigate + '   ' +
            $global:C.Cyan + 'Esc' + $global:C.Dim + ' ' + $global:T.kBack
    return Close-ChFrame -Body $lines -KeyLine (New-ChRow -Content $keys -Width $Width) -Width $Width -Height $Height
}

function Show-ChSessionSearch {
    param($Rows, [string]$QueryInicial = '')
    $catalog = @(Get-ChSessionCatalog -Rows $Rows)
    $query = $QueryInicial
    $index = 0
    $scroll = 0

    while ($true) {
        $sz = Get-ChConsoleSize
        $w = $sz.Width; $h = $sz.Height
        # @() is required: with a single hit PowerShell hands back the bare object
        # and $found.Count comes back empty instead of 1
        $found = @(Select-ChSessions -Catalog $catalog -Query $query)
        $listHeight = [int][Math]::Floor((($h - 3) - 3) / 2)
        if ($listHeight -lt 1) { $listHeight = 1 }
        if ($index -ge $found.Count) { $index = [Math]::Max(0, $found.Count - 1) }
        if ($index -lt $scroll) { $scroll = $index }
        if ($index -ge ($scroll + $listHeight)) { $scroll = $index - $listHeight + 1 }

        Write-ChFrame -Lines (Build-ChSearchLines -Results $found -Total $catalog.Count -Query $query `
            -Index $index -Scroll $scroll -Width ($w - 1) -Height $h)

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Escape'    { return }
            'UpArrow'   { if ($index -gt 0) { $index-- }; continue }
            'DownArrow' { if ($index -lt ($found.Count - 1)) { $index++ }; continue }
            'PageUp'    { $index = [Math]::Max(0, $index - $listHeight); continue }
            'PageDown'  { $index = [Math]::Min([Math]::Max(0, $found.Count - 1), $index + $listHeight); continue }
            'Backspace' {
                if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) }
                $index = 0; $scroll = 0
                continue
            }
            'Enter' {
                if ($found.Count -eq 0) { continue }
                $target = $found[$index]
                $dir = $target.Session.Cwd
                if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = $target.RepoPath }
                if ($dir -and (Test-Path -LiteralPath $dir)) {
                    Invoke-ChClaude -WorkDir $dir -Arguments @('-r', $target.Session.SessionId)
                    $global:ChSearchSignal = 'reload'
                    return
                }
                continue
            }
        }
        if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
            $query += $key.KeyChar
            $index = 0; $scroll = 0
        }
    }
}

# --- screen 3: memory ---------------------------------------------------------

function Build-ChMemoryLines {
    param($Row, $Memory, [int]$Index, [int]$Scroll, [int]$Width, [int]$Height)

    $inner = $Width - 2
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((New-ChTopBorder -Left ($global:T.memTitle + ' ' + [char]0x00B7 + ' ' + $Row.Name) -Right ($global:T.memEntries -f @($Memory).Count) -Width $Width))
    $lines.Add((New-ChRow -Content '' -Width $Width))

    $listHeight = $Height - 6
    if ($listHeight -lt 3) { $listHeight = 3 }

    $items = @($Memory)
    for ($i = $Scroll; $i -lt [Math]::Min($items.Count, $Scroll + $listHeight); $i++) {
        $m = $items[$i]
        $marker = '  '
        if ($i -eq $Index) { $marker = ' ' + $global:G.Sel }
        $title = Limit-ChText $m.Title ($inner - 4)
        if ($i -eq $Index) {
            $lines.Add((New-ChRow -Content ($marker + $title) -Width $Width -Selected))
            if ($m.Hook) {
                $lines.Add((New-ChRow -Content ('     ' + $global:C.Dim + (Limit-ChText $m.Hook ($inner - 6))) -Width $Width))
            }
        } else {
            $lines.Add((New-ChRow -Content ($marker + $global:C.White + $title) -Width $Width))
        }
    }

    $keys = '  ' + $global:C.Cyan + 'Enter' + $global:C.Dim + ' ' + $global:T.kRead + '   ' +
            $global:C.Cyan + [char]0x2191 + [char]0x2193 + $global:C.Dim + ' ' + $global:T.kNavigate + '   ' +
            $global:C.Cyan + 'Esc' + $global:C.Dim + ' ' + $global:T.kBack
    return Close-ChFrame -Body $lines -KeyLine (New-ChRow -Content $keys -Width $Width) -Width $Width -Height $Height
}

function Show-ChMemoryBody {
    param($Entry, [int]$Width, [int]$Height)
    $body = Get-ChMemoryBody -FullPath $Entry.FullPath
    $raw = @($body -split "`r?`n")
    $inner = $Width - 2
    $wrapped = New-Object System.Collections.Generic.List[string]
    foreach ($l in $raw) {
        if ($l.Length -le ($inner - 4)) { $wrapped.Add($l); continue }
        $rest = $l
        while ($rest.Length -gt ($inner - 4)) {
            $cut = $rest.LastIndexOf(' ', [Math]::Min($inner - 5, $rest.Length - 1))
            if ($cut -lt 20) { $cut = $inner - 5 }
            $wrapped.Add($rest.Substring(0, $cut))
            $rest = $rest.Substring($cut).TrimStart()
        }
        if ($rest) { $wrapped.Add($rest) }
    }

    $scroll = 0
    while ($true) {
        $sz = Get-ChConsoleSize; $w = $sz.Width; $h = $sz.Height
        $page = $h - 6
        if ($page -lt 3) { $page = 3 }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add((New-ChTopBorder -Left $Entry.File -Right '' -Width ($w - 1)))
        $lines.Add((New-ChRow -Content '' -Width ($w - 1)))
        for ($i = $scroll; $i -lt [Math]::Min($wrapped.Count, $scroll + $page); $i++) {
            $t = $wrapped[$i]
            $color = ''
            if ($t -match '^\s*#') { $color = $global:C.Bold + $global:C.Cyan }
            elseif ($t -match '^\s*[-*]\s') { $color = $global:C.White }
            elseif ($t -match '^(---|name:|description:|metadata:|\s+type:)') { $color = $global:C.Dim }
            $lines.Add((New-ChRow -Content ('  ' + $color + (Limit-ChText $t ($w - 5))) -Width ($w - 1)))
        }
        $more = ''
        if ($wrapped.Count -gt $page) { $more = $global:T.pagerLines -f ($scroll + 1), ([Math]::Min($wrapped.Count, $scroll + $page)), $wrapped.Count }
        $keyLine = New-ChRow -Content ('  ' + $global:C.Cyan + [char]0x2191 + [char]0x2193 + $global:C.Dim + ' ' + $global:T.kScroll + '   ' + $global:C.Cyan + 'Esc' + $global:C.Dim + ' ' + $global:T.kBack + $more) -Width ($w - 1)
        Write-ChFrame -Lines (Close-ChFrame -Body $lines -KeyLine $keyLine -Width ($w - 1) -Height $h)

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { if ($scroll -gt 0) { $scroll-- } }
            'DownArrow' { if ($scroll -lt ($wrapped.Count - $page)) { $scroll++ } }
            'PageUp'    { $scroll = [Math]::Max(0, $scroll - $page) }
            'PageDown'  { $scroll = [Math]::Min([Math]::Max(0, $wrapped.Count - $page), $scroll + $page) }
            'Home'      { $scroll = 0 }
            'End'       { $scroll = [Math]::Max(0, $wrapped.Count - $page) }
            'Escape'    { return }
            'Q'         { return }
        }
    }
}

# --- actions -------------------------------------------------------------------

function Invoke-ChClaude {
    param([string]$WorkDir, [string[]]$Arguments = @())
    if (-not (Test-Path -LiteralPath $WorkDir)) { return }
    Exit-ChScreen
    Push-Location -LiteralPath $WorkDir
    try {
        if ($Arguments.Count -gt 0) { & claude @Arguments } else { & claude }
    } catch {
        Write-Host ''
        Write-Host ($global:T.claudeFailed -f $_.Exception.Message) -ForegroundColor Red
        Write-Host $global:T.anyKeyBack -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    } finally {
        Pop-Location
        Enter-ChScreen
    }
}

function Invoke-ChClone {
    param($Row)
    $dest = Join-Path (Get-ChConfig).CloneRoot $Row.Name
    Exit-ChScreen
    Write-Host ''
    Write-Host ($global:T.cloneTitle -f $Row.FullName) -ForegroundColor Cyan
    Write-Host ($global:T.cloneInto -f $dest) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host $global:T.cloneConfirm -NoNewline -ForegroundColor Yellow
    $ans = [Console]::ReadKey($false)
    Write-Host ''
    if ([string]$ans.KeyChar -ne $global:T.cloneYes -and [string]$ans.KeyChar -ne $global:T.cloneYes.ToUpperInvariant()) {
        Enter-ChScreen
        return $false
    }
    # Out-Host: without it the gh output becomes the function's return value and
    # `if (Invoke-ChClone ...)` is true even when the clone failed.
    & gh repo clone $Row.FullName $dest | Out-Host
    $ok = ($LASTEXITCODE -eq 0)
    Write-Host ''
    if ($ok) { Write-Host $global:T.cloneDone -ForegroundColor Green } else { Write-Host $global:T.cloneFailed -ForegroundColor Red }
    Write-Host $global:T.anyKey -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
    Enter-ChScreen
    return $ok
}

# --- main loop -----------------------------------------------------------------

function Show-ChRepoDetail {
    # The result travels in $global:ChDetailSignal rather than a return value, on
    # purpose. If the caller wrote `$r = Show-ChRepoDetail ...`, PowerShell would
    # set up output capture for the whole call and redirect the stdout of the
    # `claude` running inside it - breaking its interface.
    param($Row)
    $global:ChDetailSignal = ''
    $index = 0
    $scroll = 0
    $status = ''
    $memory = @()
    if ($Row.Path) { $memory = @(Get-ChMemoryEntries -Path $Row.Path) }

    while ($true) {
        $sz = Get-ChConsoleSize; $w = $sz.Width; $h = $sz.Height
        $sessions = @($Row.Sessions)
        $memShown = 0
        if ($memory.Count -gt 0) { $memShown = [int](Get-ChConfig).MemoryPreviewLines }
        if ($memShown -gt $memory.Count) { $memShown = $memory.Count }
        $listHeight = Get-ChDetailListHeight -Height $h -MemShow $memShown -HasDescription ([bool]$Row.Description)
        if ($index -ge $sessions.Count) { $index = [Math]::Max(0, $sessions.Count - 1) }
        if ($index -lt $scroll) { $scroll = $index }
        if ($index -ge ($scroll + $listHeight)) { $scroll = $index - $listHeight + 1 }

        Write-ChFrame -Lines (Build-ChDetailLines -Row $Row -Index $index -Scroll $scroll -Width ($w - 1) -Height $h -Memory $memory -Status $status)
        $status = ''

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { if ($index -gt 0) { $index-- } }
            'DownArrow' { if ($index -lt ($sessions.Count - 1)) { $index++ } }
            'PageUp'    { $index = [Math]::Max(0, $index - $listHeight) }
            'PageDown'  { $index = [Math]::Min([Math]::Max(0, $sessions.Count - 1), $index + $listHeight) }
            'Home'      { $index = 0 }
            'End'       { $index = [Math]::Max(0, $sessions.Count - 1) }
            'Escape'    { return }
            'Enter' {
                if ($sessions.Count -eq 0) { $status = $global:T.stNoSession; break }
                $s = $sessions[$index]
                $dir = $s.Cwd
                if (-not (Test-Path -LiteralPath $dir)) { $dir = $Row.Path }
                if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $status = $global:T.stGoneDir; break }
                Invoke-ChClaude -WorkDir $dir -Arguments @('-r', $s.SessionId)
                $global:ChDetailSignal = 'reload'
                return
            }
            default {
                $ch = [string]$key.KeyChar
                if ($ch -eq 'n' -or $ch -eq 'N') {
                    if (-not $Row.Path) { $status = $global:T.stNoCloneClone; break }
                    Invoke-ChClaude -WorkDir $Row.Path
                    $global:ChDetailSignal = 'reload'
                    return
                }
                if ($ch -eq 'c' -or $ch -eq 'C') {
                    if (-not $Row.Path) { $status = $global:T.stNoClone; break }
                    Invoke-ChClaude -WorkDir $Row.Path -Arguments @('-c')
                    $global:ChDetailSignal = 'reload'
                    return
                }
                if ($ch -eq 'm' -or $ch -eq 'M') {
                    if ($memory.Count -eq 0) { $status = $global:T.stNoMemory; break }
                    Show-ChMemoryList -Row $Row -Memory $memory
                }
                if ($ch -eq 'g' -or $ch -eq 'G') {
                    if ($Row.Url) { Start-Process $Row.Url; $status = $global:T.stOpenedBrowser }
                    else { $status = $global:T.stNoGitHub }
                }
                if ($ch -eq 'e' -or $ch -eq 'E') {
                    if ($Row.Path -and (Test-Path -LiteralPath $Row.Path)) {
                        Start-Process explorer.exe -ArgumentList $Row.Path
                        $status = $global:T.stOpenedFolder
                    } else { $status = $global:T.stNoFolder }
                }
                if ($ch -eq 'v' -or $ch -eq 'V') {
                    if (-not $Row.Path -or -not (Test-Path -LiteralPath $Row.Path)) {
                        $status = 'sem pasta local para abrir'
                    } elseif (-not (Get-Command code -ErrorAction SilentlyContinue)) {
                        $status = $global:T.stNoCode
                    } else {
                        Start-Process -FilePath 'code' -ArgumentList @($Row.Path) -WindowStyle Hidden
                        $status = $global:T.stOpenedCode
                    }
                }
                if ($ch -eq 'q' -or $ch -eq 'Q') { $global:ChDetailSignal = 'quit'; return }
            }
        }
    }
}

function Show-ChMemoryList {
    param($Row, $Memory)
    $index = 0
    $scroll = 0
    while ($true) {
        $sz = Get-ChConsoleSize; $w = $sz.Width; $h = $sz.Height
        $listHeight = $h - 6
        if ($listHeight -lt 3) { $listHeight = 3 }
        $items = @($Memory)
        if ($index -lt $scroll) { $scroll = $index }
        if ($index -ge ($scroll + $listHeight)) { $scroll = $index - $listHeight + 1 }

        Write-ChFrame -Lines (Build-ChMemoryLines -Row $Row -Memory $items -Index $index -Scroll $scroll -Width ($w - 1) -Height $h)

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { if ($index -gt 0) { $index-- } }
            'DownArrow' { if ($index -lt ($items.Count - 1)) { $index++ } }
            'PageUp'    { $index = [Math]::Max(0, $index - $listHeight) }
            'PageDown'  { $index = [Math]::Min($items.Count - 1, $index + $listHeight) }
            'Home'      { $index = 0 }
            'End'       { $index = $items.Count - 1 }
            'Escape'    { return }
            'Enter'     { Show-ChMemoryBody -Entry $items[$index] -Width $w -Height $h }
            default     { if ($key.KeyChar -eq 'q') { return } }
        }
    }
}

function Find-ChRowForPath {
    # Which panel row corresponds to a path on disk. Same longest-prefix rule used
    # to match sessions, so `ch` run inside a subfolder opens the repository that
    # contains it, instead of the full list.
    param($Rows, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $target = $Path.TrimEnd('\')
    $best = $null
    $bestLen = -1
    foreach ($r in $Rows) {
        if (-not $r.Path) { continue }
        $root = ([string]$r.Path).TrimEnd('\')
        if ($target.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            if ($root.Length -gt $bestLen) { $best = $r; $bestLen = $root.Length }
        }
    }
    return $best
}

function Show-ChPanel {
    param(
        [string]$InitialFilter = '',
        [string]$InitialRepoPath = '',
        [string]$BuscarSessao = $null
    )

    if ([Console]::IsInputRedirected) {
        Write-Host $global:T.needTty -ForegroundColor Red
        return
    }

    $global:ChAltScreen = $Host.UI.SupportsVirtualTerminal

    $sessions = Get-ChSessionIndex
    $repos = Get-ChRepoInventory
    $all = Join-ChSessionsToRepos -Sessions $sessions -Repos $repos
    $owner = ''
    $ghUser = $repos | Where-Object { $_.Owner } | Group-Object Owner | Sort-Object Count -Descending | Select-Object -First 1
    if ($ghUser) { $owner = $ghUser.Name }

    $filter = $InitialFilter
    $index = 0
    $scroll = 0
    $status = ''
    $filterMode = $false

    Enter-ChScreen
    try {
        # entry shortcuts: land straight in the search, or straight in the repository
        # the command was called from
        if ($null -ne $BuscarSessao) {
            $global:ChSearchSignal = ''
            Show-ChSessionSearch -Rows $all -QueryInicial $BuscarSessao
            if ($global:ChSearchSignal -eq 'reload') {
                $all = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos $repos
            }
        } elseif ($InitialRepoPath) {
            $linha = Find-ChRowForPath -Rows $all -Path $InitialRepoPath
            if ($linha) {
                $achou = [Array]::IndexOf($all, $linha)
                if ($achou -ge 0) { $index = $achou }
                Show-ChRepoDetail -Row $linha
                if ($global:ChDetailSignal -eq 'quit') { return }
                if ($global:ChDetailSignal -eq 'reload') {
                    $all = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos $repos
                }
            }
        }

        while ($true) {
            $w = (Get-ChConsoleSize).Width
            $h = (Get-ChConsoleSize).Height
            if ($w -lt 54 -or $h -lt 14) {
                Write-ChFrame -Lines @('', $global:T.tooSmall, $global:T.tooSmallHint)
                $k = [Console]::ReadKey($true)
                if ($k.KeyChar -eq 'q') { return }
                continue
            }

            $rows = $all
            if ($filter) {
                $f = $filter
                $rows = @($all | Where-Object {
                    $_.Name -like "*$f*" -or $_.FullName -like "*$f*" -or ($_.Description -and $_.Description -like "*$f*")
                })
            }
            if ($index -ge $rows.Count) { $index = [Math]::Max(0, $rows.Count - 1) }
            $listHeight = $h - 8
            if ($listHeight -lt 3) { $listHeight = 3 }
            if ($index -lt $scroll) { $scroll = $index }
            if ($index -ge ($scroll + $listHeight)) { $scroll = $index - $listHeight + 1 }
            if ($scroll -gt [Math]::Max(0, $rows.Count - $listHeight)) { $scroll = [Math]::Max(0, $rows.Count - $listHeight) }

            $shownFilter = ''
            if ($filterMode -or $filter) { $shownFilter = $filter }
            Write-ChFrame -Lines (Build-ChListLines -Rows $rows -Index $index -Scroll $scroll -Filter $shownFilter -Width ($w - 1) -Height $h -Owner $owner -Status $status)
            $status = ''

            $key = [Console]::ReadKey($true)

            if ($filterMode) {
                if ($key.Key -eq 'Enter') { $filterMode = $false; continue }
                if ($key.Key -eq 'Escape') { $filterMode = $false; $filter = ''; $index = 0; continue }
                if ($key.Key -eq 'Backspace') {
                    if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1) }
                    $index = 0
                    continue
                }
                if ($key.KeyChar -and [char]::IsLetterOrDigit($key.KeyChar) -or $key.KeyChar -eq '-' -or $key.KeyChar -eq '_' -or $key.KeyChar -eq ' ') {
                    $filter += $key.KeyChar
                    $index = 0
                }
                continue
            }

            switch ($key.Key) {
                'UpArrow'   { if ($index -gt 0) { $index-- } }
                'DownArrow' { if ($index -lt ($rows.Count - 1)) { $index++ } }
                'PageUp'    { $index = [Math]::Max(0, $index - $listHeight) }
                'PageDown'  { $index = [Math]::Min([Math]::Max(0, $rows.Count - 1), $index + $listHeight) }
                'Home'      { $index = 0 }
                'End'       { $index = [Math]::Max(0, $rows.Count - 1) }
                'Escape'    { if ($filter) { $filter = ''; $index = 0 } else { return } }
                'Enter' {
                    if ($rows.Count -eq 0) { break }
                    $row = $rows[$index]
                    if ($row.Kind -eq 'repo' -and -not $row.HasClone) {
                        if (Invoke-ChClone -Row $row) {
                            $repos = Get-ChRepoInventory -Force
                            $all = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos $repos
                            $status = $global:T.stCloned
                        }
                        break
                    }
                    Show-ChRepoDetail -Row $row
                    if ($global:ChDetailSignal -eq 'quit') { return }
                    if ($global:ChDetailSignal -eq 'reload') {
                        $all = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos $repos
                        $sel = $all | Where-Object { $_.FullName -eq $row.FullName } | Select-Object -First 1
                        if ($sel) { $index = [Array]::IndexOf($all, $sel) }
                    }
                }
                default {
                    $ch = [string]$key.KeyChar
                    if ($ch -eq '/') { $filterMode = $true; $filter = '' }
                    elseif ($ch -eq 's' -or $ch -eq 'S') {
                        $global:ChSearchSignal = ''
                        Show-ChSessionSearch -Rows $all
                        if ($global:ChSearchSignal -eq 'reload') {
                            $all = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos $repos
                        }
                    }
                    elseif ($ch -eq 'q' -or $ch -eq 'Q') { return }
                    elseif ($ch -eq 'r' -or $ch -eq 'R') {
                        $status = $global:T.stReloading
                        Write-ChFrame -Lines (Build-ChListLines -Rows $rows -Index $index -Scroll $scroll -Filter $filter -Width ($w - 1) -Height $h -Owner $owner -Status $status)
                        $repos = Get-ChRepoInventory -Force
                        $all = Join-ChSessionsToRepos -Sessions (Get-ChSessionIndex) -Repos $repos
                        $status = $global:T.stUpdated
                    }
                }
            }
        }
    } finally {
        Exit-ChScreen
    }
}
