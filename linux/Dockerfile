# Linux GitHub Actions runner image based on falcondev-oss/actions-runner, with toolchains aligned to the Windows image.
FROM ghcr.io/falcondev-oss/actions-runner:latest

ENV DEBIAN_FRONTEND=noninteractive

# Base image ends as runner user; elevate to root to install extra tooling.
USER root

# Add languages/tooling comparable to the Windows build.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        curl \
        jq \
        git \
        unzip \
        tar \
        sudo \
        iputils-ping \
        build-essential \
        python3 python3-pip python3-venv \
        nodejs \
        golang \
        openjdk-17-jdk \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -y && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# Ensure runner user keeps sudo/docker (base already set; guard for future)
RUN usermod -aG sudo runner || true \
    && usermod -aG docker runner || true \
    && echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner

WORKDIR /home/runner

# Install Rust (as runner user) to match Windows toolchain
USER runner
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal && \
    /home/runner/.cargo/bin/rustup default stable
ENV PATH="/home/runner/.cargo/bin:${PATH}"

USER root
COPY linux/start.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown runner:runner /entrypoint.sh

USER runner
ENV RUNNER_NAME="" \
    RUNNER_LABELS="self-hosted,linux,docker" \
    RUNNER_WORKDIR="/home/runner/_work"

ENTRYPOINT ["/entrypoint.sh"]
