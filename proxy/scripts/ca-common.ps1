# Shared by export-ca.ps1 and install-ca.ps1. Windows PowerShell 5.1 compatible; needs no openssl.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

# Runs docker without stderr noise. Under 'Stop', PowerShell 5.1 turns a native command's stderr
# into a terminating error when the caller redirects it.
function Invoke-Native {
    $ErrorActionPreference = 'Continue'
    $exe, $rest = $args
    & $exe @rest 2>$null
}

function Get-CertFingerprint($Cert) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ($sha.ComputeHash($Cert.RawData) | ForEach-Object { $_.ToString('X2') }) -join ':'
}

# Accepts AA:BB..., AABB..., lower case or spaced forms.
function Format-Fingerprint([string]$Fingerprint) {
    ($Fingerprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function Test-IsCaCert($Cert) {
    $bc = $Cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] }
    [bool]($bc -and $bc.CertificateAuthority)
}

function ConvertTo-Pem($Cert) {
    $b64 = [Convert]::ToBase64String($Cert.RawData) -replace '(.{64})', "`$1`n"
    "-----BEGIN CERTIFICATE-----`n$($b64.TrimEnd("`n"))`n-----END CERTIFICATE-----`n"
}

# Opens a TLS connection to $Uri without trusting it, and reports whether the server's certificate
# chains to $RootCert and matches the host name. With -GetPath, also sends a GET and returns the body.
# Uses a synchronous SslStream so the validation callback runs on this thread (a PowerShell
# scriptblock can't run on the thread-pool threads HttpWebRequest would use).
function Invoke-ProxyTls([Uri]$Uri, $RootCert, [string]$GetPath) {
    $port = if ($Uri.IsDefaultPort) { 443 } else { $Uri.Port }
    $state = @{ Leaf = $null; Errors = $null; Presented = @() }
    $callback = {
        param($stream, $cert, $chain, $errors)
        $state.Leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert)
        $state.Errors = $errors
        $state.Presented = @($chain.ChainElements | ForEach-Object { $_.Certificate })
        $true
    }.GetNewClosure()

    $tcp = [System.Net.Sockets.TcpClient]::new($Uri.Host, $port)
    try {
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, [System.Net.Security.RemoteCertificateValidationCallback]$callback)
        try { $ssl.AuthenticateAsClient($Uri.Host) } catch {
            throw "TLS handshake with $($Uri.Host):$port failed. Caddy only serves the names in PROXY_SITES; use one of those. ($($_.Exception.InnerException.Message))"
        }
        $body = $null
        if ($GetPath) {
            $request = "GET $GetPath HTTP/1.1`r`nHost: $($Uri.Host)`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($request)
            $ssl.Write($bytes, 0, $bytes.Length)
            $buffer = [IO.MemoryStream]::new()
            $ssl.CopyTo($buffer)
            $text = [Text.Encoding]::ASCII.GetString($buffer.ToArray())
            $head, $body = $text -split "`r`n`r`n", 2
            if ($head -notmatch '^HTTP/1\.\d 200') { throw "GET $GetPath on $($Uri.Host) returned: $(($head -split "`r`n")[0])" }
        }
    } finally {
        $tcp.Dispose()
    }

    $chainsToRoot = $false
    if ($RootCert) {
        $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        # Our root is not in the Windows store; accept an unknown root here, then require that the
        # chain actually ends at $RootCert.
        $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
        [void]$chain.ChainPolicy.ExtraStore.Add($RootCert)
        foreach ($c in $state.Presented) { [void]$chain.ChainPolicy.ExtraStore.Add($c) }
        $built = $chain.Build($state.Leaf)
        $top = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        $chainsToRoot = $built -and ($top.Thumbprint -eq $RootCert.Thumbprint)
    }

    [pscustomobject]@{
        Host         = $Uri.Host
        ChainsToRoot = $chainsToRoot
        NameMatches  = -not ($state.Errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)
        LeafSubject  = $state.Leaf.Subject
        LeafExpires  = $state.Leaf.NotAfter
        Body         = $body
    }
}
