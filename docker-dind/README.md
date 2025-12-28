# Windows Docker-in-Docker Service

Docker daemon that exposes a TCP endpoint for Docker API access using the host's containerd runtime. Designed for GitHub Actions runners on AKS Edge and Windows Kubernetes clusters.

## Overview

This service provides Docker API access via TCP port 2375 by running a Docker daemon that connects to the host's containerd runtime. It uses Windows hostProcess containers to mount the containerd named pipe from the host, enabling Docker commands without nested containerization.

**Key features:**
- Uses host containerd runtime via `\\.\pipe\containerd-containerd`
- Exposes standard Docker TCP API on port 2375
- Compatible with AKS Edge and Windows Kubernetes
- Configurable builder garbage collection

## Installation

### Prerequisites

- AKS Edge or Kubernetes cluster with Windows node pool
- Windows hostProcess container support (Kubernetes 1.23+)
- Helm 3.x

### Windows Calico CNI Configuration

When running on Windows nodes with Calico CNI, the service defaults to a headless configuration (`clusterIP: None`). This is necessary because:
1. kube-proxy on Windows doesn't properly route ClusterIP traffic to hostNetwork pod endpoints
2. DNS resolution with a headless service resolves directly to the node IP, bypassing kube-proxy

The Docker daemon container includes a Windows firewall rule that restricts inbound traffic to port 2375 from the configured pod network CIDR (default: 10.244.0.0/16 for Calico). This provides network-level access control at the Windows host firewall.

### Option 1: Install from Helm Repository

```bash
helm repo add github-runner https://runner.actions.fyi
helm repo update
helm install docker-dind github-runner/docker-dind \
  --namespace github-arc
```

### Option 2: Install from Local Chart

```bash
helm install docker-dind ./chart \
  --namespace github-arc
```

### Helm Values

Key configuration options:

```yaml
# Service configuration
service:
  type: ClusterIP  # or LoadBalancer for external access
  clusterIP: "None"  # Headless service to work around Windows + Calico kube-proxy not routing ClusterIP traffic to hostNetwork pod endpoints
  port: 2375

# Windows firewall configuration
firewall:
  enabled: true
  podCIDR: "10.244.0.0/16"  # Calico pod network CIDR

# Resource allocation
resources:
  limits:
    cpu: 2000m
    memory: 4Gi
  requests:
    cpu: 500m
    memory: 1Gi

# Docker daemon settings
docker:
  host: "tcp://0.0.0.0:2375"
  insecureRegistries:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
  builder:
    gc:
      defaultKeepStorage: "32GB"
      enabled: true

# Windows node scheduling
nodeSelector:
  kubernetes.io/os: windows
  kubernetes.io/arch: amd64

tolerations:
  - key: "os"
    operator: "Equal"
    value: "windows"
    effect: "NoSchedule"

# Security context for host containerd access
securityContext:
  windowsOptions:
    hostProcess: true
    runAsUserName: "NT AUTHORITY\\SYSTEM"

# Persistence for Docker data
persistence:
  enabled: false
  size: 50Gi
  mountPath: C:/var/lib/docker
```

## Usage from GitHub Actions Runners

### Option 1: Using DOCKER_HOST environment variable

When launching your GitHub Actions runner containers, set:

```yaml
env:
  - name: DOCKER_HOST
    value: tcp://docker-dind:2375
```

### Option 2: Using docker context

```bash
docker context create remote-windows --docker host=tcp://docker-dind:2375
docker context use remote-windows
```

## Security Considerations

- **Windows hostProcess**: The service runs as `NT AUTHORITY\\SYSTEM` with `hostProcess: true` to access the host's containerd named pipe.
- **Network Access**: The TCP endpoint should be restricted to trusted applications within the cluster.
- **No TLS**: By default, TLS is disabled. For production, consider adding TLS certificates.
- **Windows Firewall**: Access is restricted by Windows firewall rules to the configured pod network CIDR. Configure the pod CIDR to match your cluster's pod network:

```yaml
firewall:
  enabled: true
  podCIDR: "10.244.0.0/16"  # Adjust to match your cluster's pod network
```

To allow access from any address (not recommended for production):

```yaml
firewall:
  enabled: true
  podCIDR: ""  # Empty string allows access from any address
```

- **NetworkPolicy**: Note that NetworkPolicy may not work effectively with hostNetwork pods. Use the firewall configuration for access control instead.

## Troubleshooting

### Check Docker daemon logs

```bash
kubectl logs -f deployment/docker-dind -n docker-dind
```

### Test connectivity from a pod

```bash
kubectl run -i --tty --rm debug --image=mcr.microsoft.com/windows/nanoserver:ltsc2022 --restart=Never -- nslookup docker-dind
```

### Verify Docker API

```bash
# Port-forward for local testing
kubectl port-forward svc/docker-dind 2375:2375 -n docker-dind

# Test from local machine
docker -H tcp://localhost:2375 version
```

### Common Issues

1. **Port access denied**: Ensure Windows Defender/Firewall allows port 2375
2. **hostProcess errors**: Verify Windows hostProcess containers are enabled on the node
3. **Image pull errors**: Ensure Windows nodes can access container registry
4. **Containerd pipe access**: Verify the containerd named pipe `\\\\.\\pipe\\containerd-containerd` exists on the host

## Integration with GitHub ARC

For GitHub Actions Runner Controller (ARC), add this to your RunnerSet or RunnerDeployment:

```yaml
spec:
  template:
    spec:
      containers:
        - name: runner
          env:
            - name: DOCKER_HOST
              value: tcp://docker-dind.docker-dind.svc.cluster.local:2375
```

This enables docker commands in workflows without socket mounting.
