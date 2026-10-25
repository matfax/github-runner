$script:KubeProjectLabel = "github-runner/project"
$script:KubePlatformLabel = "github-runner/platform"
$script:KubeRepoAnnotation = "github-runner/repository"

function ConvertTo-KubeName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [int]$MaxLength = 63
    )

    # DNS-1123 label: lowercase alphanumerics and '-', must start/end alphanumeric.
    $Name = (($Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-') -replace '-+', '-').Trim('-')
    if ($Name.Length -gt $MaxLength) {
        $Hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).Substring(0, 8).ToLowerInvariant()
        $Name = "$($Name.Substring(0, $MaxLength - 9).TrimEnd('-'))-$Hash"
    }
    return $Name
}

function Invoke-Kubectl {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$InputText
    )

    $Output = if ($InputText) { $InputText | kubectl @Arguments } else { kubectl @Arguments }
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments[0..1] -join ' ') failed (exit code $LASTEXITCODE)."
    }
    return ($Output -join "`n")
}

function Test-KubeRunnerActive {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$Project
    )

    $Selector = "$($script:KubeProjectLabel)=$(ConvertTo-KubeName -Value $Project)"
    $Jobs = (Invoke-Kubectl -Arguments @("get", "jobs", "-n", $Namespace, "-l", $Selector, "-o", "json") | ConvertFrom-Json).items

    # A Job counts as active until it reaches a terminal condition, including while its pod is still pulling images.
    foreach ($Job in $Jobs) {
        $Finished = $Job.status.conditions | Where-Object { $_.type -in @("Complete", "Failed") -and $_.status -eq "True" }
        if (-not $Finished) { return $true }
    }
    return $false
}

function Start-KubeRunner {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Repo,
        [Parameter(Mandatory = $true)]
        [string]$RegToken,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [ValidateSet("windows", "linux")]
        [string]$Platform,
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [int]$RunnerIdleTimeoutMinutes = 15,
        [int]$RunnerMaxRestarts = 20,
        [string]$RunnerLabels = "",
        [string]$RunnerName = ""
    )

    if ([string]::IsNullOrWhiteSpace($RegToken)) {
        throw "Registration token was empty; cannot continue."
    }
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Runner Job template not found at '$TemplatePath'."
    }

    $RepoUrl = if ($Repo.html_url) { $Repo.html_url } else { "https://github.com/$($Repo.full_name)" }
    if (-not $RunnerName) { $RunnerName = $Project }

    # Random suffix lets a new Job start while a finished one with the same project is still being garbage-collected.
    $Suffix = -join ((97..122) + (48..57) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
    $JobName = "$(ConvertTo-KubeName -Value $Project -MaxLength 50)-$Suffix"
    $SecretName = "$JobName-token"
    $Labels = @{
        $script:KubeProjectLabel  = ConvertTo-KubeName -Value $Project
        $script:KubePlatformLabel = $Platform
    }

    $Job = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $TemplatePath -Raw)
    $Job.metadata.name = $JobName
    $Job.metadata.namespace = $Namespace
    foreach ($Meta in @($Job.metadata, $Job.spec.template.metadata)) {
        if (-not $Meta.labels) { $Meta.labels = @{} }
        foreach ($Key in $Labels.Keys) { $Meta.labels[$Key] = $Labels[$Key] }
    }
    if (-not $Job.metadata.annotations) { $Job.metadata.annotations = @{} }
    $Job.metadata.annotations[$script:KubeRepoAnnotation] = $Repo.full_name

    $Container = $Job.spec.template.spec.containers | Where-Object { $_.name -eq "runner" } | Select-Object -First 1
    if (-not $Container) {
        throw "Runner Job template '$TemplatePath' has no container named 'runner'."
    }
    $Container.env = @($Container.env | Where-Object { $_ }) + @(
        @{ name = "REPO_URL"; value = $RepoUrl },
        @{ name = "RUNNER_NAME"; value = $RunnerName },
        @{ name = "RUNNER_LABELS"; value = $RunnerLabels },
        @{ name = "RUNNER_IDLE_TIMEOUT_MINUTES"; value = [string]$RunnerIdleTimeoutMinutes },
        @{ name = "RUNNER_MAX_RESTARTS"; value = [string]$RunnerMaxRestarts },
        @{ name = "REG_TOKEN"; valueFrom = @{ secretKeyRef = @{ name = $SecretName; key = "REG_TOKEN" } } }
    )

    # The token goes through stdin so it never shows up in process arguments or the Job spec.
    $Secret = @{
        apiVersion = "v1"
        kind       = "Secret"
        type       = "Opaque"
        metadata   = @{ name = $SecretName; namespace = $Namespace; labels = $Labels }
        stringData = @{ REG_TOKEN = $RegToken }
    }

    Write-Host "🚀 Launching $Platform runner Job $JobName (project $Project)..." -ForegroundColor Green
    $null = Invoke-Kubectl -Arguments @("create", "-f", "-") -InputText ($Secret | ConvertTo-Json -Depth 10)
    try {
        $Created = Invoke-Kubectl -Arguments @("create", "-f", "-", "-o", "json") -InputText ($Job | ConvertTo-Json -Depth 50) | ConvertFrom-Json
    } catch {
        kubectl delete secret $SecretName -n $Namespace --ignore-not-found | Out-Null
        throw
    }

    # Tie the Secret's lifetime to the Job so it is garbage-collected with it.
    $OwnerPatch = @{
        metadata = @{
            ownerReferences = @(@{ apiVersion = "batch/v1"; kind = "Job"; name = $JobName; uid = $Created.metadata.uid })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $null = Invoke-Kubectl -Arguments @("patch", "secret", $SecretName, "-n", $Namespace, "--type", "merge", "-p", $OwnerPatch)

    Write-Host "✅ $Platform runner Job $JobName created." -ForegroundColor Gray
}
