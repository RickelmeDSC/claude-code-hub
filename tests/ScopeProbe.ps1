# ScopeProbe.ps1 - scope probe.
#
# Deliberately loads nothing. It expects the caller to have loaded the modules
# already, and then calls their functions from inside a DIFFERENT script.
#
# That is the real production arrangement: the `ch` function in $PROFILE loads
# the modules in one scope and ch.ps1 calls them from another. A module variable
# declared with $script: disappears across that jump, because $script: resolves
# against the script that is executing at call time, not against the file that
# defined the function. That is how `ch` broke with "parameter 'Path' is null".

$result = New-Object System.Collections.Generic.List[string]

foreach ($name in @('Get-ChConfig', 'Get-ChSessionIndex', 'Get-ChRepoInventory', 'Get-ChLocalClones')) {
    if (-not (Test-Path "Function:\$name")) {
        $result.Add("$name=MISSING")
        continue
    }
    try {
        $r = & $name
        $result.Add("$name=OK:$(@($r).Count)")
    } catch {
        $result.Add("$name=FAILED:$($_.Exception.Message)")
    }
}

# the module paths also have to stay readable from here
foreach ($v in @('ChRoot', 'ChProjectsRoot', 'ChIndexCacheDir', 'ChReposCacheDir', 'ChMemProjectsRoot')) {
    $val = Get-Variable -Name $v -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($val)) { $result.Add("$v=EMPTY") } else { $result.Add("$v=OK") }
}

return $result.ToArray()
