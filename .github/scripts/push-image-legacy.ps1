#Requires -Version 7
<#
.SYNOPSIS
Tags and pushes a Docker image without using Buildx

.DESCRIPTION
Retags a local test image and pushes it to the registry

.PARAMETER TestTag
Local test image tag

.PARAMETER DockerRepo
Docker repository prefix (e.g., ghcr.io/owner/)

.PARAMETER Registry
Registry name (e.g., runner)

.PARAMETER ReleasePrefix
Release tag prefix (e.g., v1.0.0- or empty)

.PARAMETER Tag
Tag name (e.g., ubuntu, windows)

.EXAMPLE
.github/scripts/push-image-legacy.ps1 -TestTag "runner-linux-local" -DockerRepo "ghcr.io/owner/" -Registry "runner" -ReleasePrefix "" -Tag "ubuntu"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TestTag,
    
    [Parameter(Mandatory = $true)]
    [string]$DockerRepo,
    
    [Parameter(Mandatory = $true)]
    [string]$Registry,
    
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ReleasePrefix,
    
    [Parameter(Mandatory = $true)]
    [string]$Tag
)

$ErrorActionPreference = 'Stop'

$releaseTag = "${DockerRepo}${Registry}:${ReleasePrefix}${Tag}"

docker tag $TestTag $releaseTag
if ($LASTEXITCODE -ne 0) { throw "docker tag failed (exit code $LASTEXITCODE)." }
docker push $releaseTag
if ($LASTEXITCODE -ne 0) { throw "docker push failed (exit code $LASTEXITCODE)." }