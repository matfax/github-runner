function New-RegistrationToken {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PatToken,
        [Parameter(Mandatory = $true)]
        [string]$RepoFullName
    )

    if ([string]::IsNullOrWhiteSpace($PatToken)) {
        throw "PAT token is required to mint a registration token."
    }

    $FullName = $RepoFullName.Trim('/')
    $PathParts = $FullName.Split('/')
    if ($PathParts.Count -lt 1 -or $PathParts.Count -gt 2) {
        throw "RepoFullName must be 'owner/repo' or 'org'."
    }

    if ($PathParts.Count -eq 2) {
        $ApiUrl = "https://api.github.com/repos/$($PathParts[0])/$($PathParts[1])/actions/runners/registration-token"
    } else {
        $ApiUrl = "https://api.github.com/orgs/$($PathParts[0])/actions/runners/registration-token"
    }

    $Headers = @{
        "Authorization"        = "Bearer $PatToken"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    try {
        $Response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $Headers -ErrorAction Stop
        if (-not $Response.token) { throw "Empty registration token returned." }
        return $Response.token
    } catch {
        throw "Failed to create registration token: $($_.Exception.Message)"
    }
}

function Remove-Runner {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PatToken,
        [Parameter(Mandatory = $true)]
        [string]$RepoFullName,
        [Parameter(Mandatory = $true)]
        [string]$RunnerName
    )

    if ([string]::IsNullOrWhiteSpace($PatToken)) {
        Write-Warning "PAT token is required to remove a runner. Skipping removal."
        return
    }

    $FullName = $RepoFullName.Trim('/')
    $PathParts = $FullName.Split('/')
    if ($PathParts.Count -lt 1 -or $PathParts.Count -gt 2) {
        Write-Warning "RepoFullName must be 'owner/repo' or 'org'. Skipping removal."
        return
    }

    if ($PathParts.Count -eq 2) {
        $ListUrl = "https://api.github.com/repos/$($PathParts[0])/$($PathParts[1])/actions/runners"
    } else {
        $ListUrl = "https://api.github.com/orgs/$($PathParts[0])/actions/runners"
    }

    $Headers = @{
        "Authorization"        = "Bearer $PatToken"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    try {
        # List all runners to find the ID by name
        $Response = Invoke-RestMethod -Uri $ListUrl -Method Get -Headers $Headers -ErrorAction Stop
        $Runner = $Response.runners | Where-Object { $_.name -eq $RunnerName } | Select-Object -First 1

        if (-not $Runner) {
            Write-Host "ℹ️ Runner '$RunnerName' not found in GitHub. May have already been removed."
            return
        }

        # Delete the runner by ID
        if ($PathParts.Count -eq 2) {
            $DeleteUrl = "https://api.github.com/repos/$($PathParts[0])/$($PathParts[1])/actions/runners/$($Runner.id)"
        } else {
            $DeleteUrl = "https://api.github.com/orgs/$($PathParts[0])/actions/runners/$($Runner.id)"
        }

        Invoke-RestMethod -Uri $DeleteUrl -Method Delete -Headers $Headers -ErrorAction Stop
        Write-Host "✅ Successfully removed runner '$RunnerName' (ID: $($Runner.id)) from GitHub."
    } catch {
        Write-Warning "Failed to remove runner '$RunnerName' from GitHub: $($_.Exception.Message)"
    }
}
