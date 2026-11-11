# Creates a clean, self-contained copy of the project for one task run and prints its path.
#
# The workspace is its own git repo (tag "baseline"), so OpenCode treats it as the project root,
# can't see the hidden acceptance tests, and `git diff baseline` shows what the agent changed.
param([Parameter(Mandatory)][string]$Task)
. "$PSScriptRoot\common.ps1"

$taskDir = Get-TaskDir $Task
$name = '{0}-{1}' -f (Split-Path $taskDir -Leaf), (Get-Date -Format 'yyyyMMdd-HHmmss')
$ws = Join-Path $WorkspacesDir $name

New-Item -ItemType Directory -Force $WorkspacesDir | Out-Null
Copy-Item -Recurse $ProjectDir $ws
Get-ChildItem $ws -Recurse -Directory -Force -Include __pycache__, .pytest_cache | Remove-Item -Recurse -Force
if (Test-Path "$taskDir\setup") { Copy-Item -Recurse -Force "$taskDir\setup\*" $ws }
Copy-Item "$taskDir\task.md" "$ws\TASK.md"
Copy-Item "$RepoDir\opencode.json" "$ws\opencode.json"
Set-Content -Encoding ascii "$ws\.gitignore" "__pycache__/`r`n.pytest_cache/"

Invoke-Native git -C $ws init --quiet
Invoke-Native git -C $ws config core.autocrlf false
Invoke-Native git -C $ws add -A
Invoke-Native git -C $ws -c user.name=testbed -c user.email=testbed@localhost commit --quiet -m baseline
Invoke-Native git -C $ws tag baseline
if ($LASTEXITCODE) { throw "git setup failed in $ws" }

$ws
