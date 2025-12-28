# Start Docker daemon with firewall configuration for Calico CNI
# This script runs in a Windows hostProcess container

$ErrorActionPreference = 'Stop'

# Get the sandbox mount point (host filesystem root)
$root = $env:CONTAINER_SANDBOX_MOUNT_POINT
$dockerd = Join-Path $root 'Program Files\docker\dockerd.exe'
$config = Join-Path $root 'docker-config\daemon.json'

# Ensure firewall rule exists for pod network access
Write-Host "Checking firewall rule for pod network access..."
$rule = Get-NetFirewallRule -DisplayName 'Allow Docker from Pods' -ErrorAction SilentlyContinue

if (-not $rule) {
    $remoteAddress = 'Any'
    if ($env:FIREWALL_POD_CIDR) {
        $remoteAddress = $env:FIREWALL_POD_CIDR
        Write-Host "Creating firewall rule to allow traffic from pod network ($remoteAddress) to port 2375..."
    } else {
        Write-Host "Creating firewall rule to allow traffic from any address to port 2375..."
    }
    
    New-NetFirewallRule `
        -DisplayName 'Allow Docker from Pods' `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 2375 `
        -RemoteAddress $remoteAddress `
        -Action Allow | Out-Null
    Write-Host "Firewall rule created successfully."
} else {
    Write-Host "Firewall rule already exists."
}

# Start Docker daemon
Write-Host "Starting Docker daemon..."
& $dockerd --config-file=$config
