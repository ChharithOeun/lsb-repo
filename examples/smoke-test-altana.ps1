# smoke-test-altana.ps1  (v6 — Steam/Windower-aware)
#
# End-to-end smoke test for the Altana launcher after the xiloader 2.1.1 +
# xiloader_fixed addon deploy.
#
# What it does, in order:
#   1. Sanity-check xiloader.exe + ashita.exe on F:.
#   2. Aggressively hunt for retail pol.exe:
#        a. Hard-coded candidate list (Steam "FINAL FANTASY XI", FFXINA, POL Viewer).
#        b. Scan C:\Program Files (x86)\Steam\steamapps\common  for any
#           "*FINAL FANTASY*" / "FFXI*" folder containing a pol.exe.
#        c. Parse Windower 4 settings.xml and profiles for a configured
#           pol.exe path (user confirmed Windower launches retail OK, so
#           whatever path it uses is ground truth).
#        d. Fall back to a bounded recursive search in the Steam common
#           folder (where.exe /R) for any pol.exe.
#   3. Run xiloader standalone (auth baseline).
#   4. If retail pol.exe was found, back up + patch
#      F:\ffxi\Ashita\config\boot\Private Server.xml boot_file value.
#   5. Launch Ashita with the Altana/Private Server profile and observe.
#   6. Log every decision to F:\ffxi\deploy\altana-smoke-test.log.
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\smoke-test-altana.ps1

$ErrorActionPreference = 'Continue'

$LogPath    = 'F:\ffxi\deploy\altana-smoke-test.log'
$XiLoader   = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$AshitaExe  = 'F:\ffxi\Ashita\ashita.exe'
$AshitaRoot = 'F:\ffxi\Ashita'
$BootProfile= 'Private Server'
$Server     = '127.0.0.1'
$User       = 'GUESTCL1'
$Pass       = 'guestpass'

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Step "=== Altana smoke test (v6) ===" 'Cyan'
Step ("timestamp : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Step "xiloader  : $XiLoader"
Step "ashita    : $AshitaExe"
Step "profile   : $BootProfile"

# --- 1. Sanity ---------------------------------------------------------------
if (-not (Test-Path $XiLoader))  { Step "xiloader missing: $XiLoader" 'Red'; Stop-Transcript | Out-Null; exit 2 }
if (-not (Test-Path $AshitaExe)) { Step "ashita.exe missing: $AshitaExe" 'Red'; Stop-Transcript | Out-Null; exit 2 }

# --- 2. Locate retail pol.exe ------------------------------------------------
$RetailPol = $null
$Strategy  = $null

# 2a. Hard-coded candidate list (ordered by likelihood).
$candidates = @(
    'C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY XI\pol.exe',
    'C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY XI\SquareEnix\PlayOnlineViewer\pol.exe',
    'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe',
    'C:\Program Files (x86)\Steam\steamapps\common\FFXI\pol.exe',
    'C:\Program Files (x86)\PlayOnline\SquareEnix\PlayOnlineViewer\pol.exe',
    'C:\Program Files\PlayOnline\SquareEnix\PlayOnlineViewer\pol.exe',
    'C:\FINAL FANTASY XI\pol.exe',
    'F:\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe',
    'F:\Steam\steamapps\common\FINAL FANTASY XI\pol.exe',
    'F:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe',
    'F:\ffxi\SquareEnix\FINAL FANTASY XI\pol.exe',
    'F:\ffxi\PlayOnlineViewer\pol.exe'
)
foreach ($c in $candidates) {
    if (Test-Path $c) {
        $sz = (Get-Item $c).Length
        Step ("2a candidate hit: {0} ({1} bytes)" -f $c, $sz) 'Yellow'
        if ($c -ne $XiLoader) { $RetailPol = $c; $Strategy = 'candidate-list'; break }
    }
}

# 2b. Scan Steam common for any FINAL FANTASY / FFXI folder.
if (-not $RetailPol) {
    $steamRoots = @(
        'C:\Program Files (x86)\Steam\steamapps\common',
        'F:\Steam\steamapps\common',
        'D:\Steam\steamapps\common',
        'E:\Steam\steamapps\common',
        'F:\Program Files (x86)\Steam\steamapps\common'
    )
    foreach ($root in $steamRoots) {
        if (-not (Test-Path $root)) { continue }
        Step ("2b scanning: {0}" -f $root) 'DarkCyan'
        try {
            $matches = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'FINAL FANTASY|FFXI|PlayOnline' }
            foreach ($m in $matches) {
                $probe = Join-Path $m.FullName 'pol.exe'
                if (Test-Path $probe) {
                    Step ("2b found: {0}" -f $probe) 'Yellow'
                    if ($probe -ne $XiLoader) { $RetailPol = $probe; $Strategy = 'steam-scan'; break }
                }
                # Sub-scan 1 level deeper (SquareEnix\FINAL FANTASY XI\pol.exe etc.).
                $sub = Get-ChildItem -LiteralPath $m.FullName -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                       Where-Object { Test-Path (Join-Path $_.FullName 'pol.exe') } |
                       Select-Object -First 1
                if ($sub) {
                    $probe = Join-Path $sub.FullName 'pol.exe'
                    Step ("2b found (deep): {0}" -f $probe) 'Yellow'
                    if ($probe -ne $XiLoader) { $RetailPol = $probe; $Strategy = 'steam-scan-deep'; break }
                }
            }
            if ($RetailPol) { break }
        } catch { Step ("2b scan error in {0}: {1}" -f $root, $_.Exception.Message) 'DarkGray' }
    }
}

# 2c. Windower 4 settings.xml — user confirmed this launches retail, so it's ground truth.
if (-not $RetailPol) {
    $windowerRoots = @(
        'C:\Program Files (x86)\Windower',
        'C:\Program Files\Windower',
        'C:\Windower',
        'C:\Windower4',
        'F:\Windower',
        'F:\Windower4',
        'D:\Windower',
        'D:\Windower4'
    )
    foreach ($wr in $windowerRoots) {
        if (-not (Test-Path $wr)) { continue }
        Step ("2c scanning Windower root: {0}" -f $wr) 'DarkCyan'
        $xmls = Get-ChildItem -LiteralPath $wr -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'settings|profile|launcher' }
        foreach ($xf in $xmls) {
            try {
                $text = Get-Content -LiteralPath $xf.FullName -Raw -ErrorAction SilentlyContinue
                if ($text -match '([A-Za-z]:\\[^<>"\r\n]*?pol\.exe)') {
                    $p = $Matches[1]
                    if ((Test-Path $p) -and $p -ne $XiLoader) {
                        Step ("2c windower-configured pol.exe: {0}  (from {1})" -f $p, $xf.FullName) 'Yellow'
                        $RetailPol = $p; $Strategy = "windower:$($xf.Name)"; break
                    }
                }
            } catch {}
        }
        if ($RetailPol) { break }
    }
}

# 2d. Bounded recursive find in Steam common via where.exe (fast, uses OS indexer-free walk).
if (-not $RetailPol) {
    $roots = @('C:\Program Files (x86)\Steam\steamapps\common') |
             Where-Object { Test-Path $_ }
    foreach ($root in $roots) {
        Step ("2d where.exe /R scan: {0}" -f $root) 'DarkCyan'
        try {
            $hits = & where.exe /R "$root" pol.exe 2>$null
            foreach ($h in $hits) {
                $h = $h.Trim()
                if ($h -and (Test-Path $h) -and $h -ne $XiLoader) {
                    $sz = (Get-Item $h).Length
                    Step ("2d hit: {0} ({1} bytes)" -f $h, $sz) 'Yellow'
                    $RetailPol = $h; $Strategy = 'where-recursive'; break
                }
            }
            if ($RetailPol) { break }
        } catch { Step ("2d where.exe error: {0}" -f $_.Exception.Message) 'DarkGray' }
    }
}

if ($RetailPol) {
    Step ("Retail pol.exe selected: {0}  [strategy={1}]" -f $RetailPol, $Strategy) 'Green'
} else {
    Step "Retail pol.exe NOT found by any strategy." 'Yellow'
}

# --- 3. Pre-launch PID snapshot ---------------------------------------------
$beforePids = @(Get-Process -Name 'pol' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Step ("pol.exe PIDs before: [{0}]" -f ($beforePids -join ','))

# --- 4. Direct xiloader smoke test (auth baseline) --------------------------
Step "--- direct xiloader auth baseline ---" 'Cyan'
$xiArgs = @('--server', $Server, '--user', $User, '--password', $Pass, '--hairpin', '--hide')
$xi = Start-Process -FilePath $XiLoader -ArgumentList $xiArgs -PassThru -WindowStyle Hidden
Step ("xiloader PID: {0}" -f $xi.Id)
Start-Sleep -Milliseconds 3000

$afterPids = @(Get-Process -Name 'pol' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids = @($afterPids | Where-Object { $beforePids -notcontains $_ })
Step ("pol.exe PIDs after direct xiloader: [{0}]" -f ($afterPids -join ','))
Step ("new PIDs: [{0}]" -f ($newPids -join ','))

Get-Process -Id $xi.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($p in $newPids) {
    if ($p -ne $xi.Id) {
        Step ("Leaving child PID {0} running (retail pol.exe spawned by xiloader)." -f $p) 'Green'
    }
}

# --- 5. If retail found, patch boot profile --------------------------------
if ($RetailPol) {
    $BootProfilePath = Join-Path $AshitaRoot ('config\boot\{0}.xml' -f $BootProfile)
    if (Test-Path $BootProfilePath) {
        Step "--- updating boot profile to retail pol.exe ---" 'Cyan'
        $backupsDir = Join-Path $AshitaRoot 'config\_backups'
        New-Item -ItemType Directory -Force -Path $backupsDir | Out-Null
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bk = Join-Path $backupsDir ("{0}.xml.{1}.smoke.bak" -f $BootProfile, $ts)
        Copy-Item -LiteralPath $BootProfilePath -Destination $bk -Force
        Step ("backup: {0}" -f $bk) 'DarkCyan'

        [xml]$xml = Get-Content -LiteralPath $BootProfilePath
        $n = $xml.settings.setting | Where-Object { $_.name -eq 'boot_file' }
        if ($n) {
            $old = [string]$n.'#text'
            $n.'#text' = $RetailPol
            $xml.Save($BootProfilePath)
            Step ("boot_file: '{0}' -> '{1}'" -f $old, $RetailPol) 'Green'
        } else {
            Step "boot_file node not found in profile (unexpected)." 'Yellow'
        }
    } else {
        Step ("boot profile missing: {0}" -f $BootProfilePath) 'Yellow'
    }
} else {
    Step "No retail pol.exe, skipping boot_file patch." 'DarkGray'
}

# --- 6. Launch Ashita -> Altana profile -------------------------------------
Step "--- launching Ashita (Altana / Private Server profile) ---" 'Cyan'
$asArgs = @('--boot', $BootProfile)
$as = Start-Process -FilePath $AshitaExe -ArgumentList $asArgs -PassThru
Step ("ashita PID: {0}" -f $as.Id)
Start-Sleep -Seconds 8

$afterAshitaPids = @(Get-Process -Name 'pol' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Step ("pol.exe PIDs after Ashita launch: [{0}]" -f ($afterAshitaPids -join ','))

$ashitaRunning = Get-Process -Id $as.Id -ErrorAction SilentlyContinue
if ($ashitaRunning) {
    Step ("Ashita still running (PID {0}) — good sign, injector likely attached." -f $as.Id) 'Green'
} else {
    Step "Ashita process exited early — inspect F:\ffxi\Ashita\logs for injection errors." 'Red'
}

# --- 7. Surface the latest Ashita log line if any ---------------------------
$logDir = Join-Path $AshitaRoot 'logs'
if (Test-Path $logDir) {
    $latest = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Step ("latest Ashita log: {0}" -f $latest.FullName) 'DarkCyan'
        try {
            $tail = Get-Content -LiteralPath $latest.FullName -Tail 20 -ErrorAction SilentlyContinue
            if ($tail) { Step '--- ashita log tail ---' 'DarkCyan'; $tail | ForEach-Object { Write-Host $_ } }
        } catch {}
    }
}

Step "--- smoke test complete; review this log for next steps ---" 'Cyan'
Stop-Transcript | Out-Null
