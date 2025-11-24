param (
    [string]$RepoUrl = $env:REPO_URL,
    [string]$RegToken = $env:REG_TOKEN,
    [string]$PatToken = $env:PAT_TOKEN,
    [int]$IdleTimeoutMinutes = $(if ($env:RUNNER_IDLE_TIMEOUT_MINUTES) { [int]$env:RUNNER_IDLE_TIMEOUT_MINUTES } else { 15 }),
    [int]$MaxRestarts = $(if ($env:RUNNER_MAX_RESTARTS) { [int]$env:RUNNER_MAX_RESTARTS } else { 20 }),
    [string]$LabelsEnv = $(if ($env:RUNNER_LABELS) { $env:RUNNER_LABELS } else { "windows,docker,server-core" })
)

# Validation
if (-not $RepoUrl) {
    Write-Error "Error: REPO_URL environment variable is missing."
    exit 1
}

$ErrorActionPreference = "Stop"
$RunnerName = "win-" + $env:COMPUTERNAME
$RunnerConfigured = Test-Path ".\\.runner"

# Cleanup function to deregister runner from GitHub
function Cleanup-Runner {
    if ($PatToken -and (Test-Path ".\\.runner")) {
        Write-Host "🧹 Deregistering runner from GitHub..."
        try {
            .\\config.cmd remove --token $PatToken
            Write-Host "✅ Runner deregistered successfully."
        } catch {
            Write-Warning "⚠️ Failed to deregister runner: $_"
        }
    }
}

try {
    # 1. Configure only if not already registered (non-ephemeral)
    if (-not $RunnerConfigured) {
        if (-not $RegToken) {
            Write-Error "Error: REG_TOKEN environment variable is missing for initial configuration."
            exit 1
        }

        Write-Host "⚙️ Configuring Runner: $RunnerName (initial)"
        ./config.cmd --url $RepoUrl --token $RegToken --name $RunnerName --unattended --work _work --labels $LabelsEnv
        $env:REG_TOKEN = $null
    } else {
        Write-Host "ℹ️ Runner already configured. Skipping configuration."
    }

    # 2. Run with idle timeout watchdog (exit 0 on idle; non-idle exit triggers restart)
    Write-Host "✅ Listening for jobs..."
    $DiagPath = Join-Path (Get-Location) "_diag"

    $RestartCount = 0

    while ($RestartCount -lt $MaxRestarts) {
        $RunnerProc = Start-Process -FilePath ".\\run.cmd" -PassThru -WindowStyle Hidden
        $LastActivity = Get-Date
        $IdleStop = $false

        while (-not $RunnerProc.HasExited) {
            if (Test-Path $DiagPath) {
                $LatestLog = Get-ChildItem -Path $DiagPath -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($LatestLog) {
                    $LastActivity = $LatestLog.LastWriteTime
                }
            }

            $IdleMinutes = (New-TimeSpan -Start $LastActivity -End (Get-Date)).TotalMinutes
            if ($IdleMinutes -ge $IdleTimeoutMinutes) {
                Write-Host "⏱️ Idle timeout ($IdleTimeoutMinutes min) reached. Stopping runner..."
                $IdleStop = $true
                try { Stop-Process -Id $RunnerProc.Id -Force } catch {}
                break
            }

            Start-Sleep -Seconds 10
        }

        if (-not $RunnerProc.HasExited) {
            $RunnerProc.WaitForExit()
        }

        if ($IdleStop) {
            Write-Host "🛑 Runner stopped due to idle timeout. Exiting container."
            exit 0
        }

        Write-Host "⚠️ Runner exited (code $($RunnerProc.ExitCode)). Restarting run.cmd inside container..."
        $RestartCount++
        if ($RestartCount -ge $MaxRestarts) {
            Write-Host "❌ Max restarts ($MaxRestarts) reached. Exiting container."
            exit 1
        }
        Start-Sleep -Seconds 5
    }
} finally {
    # Always attempt to cleanup the runner on exit
    Cleanup-Runner
}
