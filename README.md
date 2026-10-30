# GitHub Runner Launcher

PowerShell watcher that runs in Kubernetes (built for an RKE2 home lab), detects queued self-hosted jobs across every repo a GitHub App is installed on, and launches a runner Job for each. Linux and Windows runners are supported, and a shared Actions cache server runs alongside.

Why not ARC? GitHub only offers runners at repo, org or enterprise level. On a personal account, ARC needs a scale set per repo; this watcher covers all your repos automatically.

## How it works
- The watcher (`charts/runner-watcher`) polls GitHub with a short-lived GitHub App installation token.
- For each repo with a queued job whose labels include `requiredLabels` and match the Linux or Windows regex, it mints a registration token and creates a Kubernetes Job from the platform's template.
  - **Linux**: `ghcr.io/matfax/github-runner/runner:ubuntu` with a privileged `docker:dind` sidecar on the pod's loopback. The workspace and runner externals are shared with the sidecar so `container:` jobs and bind mounts work.
  - **Windows**: `ghcr.io/matfax/github-runner/runner:windows`, scheduled next to the `docker-dind` chart and using it via `DOCKER_HOST=tcp://$(NODE_IP):2375`.
- At most one runner Job per repo and platform runs at a time. Runners exit after `idleTimeoutMinutes` without work; finished Jobs are removed after `ttlSecondsAfterFinished`, and stale runner registrations are deleted from GitHub.
- Registration tokens are passed in a per-Job Secret (owned by the Job, so it's garbage-collected with it) and unset by the start scripts after configuration.
- Runners get `CUSTOM_ACTIONS_RESULTS_URL` pointing at the in-cluster cache server (falcondev-oss/github-actions-cache-server).

## Prerequisites
- RKE2 (Kubernetes 1.29+, for native sidecars) with Linux nodes; for Windows runners, a Windows Server 2022 agent node (the runner image is `ltsc2022`).
- Helm 3.
- A namespace that allows privileged pods (Linux dind sidecar, Windows hostProcess dockerd). Only needed with RKE2's CIS profile:
  ```bash
  kubectl create namespace github-runners
  kubectl label namespace github-runners pod-security.kubernetes.io/enforce=privileged
  ```
- A default StorageClass for the cache PVC (e.g. local-path or Longhorn), or set `cache.persistence.storageClass`.

## Setup
1) Create a GitHub App (Settings → Developer settings → GitHub Apps → New):
   - Webhook: uncheck **Active** (the watcher polls).
   - Repository permissions: **Administration: Read and write** (registration tokens, runner cleanup), **Actions: Read** (queued jobs), Metadata: Read.
   - Install it on your account for all repositories, or only those the watcher should serve.
   - Generate a private key and note the App ID (and the installation ID from the installation's URL, optional).

2) Store the App credentials in the namespace:
   ```bash
   kubectl -n github-runners create secret generic github-app --from-literal=app-id=<app id> --from-literal=installation-id=<installation id> --from-file=private-key=<app>.private-key.pem
   ```
   `installation-id` can be left out when the App has a single installation (or set `watcher.owner` to pick one).

3) For Windows runners, install the Docker daemon chart on the Windows node:
   ```bash
   helm repo add github-runner https://runner.actions.fyi
   helm install docker-dind github-runner/docker-dind -n github-runners
   ```
   It serves mutual TLS on port 2376 with a Docker daemon per repository (client certificate CN `owner/repo`); configure `tls.*` for your certificates. Its firewall admits RKE2's pod CIDR `10.42.0.0/16`; set `firewall.podCIDR` if yours differs. See [docker-dind/README.md](docker-dind/README.md).

4) Install the watcher:
   ```bash
   helm install runner-watcher ./charts/runner-watcher -n github-runners
   ```
   Useful values (see [values.yaml](charts/runner-watcher/values.yaml)):
   ```yaml
   watcher:
     owner: ""             # optional owner filter
     includeRepos: []      # optional, e.g. ["user/repo1"]
     excludeRepos: []
     requiredLabels: [self-hosted, orchestrated]
   runners:
     idleTimeoutMinutes: 15
     windows:
       enabled: false      # Linux-only cluster
   cache:
     persistence:
       size: 20Gi
   ```

5) Target the runners from a workflow:
   ```yaml
   runs-on: [self-hosted, orchestrated, linux]
   ```

## Running the watcher outside the cluster
With a kubeconfig pointing at the cluster, the watcher also runs locally (PowerShell 7, `kubectl`, `Install-Module powershell-yaml`):
```pwsh
Copy-Item config.example.yml config.yml   # point runnerTemplates at rendered Job manifests and set namespace
$env:GITHUB_APP_ID = "<app id>"
$env:GITHUB_APP_PRIVATE_KEY_PATH = "<app>.private-key.pem"
./watch-repos.ps1
```
Render the Job templates with `helm template runner-watcher ./charts/runner-watcher -s templates/configmap.yaml`.

## Images (GHCR)
- `ghcr.io/matfax/github-runner/watcher:latest` from the root [Dockerfile](Dockerfile) (watcher scripts, PowerShell, kubectl).
- `ghcr.io/matfax/github-runner/runner:ubuntu` from `linux/Dockerfile`, `runner:windows` from `windows/Dockerfile`.
- `ghcr.io/matfax/github-runner/docker-dind` from `docker-dind/Dockerfile`.
- CI behavior:
  - `push` to default branch → push `:latest`.
  - `pull_request` → build only (no push).
  - `release` (published) → push `:<release tag>`.

CI still smoke-tests the runner images with docker compose (`launch.ps1`, `linux/` and `windows/docker-compose.yml`); the watcher itself no longer uses compose.

## Logs
- Watcher: `kubectl -n github-runners logs -f deploy/runner-watcher`
- Runner Jobs: `kubectl -n github-runners get jobs -l app.kubernetes.io/component=runner`, then `kubectl logs job/<name> -c runner` (Linux dind sidecar: `-c dind`).
- Cache: `kubectl -n github-runners logs -f deploy/runner-watcher-cache`
