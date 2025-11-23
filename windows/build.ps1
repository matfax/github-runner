$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- GITHUB RUNNER AGENT (falcondev fork) ---
Write-Host "🏃 Downloading latest falcondev-oss GitHub Runner..." -ForegroundColor Cyan
$LatestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/falcondev-oss/github-actions-runner/releases/latest"
$Version = $LatestRelease.tag_name -replace '^v',''
$Url = "https://github.com/falcondev-oss/github-actions-runner/releases/download/v$Version/actions-runner-win-x64-$Version.zip"

New-Item -ItemType Directory -Force -Path "C:\actions-runner" | Out-Null
Invoke-WebRequest -Uri $Url -OutFile "C:\actions-runner\runner.zip"
Expand-Archive -Path "C:\actions-runner\runner.zip" -DestinationPath "C:\actions-runner"
Remove-Item "C:\actions-runner\runner.zip" -Force

Write-Host "✅ Build Complete."
