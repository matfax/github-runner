$script:GitHubAppTokenCache = $null

function ConvertTo-Base64Url {
    param ([byte[]]$Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$PrivateKeyPath
    )

    if (-not (Test-Path -LiteralPath $PrivateKeyPath)) {
        throw "GitHub App private key not found at '$PrivateKeyPath'."
    }

    # Backdate iat to tolerate clock drift; GitHub caps exp at 10 minutes.
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Header = @{ alg = "RS256"; typ = "JWT" } | ConvertTo-Json -Compress
    $Payload = @{ iat = $Now - 60; exp = $Now + 540; iss = $AppId } | ConvertTo-Json -Compress

    $Unsigned = "$(ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($Header))).$(ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($Payload)))"

    $Rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $Rsa.ImportFromPem((Get-Content -LiteralPath $PrivateKeyPath -Raw))
        $Signature = $Rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($Unsigned),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
        $Rsa.Dispose()
    }

    return "$Unsigned.$(ConvertTo-Base64Url $Signature)"
}

function Resolve-GitHubAppInstallationId {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Jwt,
        [string]$Owner
    )

    $Headers = New-GitHubHeaders -Token $Jwt
    try {
        $Installations = @(Invoke-RestMethod -Uri "https://api.github.com/app/installations?per_page=100" -Headers $Headers -ErrorAction Stop)
    } catch {
        throw "Failed to list GitHub App installations: $($_.Exception.Message)"
    }

    if ($Owner) {
        $Installations = @($Installations | Where-Object { $_.account.login -ieq $Owner })
    }

    if ($Installations.Count -ne 1) {
        throw "Expected exactly one GitHub App installation$(if ($Owner) { " for '$Owner'" }), found $($Installations.Count). Set GITHUB_APP_INSTALLATION_ID."
    }

    return [string]$Installations[0].id
}

function Get-GitHubAppToken {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$PrivateKeyPath,
        [string]$InstallationId,
        [string]$Owner
    )

    # Installation tokens live for an hour; renew once less than 5 minutes remain.
    $Cache = $script:GitHubAppTokenCache
    if ($Cache -and $Cache.ExpiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $Cache.Token
    }

    $Jwt = New-GitHubAppJwt -AppId $AppId -PrivateKeyPath $PrivateKeyPath
    if (-not $InstallationId) {
        $InstallationId = if ($Cache) { $Cache.InstallationId } else { Resolve-GitHubAppInstallationId -Jwt $Jwt -Owner $Owner }
    }

    $Headers = New-GitHubHeaders -Token $Jwt
    try {
        $Response = Invoke-RestMethod -Uri "https://api.github.com/app/installations/$InstallationId/access_tokens" -Method Post -Headers $Headers -ErrorAction Stop
    } catch {
        throw "Failed to create installation token for installation ${InstallationId}: $($_.Exception.Message)"
    }

    $script:GitHubAppTokenCache = [pscustomobject]@{
        Token          = $Response.token
        ExpiresAt      = [DateTimeOffset]$Response.expires_at
        InstallationId = $InstallationId
    }

    return $Response.token
}
