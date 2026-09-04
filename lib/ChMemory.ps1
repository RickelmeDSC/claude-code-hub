# ChMemory.ps1 - per-project memory reader. Read only.
#
# Memory lives in ~/.claude/projects/<slug>/memory/, with a MEMORY.md that
# indexes the individual files in this format:
#     - [Title](file.md) - one-line hook

$global:ChMemProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'

function ConvertTo-ChProjectSlug {
    # Reproduz a regra do Claude Code: ':', '\', '/', '_' e '.' viram '-'.
    # Confirmado contra as pastas existentes, inclusive C--Users-administrador--local-bin,
    # que vem de C:\Users\administrador\.local\bin.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.TrimEnd('\', '/')
    return ($p -replace '[:\\/_.]', '-')
}

function Get-ChProjectDir {
    # The drive letter shows up in both cases across existing folders, so the
    # lookup ignores case.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $slug = ConvertTo-ChProjectSlug $Path
    if (-not [System.IO.Directory]::Exists($global:ChMemProjectsRoot)) { return $null }
    if (-not $global:ChProjectDirIndex) {
        $global:ChProjectDirIndex = @{}
        foreach ($d in [System.IO.Directory]::GetDirectories($global:ChMemProjectsRoot)) {
            $global:ChProjectDirIndex[[System.IO.Path]::GetFileName($d)] = $d
        }
    }
    if ($global:ChProjectDirIndex.ContainsKey($slug)) { return $global:ChProjectDirIndex[$slug] }
    return $null
}

function Get-ChMemoryDir {
    param([string]$Path)
    $proj = Get-ChProjectDir -Path $Path
    if (-not $proj) { return $null }
    $mem = Join-Path $proj 'memory'
    if (Test-Path -LiteralPath $mem) { return $mem }
    return $null
}

function Get-ChMemoryEntries {
    param([string]$Path)
    $out = New-Object System.Collections.Generic.List[object]
    $memDir = Get-ChMemoryDir -Path $Path
    if (-not $memDir) { return $out.ToArray() }

    $index = Join-Path $memDir 'MEMORY.md'
    if (Test-Path -LiteralPath $index) {
        $lines = @()
        try { $lines = Get-Content -LiteralPath $index -Encoding UTF8 -ErrorAction Stop } catch { }
        foreach ($line in $lines) {
            $m = [regex]::Match($line, '^\s*[-*+]\s*\[(?<t>[^\]]+)\]\((?<f>[^)]+)\)\s*(?:[-\u2014\u2013:]\s*)?(?<h>.*)$')
            if (-not $m.Success) { continue }
            $file = $m.Groups['f'].Value.Trim()
            $full = Join-Path $memDir $file
            $out.Add([pscustomobject]@{
                Title    = $m.Groups['t'].Value.Trim()
                File     = $file
                Hook     = $m.Groups['h'].Value.Trim()
                FullPath = $full
                Exists   = (Test-Path -LiteralPath $full)
            })
        }
    }

    if ($out.Count -eq 0) {
        # no MEMORY.md (or a different format): list the loose files instead
        $files = Get-ChildItem -LiteralPath $memDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'MEMORY.md' } | Sort-Object Name
        foreach ($f in $files) {
            $out.Add([pscustomobject]@{
                Title    = $f.BaseName
                File     = $f.Name
                Hook     = ''
                FullPath = $f.FullName
                Exists   = $true
            })
        }
    }

    return $out.ToArray()
}

function Get-ChMemoryBody {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
    if (-not (Test-Path -LiteralPath $FullPath)) { return '' }
    try {
        return (Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 -ErrorAction Stop)
    } catch {
        return ''
    }
}

function Get-ChMemoryCount {
    param([string]$Path)
    return @(Get-ChMemoryEntries -Path $Path).Count
}
