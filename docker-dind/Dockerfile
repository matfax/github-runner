# escape=`

# Use Windows Server Core as base
FROM mcr.microsoft.com/powershell:lts-windowsservercore-ltsc2022@sha256:4d58db7a0242824875f60449f8ebe482e14c15470b2a9a7ca1bce0172770240c

# Metadata
LABEL org.opencontainers.image.source="https://github.com/matfax/github-runner"
LABEL org.opencontainers.image.vendor="matfax"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.title="Windows Docker-in-Docker Service"
LABEL org.opencontainers.image.description="Docker-in-Docker for Windows with TCP endpoint"
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

# Configure Docker daemon for TCP
RUN mkdir C:\docker-config
COPY daemon.json C:/docker-config/daemon.json

# Expose Docker TCP port
EXPOSE 2375

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD docker version

CMD ["dockerd", "--config-file=C:\\docker-config\\daemon.json"]
