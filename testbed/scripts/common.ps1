# Shared paths and helpers, dot-sourced by the other testbed scripts. Windows PowerShell 5.1 compatible.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$TestbedDir    = Split-Path $PSScriptRoot
$RepoDir       = Split-Path $TestbedDir
$ProjectDir    = Join-Path $TestbedDir 'project'
$TasksDir      = Join-Path $TestbedDir 'tasks'
$WorkspacesDir = Join-Path $TestbedDir 'workspaces'
$ResultsDir    = Join-Path $TestbedDir 'results'
$VenvDir       = Join-Path $TestbedDir '.venv'
$VenvPython    = Join-Path $VenvDir 'Scripts\python.exe'

# Runs git/opencode without stderr noise. Under 'Stop', PowerShell 5.1 turns a native command's
# stderr (e.g. git's CRLF warnings) into a terminating error when the caller redirects it.
function Invoke-Native {
    $ErrorActionPreference = 'Continue'
    $exe, $rest = $args
    & $exe @rest 2>$null
}

function Assert-Venv {
    if (-not (Test-Path $VenvPython)) { throw "Testbed venv missing. Run testbed\scripts\setup.ps1 first." }
}

# Accepts a full task folder name ("01-bulk-discount") or its number ("01", "1").
function Get-TaskDir([string]$Task) {
    $all = Get-ChildItem $TasksDir -Directory
    $match = @($all | Where-Object { $_.Name -eq $Task })
    if (-not $match) { $match = @($all | Where-Object { $_.Name -like ('{0:D2}-*' -f [int]($Task -replace '\D', '0')) }) }
    if ($match.Count -ne 1) { throw "Unknown task '$Task'. Available: $(($all | ForEach-Object Name) -join ', ')" }
    $match[0].FullName
}

# Workspace folders are named <task>-<yyyyMMdd-HHmmss>.
function Get-WorkspaceTask([string]$Workspace) {
    (Split-Path $Workspace -Leaf) -replace '-\d{8}-\d{6}$', ''
}

# Start-Process can't launch the npm .ps1 shim, so resolve the .cmd one.
function Get-OpenCodeExe {
    $cmd = Get-Command opencode.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { $cmd = Get-Command opencode -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
    $cmd.Source
}

# The workspace is its own git root, so OpenCode lists only the sessions run in it.
function Get-LatestSessionId([string]$Workspace) {
    Push-Location $Workspace
    try { $json = Invoke-Native opencode session list --standalone -n 1 --format json | Out-String } finally { Pop-Location }
    $sessions = @($json | ConvertFrom-Json)
    if ($sessions.Count -gt 0) { $sessions[0].id }
}

function Get-SessionSummary([string]$Workspace, [string]$SessionId) {
    Push-Location $Workspace
    try { $json = Invoke-Native opencode session export --standalone $SessionId | Out-String } finally { Pop-Location }
    $session = $json | ConvertFrom-Json
    $steps = @($session.messages | Where-Object { $_.type -eq 'assistant' })
    $parts = @($steps | ForEach-Object { $_.content })
    $end = ($steps | ForEach-Object { $_.time.completed } | Measure-Object -Maximum).Maximum
    [ordered]@{
        outcome       = $session.info.outcome
        steps         = $steps.Count
        tool_calls    = @($parts | Where-Object { $_.type -eq 'tool' }).Count
        failed_tools  = @($parts | Where-Object { $_.type -eq 'tool' -and $_.state.status -ne 'completed' }).Count
        text_steps    = @($steps | Where-Object { @($_.content | Where-Object { $_.type -eq 'text' }).Count -gt 0 }).Count
        # Tool calls the model wrote as text (e.g. Qwen's <function=...> without <tool_call>) that
        # Ollama didn't parse; OpenCode then takes the turn as a final answer and stops.
        leaked_tool_calls = @($parts | Where-Object { $_.type -eq 'text' -and $_.text -match '<function=|<tool_call>' }).Count
        input_tokens  = $session.info.tokens.input
        output_tokens = $session.info.tokens.output
        agent_seconds = if ($end) { [math]::Round(($end - $session.info.time.created) / 1000) } else { $null }
    }
}
