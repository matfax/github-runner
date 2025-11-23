param (
    [string]$TaskName = "GH Runner Watcher",
    [string]$ScriptPath = (Join-Path $PSScriptRoot "watch-repos.ps1"),
    [string]$Vault = "",
    [string]$SecretRef = ""
)

$ErrorActionPreference = "Stop"

$ConnectDir = Join-Path $PSScriptRoot "connect"
$ConnectCredsPath = Join-Path $ConnectDir "1password-credentials.json"
$ConfigPath = Join-Path $PSScriptRoot "config.yml"
$ConfigExamplePath = Join-Path $PSScriptRoot "config.example.yml"

if (-not (Test-Path $ScriptPath)) {
    throw "watch-repos script not found at '$ScriptPath'."
}

try {
    $ResolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
} catch {
    throw "Failed to resolve script path '$ScriptPath': $($_.Exception.Message)"
}

$RepoRoot = Split-Path -Path $ResolvedScript -Parent

# Helpers
function Install-YamlModule {
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Write-Host "📦 Installing powershell-yaml for current user..." -ForegroundColor Cyan
        try {
            Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Failed to install powershell-yaml. Ensure PowerShell 7+ is available or install the module manually."
        }
    }
}

function Get-ConfigFromFile {
    param([string]$Path)
    $Raw = Get-Content -LiteralPath $Path -Raw
    return ConvertFrom-Yaml -Yaml $Raw
}

function Set-ConfigFile {
    param([string]$Path, [object]$Config)
    if (-not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        Write-Warning "ConvertTo-Yaml unavailable; cannot persist connectToken automatically. Install PowerShell 7+ or powershell-yaml."
        return
    }
    $Yaml = ConvertTo-Yaml -Data $Config
    Set-Content -LiteralPath $Path -Value $Yaml -Encoding UTF8
}

function Test-HostOp {
    if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        throw "1Password CLI (op) is required on the host. Install it and sign in before running this installer."
    }
}

function Parse-OpSecretRef {
    param ([string]$SecretRef)

    if ([string]::IsNullOrWhiteSpace($SecretRef)) {
        throw "connectSecretRef is required in config.yml (format: op://Vault/Item/Field)."
    }

    if ($SecretRef -notmatch '^op:\/\/([^\/]+)\/([^\/]+)\/(.+)$') {
        throw "connectSecretRef must be in format op://Vault/Item/Field (got '$SecretRef')."
    }

    return @{
        Vault = $Matches[1]
        Item  = $Matches[2]
        Field = $Matches[3]
    }
}

function New-ConnectCredentialsFile {
    if (Test-Path $ConnectCredsPath) { return }
    if ([string]::IsNullOrWhiteSpace($Vault)) {
        throw "Vault name or ID is required (pass -Vault or set connectSecretRef) to create connect/1password-credentials.json."
    }

    Write-Host "🔐 Generating 1Password Connect credentials via host 'op'..." -ForegroundColor Cyan
    $Attempts = @(
        @{ Args = @("connect", "credentials", "get", "--vault", $Vault, "--format", "json"); Label = "op connect credentials get" },
        @{ Args = @("connect", "server", "create", "--name", "gh-runner-connect", "--vault", $Vault, "--format", "json"); Label = "op connect server create" }
    )

    foreach ($Attempt in $Attempts) {
        try {
            $Output = & op @($Attempt.Args) 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($Output)) {
                $Output | Out-File -LiteralPath $ConnectCredsPath -Encoding UTF8 -Force
                Write-Host "   Created connect/1password-credentials.json using '$($Attempt.Label)'." -ForegroundColor Gray
                return
            }
        } catch {}
    }

    throw "Could not generate connect/1password-credentials.json via 'op'. Create it manually per https://developer.1password.com/docs/connect/get-started/ and rerun."
}

function Set-ConnectToken {
    param([hashtable]$Config)

    if ($Config.connectToken -and -not [string]::IsNullOrWhiteSpace($Config.connectToken)) {
        return $Config.connectToken
    }

    if ([string]::IsNullOrWhiteSpace($Vault)) {
        throw "Vault name or ID is required (derive it from connectSecretRef or pass -Vault/-SecretRef) to create a Connect API token."
    }

    Write-Host "🔑 Creating 1Password Connect API token via host 'op' (vault: $Vault)..." -ForegroundColor Cyan
    $Token = $null

    # Try generic token create; newer CLIs may support --format json with 'token' field
    try {
        $Output = & op connect token create --vault $Vault --format json 2>$null
        if ($LASTEXITCODE -eq 0 -and $Output) {
            try {
                $Obj = $Output | ConvertFrom-Json
                if ($Obj.token) { $Token = $Obj.token }
            } catch {
                $Token = ($Output | Out-String).Trim()
            }
        }
    } catch {}

    if (-not $Token) {
        Write-Warning "Could not create Connect API token via 'op'. Create one manually and set connectToken in $ConfigPath."
        return $null
    }

    $Config.connectToken = $Token
    Write-Host "   Stored Connect API token in config.yml (connectToken)." -ForegroundColor Gray
    return $Token
}

# Ensure config exists
if (-not (Test-Path $ConfigPath)) {
    if (-not (Test-Path $ConfigExamplePath)) {
        throw "Config example not found at '$ConfigExamplePath'."
    }
    Copy-Item $ConfigExamplePath $ConfigPath
    Write-Host "ℹ️ Created config.yml from example. Fill in Connect values before running." -ForegroundColor Yellow
}

Test-HostOp
Install-YamlModule

# Load config and ensure Connect assets
$Config = Get-ConfigFromFile -Path $ConfigPath
if (-not $Config.connectUrl) { $Config | Add-Member -NotePropertyName connectUrl -NotePropertyValue "http://localhost:8181" -Force }
if (-not $Config.connectSecretRef) { $Config | Add-Member -NotePropertyName connectSecretRef -NotePropertyValue "" -Force }

# Determine secret reference (param overrides config)
$SecretRefEffective = if (-not [string]::IsNullOrWhiteSpace($SecretRef)) { $SecretRef } else { $Config.connectSecretRef }
if ([string]::IsNullOrWhiteSpace($SecretRefEffective)) {
    throw "connectSecretRef must be provided via config.yml or -SecretRef (format: op://Vault/Item/Field)."
}

# Persist provided secret ref into config
if (-not $Config.connectSecretRef -or [string]::IsNullOrWhiteSpace($Config.connectSecretRef)) {
    $Config.connectSecretRef = $SecretRefEffective
}

# Derive vault from secret ref if not provided as parameter
if (-not $Vault -or [string]::IsNullOrWhiteSpace($Vault)) {
    $ParsedRef = Parse-OpSecretRef -SecretRef $SecretRefEffective
    $Vault = $ParsedRef.Vault
}

New-ConnectCredentialsFile
$Token = Set-ConnectToken -Config $Config
if ($Token) {
    Set-ConfigFile -Path $ConfigPath -Config $Config
}

# Create scheduled task
$ActionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ResolvedScript`""
$Action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument $ActionArgs -WorkingDirectory $RepoRoot
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    throw "Scheduled task '$TaskName' already exists. Run uninstall-task.ps1 first if you want to recreate it."
}

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Description "Start GH runner watcher with WSL cache"

Write-Host "✅ Scheduled task '$TaskName' registered to start at boot."
Write-Host "   Script: $ResolvedScript"
