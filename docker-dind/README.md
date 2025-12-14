# Windows Docker-in-Docker Service

Windows Docker-in-Docker service that provides a TCP endpoint for Docker API access without requiring socket mounting or host Docker access.

## Overview

This service runs the Docker daemon (`dockerd`) on Windows, exposing a TCP endpoint (port 2375) that can be used by GitHub Actions runners or other applications to run Docker containers without needing access to the host Docker socket.

## Docker Build

Build the image:

```bash
cd docker-dind
docker build -t ghcr.io/matfax/github-runner/docker-dind:latest .

# Also tag with specific version (appVersion)
docker build -t ghcr.io/matfax/github-runner/docker-dind:25.0.3 .
```

## Kubernetes Deployment with Helm

### Prerequisites

- Kubernetes cluster with Windows node pool
- Windows Server 2022 LTSC nodes
- Containers feature enabled on Windows nodes

### Helm Installation

```bash
# Install from chart directory
helm install windows-docker-dind ./chart \
  --namespace docker-dind \
  --create-namespace

# With custom configuration
helm install windows-docker-dind ./chart \
  --namespace docker-dind \
  --set service.type=LoadBalancer \
  --set resources.limits.memory=8Gi
```

### Helm Values

Key configuration options:

```yaml
# Service configuration
service:
  type: ClusterIP  # or LoadBalancer for external access
  port: 2375

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

# Windows node scheduling
nodeSelector:
  kubernetes.io/os: windows
  kubernetes.io/arch: amd64

tolerations:
  - key: "os"
    operator: "Equal"
    value: "windows"
    effect: "NoSchedule"

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
    value: tcp://windows-docker-dind:2375
```

### Option 2: Using docker context

```bash
docker context create remote-windows --docker host=tcp://windows-docker-dind:2375
docker context use remote-windows
```

## Build and Release Process

### Versioning

This image follows Docker CE versioning:

1. **Dockerfile** uses `ARG DOCKER_GITHUB_VERSION` with a renovate comment:
   ```dockerfile
   ARG DOCKER_GITHUB_VERSION=25.0.3 # repository: docker/docker-ce
   ```

2. **Chart.yaml** uses the same version via renovate comment:
   ```yaml
   appVersion: "25.0.3" # repository: docker/docker-ce
   ```

3. Renovate automatically updates both when new Docker releases are published.

### Building for Release

```bash
cd docker-dind

# Get version from Dockerfile
DOCKER_VERSION=$(grep "DOCKER_GITHUB_VERSION" Dockerfile | cut -d'=' -f2 | cut -d' ' -f1)

# Build and push both tags
docker build -t ghcr.io/matfax/github-runner/docker-dind:latest .
docker build -t ghcr.io/matfax/github-runner/docker-dind:${DOCKER_VERSION} .
docker push ghcr.io/matfax/github-runner/docker-dind:latest
docker push ghcr.io/matfax/github-runner/docker-dind:${DOCKER_VERSION}
```

### CI/CD Integration

In your GitHub Actions workflow:

```yaml
- name: Extract Docker version
  id: version
  run: |
    DOCKER_VERSION=$(grep "DOCKER_GITHUB_VERSION" docker-dind/Dockerfile | cut -d'=' -f2 | cut -d' ' -f1)
    echo "version=${DOCKER_VERSION}" >> $GITHUB_OUTPUT

- name: Build and push
  uses: docker/build-push-action@v5
  with:
    context: docker-dind
    platforms: windows/amd64
    push: true
    tags: |
      ghcr.io/matfax/github-runner/docker-dind:latest
      ghcr.io/matfax/github-runner/docker-dind:${{ steps.version.outputs.version }}
```

## Security Considerations

- **Privileged Mode**: Docker-in-Docker requires privileged mode. Ensure proper RBAC and network policies.
- **Network Access**: The TCP endpoint should be restricted to trusted applications within the cluster.
- **No TLS**: By default, TLS is disabled. For production, consider adding TLS certificates.
- **Use NetworkPolicies**: Restrict which pods can access the Docker daemon:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: docker-dind-access
spec:
  podSelector:
    matchLabels:
      app: windows-docker-dind
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: github-actions
        - podSelector:
            matchLabels:
              app: github-runner
      ports:
        - protocol: TCP
          port: 2375
```

## Troubleshooting

### Check Docker daemon logs

```bash
kubectl logs -f deployment/windows-docker-dind -n docker-dind
```

### Test connectivity from a pod

```bash
kubectl run -i --tty --rm debug --image=mcr.microsoft.com/windows/nanoserver:ltsc2022 --restart=Never -- nslookup windows-docker-dind
```

### Verify Docker API

```bash
# Port-forward for local testing
kubectl port-forward svc/windows-docker-dind 2375:2375 -n docker-dind

# Test from local machine
docker -H tcp://localhost:2375 version
```

### Common Issues

1. **Port access denied**: Ensure Windows Defender/Firewall allows port 2375
2. **Privileged mode error**: Verify cluster allows privileged containers
3. **Image pull errors**: Ensure Windows nodes can access container registry
4. **Storage issues**: Enable persistence or increase disk space

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
              value: tcp://windows-docker-dind.docker-dind.svc.cluster.local:2375
```

This enables docker commands in workflows without socket mounting.
