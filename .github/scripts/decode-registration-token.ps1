#Requires -Version 7
<#
.SYNOPSIS
Decodes an encrypted registration token from GitHub Actions

.DESCRIPTION
Decrypts a base64-encoded, AES-encrypted registration token using a shared secret.
Used by GitHub Actions workflows to securely pass registration tokens between jobs.

.PARAMETER EncodedToken
The base64-encoded encrypted token string

.PARAMETER SymmetricKey
The symmetric encryption key used for decryption

.OUTPUTS
Sets output variable 'out' with the decrypted token

.EXAMPLE
.github/scripts/decode-registration-token.ps1 -EncodedToken "..." -SymmetricKey "..."
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$EncodedToken,
    
    [Parameter(Mandatory = $true)]
    [string]$SymmetricKey
)

$ErrorActionPreference = 'Stop'

# Decrypt the token
$payload = [Convert]::FromBase64String($EncodedToken)
if ($payload.Length -lt 17) { 
    throw "Encoded token payload invalid (less than 17 bytes)"
}

# Extract IV and ciphertext
$iv = $payload[0..15]
$cipher = $payload[16..($payload.Length - 1)]

# Derive AES key from shared secret
$key = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($SymmetricKey))

# Configure AES decryption
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.Mode = 'CBC'
$aes.Padding = 'PKCS7'
$aes.Key = $key
$aes.IV = $iv

# Decrypt
try {
    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
    $plain = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    
    # Output for GitHub Actions (mask the secret)
    Write-Output "::add-mask::$plain"
    "out=$plain" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
catch {
    throw "Failed to decrypt registration token: $($_.Exception.Message)"
}
finally {
    if ($aes) { $aes.Dispose() }
}
