# escape=`

# Use Windows Server Core with .NET Framework SDK as base image
FROM mcr.microsoft.com/dotnet/framework/sdk:4.8.1-windowsservercore-ltsc2022

# Set metadata labels
LABEL org.opencontainers.image.source="https://github.com/matfax/github-runner"
LABEL org.opencontainers.image.vendor="matfax"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.title="GitHub Actions Runner"
LABEL org.opencontainers.image.description="Windows Community Runner for GitHub Actions"
LABEL org.opencontainers.image.base.name="mcr.microsoft.com/dotnet/framework/sdk:4.8.1-windowsservercore-ltsc2025"

# Switch to PowerShell for build commands
SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'"]

# Install Chocolatey
ADD https://community.chocolatey.org/install.ps1 C:/install_choco.ps1

ARG CHOCO_VERSION=2.6.0
ENV CHOCO_VERSION=${CHOCO_VERSION}

RUN Set-ExecutionPolicy Bypass -Scope Process -Force; `
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; `
    $env:chocolateyVersion = "${CHOCO_VERSION}"; `
    C:/install_choco.ps1; `
    Remove-Item C:/install_choco.ps1 -Force

RUN "[Environment]::SetEnvironmentVariable('PATH', 'C:\ProgramData\chocolatey\bin'+$env:PATH, [EnvironmentVariableTarget]::Machine)"

# Install PowerShell Core and core tools
RUN choco install powershell-core -y --version 7.5.0
RUN choco install zstandard -y --version 1.5.7.20250308
RUN choco install git -y --version 2.52.0 --params '/GitAndUnixToolsOnPath'
RUN choco install gh -y --version 2.83.1

# Install Rust
RUN choco install rust -y --version 1.91.1
RUN choco install rustup.install -y --version 1.27.1
RUN rustup.exe default stable

# Install other languages/tooling
RUN choco install golang -y --version 1.25.3
RUN choco install python -y --version 3.14.0
RUN choco install nodejs -y --version 25.2.1
RUN choco install docker-cli -y --version 29.0.2
RUN choco install openjdk17 -y --version 17.0.2.20220913

# Set working directory
WORKDIR C:/actions-runner

ARG RUNNER_VERSION=2.329.0

ADD https://github.com/falcondev-oss/github-actions-runner/releases/download/v${RUNNER_VERSION}/actions-runner-win-x64-${RUNNER_VERSION}.zip C:/actions-runner/runner.zip

RUN Expand-Archive -Path C:\actions-runner\runner.zip -DestinationPath C:\actions-runner; `
    Remove-Item C:\actions-runner\runner.zip -Force

COPY start.ps1 C:/actions-runner/start.ps1

CMD ["pwsh", ".\\start.ps1"]
