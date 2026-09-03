# ChIndex.ps1 - index of Claude Code sessions.
#
# Reads only the direct children of ~/.claude/projects/<slug>/, because
# <session>/subagents/ holds agent transcripts, which are not your conversations.
#
# Each file is read in slices: the last 256 KB (where the title, the last
# timestamp, the branch and the cwd live) and the first 64 KB (start and first
# prompt). Never the whole file - the largest one measured here was 31 MB.

if (-not (Test-Path Function:\Get-ChText)) { . (Join-Path $PSScriptRoot 'ChText.ps1') }

$global:ChProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$global:ChIndexCacheDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'cache'
$global:ChTailBytes = 262144
$global:ChHeadBytes = 65536

function Get-ChTailText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Bytes = 0
    )
    if ($Bytes -le 0) { $Bytes = $global:ChTailBytes }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -eq 0) { return '' }
        $start = 0
        if ($len -gt $Bytes) { $start = $len - $Bytes }
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $count = [int]($len - $start)
        $buf = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $fs.Read($buf, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        if ($start -gt 0) {
            # drop the first line: it starts mid-record and may have cut a
            # UTF-8 character in half
            $nl = $text.IndexOf("`n")
            if ($nl -ge 0) { $text = $text.Substring($nl + 1) }
        }
        return $text
    } catch {
        return ''
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-ChHeadText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Bytes = 0
    )
    if ($Bytes -le 0) { $Bytes = $global:ChHeadBytes }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -eq 0) { return '' }
        $count = [int][Math]::Min($len, $Bytes)
        $buf = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $fs.Read($buf, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        if ($len -gt $count) {
            # cut at the last complete line ending
            $nl = $text.LastIndexOf("`n")
            if ($nl -ge 0) { $text = $text.Substring(0, $nl) }
        }
        return $text
    } catch {
        return ''
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function ConvertFrom-ChJsonString {
    # Unescapes a JSON string value that already lost its outer quotes.
    # Delegates to the parser itself, which handles \\ \" \n and \uXXXX.
    param([string]$Raw)
    if ($null -eq $Raw) { return $null }
    if ($Raw.Length -eq 0) { return '' }
    try {
        return (ConvertFrom-Json ('{"v":"' + $Raw + '"}')).v
    } catch {
        return $Raw
    }
}

function Get-ChJsonValueRegex {
    param([string]$Key, [switch]$RightToLeft)
    if (-not $global:ChRegexCache) { $global:ChRegexCache = @{} }
    $cacheKey = $Key
    $opts = [System.Text.RegularExpressions.RegexOptions]::None
    if ($RightToLeft) {
        $cacheKey = $Key + '|rtl'
        $opts = [System.Text.RegularExpressions.RegexOptions]::RightToLeft
    }
    if (-not $global:ChRegexCache.ContainsKey($cacheKey)) {
        $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"((?:[^"\\]|\\.)*)"'
        $global:ChRegexCache[$cacheKey] = New-Object System.Text.RegularExpressions.Regex(
            $pattern, $opts, [TimeSpan]::FromSeconds(5))
    }
    return $global:ChRegexCache[$cacheKey]
}

function Get-ChLastJsonValue {
    # RightToLeft finds the last match and stops there, instead of collecting
    # every match in a 256 KB slice only to throw the rest away.
    param([string]$Text, [string]$Key)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try {
        $m = (Get-ChJsonValueRegex -Key $Key -RightToLeft).Match($Text)
    } catch {
        return $null
    }
    if (-not $m.Success) { return $null }
    return ConvertFrom-ChJsonString $m.Groups[1].Value
}

function Get-ChFirstJsonValue {
    param([string]$Text, [string]$Key)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try {
        $m = (Get-ChJsonValueRegex -Key $Key).Match($Text)
    } catch {
        return $null
    }
    if (-not $m.Success) { return $null }
    return ConvertFrom-ChJsonString $m.Groups[1].Value
}

function Test-ChPromptSubstantivo {
    # A "good morning, Claude" is a real message, but it says nothing about
    # what the conversation was. Fine as a caption; useless as a title.
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $false }
    if ($Texto.Length -lt 25) { return $false }
    if ($Texto -match '^\s*(ol[aáà]|oi|e a[ií]|bom dia|boa tarde|boa noite|hey|hi|hello|yo)\b[\s,.!?]*(claude)?[\s,.!?]*$') { return $false }
    return $true
}

function Test-ChTituloGenerico {
    # Titles Claude produces when the conversation opened with a greeting and it
    # never renamed the session afterwards.
    param([string]$Titulo)
    if ([string]::IsNullOrWhiteSpace($Titulo)) { return $true }
    return ($Titulo -match '^\s*(greeting|initial greeting|untitled|new conversation|conversation|sauda[cç][aã]o)\b')
}

function Get-ChFirstUserPrompt {
    # The first real user message, skipping harness noise.
    # Prefers the first SUBSTANTIVE message; if there is only a greeting, returns
    # the greeting. Measured: the substantive message shows up within the first
    # 64 KB even in a 31 MB file, so there is no need to read further.
    param([string]$HeadText)
    if ([string]::IsNullOrEmpty($HeadText)) { return $null }
    $firstReal = $null
    foreach ($line in ($HeadText -split "`n")) {
        if ($line.Length -lt 20) { continue }
        if ($line -notmatch '"type"\s*:\s*"user"') { continue }
        $obj = $null
        try { $obj = ConvertFrom-Json $line } catch { continue }
        if (-not $obj) { continue }
        if (-not $obj.PSObject.Properties.Match('message').Count) { continue }
        if (-not $obj.message) { continue }
        $content = $obj.message.content
        $text = ''
        if ($content -is [string]) {
            $text = $content
        } elseif ($content) {
            foreach ($part in @($content)) {
                if ($part -is [string]) { $text += $part + ' '; continue }
                if ($part.type -eq 'text' -and $part.text) { $text += [string]$part.text + ' ' }
            }
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        # Strip what the harness injects and the person never typed: system
        # reminders, the editor's open-file notice (<ide_opened_file>), local
        # command output. Applies to any <tag>...</tag> pair.
        $text = [regex]::Replace($text, '(?is)<([a-z0-9_-]+)>.*?</\1>', ' ')
        $text = [regex]::Replace($text, '(?s)<[^>]{1,40}>', ' ')
        $text = ($text -replace '\s+', ' ').Trim()
        # an absolute path pasted at the start of a message adds nothing to a
        # title - the repository is already in the column next to it
        $text = [regex]::Replace($text, '^[A-Za-z]:\\[^\s]+\s+(?=\S)', '')

        if ($text.Length -lt 3) { continue }
        if ($text.StartsWith('[Request interrupted')) { continue }
        if ($text.StartsWith('Caveat:')) { continue }
        if ($text.StartsWith('[')) { continue }
        # skill payload injected as if it were a user message
        if ($text.StartsWith('Base directory for this skill:')) { continue }

        if (Test-ChPromptSubstantivo $text) { return $text }
        if (-not $firstReal) { $firstReal = $text }
    }
    return $firstReal
}

function ConvertTo-ChDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { return $parsed.ToLocalTime() }
        return $parsed
    }
    return $null
}

function Read-ChSessionFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $tail = Get-ChTailText -Path $File.FullName
    $head = Get-ChHeadText -Path $File.FullName

    $started = ConvertTo-ChDate (Get-ChFirstJsonValue -Text $head -Key 'timestamp')
    $last = ConvertTo-ChDate (Get-ChLastJsonValue -Text $tail -Key 'timestamp')
    if (-not $last) { $last = $File.LastWriteTime }
    if (-not $started) { $started = $last }

    $title = Get-ChLastJsonValue -Text $tail -Key 'aiTitle'
    $prompt = Get-ChFirstUserPrompt -HeadText $head

    # A session with no assistant turn is not a conversation: these are the ones
    # you opened, ran a /model in, and closed. Calling it "(untitled)" suggests
    # a defect; the honest thing is to say what it is.
    $hasReply = ($tail -match '"type"\s*:\s*"assistant"') -or ($head -match '"type"\s*:\s*"assistant"')

    if (-not $hasReply) {
        $title = (Get-ChText 'noConversation')
    } elseif (Test-ChTituloGenerico $title) {
        # Claude's title got stuck on the opening greeting. The first real
        # request describes the session better.
        if (-not (Test-ChPromptSubstantivo $prompt) -and $File.Length -gt $global:ChHeadBytes) {
            # Second pass, only in the few cases where the opening is nothing but a
            # greeting: reads 1 MB looking for the first real request. Costs about
            # 60ms and never touches sessions that already have a good title.
            $deeper = Get-ChFirstUserPrompt -HeadText (Get-ChHeadText -Path $File.FullName -Bytes 1048576)
            if (Test-ChPromptSubstantivo $deeper) { $prompt = $deeper }
        }
        if (Test-ChPromptSubstantivo $prompt) { $title = $prompt }
        elseif ([string]::IsNullOrWhiteSpace($title)) { $title = $prompt }
    }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = (Get-ChText 'noTitle') }

    $cwd = Get-ChLastJsonValue -Text $tail -Key 'cwd'
    if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = Get-ChFirstJsonValue -Text $head -Key 'cwd' }

    [pscustomobject]@{
        SessionId    = $File.BaseName
        Path         = $File.FullName
        ProjectDir   = $File.Directory.Name
        Cwd          = $cwd
        Title        = $title
        FirstPrompt  = $prompt
        Started      = $started
        LastActivity = $last
        Branch       = Get-ChLastJsonValue -Text $tail -Key 'gitBranch'
        Version      = Get-ChLastJsonValue -Text $tail -Key 'version'
        SizeBytes    = $File.Length
        # Ticks rather than an ISO string, deliberately: ConvertFrom-Json in PS 5.1
        # turns anything that looks like a date into a DateTime, which would make
        # the cache comparison fail every time and reparse everything on every open.
        MtimeTicks   = $File.LastWriteTimeUtc.Ticks
    }
}

function Get-ChSessionFiles {
    # Directory.GetFiles instead of Get-ChildItem: the cmdlet wraps every file in
    # a PowerShell-adapted object and costs 7x more (186ms against 27ms here).
    if (-not [System.IO.Directory]::Exists($global:ChProjectsRoot)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in [System.IO.Directory]::GetDirectories($global:ChProjectsRoot)) {
        # no recursion on purpose: <session>\subagents\ stays out
        try { $files = [System.IO.Directory]::GetFiles($d, '*.jsonl') } catch { continue }
        foreach ($p in $files) { $out.Add((New-Object System.IO.FileInfo $p)) }
    }
    return $out.ToArray()
}

# --- cache -------------------------------------------------------------------
#
# A line format of our own instead of JSON. ConvertFrom-Json in PS 5.1 spends
# 1.36s rebuilding 47 records; the same data as TAB-separated lines comes back
# in milliseconds. The text fields are for display, so replacing TAB and line
# breaks with a space loses nothing that reaches the screen.

# v2: the title rule changed (generic greeting, session with no reply), so a
# cache written by v1 holds stale titles and has to be rebuilt.
$global:ChCacheHeader = '#claude-hub-sessions-v2'
$global:ChCacheFields = @('SessionId', 'Path', 'ProjectDir', 'Cwd', 'Title', 'FirstPrompt',
                          'StartedTicks', 'LastActivityTicks', 'Branch', 'Version',
                          'SizeBytes', 'MtimeTicks')

function ConvertTo-ChCacheField {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value -replace '[\t\r\n]', ' ')
}

function ConvertTo-ChCacheLine {
    param($Session)
    $started = 0
    if ($Session.Started) { $started = ([datetime]$Session.Started).Ticks }
    $last = 0
    if ($Session.LastActivity) { $last = ([datetime]$Session.LastActivity).Ticks }
    $parts = @(
        (ConvertTo-ChCacheField $Session.SessionId)
        (ConvertTo-ChCacheField $Session.Path)
        (ConvertTo-ChCacheField $Session.ProjectDir)
        (ConvertTo-ChCacheField $Session.Cwd)
        (ConvertTo-ChCacheField $Session.Title)
        (ConvertTo-ChCacheField $Session.FirstPrompt)
        [string]$started
        [string]$last
        (ConvertTo-ChCacheField $Session.Branch)
        (ConvertTo-ChCacheField $Session.Version)
        [string]$Session.SizeBytes
        [string]$Session.MtimeTicks
    )
    return ($parts -join "`t")
}

function ConvertFrom-ChCacheLine {
    param([string]$Line)
    $p = $Line -split "`t"
    if ($p.Count -ne $global:ChCacheFields.Count) { return $null }
    $started = $null
    if ($p[6] -ne '0') { $started = New-Object System.DateTime ([long]$p[6]) }
    $last = $null
    if ($p[7] -ne '0') { $last = New-Object System.DateTime ([long]$p[7]) }
    return [pscustomobject]@{
        SessionId    = $p[0]
        Path         = $p[1]
        ProjectDir   = $p[2]
        Cwd          = $p[3]
        Title        = $p[4]
        FirstPrompt  = $p[5]
        Started      = $started
        LastActivity = $last
        Branch       = $p[8]
        Version      = $p[9]
        SizeBytes    = [long]$p[10]
        MtimeTicks   = [long]$p[11]
    }
}

function Get-ChSessionIndex {
    param([switch]$Force)

    $cachePath = Join-Path $global:ChIndexCacheDir 'sessions.tsv'
    $cache = @{}
    if (-not $Force -and [System.IO.File]::Exists($cachePath)) {
        try {
            $lines = [System.IO.File]::ReadAllLines($cachePath, [System.Text.Encoding]::UTF8)
            if ($lines.Count -gt 0 -and $lines[0] -eq $global:ChCacheHeader) {
                for ($i = 1; $i -lt $lines.Count; $i++) {
                    if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
                    $e = ConvertFrom-ChCacheLine $lines[$i]
                    if ($e -and $e.Path) { $cache[$e.Path] = $e }
                }
            }
        } catch {
            $cache = @{}
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    $dirty = $false
    # how many files had to be reparsed in this call; 0 means the cache was
    # fully reused. The self-test asserts on this.
    $global:ChIndexParsedCount = 0
    $files = Get-ChSessionFiles
    foreach ($f in $files) {
        $hit = $null
        if ($cache.ContainsKey($f.FullName)) { $hit = $cache[$f.FullName] }
        if ($hit -and ($hit.MtimeTicks -eq $f.LastWriteTimeUtc.Ticks) -and ($hit.SizeBytes -eq $f.Length)) {
            $result.Add($hit)
        } else {
            $result.Add((Read-ChSessionFile -File $f))
            $global:ChIndexParsedCount++
            $dirty = $true
        }
    }
    # a file that vanished from disk also invalidates the stored cache
    if ($cache.Count -ne $files.Count) { $dirty = $true }

    if ($dirty) {
        try {
            if (-not [System.IO.Directory]::Exists($global:ChIndexCacheDir)) {
                [void][System.IO.Directory]::CreateDirectory($global:ChIndexCacheDir)
            }
            $out = New-Object System.Collections.Generic.List[string]
            $out.Add($global:ChCacheHeader)
            foreach ($s in $result) { $out.Add((ConvertTo-ChCacheLine $s)) }
            [System.IO.File]::WriteAllLines($cachePath, $out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            # the cache is an optimisation, not a requirement: carry on without it
        }
    }

    return $result.ToArray()
}

function Clear-ChSessionCache {
    foreach ($n in @('sessions.tsv', 'sessions.json')) {
        $p = Join-Path $global:ChIndexCacheDir $n
        if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) }
    }
}
