# find-retail-pol.ps1
# Hunt for retail FFXI pol.exe across Steam install directories and Windower
# profiles, then print every candidate with size/version so you can pick the
# right one. Read-only: does NOT patch anything.
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\find-retail-pol.ps1

$ErrorActionPreference = 'Continue'
$XiLoader = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$LogPath  = 'F:\ffxi\deploy\find-retail-pol.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Note($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

$hits = New-Object System.Collections.Generic.List[object]

function AddHit([string]$path, [string]$source) {
    if (-not $path) { return }
    if (-not (Test-Path -LiteralPath $path)) { return }
    if ($path -ieq $XiLoader) { return }  # skip the LSB xiloader at its deploy path
    $fi = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $fi) { return }
    $ver = try { (Get-Command $path -ErrorAction SilentlyContinue).FileVersionInfo.FileVersion } catch { $null }
    $hits.Add([pscustomobject]@{
        path       = $fi.FullName
        size       = $fi.Length
        modified   = $fi.LastWriteTime
        version    = $ver
        source     = $source
    }) | Out-Null
}

# 1. Candidate list.
$candidates = @(
    'C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY XI\pol.exe',
    'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe',
    'C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY XI\SquareEnix\PlayOnlineViewer\pol.exe',
    'C:\Program Files (x86)\PlayOnline\SquareEnix\PlayOnlineViewer\pol.exe',
    'F:\Steam\steamapps\common\FINAL FANTASY XI\pol.exe'
)
foreach ($c in $candidates) { AddHit $c 'candidate' }

# 2. Steam "common" scan.
$steamRoots = @(
    'C:\Program Files (x86)\Steam\steamapps\common',
    'F:\Steam\steamapps\common',
    'D:\Steam\steamapps\common',
    'E:\Steam\steamapps\common'
) | Where-Object { Test-Path $_ }
foreach ($root in $steamRoots) {
    Note "scanning $root" 'DarkCyan'
    $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'FINAL FANTASY|FFXI|PlayOnline' }
    foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d.FullName -Filter 'pol.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            ForEach-Object { AddHit $_.FullName ("steam:{0}" -f $d.Name) }
    }
}

# 3. Windower settings.xml parse.
$windowerRoots = @(
    'C:\Program Files (x86)\Windower',
    'C:\Program Files\Windower',
    'C:\Windower',
    'C:\Windower4',
    'F:\Windower',
    'F:\Windower4',
    'D:\Windower',
    'D:\Windower4'
) | Where-Object { Test-Path $_ }
foreach ($wr in $windowerRoots) {
    Note "scanning windower $wr" 'DarkCyan'
    Get-ChildItem -LiteralPath $wr -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'settings|profile|launcher' } |
        ForEach-Object {
            try {
                $txt = Get-Content -LiteralPath $_.FullName -Raw
                $m = [regex]::Matches($txt, '([A-Za-z]:\\[^<>"\r\n]*?pol\.exe)', 'IgnoreCase')
                foreach ($x in $m) { AddHit $x.Value ("windower:{0}" -f $_.Name) }
            } catch {}
        }
}

# 4. where.exe /R recursive fallback.
foreach ($root in $steamRoots) {
    try {
        $lines = & where.exe /R "$root" pol.exe 2>$null
        foreach ($l in $lines) { AddHit $l.Trim() 'where-recursive' }
    } catch {}
}

Note "=== retail pol.exe candidates ===" 'Green'
if ($hits.Count -eq 0) {
    Note "No retail pol.exe found anywhere. Is the Steam FFXI install mounted?" 'Yellow'
} else {
    $hits |
        Sort-Object path -Unique |
        Format-Table -AutoSize -Wrap path, size, version, source |
        Out-String |
        Write-Host
}

Stop-Transcript | Out-Null
