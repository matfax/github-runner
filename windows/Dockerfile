# escape=`

# Use Windows Server Core 2025 (LTSC)
FROM mcr.microsoft.com/windows/servercore:ltsc2025

# Switch to PowerShell for build commands
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# -----------------------------------------------------------------------------
# 1. INSTALL CHOCOLATEY
# -----------------------------------------------------------------------------
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; `
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; `
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# -----------------------------------------------------------------------------
# 2. INSTALL TOOLCHAIN
# -----------------------------------------------------------------------------
# Install Git, GitHub CLI, Python, Node.js, Docker CLI, Go, Rust, and Kotlin
RUN choco install git -y --params '/GitAndUnixToolsOnPath'; `
    choco install gh -y; `
    choco install python -y; `
    choco install nodejs -y; `
    choco install docker-cli -y; `
    choco install golang -y; `
    choco install rust -y; `
    choco install openjdk17 -y

# Compression tools
RUN choco install zstd -y

# Install Rustup specifically (The toolchain manager)
RUN choco install rustup.install -y

# -----------------------------------------------------------------------------
# 4. INITIALIZE RUST
# -----------------------------------------------------------------------------
# FIX: We call rustup from the Chocolatey path first to initialize the environment
# We use 'stable-msvc' by default, but you might need 'stable-gnu' if you lack VS Build Tools
RUN rustup.exe default stable

# -----------------------------------------------------------------------------
# 4. DYNAMIC GITHUB RUNNER INSTALLATION
# -----------------------------------------------------------------------------
WORKDIR C:\actions-runner

# Copy the internal entrypoint script
COPY windows/build.ps1 .\build.ps1

RUN powershell .\build.ps1

# Copy the internal entrypoint script
COPY windows/start.ps1 C:\actions-runner\start.ps1

# Start the runner
CMD ["powershell", ".\\start.ps1"]
