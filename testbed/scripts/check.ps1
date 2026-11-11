# Judges a workspace after an agent run, whatever channel ran it (CLI, VS Code, ...).
#
# Runs the workspace's own tests plus the task's hidden acceptance tests, checks the task's
# protected paths and minimum test counts, summarises the OpenCode session, and appends a row
# to testbed\results\runs.jsonl.
param(
    [Parameter(Mandatory)][string]$Workspace,
    [string]$Channel = 'manual',
    [string]$SessionId,
    [int]$WallSeconds,
    [switch]$TimedOut,
    [switch]$NoRecord
)
. "$PSScriptRoot\common.ps1"
Assert-Venv

$ws = (Resolve-Path $Workspace).Path
$taskName = Get-WorkspaceTask $ws
$taskDir = Get-TaskDir $taskName
$rules = Get-Content -Raw "$taskDir\task.json" | ConvertFrom-Json
$problems = @()

# Tests: the agent's suite plus acceptance tests it never saw, removed again afterwards.
$acceptance = Join-Path $ws '_acceptance'
if (Test-Path "$taskDir\acceptance") { Copy-Item -Recurse "$taskDir\acceptance" $acceptance }
Push-Location $ws
try {
    $pytestArgs = @('-m', 'pytest', '-q', '-p', 'no:cacheprovider', 'tests')
    if (Test-Path $acceptance) { $pytestArgs += '_acceptance' }
    $testOutput = & $VenvPython @pytestArgs 2>&1 | Out-String
    $testsPassed = ($LASTEXITCODE -eq 0)
} finally {
    Pop-Location
    if (Test-Path $acceptance) { Remove-Item -Recurse -Force $acceptance }
}
$summaryLine = ($testOutput -split "`r?`n" | Where-Object { $_ -match '\d+ (passed|failed|error)' } | Select-Object -Last 1)
if (-not $testsPassed) { $problems += "tests failed: $summaryLine" }

# Protected paths must be identical to the baseline (no edits, no new files).
foreach ($path in $rules.protected) {
    $touched = @(Invoke-Native git -C $ws diff --name-only baseline -- $path) + @(Invoke-Native git -C $ws ls-files --others --exclude-standard -- $path)
    if ($touched | Where-Object { $_ }) { $problems += "protected path changed: $(($touched | Where-Object { $_ }) -join ', ')" }
}

# Guards against "fixing" a test file by deleting its tests.
foreach ($entry in $rules.min_tests.PSObject.Properties) {
    Push-Location $ws
    try { $collected = & $VenvPython -m pytest --collect-only -q -p no:cacheprovider $entry.Name 2>&1 | Out-String } finally { Pop-Location }
    $count = @($collected -split "`r?`n" | Where-Object { $_ -match '::' }).Count
    if ($count -lt $entry.Value) { $problems += "$($entry.Name) has $count tests, needs at least $($entry.Value)" }
}

$changed = @(Invoke-Native git -C $ws diff --name-only baseline) + @(Invoke-Native git -C $ws ls-files --others --exclude-standard) | Where-Object { $_ }

if (-not $SessionId) { $SessionId = Get-LatestSessionId $ws }
$session = if ($SessionId) { Get-SessionSummary $ws $SessionId } else { $null }
if (-not $SessionId) { $problems += 'no OpenCode session found for this workspace' }
if ($TimedOut) { $problems += 'agent run hit the time limit' }
if ($session -and $session.leaked_tool_calls) { $problems += "model wrote $($session.leaked_tool_calls) tool call(s) as text; Ollama didn't parse them and the agent stopped" }

$result = [ordered]@{
    time          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    task          = $taskName
    channel       = $Channel
    workspace     = Split-Path $ws -Leaf
    session_id    = $SessionId
    passed        = ($problems.Count -eq 0)
    tests         = $summaryLine
    problems      = $problems
    changed_files = @($changed)
    wall_seconds  = if ($PSBoundParameters.ContainsKey('WallSeconds')) { $WallSeconds } else { $null }
    timed_out     = [bool]$TimedOut
    session       = $session
}

if (-not $NoRecord) {
    New-Item -ItemType Directory -Force $ResultsDir | Out-Null
    Add-Content -Encoding utf8 (Join-Path $ResultsDir 'runs.jsonl') ($result | ConvertTo-Json -Compress -Depth 5)
}

Write-Host ''
Write-Host ("{0}  {1}  [{2}]" -f $(if ($result.passed) { 'PASS' } else { 'FAIL' }), $taskName, $Channel)
Write-Host "  tests:    $summaryLine"
foreach ($p in $problems) { Write-Host "  problem:  $p" }
Write-Host "  changed:  $($changed -join ', ')"
if ($session) {
    Write-Host ("  session:  {0}  outcome={1}  steps={2}  tool_calls={3} (failed {4})  tokens in/out={5}/{6}" -f $SessionId, $session.outcome, $session.steps, $session.tool_calls, $session.failed_tools, $session.input_tokens, $session.output_tokens)
}
if (-not $testsPassed) { Write-Host ''; Write-Host $testOutput }
