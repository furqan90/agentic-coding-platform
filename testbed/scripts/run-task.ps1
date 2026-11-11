# CLI channel: creates a workspace for a task, runs `opencode run` in it with a time limit,
# then judges the result with check.ps1.
#
#   .\testbed\scripts\run-task.ps1 -Task 01
#   .\testbed\scripts\run-task.ps1 -Task 02-sales-tax -TimeoutMinutes 15 -UseService
param(
    [Parameter(Mandatory)][string]$Task,
    [string]$Model = 'proxy/qwen3-coder:30b-32k',
    [int]$TimeoutMinutes = 10,
    # Send the run to the OpenCode Desktop background service (the path the VS Code extension
    # uses) instead of a private server. The service only has the env vars it was started with.
    [switch]$UseService
)
. "$PSScriptRoot\common.ps1"
Assert-Venv

foreach ($name in 'OPENCODE_PROXY_API_KEY', 'NODE_EXTRA_CA_CERTS') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set (see docs/proxy-setup.md, Step 6)." }
}

$ws = & "$PSScriptRoot\new-workspace.ps1" -Task $Task
$name = Split-Path $ws -Leaf
$logs = Join-Path $ResultsDir 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
Write-Host "workspace: $ws"

# Start-Process joins arguments with spaces, so quote the ones that contain spaces.
$opencodeArgs = @('run', '--model', $Model, '--title', "`"testbed $name`"", '"Do the task described in TASK.md."')
if (-not $UseService) { $opencodeArgs = @('run', '--standalone') + $opencodeArgs[1..($opencodeArgs.Count - 1)] }

# The agent's shell inherits PATH, so `python -m pytest` picks up the testbed venv.
$savedPath = $env:PATH
$env:PATH = "$VenvDir\Scripts;$env:PATH"
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    $proc = Start-Process -FilePath (Get-OpenCodeExe) -ArgumentList $opencodeArgs -WorkingDirectory $ws -NoNewWindow -PassThru `
        -RedirectStandardOutput "$logs\$name.out.txt" -RedirectStandardError "$logs\$name.err.txt"
    $timedOut = -not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)
    if ($timedOut) {
        Write-Host "time limit of $TimeoutMinutes min reached, stopping OpenCode"
        taskkill /T /F /PID $proc.Id | Out-Null
    }
} finally {
    $env:PATH = $savedPath
}
$timer.Stop()

Write-Host "agent output: $logs\$name.out.txt"
$channel = if ($UseService) { 'cli-service' } else { 'cli' }
& "$PSScriptRoot\check.ps1" -Workspace $ws -Channel $channel -WallSeconds ([int]$timer.Elapsed.TotalSeconds) -TimedOut:$timedOut
