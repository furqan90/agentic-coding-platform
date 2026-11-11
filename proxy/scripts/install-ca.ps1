# Developer machine: installs the proxy's root certificate for OpenCode and sets NODE_EXTRA_CA_CERTS.
#
#   # shared proxy: download from the proxy, verified against the fingerprint the admin gave you
#   .\proxy\scripts\install-ca.ps1 -ProxyUrl https://ai-proxy.corp.example -Fingerprint AB:CD:...
#   # file the admin sent you, or the one export-ca.ps1 wrote on your own machine
#   .\proxy\scripts\install-ca.ps1 -CertFile .\proxy\certs\proxy-root-ca.crt
#
# The download happens before the certificate is trusted, so the fingerprint is what proves it
# is genuine. Without -CertFile, -Fingerprint is required.
param(
    [string]$ProxyUrl = 'https://localhost',
    [string]$Fingerprint,
    [string]$CertFile,
    # User: persists for new processes (OpenCode Desktop, VS Code); Process: this shell only.
    [ValidateSet('User', 'Process')][string]$Scope = 'User',
    [string]$InstallPath = (Join-Path $env:USERPROFILE '.agentic-coding\proxy-root-ca.crt'),
    # Replace NODE_EXTRA_CA_CERTS even if it already points at a different file.
    [switch]$Force
)
. "$PSScriptRoot\ca-common.ps1"

$uri = [Uri]$ProxyUrl
if ($CertFile) {
    $root = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path $CertFile).Path)
} else {
    if (-not $Fingerprint) { throw "-Fingerprint is required when downloading from $ProxyUrl. Ask the proxy admin for it (export-ca.ps1 prints it)." }
    $pem = (Invoke-ProxyTls $uri $null '/ca.crt').Body
    $root = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Text.Encoding]::ASCII.GetBytes($pem))
}

$actual = Get-CertFingerprint $root
if ($Fingerprint -and (Format-Fingerprint $Fingerprint) -ne (Format-Fingerprint $actual)) {
    throw "Fingerprint mismatch: expected $Fingerprint, got $actual. Nothing was installed. Check the value with your admin."
}
if (-not (Test-IsCaCert $root)) { throw "The certificate ($($root.Subject)) is not a CA certificate. Nothing was installed." }

# Node reads a single file from NODE_EXTRA_CA_CERTS, so don't silently drop a CA someone else set.
$existing = [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $Scope)
if ($existing -and ($existing -ne $InstallPath) -and -not $Force) {
    throw "NODE_EXTRA_CA_CERTS ($Scope) already points at $existing. Re-run with -Force to replace it, or combine both PEM files into one and point the variable at that."
}

$verify = Invoke-ProxyTls $uri $root
if (-not ($verify.ChainsToRoot -and $verify.NameMatches)) {
    throw "$ProxyUrl does not present a certificate for '$($uri.Host)' signed by this root (chains to root=$($verify.ChainsToRoot), name matches=$($verify.NameMatches)). Nothing was installed."
}

New-Item -ItemType Directory -Force (Split-Path $InstallPath) | Out-Null
[IO.File]::WriteAllText($InstallPath, (ConvertTo-Pem $root), [Text.Encoding]::ASCII)
[Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $InstallPath, $Scope)
$env:NODE_EXTRA_CA_CERTS = $InstallPath

Write-Host "Installed $($root.Subject) (SHA256 $actual)"
Write-Host "  file:                 $InstallPath"
Write-Host "  NODE_EXTRA_CA_CERTS:  set ($Scope)"
Write-Host "  $ProxyUrl presents a certificate signed by it, valid until $($verify.LeafExpires.ToString('yyyy-MM-dd'))"
if ($Scope -eq 'User') { Write-Host 'Fully quit and restart OpenCode Desktop and VS Code so they pick up the new value.' }
if ($uri.Host -ne 'localhost') { Write-Host "Set provider.proxy.options.baseURL in opencode.json to $($ProxyUrl.TrimEnd('/'))/v1." }
