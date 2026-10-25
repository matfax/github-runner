#Requires -Version 7
<#
.SYNOPSIS
Tests a Docker container by starting it and verifying it reaches running state

.DESCRIPTION
Starts a container, waits for it to reach running state, captures logs, then cleans up

.PARAMETER ImageTag
Docker image tag to test

.PARAMETER ContainerName
Name for the test container

.PARAMETER TimeoutSeconds
Maximum seconds to wait for container to start (default: 60)

.EXAMPLE
.github/scripts/test-container.ps1 -ImageTag "docker-dind:test" -ContainerName "dind-test-123"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ImageTag,
    
    [Parameter(Mandatory = $true)]
    [string]$ContainerName,
    
    [Parameter()]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

Write-Host "Starting test container '$ContainerName' from image '$ImageTag'..."

docker run -d --name $ContainerName $ImageTag

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$running = $false

while ((Get-Date) -lt $deadline) {
    $stateJson = docker inspect --format "{{json .State}}" $ContainerName 2>$null
    if (-not $stateJson) {
        Start-Sleep -Seconds 2
        continue
    }
    
    $state = $stateJson | ConvertFrom-Json
    if ($state.Running) {
        $running = $true
        break
    }
    
    Start-Sleep -Seconds 2
}

$logs = docker logs $ContainerName
Write-Host "Container logs:"
Write-Host $logs

docker rm --force $ContainerName | Out-Null

if (-not $running) {
    throw "Container did not reach running state within $TimeoutSeconds seconds"
}

Write-Host "✅ Basic container test passed"
