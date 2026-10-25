# Watcher that polls GitHub for queued self-hosted jobs and launches runner Jobs in Kubernetes.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

LABEL org.opencontainers.image.source="https://github.com/matfax/github-runner"
LABEL org.opencontainers.image.vendor="matfax"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.title="GitHub Runner Watcher"
LABEL org.opencontainers.image.description="Launches ephemeral GitHub Actions runner Jobs in Kubernetes on demand"
LABEL org.opencontainers.image.base.name="ubuntu:24.04"

ARG TARGETARCH
ARG POWERSHELL_GITHUB_VERSION=7.6.8
# repository: PowerShell/PowerShell
ARG KUBECTL_GITHUB_VERSION=1.37.1
# repository: kubernetes/kubernetes
ARG POWERSHELL_YAML_VERSION=0.4.12

ENV DEBIAN_FRONTEND=noninteractive \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends ca-certificates curl libicu74 \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
        amd64) PWSH_ARCH=x64 ;; \
        arm64) PWSH_ARCH=arm64 ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_GITHUB_VERSION}/powershell-${POWERSHELL_GITHUB_VERSION}-linux-${PWSH_ARCH}.tar.gz" -o /tmp/pwsh.tar.gz \
    && mkdir -p /opt/microsoft/powershell \
    && tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell \
    && chmod +x /opt/microsoft/powershell/pwsh \
    && ln -s /opt/microsoft/powershell/pwsh /usr/local/bin/pwsh \
    && rm /tmp/pwsh.tar.gz

RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_GITHUB_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl \
    && echo "$(curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_GITHUB_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl

RUN pwsh -NoProfile -Command "Install-Module powershell-yaml -RequiredVersion ${POWERSHELL_YAML_VERSION} -Scope AllUsers -Force"

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin watcher

WORKDIR /app
COPY watch-repos.ps1 github-app.ps1 kube-launch.ps1 registration.ps1 runner-api.ps1 ./

USER 10001
ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/app/watch-repos.ps1"]
CMD ["-ConfigPath", "/etc/github-runner/config.yml"]
