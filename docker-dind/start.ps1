# Starts the docker-dind gateway in a Windows HostProcess container (or a plain container for testing).
# Before that it sets up the Windows Firewall rules the service relies on:
#   - inbound TCP 2376 (the mutual-TLS gateway) from the configured networks only;
#   - for build containers (the tenant NAT pool): no outbound traffic to private, cluster or node
#     addresses, and no inbound connections at all.

$ErrorActionPreference = 'Stop'

$root = if ($env:CONTAINER_SANDBOX_MOUNT_POINT) { $env:CONTAINER_SANDBOX_MOUNT_POINT } else { 'C:\' }
$gateway = Join-Path $root 'dind\gateway.exe'

# The Kubernetes ConfigMap overrides the baked-in config
$k8sConfig = Join-Path $root 'docker-config-k8s\gateway.json'
$bakedConfig = Join-Path $root 'dind\gateway.json'
$config = if (Test-Path $k8sConfig) { $k8sConfig } else { $bakedConfig }
Write-Host "Using gateway config: $config"

& $gateway -config $config -check
if ($LASTEXITCODE -ne 0) { throw "Gateway configuration or certificates are invalid (see above)." }

function Set-FirewallRule {
    param([string]$Name, [string]$DisplayName, [hashtable]$Settings)
    # Recreate on every start so changed settings always apply
    Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $Name -DisplayName $DisplayName -Group 'docker-dind' @Settings | Out-Null
    Write-Host "Firewall rule '$DisplayName' set."
}

if ($env:FIREWALL_ENABLED -ne 'false') {
    # Rule of earlier chart versions for the unauthenticated port 2375
    Get-NetFirewallRule -DisplayName 'Allow Docker from Pods' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    $disabled = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled } | ForEach-Object Name)
    if ($disabled.Count -gt 0) {
        $msg = "Windows Firewall is disabled for profile(s) $($disabled -join ', '); its rules (port 2376 and build container isolation) have no effect."
        if ($env:FIREWALL_REQUIRED -ne 'false') {
            throw "$msg Enable the profiles (Set-NetFirewallProfile -Enabled True) or set firewall.required=false."
        }
        Write-Warning $msg
    }

    # Inbound 2376 for the gateway
    $allowFrom = @($env:FIREWALL_POD_CIDR, $env:FIREWALL_NODE_CIDR) -split ',' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($allowFrom.Count -eq 0) { $allowFrom = @('Any') }
    Set-FirewallRule -Name 'docker-dind-gateway' -DisplayName 'docker-dind: gateway (TCP 2376)' -Settings @{
        Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = 2376; RemoteAddress = $allowFrom; Action = 'Allow'
    }

    # Build containers: block rules take precedence over any allow rule
    $plan = & $gateway -config $config -firewall-plan | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Could not compute the build container firewall rules." }
    Set-FirewallRule -Name 'docker-dind-build-egress' -DisplayName 'docker-dind: build containers to private networks' -Settings @{
        Direction = 'Outbound'; Protocol = 'Any'; LocalAddress = $plan.pool; RemoteAddress = $plan.block; Action = 'Block'
    }
    Set-FirewallRule -Name 'docker-dind-build-ingress' -DisplayName 'docker-dind: connections into build containers' -Settings @{
        Direction = 'Inbound'; Protocol = 'Any'; LocalAddress = $plan.pool; Action = 'Block'
    }
    Write-Host "Build containers ($($plan.pool)) may not reach: $($plan.block -join ', ')"
} else {
    Write-Warning 'Firewall management is disabled: build containers can reach private networks and nothing restricts port 2376 to the pod network.'
}

Write-Host 'Starting docker-dind gateway...'
& $gateway -config $config
exit $LASTEXITCODE
