# Admin: copies the public root certificate of Caddy's local CA out of the container, checks that
# every site Caddy serves presents a certificate chaining to it, and prints the SHA-256 fingerprint
# to give developers (through a channel they already trust) for install-ca.ps1.
#
#   .\proxy\scripts\export-ca.ps1
#   .\proxy\scripts\export-ca.ps1 -Sites ai-proxy.corp.example
#
# Only root.crt is exported. root.key, next to it in the caddy_data volume, must never leave the proxy host.
param(
    [string]$OutFile = (Join-Path (Split-Path $PSScriptRoot) 'certs\proxy-root-ca.crt'),
    # Host names to check; default: the PROXY_SITES the running Caddy container was started with.
    [string[]]$Sites
)
. "$PSScriptRoot\ca-common.ps1"

$proxyDir = Split-Path $PSScriptRoot
$compose = @('compose', '--project-directory', $proxyDir)
if (Test-Path "$proxyDir\.env") { $compose += @('--env-file', "$proxyDir\.env") }

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
Invoke-Native docker @compose cp caddy:/data/caddy/pki/authorities/local/root.crt $OutFile | Out-Null
if (-not (Test-Path $OutFile)) { throw "Could not copy root.crt from the caddy container. Is the proxy stack running?" }

$root = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($OutFile)
if (-not (Test-IsCaCert $root)) { throw "$OutFile is not a CA certificate." }

if (-not $Sites) {
    $configured = Invoke-Native docker @compose exec -T caddy printenv PROXY_SITES
    $Sites = @(($configured -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Sites) { $Sites = @('localhost') }
}

$fingerprint = Get-CertFingerprint $root
Write-Host "Root certificate: $OutFile"
Write-Host "  subject:     $($root.Subject)"
Write-Host "  expires:     $($root.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "  fingerprint: SHA256 $fingerprint"
Write-Host ''

$failed = $false
foreach ($site in $Sites) {
    try {
        $r = Invoke-ProxyTls "https://$site" $root
        $ok = $r.ChainsToRoot -and $r.NameMatches
        Write-Host ("  {0}  https://{1}  chains to root={2}  name matches={3}  leaf expires {4}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $site, $r.ChainsToRoot, $r.NameMatches, $r.LeafExpires.ToString('yyyy-MM-dd'))
        if (-not $ok) { $failed = $true }
    } catch {
        Write-Host "  FAIL  https://$site  $($_.Exception.Message)"
        $failed = $true
    }
}

Write-Host ''
Write-Host 'Give developers the fingerprint above and this command (or send them the .crt file):'
Write-Host "  .\proxy\scripts\install-ca.ps1 -ProxyUrl https://$($Sites[-1]) -Fingerprint $fingerprint"
if ($failed) { exit 1 }
