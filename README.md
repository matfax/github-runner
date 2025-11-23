# GitHub Runner Launcher

PowerShell watcher that detects queued self-hosted jobs across your admin repos and spins up Windows runner containers. Includes an optional WSL-hosted cache server shared across all runners.

## Prerequisites
- PowerShell 7+ (for built-in `ConvertFrom-Yaml`) or `Install-Module powershell-yaml`
- Docker Desktop with Windows containers
- WSL2 with its **own** Docker/Compose (containerd) stack running inside the distro (the Windows-host Docker integration is not used for the cache)
- For WSL Docker networking, use mirrored networking with host loopback forwarding (e.g., in `.wslconfig`: `[wsl2] networkingMode=mirrored` and `localhostForwarding=true`) so `host.docker.internal` resolves from WSL containers.
- 1Password CLI (`op`) installed and signed in on the host (installer uses it to create Connect credentials/token)
- 1Password Connect running locally (compose in `connect/`) with `connect/1password-credentials.json` present (installer tries to create it via `op`)
- GitHub PAT stored in 1Password; PAT is pulled via Connect on-demand (no long-lived caching)
- GitHub PAT (fine-grained) with at least:
  - **Repository permissions**: Actions → Read, Administration → Write, Metadata → Read (all repo-scoped)
  - Scope it to the repos/orgs you intend to watch

## Setup (installer-first)
0) Clone to the location you want to keep permanently (the install task stores this path):
   ```pwsh
   git clone <your-fork-or-repo-url> D:\Docker\gh-runner
   cd D:\Docker\gh-runner
   ```
   If you move the folder later, reinstall the scheduled task so it points to the new path.

1) Run the installer (requires host `op` signed in). Provide the secret reference (or ensure it’s already in `config.yml`):
   ```pwsh
   ./install-task.ps1 -SecretRef "op://Vault/Item/Field"
   # If connectSecretRef is already set in config.yml, you can omit -SecretRef.
   ```
   What it does:
   - Copies `config.example.yml` to `config.yml` if missing.
   - Uses host `op` and the vault derived from your secret ref to generate `connect/1password-credentials.json`.
   - Uses host `op` and the vault derived from your secret ref to create a Connect API token and writes it to `config.yml` as `connectToken`.
   - Registers the startup scheduled task pointing at this path.
   If `op` commands fail in your version, create the credentials JSON/token manually via 1Password Connect and add them to `connect/` and `config.yml`.

2) Review/edit `config.yml` to fill in repo filters and the PAT secret reference (if you didn’t pass it to the installer):
   ```pwsh
   Copy-Item config.example.yml config.yml
   ```
   Edit `config.yml`:
   ```yaml
   owner: ""             # optional
   includeRepos: []      # optional, e.g. ["user/repo1"]
   excludeRepos: []      # optional
   pollSeconds: 30
   maxLaunchPerCycle: 2
   runnerIdleTimeoutMinutes: 15
   runnerMaxRestarts: 20
   requiredLabels:
     - self-hosted
   windowsLabelRegex: (?i)windows
   linuxLabelRegex: (?i)linux
   connectUrl: "http://localhost:8181"
   connectToken: "<Connect API access token>"
   connectSecretRef: "op://<vault>/<item>/<field>"  # vault/item/field for PAT
   ```
   Only `config.example.yml` is tracked; `config.yml` is ignored by `.gitignore`.

   The PAT item must live at the secret reference you provide (`op://Vault/Item/Field`). The installer will derive the vault from this path when creating Connect credentials/token via `op`.

3) Ensure WSL can run Docker/Compose so the Connect and cache stacks can start via `wsl docker compose up -d` in `connect/` and `caching/`.

4) Run the watcher manually (even though the scheduled task is registered):
   ```pwsh
   ./watch-repos.ps1
   ```

5) (Optional) Remove the startup task if you don’t want it:
   ```pwsh
   ./uninstall-task.ps1
   ```

## Images (GHCR)
- Linux runner image is built from `linux/Dockerfile` to `ghcr.io/matfax/github-runner/runner-linux` via `.github/workflows/build-linux-image.yml`.
- Windows runner image is built from `windows/Dockerfile` to `ghcr.io/matfax/github-runner/runner-windows` via `.github/workflows/build-windows-image.yml`.
- CI behavior:
  - `push` to default branch → push `:latest`.
  - `pull_request` → build only (no push).
  - `release` (published) → push `:<release tag>`.

## Behavior
- Reads settings from `config.yml`; fetches the GitHub PAT on-demand from 1Password Connect each poll cycle and discards it after use.
- Starts the 1Password Connect stack and cache server in WSL (compose in `connect/` and `caching/`) once, shared for all runners.
- Watches admin repos (optionally filtered) for queued self-hosted jobs:
  - `windowsLabelRegex` → Windows runner via host Docker (image `ghcr.io/matfax/github-runner/runner-windows:latest`, compose file `windows/docker-compose.yml`).
  - `linuxLabelRegex` → Linux runner via WSL Docker (image `ghcr.io/matfax/github-runner/runner-linux:latest`, compose file `linux/docker-compose.yml`).
- Registration tokens are only set in the runner containers during initial configuration and are cleared before the runner starts processing jobs (`REG_TOKEN` is unset in the start scripts). Idle timeout (`runnerIdleTimeoutMinutes` / env `RUNNER_IDLE_TIMEOUT_MINUTES`) is enforced by both start scripts; idle runners exit cleanly so compose can recreate when needed.
  `runnerMaxRestarts` / env `RUNNER_MAX_RESTARTS` limits restart attempts for non-idle exits.

## Logs
- Runner logs: `docker-compose logs -f` in repo-specific projects.
- 1Password Connect logs: `wsl docker compose logs -f` from `connect/`.
- Cache logs: `wsl docker compose logs -f` from `caching/`.
