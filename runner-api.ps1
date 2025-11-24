function Get-RunnerApiBaseUri {
    param ([string]$RepoFullName)

    $FullName = $RepoFullName.Trim('/')
    $Parts = $FullName.Split('/')
    if ($Parts.Count -lt 1 -or $Parts.Count -gt 2) {
        throw "RepoFullName must be 'owner/repo' or 'org'."
    }

    if ($Parts.Count -eq 2) {
        return "https://api.github.com/repos/$($Parts[0])/$($Parts[1])"
    }

    return "https://api.github.com/orgs/$($Parts[0])"
}

function New-GitHubHeaders {
    param ([string]$PatToken)

    return @{
        "Authorization"        = "Bearer $PatToken"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "gh-runner-auto-launch"
    }
}

function Get-RunnersForRepo {
    param (
        [hashtable]$Headers,
        [string]$RepoFullName
    )

    $BaseUrl = Get-RunnerApiBaseUri -RepoFullName $RepoFullName
    $Runners = @()
    $Page = 1
    while ($true) {
        $Uri = "$BaseUrl/actions/runners?per_page=100&page=$Page"
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers -ErrorAction Stop
        if ($Response.runners) { $Runners += $Response.runners }
        if (-not $Response.runners -or $Response.runners.Count -lt 100) { break }
        $Page++
    }

    return $Runners
}

function Get-RunnerIdByName {
    param (
        [hashtable]$Headers,
        [string]$RepoFullName,
        [string]$RunnerName
    )

    if (-not $RunnerName) { return $null }
    $Runners = Get-RunnersForRepo -Headers $Headers -RepoFullName $RepoFullName
    $Match = $Runners | Where-Object { $_.name -eq $RunnerName } | Select-Object -First 1
    return $(if ($Match) { $Match.id } else { $null })
}

function Remove-RunnerByName {
    param (
        [hashtable]$Headers,
        [string]$RepoFullName,
        [string]$RunnerName
    )

    if (-not $RunnerName) { throw "RunnerName is required for deletion." }

    $RunnerId = Get-RunnerIdByName -Headers $Headers -RepoFullName $RepoFullName -RunnerName $RunnerName
    if (-not $RunnerId) { return $false }

    $BaseUrl = Get-RunnerApiBaseUri -RepoFullName $RepoFullName
    $DeleteUri = "$BaseUrl/actions/runners/$RunnerId"
    Invoke-RestMethod -Uri $DeleteUri -Method Delete -Headers $Headers -ErrorAction Stop | Out-Null
    return $true
}
