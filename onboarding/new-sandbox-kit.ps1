# Builds a Windows Sandbox kit for testing bootstrap.ps1 on a clean machine: copies bootstrap.ps1 and
# an onboarding file into a folder and writes a .wsb that maps it read-only into the sandbox and runs
# bootstrap at logon. Double-click the .wsb to start. The sandbox is discarded when it is closed.
#
#   .\onboarding\new-sandbox-kit.ps1 -Config .\onboarding-alice.json
#
# proxy_url in the onboarding file must be reachable from the sandbox: the proxy host's IP or name
# (in PROXY_SITES), not localhost. The kit folder holds the onboarding file, i.e. an API key.
param(
    [Parameter(Mandatory)][string]$Config,
    [string]$OutDir = (Join-Path $PSScriptRoot '.sandbox')
)
$ErrorActionPreference = 'Stop'

$cfg = Get-Content -Raw (Resolve-Path $Config).Path | ConvertFrom-Json
if (([Uri]$cfg.proxy_url).Host -in 'localhost', '127.0.0.1') {
    throw "proxy_url is $($cfg.proxy_url); inside the sandbox that is the sandbox itself. Use the proxy host's IP or name."
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
Copy-Item -Force (Join-Path $PSScriptRoot 'bootstrap.ps1') "$OutDir\bootstrap.ps1"
Copy-Item -Force (Resolve-Path $Config).Path "$OutDir\onboarding.json"

# `start` gives bootstrap a visible window; LogonCommand itself runs without one.
$command = 'cmd.exe /c start "bootstrap" powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\kit\bootstrap.ps1 -Config C:\kit\onboarding.json'
$wsb = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($OutDir))</HostFolder>
      <SandboxFolder>C:\kit</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <Networking>Enable</Networking>
  <LogonCommand>
    <Command>$([Security.SecurityElement]::Escape($command))</Command>
  </LogonCommand>
</Configuration>
"@
Set-Content -Encoding utf8 "$OutDir\agentic-coding-bootstrap.wsb" $wsb

Write-Host "Kit: $OutDir"
Write-Host "Start the test: double-click $OutDir\agentic-coding-bootstrap.wsb"
Write-Host 'Delete the kit folder afterwards; it contains the onboarding file (API key).'
