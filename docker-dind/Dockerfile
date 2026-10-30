# escape=`

# Build the mutual-TLS gateway on the same base image, so the build pulls no extra base layers
FROM mcr.microsoft.com/powershell:lts-windowsservercore-ltsc2022@sha256:4d58db7a0242824875f60449f8ebe482e14c15470b2a9a7ca1bce0172770240c AS gateway

SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG GO_VERSION=1.27.3
ADD https://go.dev/dl/go${GO_VERSION}.windows-amd64.zip C:/go.zip
RUN Expand-Archive -Path C:/go.zip -DestinationPath C:/ -Force; `
    Remove-Item C:/go.zip -Force

ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0
WORKDIR C:/src
COPY gateway/go.mod gateway/go.sum ./
RUN $env:PATH = 'C:\go\bin;' + $env:PATH; `
    go mod download; if ($LASTEXITCODE) { exit $LASTEXITCODE }
COPY gateway/ ./
ARG GATEWAY_VERSION=dev
RUN $env:PATH = 'C:\go\bin;' + $env:PATH; `
    go vet ./...; if ($LASTEXITCODE) { exit $LASTEXITCODE }; `
    go test ./...; if ($LASTEXITCODE) { exit $LASTEXITCODE }; `
    go build -trimpath -ldflags "-s -w -X main.version=$env:GATEWAY_VERSION" -o C:/out/gateway.exe .; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Use Windows Server Core as base
FROM mcr.microsoft.com/powershell:lts-windowsservercore-ltsc2022@sha256:4d58db7a0242824875f60449f8ebe482e14c15470b2a9a7ca1bce0172770240c

# Metadata
LABEL org.opencontainers.image.source="https://github.com/matfax/github-runner"
LABEL org.opencontainers.image.vendor="matfax"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.title="Windows Docker-in-Docker Service"
LABEL org.opencontainers.image.description="Per-repository Docker daemons for Windows image builds behind a mutual-TLS gateway"
LABEL org.opencontainers.image.base.name="mcr.microsoft.com/windows/servercore:ltsc2022"

SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Install Chocolatey
ADD https://community.chocolatey.org/install.ps1 C:/install_choco.ps1

ARG CHOCO_GITHUB_VERSION=2.6.0 # repository: chocolatey/choco
ENV CHOCO_VERSION=${CHOCO_GITHUB_VERSION}

RUN Set-ExecutionPolicy Bypass -Scope Process -Force; `
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; `
    $env:chocolateyVersion = "${CHOCO_VERSION}"; `
    C:/install_choco.ps1; `
    Remove-Item C:/install_choco.ps1 -Force

RUN "[Environment]::SetEnvironmentVariable('PATH', (Join-Path $env:ProgramData 'chocolatey' 'bin') + [IO.Path]::PathSeparator + $env:PATH, [EnvironmentVariableTarget]::Machine)"

# Install Docker Engine (download static binaries directly, no service needed)
ARG DOCKERD_GITHUB_VERSION=28.3.1 # repository: moby/moby
ADD https://download.docker.com/win/static/stable/x86_64/docker-${DOCKERD_GITHUB_VERSION}.zip C:/docker-binaries.zip
RUN Expand-Archive -Path C:/docker-binaries.zip -DestinationPath C:\docker-extract -Force; `
    New-Item -ItemType Directory -Path (Join-Path $env:ProgramFiles 'docker') -Force; `
    Move-Item -Path (Join-Path "C:\docker-extract" "docker" "*") -Destination (Join-Path $env:ProgramFiles 'docker') -Force; `
    Remove-Item C:/docker-binaries.zip -Force; `
    Remove-Item C:\docker-extract -Recurse -Force

RUN "[Environment]::SetEnvironmentVariable('PATH', (Join-Path $env:ProgramFiles 'docker') + [IO.Path]::PathSeparator + $env:PATH, [EnvironmentVariableTarget]::Machine)"

# Install BuildKit and dependencies
ARG BUILDKIT_GITHUB_VERSION=0.18.0 # repository: moby/buildkit

# Install BuildKit
ADD https://github.com/moby/buildkit/releases/download/v${BUILDKIT_GITHUB_VERSION}/buildkit-v${BUILDKIT_GITHUB_VERSION}.windows-amd64.tar.gz C:/buildkit.tar.gz
RUN Write-Host "Installing BuildKit v${BUILDKIT_GITHUB_VERSION}..."; `
    $buildkitRoot = Join-Path $env:ProgramFiles 'buildkit'; `
    New-Item -ItemType Directory -Force -Path $buildkitRoot | Out-Null; `
    tar.exe xvf C:\buildkit.tar.gz -C $buildkitRoot; `
    Remove-Item C:\buildkit.tar.gz -Force

RUN "[Environment]::SetEnvironmentVariable('PATH', (Join-Path $env:ProgramFiles 'buildkit' 'bin') + [IO.Path]::PathSeparator + $env:PATH, [EnvironmentVariableTarget]::Machine)

ARG CNI_GITHUB_VERSION=0.3.1 # repository: microsoft/windows-container-networking

# Install CNI plugins
ADD https://github.com/microsoft/windows-container-networking/releases/download/v${CNI_GITHUB_VERSION}/windows-container-networking-cni-amd64-v${CNI_GITHUB_VERSION}.zip C:/cni-plugins.zip
RUN Write-Host "Installing CNI plugins v${CNI_GITHUB_VERSION}..."; `
    $cniBinDir = Join-Path $env:ProgramFiles 'containerd' 'cni' 'bin'; `
    New-Item -ItemType Directory -Force -Path $cniBinDir | Out-Null; `
    Expand-Archive -Path C:\cni-plugins.zip -DestinationPath $cniBinDir; `
    Remove-Item C:\cni-plugins.zip -Force

# CNI plugins and BuildKit are only used by buildkitd, which this image ships but does not start; the
# per-repository dockerd instances use their own HNS NAT networks, not CNI.

# Gateway, startup script and defaults for running outside Kubernetes
COPY --from=gateway C:/out/gateway.exe C:/dind/gateway.exe
COPY gateway.json C:/dind/gateway.json
COPY start.ps1 C:/start.ps1

# Base config every per-repository dockerd inherits
COPY daemon.json C:/docker-config/daemon.json

# Mutual-TLS Docker endpoint (the only listener)
EXPOSE 2376

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD pwsh -NoProfile -Command "$c = [Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 2376); $c.Close()"

CMD ["pwsh", "-NoProfile", "-File", "C:\\start.ps1"]
