#Requires -Version 7
<#
.SYNOPSIS
Integration test for the runner-watcher chart and the watcher's Kubernetes launcher

.DESCRIPTION
Expects kubectl and helm pointed at a disposable cluster (e.g. kind). Syntax-checks the watcher
scripts, installs the chart with a dummy GitHub App secret, then launches one runner Job per
platform through Start-KubeRunner using the Job templates the chart rendered.

.PARAMETER Namespace
Namespace to install into (created if missing)

.EXAMPLE
.github/scripts/test-watcher.ps1 -Namespace runner-watcher-test
#>
param(
    [Parameter()]
    [string]$Namespace = "runner-watcher-test"
)

$ErrorActionPreference = 'Stop'

# Syntax check
$ParseErrors = foreach ($Script in Get-ChildItem -Path . -Filter *.ps1) {
    $Errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Script.FullName, [ref]$null, [ref]$Errors)
    $Errors | ForEach-Object { "$($Script.Name):$($_.Extent.StartLineNumber) $($_.Message)" }
}
if ($ParseErrors) {
    $ParseErrors | ForEach-Object { Write-Host "::error::$_" }
    throw "PowerShell parse errors found."
}
Write-Host "✅ Watcher scripts parse."

# Chart install; the watcher itself crash-loops on the dummy key, the API server still validates every object
kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $Namespace create secret generic github-app --from-literal=app-id=1 --from-literal=private-key=dummy
helm install runner-watcher charts/runner-watcher -n $Namespace --set cache.persistence.enabled=false
if ($LASTEXITCODE -ne 0) { throw "helm install failed (exit code $LASTEXITCODE)." }
Write-Host "✅ Chart installed."

# Launch one Job per platform through the watcher's own code
Install-Module powershell-yaml -Scope CurrentUser -Force
Import-Module powershell-yaml
. ./kube-launch.ps1

$ConfigMap = kubectl -n $Namespace get configmap runner-watcher -o json | ConvertFrom-Json
$Repo = [pscustomobject]@{ full_name = "matfax/github-runner"; html_url = "https://github.com/matfax/github-runner" }

foreach ($Platform in @("linux", "windows")) {
    $TemplatePath = Join-Path ([IO.Path]::GetTempPath()) "runner-$Platform.yaml"
    Set-Content -LiteralPath $TemplatePath -Value $ConfigMap.data."runner-$Platform.yaml"
    $Project = "test-$Platform"

    Start-KubeRunner -Repo $Repo -RegToken "dummy" -Project $Project -Platform $Platform -TemplatePath $TemplatePath -Namespace $Namespace -RunnerLabels "self-hosted,$Platform"

    if (-not (Test-KubeRunnerActive -Namespace $Namespace -Project $Project)) {
        throw "Job for $Project is not reported as active."
    }

    $Secret = (kubectl -n $Namespace get secrets -l "github-runner/project=$Project" -o json | ConvertFrom-Json).items | Select-Object -First 1
    if ($Secret.metadata.ownerReferences[0].kind -ne "Job") {
        throw "Registration token Secret for $Project is not owned by its Job."
    }
    Write-Host "✅ $Platform runner Job created and tracked."
}
