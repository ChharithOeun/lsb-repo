# chharbot.ps1 - convenience wrapper for the live Windows box.
#
# Finds a sensible Python interpreter, sets sidecar/admin URLs to the
# defaults baked into the live deploy, and forwards every argument to
# `python -m chharbot`.
#
# Examples:
#   .\chharbot.ps1 "how many chars in the DB?"
#   .\chharbot.ps1 --allow-writes "announce 'be right back'"
#   .\chharbot.ps1 --repl --trace
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

function Find-Python {
    foreach ($candidate in @('python', 'python3', 'py')) {
        $p = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
    }
    throw 'No Python interpreter found on PATH.'
}

$py = Find-Python

# Install the package in editable mode if the module isn't importable.
& $py -c "import chharbot" 2>$null
if ($LASTEXITCODE -ne 0) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $pkgRoot  = Join-Path $repoRoot 'chharbot'
    Write-Host "chharbot not installed; running: pip install -e '$pkgRoot'"
    & $py -m pip install -e $pkgRoot
}

& $py -m chharbot @Args
exit $LASTEXITCODE
