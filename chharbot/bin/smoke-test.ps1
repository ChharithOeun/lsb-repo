# smoke-test.ps1 - end-to-end chharbot check on the live Windows box.
#
# Steps:
#   1. Verify Python + chharbot package are installed.
#   2. Verify Ollama is installed and running; pull the target model if missing.
#   3. Verify the two bridges are reachable (or fall back to server-only mode).
#   4. Run three read-only chharbot prompts and print the outputs.
#   5. Exit 0 if all three returned non-empty content; exit 1 otherwise.
#
# Safe to re-run. Writes a transcript to <DeployRoot>\logs\chharbot-smoke.log.
#
# Examples:
#   .\smoke-test.ps1
#   .\smoke-test.ps1 -Model llama3.1:8b -PullIfMissing
#   .\smoke-test.ps1 -NoOllama -Model gpt-4o-mini -Backend openai `
#       -LlmUrl https://api.openai.com/v1
[CmdletBinding()]
param(
    [string]$Model          = 'llama3.1:8b-instruct-q4_K_M',
    [string]$Backend        = 'ollama',
    [string]$LlmUrl         = 'http://127.0.0.1:11434',
    [string]$DeployRoot     = 'F:\ffxi\deploy',
    [switch]$PullIfMissing,
    [switch]$NoOllama,       # skip ollama plumbing (use with external/openai backend)
    [switch]$AllowWrites
)

# NOTE: we intentionally run with Continue (not Stop) because Python writes its
# tracebacks to stderr. With ErrorActionPreference=Stop + 2>&1, PS5.1 wraps
# those as NativeCommandError terminating exceptions and aborts the whole
# script before we can print the real error. Continue lets us see it.
$ErrorActionPreference = 'Continue'
$LogRoot = Join-Path $DeployRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
$LogPath = Join-Path $LogRoot 'chharbot-smoke.log'
$TraceRoot = Join-Path $LogRoot 'chharbot-smoke-traces'
New-Item -ItemType Directory -Force -Path $TraceRoot | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Say($msg, $color = 'Cyan') { Write-Host $msg -ForegroundColor $color }
function Die($msg) { Say "FAIL: $msg" 'Red'; Stop-Transcript | Out-Null; exit 1 }

Say "=== chharbot smoke test ===" 'Green'
Say ("  model   : {0}" -f $Model)
Say ("  backend : {0}" -f $Backend)
Say ("  llm url : {0}" -f $LlmUrl)

# 1. Python + chharbot
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { $py = Get-Command py      -ErrorAction SilentlyContinue }
if (-not $py) { Die "Python not on PATH." }
& $py.Source -c "import chharbot" 2>$null
if ($LASTEXITCODE -ne 0) { Die "chharbot module not importable. Run 'pip install -e <repo>\chharbot' first." }
Say "  chharbot: installed" 'Green'

# 2. Ollama
if (-not $NoOllama -and $Backend -eq 'ollama') {
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) {
        Die "ollama not on PATH. Install from https://ollama.com/download (no-download version: skip with -NoOllama)."
    }

    # Probe the daemon.
    try {
        $null = Invoke-RestMethod -Uri ("$LlmUrl/api/tags") -TimeoutSec 3
        Say "  ollama  : daemon up" 'Green'
    } catch {
        Say "  ollama  : daemon not responding; starting..." 'Yellow'
        Start-Process -FilePath $ollama.Source -ArgumentList 'serve' -WindowStyle Hidden
        Start-Sleep -Seconds 3
        try {
            $null = Invoke-RestMethod -Uri ("$LlmUrl/api/tags") -TimeoutSec 3
            Say "  ollama  : daemon up after start" 'Green'
        } catch { Die "could not reach ollama at $LlmUrl after starting it." }
    }

    # Check if the target model is present; pull if asked.
    $tags = Invoke-RestMethod -Uri ("$LlmUrl/api/tags") -TimeoutSec 5
    $have = $false
    foreach ($m in $tags.models) { if ($m.name -eq $Model) { $have = $true; break } }
    if (-not $have) {
        if ($PullIfMissing) {
            Say ("  ollama  : pulling {0} (this may take a while)" -f $Model) 'Yellow'
            & $ollama.Source pull $Model
            if ($LASTEXITCODE -ne 0) { Die "ollama pull failed for $Model" }
        } else {
            Die "model '$Model' not loaded. Re-run with -PullIfMissing or pull it manually."
        }
    }
    Say ("  ollama  : model {0} present" -f $Model) 'Green'
}

# 3. Bridges
function Test-Tcp($hostname, $port, $timeoutMs = 1500) {
    # Parameter name is $hostname (not $host) because $Host is a built-in
    # PowerShell automatic variable and read-only.
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($hostname, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $c.Connected) { return $true }
    } catch { } finally { $c.Close() }
    return $false
}

$aiUp    = Test-Tcp '127.0.0.1' 27115
$adminUp = Test-Tcp '127.0.0.1' 27116
Say ("  ai_bridge      : {0}" -f ($(if ($aiUp)    { 'up' } else { 'down' }))) ($(if ($aiUp)    { 'Green' } else { 'DarkYellow' }))
Say ("  lsb_admin_api  : {0}" -f ($(if ($adminUp) { 'up' } else { 'down' }))) ($(if ($adminUp) { 'Green' } else { 'DarkYellow' }))
if (-not $adminUp) { Die "lsb_admin_api sidecar is required for smoke test." }

# 4. Prompts
$prompts = @(
    'What are the current server stats? Answer in one line.',
    'Is login.lua in sync with the retail client on this box? Answer briefly.',
    'How many zones have characters in them? Just the count.'
)

$pyArgs = @(
    '-m', 'chharbot',
    '--backend', $Backend,
    '--model',   $Model,
    '--llm-url', $LlmUrl
)
if (-not $aiUp)      { $pyArgs += '--no-ai-bridge' }
if ($AllowWrites)    { $pyArgs += '--allow-writes' }

$pass = 0
$fail = 0
$idx = 0
foreach ($p in $prompts) {
    $idx++
    Say ""
    Say ">>> $p" 'Cyan'
    $stdout = Join-Path $TraceRoot ("prompt-{0}.stdout.log" -f $idx)
    $stderr = Join-Path $TraceRoot ("prompt-{0}.stderr.log" -f $idx)
    # Separate stdout/stderr so Python tracebacks survive intact. Invoke via
    # Start-Process so NativeCommandError cannot be raised at all.
    $proc = Start-Process -FilePath $py.Source `
                          -ArgumentList (@($pyArgs + @($p)) | ForEach-Object {
                              if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
                          }) `
                          -NoNewWindow -Wait -PassThru `
                          -RedirectStandardOutput $stdout `
                          -RedirectStandardError  $stderr
    $code = $proc.ExitCode
    $outText = if (Test-Path $stdout) { (Get-Content $stdout -Raw) } else { '' }
    $errText = if (Test-Path $stderr) { (Get-Content $stderr -Raw) } else { '' }
    $outText = ($outText -as [string]).Trim()
    $errText = ($errText -as [string]).Trim()
    Say ("  exit code : {0}" -f $code) $(if ($code -eq 0) { 'Green' } else { 'Red' })
    if ($outText) {
        Say "  --- stdout ---" 'DarkGray'
        Say $outText 'White'
    }
    if ($errText) {
        Say "  --- stderr ---" 'DarkGray'
        Say $errText 'Yellow'
    }
    if ($code -eq 0 -and $outText) {
        $pass++
    } else {
        $fail++
    }
}

Say ""
Say ("=== result: {0} ok / {1} empty ===" -f $pass, $fail) $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Stop-Transcript | Out-Null
if ($fail -gt 0) { exit 1 } else { exit 0 }
