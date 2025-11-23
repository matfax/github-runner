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
