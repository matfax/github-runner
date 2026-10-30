# Windows Docker Build Service (docker-dind)

A remote Docker endpoint for building Windows images on a Windows Kubernetes node (RKE2, AKS Edge, any cluster with Windows nodes). Clients connect over **mutual TLS on port 2376**; each GitHub repository, identified by its client certificate, gets **its own Docker daemon** with its own cache and its own build network.

It runs as a Windows HostProcess pod (`hostNetwork: true`) and uses the node's containerd (`\\.\pipe\containerd-containerd`). Builds use the classic builder (`docker build` / `docker push`); BuildKit is not available for Windows daemons.

## How it works

```
runner pod (repo A) --mTLS--> :2376 gateway --npipe--> dockerd A  (data-root, cache, NAT network A)
runner pod (repo B) --mTLS--> :2376 gateway --npipe--> dockerd B  (data-root, cache, NAT network B)
                                                         \___ host containerd, one namespace per repo
```

- **Gateway** (`gateway/`, Go): the only network listener. It requires a client certificate that chains to the client CA, reads the repository from it, starts that repository's dockerd on first use, screens the request (see [What the gateway refuses](#what-the-gateway-refuses)) and proxies it over the daemon's named pipe. Renewed certificates are picked up from the mounted Secret without a restart. There is no revocation check: to cut off a repository, remove it from `tenants.allowed` or rotate the client CA.
- **One dockerd per repository**, started on demand and stopped after `tenants.idleTimeout` without requests and running containers (or after `tenants.containerIdleTimeout` without requests, even with containers running). Each has its own data-root, exec-root, pidfile, containerd namespace and named pipe (`\\.\pipe\docker-dind-<id>`, open to Administrators and SYSTEM only). Jobs of the same repository share images, layers and build cache; other repositories cannot see or touch them.
- **One NAT network per repository** for build containers (`RUN` steps, `docker run`), on its own subnet of `network.pool`. Windows Firewall rules block their traffic to private, cluster and node addresses and block every connection into them; the internet stays reachable (`choco install` works).

## Client contract

| | |
|---|---|
| Endpoint | `tcp://<svc>.<namespace>.svc.<clusterDomain>:2376` — a headless Service resolving to the node IP. Use the DNS name: the server certificate covers `<svc>.<ns>.svc.<clusterDomain>`, `<svc>.<ns>.svc`, `<svc>.<ns>` and `<svc>`, not the node IP. |
| Server trust | `ca.crt` of the server Secret (`tls.existingSecret`, or `<fullname>-tls` when the chart creates it). Clients mount it. |
| Client identity | A certificate chaining to `tls.clientCA`, with extended key usage `clientAuth`, naming the repository as `owner/repo` in the subject CN and/or a URI SAN (the URI string exactly `owner/repo`; if both are present they must agree). Case-insensitive. Optionally limited by `tenants.allowed`. |
| Network | The node's IPs, TCP 2376. The Windows Firewall admits `firewall.podCIDR` (and `firewall.nodeCIDR` if set). |

Docker CLI settings for a client:

```bash
DOCKER_HOST=tcp://docker-dind.github-runners.svc.cluster.local:2376
DOCKER_TLS_VERIFY=1
DOCKER_CERT_PATH=/path/to/certs   # ca.pem (server CA), cert.pem and key.pem (client certificate)
```

When mounting Secrets, map the keys to the CLI's file names with volume `items` (`ca.crt` → `ca.pem`, `tls.crt` → `cert.pem`, `tls.key` → `key.pem`).

Repository names are validated against GitHub's rules (owner: 1–39 alphanumerics or hyphens; repository: 1–100 of alphanumerics, `.`, `-`, `_`), lower-cased, and mapped to an ID of the form `<slug>-<96 bits of SHA-256 in hex>` (for example `matfax-githu-caa474164f4cc1bcca25f459`). That ID names the daemon's directories, pipe, containerd namespace and HNS network; each directory also records its repository, and a second name for the same ID is refused.

## Installation

Prerequisites: a Windows Server 2022 node (`ltsc2022` image) with HostProcess support (Kubernetes 1.23+), containerd at `\\.\pipe\containerd-containerd`, the Windows Firewall enabled on all profiles, and Helm 3.

```bash
helm repo add github-runner https://runner.actions.fyi
helm install docker-dind github-runner/docker-dind -n github-runners
```

### Certificates

Pick one source for the server certificate:

1. **Your own Secret** (`kubernetes.io/tls` with `tls.crt`, `tls.key`, `ca.crt`):
   ```yaml
   tls:
     existingSecret: docker-dind-tls
   ```
2. **cert-manager**, with any Issuer or ClusterIssuer you provide:
   ```yaml
   tls:
     certManager:
       enabled: true
       issuerRef: { name: ci-ca, kind: ClusterIssuer, group: cert-manager.io }
   ```
   The chart creates a `Certificate` (ECDSA P-256, `server auth`, 90 days, renewed 15 days early) for the service DNS names into `<fullname>-tls`. Issuers that do not fill `ca.crt` (e.g. ACME) need `tls.clientCA` set explicitly.
3. **Neither**: the chart generates a CA (Secret `<fullname>-ca`, kept on uninstall) and a server certificate signed by it, both valid for `tls.generatedValidityDays` and kept across upgrades. Client certificates can be signed with that CA.

The client CA is separate: `tls.clientCA.secretName`/`key` (default: `ca.crt` of the server Secret). Point it at the CA that issues the per-repository client certificates.

**Renewal:** the gateway re-reads the mounted files every `tls.reloadInterval` (30s) and serves new certificates on new connections; tenant daemons never handle TLS, so nothing restarts. The Secrets are mounted without `subPath`, so kubelet updates them in place. If a renewal does not show up (check the `loaded TLS certificates` log line), restart the pod: `kubectl rollout restart deployment/docker-dind`.

### Values

| Value | Default | Purpose |
|---|---|---|
| `service.port` | `2376` | mTLS port on the node and Service |
| `clusterDomain` | `cluster.local` | Used in the certificate DNS names |
| `tls.*` | | See [Certificates](#certificates) |
| `tenants.allowed` | `[]` | Glob patterns of allowed `owner/repo` identities (e.g. `matfax/*`); empty allows every identity the client CA vouches for |
| `tenants.idleTimeout` | `15m` | Stop a repository's daemon after this long without requests and running containers |
| `tenants.containerIdleTimeout` | `4h` | Stop it after this long without requests even if containers run, so they cannot hold a slot forever |
| `tenants.maxRunning` | `4` | Daemons running at once; another repository waits (HTTP 503) until one is idle |
| `isolation` | `process` | `process` or `hyperv`, see [Isolation](#isolation) |
| `docker.dataRoot` | `C:/docker-data` | Host directory; repositories live under `<dataRoot>/tenants/<id>` |
| `docker.execRoot` | `C:/ProgramData/docker-dind/exec` | Host directory for the exec-roots |
| `docker.insecureRegistries`, `docker.builder.gc` | | Inherited by every daemon |
| `docker.extraConfig` | `{}` | More `daemon.json` settings (per-repository settings always win) |
| `network.pool` / `network.prefixLength` | `172.30.0.0/16` / `24` | Build network subnets, one per repository (256 by default) |
| `network.dns` | `1.1.1.1`, `8.8.8.8` | DNS servers of build containers |
| `network.serviceCIDR` | `10.43.0.0/16` | Cluster service CIDR, blocked for build containers |
| `network.egress.block` / `allow` | RFC 1918, CGNAT, link-local, `0/8`, `224/3` (multicast, reserved) / `[]` | What build containers may not reach, and exceptions |
| `firewall.enabled` | `true` | Manage the Windows Firewall rules |
| `firewall.required` | `true` | Refuse to start while a firewall profile is disabled |
| `firewall.podCIDR` | `10.42.0.0/16` | May connect to 2376; blocked for build containers |
| `firewall.nodeCIDR` | `""` | More networks that may connect to 2376 (comma-separated) |
| `persistence.*` | disabled | PVC for the Docker data |

## Build container networking

Every repository's daemon runs with `bridge: none`, so it creates no default `nat` network (the setting that avoided the overlay VNI errors with the cluster CNI is kept). After the daemon starts, the gateway creates the repository's network `build`: driver `nat`, a subnet of `network.pool` that stays assigned to the repository (`<dataRoot>/tenants/subnets.json`), HNS name `docker-dind-<id>`, the configured DNS servers and the NAT gateway's DNS proxy disabled. Containers and builds asking for the default network (`""`, `default`, `nat`, `bridge`) get `build`; `none` and `container:<id>` are allowed; anything else is refused. This matters because HNS networks are host-wide: every daemon also lists the other repositories' networks and the cluster's (e.g. Calico's) networks.

At every start, `start.ps1` sets these Windows Firewall rules (group `docker-dind`):

| Rule | Effect |
|---|---|
| `docker-dind-gateway` | Allows inbound TCP 2376 from `firewall.podCIDR` and `firewall.nodeCIDR` |
| `docker-dind-build-egress` | Blocks traffic from `network.pool` to `network.egress.block`, the pod and service CIDRs, the pool itself (other repositories) and the node's own IPv4 addresses, minus `network.egress.allow` and the DNS servers |
| `docker-dind-build-ingress` | Blocks every inbound connection to `network.pool` (published ports are refused anyway) |

Block rules take precedence over allow rules, so exceptions are cut out of the block list rather than added as allow rules (`gateway -firewall-plan` prints the result). Replies to the containers' own outbound connections are not affected.

Limits:
- **Windows Firewall enforces these rules for process-isolated containers only.** For Hyper-V isolated containers on NAT networks, Microsoft documents no host-side port ACLs, so with `isolation: hyperv` the private-range block is not enforced on the node; filter it upstream (router, node firewall towards the LAN) if you need it.
- **The rules cover build containers, not the daemons.** Image pulls and pushes and `ADD <url>` in a Dockerfile are fetched by the repository's dockerd on the node's network, so they can reach what the node reaches (by design for private registries, see `docker.insecureRegistries`). Do not expose internal HTTP services to the node that builds must not read.
- With a firewall profile disabled the rules have no effect, hence `firewall.required`.
- The node's own addresses are read when the pod starts; restart it after the node's IP addresses change.
- Containers of the same repository cannot connect to each other either (e.g. a database container for tests).
- IPv6 is not used: Windows NAT networks are IPv4 only.

The CNI plugins and BuildKit in the image are only used by `buildkitd`, which the image ships but does not start; the Docker daemons do not use CNI.

## Isolation

`isolation: process` (default) runs build containers on the node's kernel. **Process isolation is not a security boundary**: Microsoft states that Windows Server containers must not be used to isolate untrusted code, and the per-repository daemons themselves run as SYSTEM. Separate daemons, the gateway policy and the firewall rules keep repositories apart against accidents and ordinary misuse, not against a kernel exploit from a malicious build.

`isolation: hyperv` runs each container in a utility VM and refuses requests for process isolation. Check that the node supports it before enabling it:

```powershell
# Hyper-V role and Containers feature (Windows Server)
Get-WindowsFeature Hyper-V, Containers | Select-Object Name, InstallState
# On a VM, the host must expose virtualization extensions (on the Hyper-V host: Set-VMProcessor <vm> -ExposeVirtualizationExtensions $true)
Get-CimInstance Win32_Processor | Select-Object VirtualizationFirmwareEnabled
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
# End-to-end, through the service (should print the Windows version)
docker run --rm --isolation=hyperv mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c ver
```

Note the firewall limitation above for Hyper-V isolation.

## What the gateway refuses

Requests are answered with HTTP 403 and a `docker-dind: ...` message:

- host bind mounts and named pipe mounts (`-v C:\x:C:\y`, `--mount type=bind|npipe`); named volumes are fine, without driver options;
- published ports (`-p`, `-P`), `--privileged`, devices, other runtimes, gMSA credential specs, `host` namespace modes;
- swarm, plugin install or changes, network create/remove/connect/disconnect/prune, networks other than `build`;
- BuildKit (`/grpc`, `/session`, `version=2` builds), remote build contexts (`docker build <url>`) and image imports from a URL (`docker import <url>`);
- log drivers that ship logs to the network (only `json-file`, `local`, `none`, `etwlogs`), container annotations;
- inspecting networks other than `build`; `docker network ls` lists only `build`;
- API paths it does not know, form or multipart request bodies, and JSON bodies that spell a checked field twice (`Binds` and `binds`), since dockerd would read them past the checks;
- process isolation when `isolation: hyperv`.

## Upgrading from the plain TCP version

- Port 2375 and its firewall rule (`Allow Docker from Pods`) are removed; only 2376 with mutual TLS is served.
- `docker.host` and `docker.network.bridge` are gone (the gateway sets them per repository). `firewall.nodeCIDR` now defaults to empty.
- Images and caches of the old single daemon under `C:/docker-data` are not migrated; each repository starts with an empty cache under `C:/docker-data/tenants`. Delete the old data once you no longer need it.
- Clients must switch to `DOCKER_HOST=tcp://<svc>.<ns>.svc.<clusterDomain>:2376` with TLS.

To remove the firewall rules after uninstalling: `Get-NetFirewallRule -Group docker-dind | Remove-NetFirewallRule`.

## Troubleshooting

```bash
kubectl logs -f deployment/docker-dind -n github-runners   # gateway; daemon output is prefixed [<id>]
```

- `a verified client certificate is required` / TLS errors: the client certificate does not chain to `tls.clientCA` or lacks `clientAuth`.
- `... is not a valid GitHub owner/repo name`: fix the certificate's CN or URI SAN.
- `x509: certificate is valid for ..., not 10.x.x.x`: the client uses the node IP; use the Service DNS name.
- `too many tenant daemons are running`: raise `tenants.maxRunning` or lower `tenants.idleTimeout`.
- `Windows Firewall is disabled for profile(s) ...`: enable the profiles or set `firewall.required=false` (and accept unfiltered build containers).
- A build cannot reach an internal host: add its range to `network.egress.allow`.

## Development

```bash
cd docker-dind/gateway
go test ./...      # runs on any OS; named pipes are tested on Windows
```

The Dockerfile runs `go vet` and `go test` on Windows while building the image.
