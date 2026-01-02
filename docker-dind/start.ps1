# Start Docker daemon with firewall configuration for Calico CNI
# This script runs in a Windows hostProcess container

$ErrorActionPreference = 'Stop'

# Get the sandbox mount point (host filesystem root)
$root = $env:CONTAINER_SANDBOX_MOUNT_POINT
$dockerd = Join-Path $root 'Program Files\docker\dockerd.exe'

# Check for Kubernetes override config first, fall back to baked-in config
$k8sConfig = Join-Path $root 'docker-config-k8s\daemon.json'
$bakedConfig = Join-Path $root 'docker-config\daemon.json'

if (Test-Path $k8sConfig) {
    $config = $k8sConfig
    Write-Host "Using Kubernetes override config: $config"
} else {
    $config = $bakedConfig
    Write-Host "Using baked-in config: $config"
}

if (-not (Test-Path $config)) {
    Write-Error "No valid Docker configuration file found. Checked:`n  Kubernetes override: $k8sConfig`n  Baked-in config: $bakedConfig"
    exit 1
}
# Ensure firewall rule exists for pod network access
Write-Host "Checking firewall rule for pod network access..."
$rule = Get-NetFirewallRule -DisplayName 'Allow Docker from Pods' -ErrorAction SilentlyContinue

# Build the desired remote addresses
$remoteAddresses = @()

if (-not [string]::IsNullOrEmpty($env:FIREWALL_POD_CIDR)) {
    $remoteAddresses += $env:FIREWALL_POD_CIDR
}

if (-not [string]::IsNullOrEmpty($env:FIREWALL_NODE_CIDR)) {
    $remoteAddresses += $env:FIREWALL_NODE_CIDR
}

$desiredRemoteAddress = 'Any'
$desiredRemoteAddressDisplay = 'Any'
if ($remoteAddresses.Count -gt 0) {
    # Sort addresses to ensure consistent comparison
    $remoteAddresses = $remoteAddresses | Sort-Object
    $desiredRemoteAddress = $remoteAddresses  # Keep as array for New-NetFirewallRule
    $desiredRemoteAddressDisplay = $remoteAddresses -join ','  # String for display/comparison
}

# Check if rule needs to be created or updated
$needsUpdate = $false
if ($rule) {
    Write-Host "Firewall rule exists. Checking configuration..."
    
    # Get the current remote address configuration
    # Select the first filter if multiple exist
    $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if (-not $addressFilter) {
        Write-Host "Warning: Could not retrieve firewall address filter. Recreating rule..."
        try {
            $rule | Remove-NetFirewallRule
            $rule = $null
            $needsUpdate = $true
        } catch {
            Write-Error "Failed to remove firewall rule: $_"
            throw
        }
    } else {
        # Handle both array and single string values for RemoteAddress
        if ($addressFilter.RemoteAddress -is [array]) {
            $currentRemoteAddresses = $addressFilter.RemoteAddress
        } else {
            $currentRemoteAddresses = @($addressFilter.RemoteAddress)
        }
        
        # Sort addresses to ensure consistent comparison
        $currentRemoteAddresses = $currentRemoteAddresses | Sort-Object
        $currentRemoteAddress = $currentRemoteAddresses -join ','
        
        Write-Host "Current remote address: $currentRemoteAddress"
        Write-Host "Desired remote address: $desiredRemoteAddressDisplay"
        
        if ($currentRemoteAddress -ne $desiredRemoteAddressDisplay) {
            Write-Host "Firewall rule configuration has changed. Removing old rule..."
            try {
                $rule | Remove-NetFirewallRule
                $rule = $null
                $needsUpdate = $true
            } catch {
                Write-Error "Failed to remove firewall rule: $_"
                throw
            }
        } else {
            Write-Host "Firewall rule configuration is up to date."
        }
    }
}

# Create the rule if it doesn't exist or needs update
if (-not $rule -or $needsUpdate) {
    if ($remoteAddresses.Count -gt 0) {
        Write-Host "Creating firewall rule to allow traffic from networks ($desiredRemoteAddressDisplay) to port 2375..."
    } else {
        Write-Host "Creating firewall rule to allow traffic from any address to port 2375..."
    }
    
    New-NetFirewallRule `
        -DisplayName 'Allow Docker from Pods' `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 2375 `
        -RemoteAddress $desiredRemoteAddress `
        -Action Allow | Out-Null
    Write-Host "Firewall rule created successfully."
}

# Start Docker daemon
Write-Host "Starting Docker daemon..."
& $dockerd --config-file=$config
