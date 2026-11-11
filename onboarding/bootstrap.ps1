# Sets up a developer machine for the agentic coding platform from an onboarding file issued by
# a proxy admin. Self-contained (a new developer doesn't have this repo); Windows PowerShell 5.1.
#
#   powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Config .\onboarding-alice.json
#
# 1. checks the onboarding file
# 2. downloads the proxy's root CA, verifies it against the file's fingerprint, saves it
# 3. checks the API key against the proxy (over the verified connection)
# 4. installs the pinned OpenCode CLI from the npm registry (sha512-verified; no Node needed)
# 5. sets NODE_EXTRA_CA_CERTS and OPENCODE_PROXY_API_KEY, adds OpenCode to PATH
# 6. writes the proxy provider into the global OpenCode config (other settings are kept)
# 7. runs a smoke test through the proxy
#
# Onboarding file (format "agentic-coding-onboarding/1"):
#   { "format", "email", "issued_at", "proxy_url", "ca_fingerprint_sha256", "api_key",
#     "opencode_version", "default_model", "models": [{ "id", "name", "context", "output" }] }
param(
    [Parameter(Mandatory)][string]$Config,
    # User: persists for new processes (terminals, VS Code). Process: this shell only, for trying it out.
    [ValidateSet('User', 'Process')][string]$Scope = 'User',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\agentic-coding\opencode'),
    [string]$CaPath = (Join-Path $env:USERPROFILE '.agentic-coding\proxy-root-ca.crt'),
    [string]$OpenCodeConfigPath = (Join-Path $env:USERPROFILE '.config\opencode\opencode.json'),
    [int]$SmokeTestMinutes = 6,
    [switch]$SkipSmokeTest,
    # Replace NODE_EXTRA_CA_CERTS even if it already points at a different file.
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar on 5.1
$defaultConfigPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "   ok  $Text" }

function Get-CertFingerprint($Cert) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ($sha.ComputeHash($Cert.RawData) | ForEach-Object { $_.ToString('X2') }) -join ':'
}

function Format-Fingerprint([string]$Fingerprint) { ($Fingerprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() }

function ConvertTo-Pem($Cert) {
    $b64 = [Convert]::ToBase64String($Cert.RawData) -replace '(.{64})', "`$1`n"
    "-----BEGIN CERTIFICATE-----`n$($b64.TrimEnd("`n"))`n-----END CERTIFICATE-----`n"
}

function Set-UserOrProcessEnv([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
    Set-Item "env:$Name" $Value
}

# Minimal HTTPS GET over a synchronous SslStream (a PowerShell scriptblock can't serve as a TLS
# validation callback on the thread-pool threads Invoke-WebRequest would use).
# With $RootCert, the connection must chain to it and match the host name BEFORE anything
# (e.g. the API key) is sent; without it, the server is not verified (used only to fetch /ca.crt,
# which is then checked against the fingerprint).
function Invoke-ProxyGet([Uri]$Uri, [string]$Path, $RootCert, [hashtable]$Headers = @{}) {
    $port = if ($Uri.IsDefaultPort) { 443 } else { $Uri.Port }
    $state = @{ Leaf = $null; Errors = $null; Presented = @() }
    $callback = {
        param($stream, $cert, $chain, $errors)
        $state.Leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert)
        $state.Errors = $errors
        $state.Presented = @($chain.ChainElements | ForEach-Object { $_.Certificate })
        $true
    }.GetNewClosure()

    try { $tcp = [System.Net.Sockets.TcpClient]::new($Uri.Host, $port) }
    catch { throw "Cannot reach $($Uri.Host):$port. Check the proxy URL, DNS and firewall. ($($_.Exception.InnerException.Message))" }
    try {
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, [System.Net.Security.RemoteCertificateValidationCallback]$callback)
        try { $ssl.AuthenticateAsClient($Uri.Host) }
        catch { throw "TLS handshake with $($Uri.Host) failed; the proxy may not serve this host name. ($($_.Exception.InnerException.Message))" }

        if ($RootCert) {
            $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
            $chain.ChainPolicy.RevocationMode = 'NoCheck'
            $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
            [void]$chain.ChainPolicy.ExtraStore.Add($RootCert)
            foreach ($c in $state.Presented) { [void]$chain.ChainPolicy.ExtraStore.Add($c) }
            $built = $chain.Build($state.Leaf)
            $top = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
            $nameOk = -not ($state.Errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)
            if (-not ($built -and $top.Thumbprint -eq $RootCert.Thumbprint -and $nameOk)) {
                throw "$($Uri.Host) did not present a certificate for that name signed by the proxy CA. Nothing was sent."
            }
        }

        $request = "GET $Path HTTP/1.1`r`nHost: $($Uri.Host)`r`n"
        foreach ($h in $Headers.GetEnumerator()) { $request += "$($h.Key): $($h.Value)`r`n" }
        $request += "Connection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $ssl.Write($bytes, 0, $bytes.Length)
        $buffer = [IO.MemoryStream]::new()
        $ssl.CopyTo($buffer)
    } finally {
        $tcp.Dispose()
    }

    $latin1 = [Text.Encoding]::GetEncoding(28591)  # 1:1 byte mapping, so offsets stay byte offsets
    $raw = $latin1.GetString($buffer.ToArray())
    $head, $body = $raw -split "`r`n`r`n", 2
    if ($head -match 'Transfer-Encoding:\s*chunked') {
        $decoded = ''
        while ($body -match '^([0-9A-Fa-f]+)\r\n') {
            $size = [Convert]::ToInt32($Matches[1], 16)
            if ($size -eq 0) { break }
            $start = $Matches[0].Length
            $decoded += $body.Substring($start, $size)
            $body = $body.Substring($start + $size + 2)
        }
        $body = $decoded
    }
    [pscustomobject]@{
        Status      = [int](($head -split ' ')[1])
        Body        = [Text.Encoding]::UTF8.GetString($latin1.GetBytes($body))
        LeafExpires = $state.Leaf.NotAfter
    }
}

# --- 1. onboarding file -------------------------------------------------------------------------
Write-Step 'Onboarding file'
$cfg = Get-Content -Raw (Resolve-Path $Config).Path | ConvertFrom-Json
if ($cfg.format -ne 'agentic-coding-onboarding/1') { throw "Unsupported onboarding file format '$($cfg.format)'." }
foreach ($field in 'email', 'proxy_url', 'ca_fingerprint_sha256', 'api_key', 'opencode_version', 'default_model', 'models') {
    if (-not $cfg.$field) { throw "Onboarding file is missing '$field'. Ask your admin for a new one." }
}
$proxyBase = $cfg.proxy_url.TrimEnd('/')  # [Uri] adds a trailing slash, so build URLs from this
$proxy = [Uri]$proxyBase
if ($proxy.Scheme -ne 'https') { throw "proxy_url must be https: $($cfg.proxy_url)" }
Write-Ok "$($cfg.email), proxy $proxyBase, issued $($cfg.issued_at)"

# --- 2. proxy CA --------------------------------------------------------------------------------
Write-Step 'Proxy certificate'
$download = Invoke-ProxyGet $proxy '/ca.crt' $null
if ($download.Status -ne 200) { throw "GET $proxyBase/ca.crt returned $($download.Status)." }
$root = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Text.Encoding]::ASCII.GetBytes($download.Body))
$fingerprint = Get-CertFingerprint $root
if ((Format-Fingerprint $fingerprint) -ne (Format-Fingerprint $cfg.ca_fingerprint_sha256)) {
    throw "Certificate fingerprint mismatch: onboarding file says $($cfg.ca_fingerprint_sha256), proxy served $fingerprint. Nothing was installed. Contact your admin."
}
$bc = $root.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] }
if (-not ($bc -and $bc.CertificateAuthority)) { throw "The certificate served by the proxy is not a CA certificate. Nothing was installed." }
Write-Ok "$($root.Subject), fingerprint matches"

# --- 3. API key ---------------------------------------------------------------------------------
Write-Step 'API key'
$models = Invoke-ProxyGet $proxy '/v1/models' $root @{ Authorization = "Bearer $($cfg.api_key)" }
if ($models.Status -eq 401) { throw 'The proxy rejected the API key (401). It may have been revoked; ask your admin for a new onboarding file.' }
if ($models.Status -ne 200) { throw "GET /v1/models returned $($models.Status): $($models.Body)" }
$served = @(($models.Body | ConvertFrom-Json).data | ForEach-Object id)
if ($served -notcontains $cfg.default_model) { throw "The proxy doesn't serve '$($cfg.default_model)' to this key (it serves: $($served -join ', '))." }
Write-Ok "key accepted; models: $($served -join ', ')"

# --- 4. OpenCode CLI ----------------------------------------------------------------------------
Write-Step "OpenCode CLI $($cfg.opencode_version)"
$exe = Join-Path $InstallDir 'opencode.exe'
$installed = if (Test-Path $exe) { (& $exe --version 2>$null | Out-String).Trim() } else { '' }
if ($installed -match [regex]::Escape($cfg.opencode_version)) {
    Write-Ok "already installed: $exe"
} else {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { throw "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE" } }
    $package = "@opencode/cli-windows-$arch"
    $meta = Invoke-RestMethod "https://registry.npmjs.org/$($package -replace '/', '%2f')/$($cfg.opencode_version)"
    $work = Join-Path ([IO.Path]::GetTempPath()) "opencode-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $work | Out-Null
    try {
        $tgz = Join-Path $work 'package.tgz'
        Write-Host "   downloading $package@$($cfg.opencode_version) (~200 MB)"
        Invoke-WebRequest $meta.dist.tarball -OutFile $tgz -UseBasicParsing
        $sha512 = [System.Security.Cryptography.SHA512]::Create()
        $stream = [IO.File]::OpenRead($tgz)
        try { $actual = 'sha512-' + [Convert]::ToBase64String($sha512.ComputeHash($stream)) } finally { $stream.Dispose() }
        if ($actual -ne $meta.dist.integrity) { throw "Downloaded OpenCode package failed its integrity check ($actual vs $($meta.dist.integrity)). Nothing was installed." }
        tar -xzf $tgz -C $work
        if ($LASTEXITCODE) { throw 'Could not unpack the OpenCode package (tar failed).' }
        New-Item -ItemType Directory -Force $InstallDir | Out-Null
        Copy-Item -Force (Join-Path $work 'package\bin\opencode.exe') $exe
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
    Write-Ok "installed $exe (sha512 verified)"
}

# --- 5. environment -----------------------------------------------------------------------------
Write-Step "Environment ($Scope)"
$existingCa = [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $Scope)
if ($existingCa -and ($existingCa -ne $CaPath) -and -not $Force) {
    throw "NODE_EXTRA_CA_CERTS already points at $existingCa. Re-run with -Force to replace it, or combine both PEM files into one."
}
New-Item -ItemType Directory -Force (Split-Path $CaPath) | Out-Null
[IO.File]::WriteAllText($CaPath, (ConvertTo-Pem $root), [Text.Encoding]::ASCII)
Set-UserOrProcessEnv 'NODE_EXTRA_CA_CERTS' $CaPath
Set-UserOrProcessEnv 'OPENCODE_PROXY_API_KEY' $cfg.api_key
Write-Ok "NODE_EXTRA_CA_CERTS = $CaPath"
Write-Ok 'OPENCODE_PROXY_API_KEY set'

$userPath = [Environment]::GetEnvironmentVariable('Path', $Scope)
if (($userPath -split ';') -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable('Path', (@($InstallDir) + @($userPath -split ';' | Where-Object { $_ })) -join ';', $Scope)
}
if (($env:Path -split ';') -notcontains $InstallDir) { $env:Path = "$InstallDir;$env:Path" }
Write-Ok "PATH includes $InstallDir"

# --- 6. OpenCode config -------------------------------------------------------------------------
Write-Step 'OpenCode config'
$modelEntries = [ordered]@{}
foreach ($m in $cfg.models) {
    $modelEntries[$m.id] = [ordered]@{ name = $m.name; limit = [ordered]@{ context = [int]$m.context; output = [int]$m.output } }
}
$provider = [ordered]@{
    npm     = '@ai-sdk/openai-compatible'
    name    = 'Agentic coding proxy'
    options = [ordered]@{ baseURL = "$proxyBase/v1"; apiKey = '{env:OPENCODE_PROXY_API_KEY}' }
    models  = $modelEntries
}
# Keep whatever else is in an existing config; only the proxy provider and default model change.
if (Test-Path $OpenCodeConfigPath) {
    $backup = "$OpenCodeConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $OpenCodeConfigPath $backup
    $oc = Get-Content -Raw $OpenCodeConfigPath | ConvertFrom-Json
    Write-Ok "existing config backed up to $backup"
} else {
    New-Item -ItemType Directory -Force (Split-Path $OpenCodeConfigPath) | Out-Null
    $oc = [pscustomobject]@{ '$schema' = 'https://opencode.ai/config.json' }
}
if (-not $oc.PSObject.Properties['provider']) { $oc | Add-Member provider ([pscustomobject]@{}) }
$oc.provider | Add-Member -Force proxy ([pscustomobject]$provider)
$oc | Add-Member -Force model "proxy/$($cfg.default_model)"
[IO.File]::WriteAllText($OpenCodeConfigPath, ($oc | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
if ($OpenCodeConfigPath -ne $defaultConfigPath) { Set-UserOrProcessEnv 'OPENCODE_CONFIG' $OpenCodeConfigPath }
Write-Ok "$OpenCodeConfigPath (default model proxy/$($cfg.default_model))"

# --- 7. smoke test ------------------------------------------------------------------------------
if (-not $SkipSmokeTest) {
    Write-Step 'Smoke test (the first request can take a few minutes while the model loads)'
    $dir = Join-Path ([IO.Path]::GetTempPath()) "agentic-coding-smoke-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $dir | Out-Null
    try {
        $proc = Start-Process -FilePath $exe -WorkingDirectory $dir -NoNewWindow -PassThru `
            -ArgumentList @('run', '--standalone', '--model', "proxy/$($cfg.default_model)", '"reply with exactly: PROXY_OK"') `
            -RedirectStandardOutput "$dir\out.txt" -RedirectStandardError "$dir\err.txt"
        if (-not $proc.WaitForExit($SmokeTestMinutes * 60 * 1000)) {
            taskkill /T /F /PID $proc.Id | Out-Null
            throw "Smoke test timed out after $SmokeTestMinutes min. Setup is complete; try 'opencode run `"hello`"' later, or ask your admin whether the model server is busy."
        }
        $out = (Get-Content "$dir\out.txt" -Raw) + (Get-Content "$dir\err.txt" -Raw)
        if ($out -notmatch 'PROXY_OK') { throw "Smoke test did not get the expected reply. OpenCode output:`n$out" }
        Write-Ok 'OpenCode answered through the proxy'
    } finally {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
if ($Scope -eq 'User') { Write-Host 'Open a new terminal (and restart VS Code / OpenCode Desktop) to pick up the new environment.' }
Write-Host "Delete the onboarding file now; it contains your API key: $((Resolve-Path $Config).Path)"
