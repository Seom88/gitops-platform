# Devcontainer image for this repo: a minimal Debian base hosting the AI coding
# agents (opencode + gentle-ai, spec S2) without the repo toolchain (S8), with
# no tailscale client (S5, cluster access routes through the host's tailnet
# NAT), and no human credentials baked into the image (S6/S7: the only
# kubeconfig arrives as a bind-mounted read-only file at runtime).
FROM docker.io/library/debian:bookworm-slim@sha256:ec31d744f83f4a73447ba045aaab9409997efe5cc706eca4890c1be36cc1606a

LABEL org.opencontainers.image.title="secured-gitops-tailscale-homelab devcontainer"
LABEL org.opencontainers.image.description="Podman devcontainer with opencode + gentle-ai agents, kubectl pointed at the tailnet API server; no tailscale client, no host toolchain, no inherited credentials."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/Seom88/secured-gitops-tailscale-homelab"

# Pinned tool versions (refresh deliberately, like the repo's digest pins).
# KUBECTL_VERSION matches the in-cluster kubectl pin used by
# platform/longhorn/templates/csi-wait-job.yaml (1.37.0).
ARG KUBECTL_VERSION=v1.37.0
# Active LTS line at authoring time (2026-10): 24.x "Krypton".
ARG NODE_VERSION=24.22.0
ARG PNPM_VERSION=12.14.0
# gentle-ai (Gentleman-Programming/gentle-ai, Go binary) is NOT distributed on
# npm/pnpm; its official install.sh always resolves latest and supports no
# version pin. To keep builds reproducible we download the pinned release
# tarball directly and verify its sha256 against the release-published
# checksums.txt value below. The alternative pnpm/npm path does not exist, so
# S2 is satisfied via pnpm for opencode-ai and via the upstream release route
# for gentle-ai (never npm).
ARG GENTLE_AI_VERSION=v4.2.0
ARG GENTLE_AI_SHA256=552c1642fd10f5d96cfe9bb1cc3b66b30eb47d3074cc7ca0559b598eb086defc

ARG DEBIAN_FRONTEND=noninteractive

# Apt packages kept to agent essentials only (S8): git/curl/kubectl/node/pnpm
# and a couple of quality-of-life tools. No helm, trivy, yamllint, shellcheck
# or just; and no tailscale package (S5).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        procps \
        ripgrep \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# kubectl from dl.k8s.io, sha256-verified against the per-release published
# digest, then smoke-tested with --client.
RUN set -eu \
    && curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    && echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c \
    && install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && kubectl version --client \
    && rm -f /tmp/kubectl /tmp/kubectl.sha256

# Node.js from the official nodejs.org tarball. The dist ships npm and
# corepack inside lib/node_modules; they are removed because the agents stack
# installs packages only via pnpm (S2) and npm must not be reachable in the
# container.
RUN set -eu \
    && curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSLo /tmp/node-SHASUMS256.txt "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
    && echo "$(grep "node-v${NODE_VERSION}-linux-x64.tar.xz$" /tmp/node-SHASUMS256.txt | awk '{print $1}')  /tmp/node.tar.xz" | sha256sum -c \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && rm -f /tmp/node.tar.xz /tmp/node-SHASUMS256.txt \
    && node --version

# gentle-ai: pinned GitHub release tarball, sha256-verified. See the ARG
# comment above for why this is not a pnpm/npm install.
RUN set -eu \
    && curl -fsSLo /tmp/gentle-ai.tar.gz "https://github.com/Gentleman-Programming/gentle-ai/releases/download/${GENTLE_AI_VERSION}/gentle-ai_${GENTLE_AI_VERSION#v}_linux_amd64.tar.gz" \
    && echo "${GENTLE_AI_SHA256}  /tmp/gentle-ai.tar.gz" | sha256sum -c \
    && tar -xzf /tmp/gentle-ai.tar.gz -C /usr/local/bin gentle-ai \
    && chmod 0755 /usr/local/bin/gentle-ai \
    && rm -f /tmp/gentle-ai.tar.gz \
    && /usr/local/bin/gentle-ai --version

# Non-root user with a stable UID; workspace files are bind-mounted at runtime.
RUN useradd -u 1000 -m -d /home/agent -s /bin/bash agent \
    && mkdir -p /home/agent/.kube \
    && chown agent:agent /home/agent/.kube

ENV PNPM_HOME=/home/agent/.local/share/pnpm
# Both layouts are on PATH on purpose: pnpm v10 linked its binary into
# PNPM_HOME itself, while v11+ links it into PNPM_HOME/bin (pnpm setup's PATH
# line). Keeping both keeps the pin conservative across version bumps.
ENV PATH="/home/agent/.local/share/pnpm:/home/agent/.local/share/pnpm/bin:/usr/local/bin:/usr/bin:/bin"

USER 1000

# pnpm via the official standalone installer (env-var driven version pin),
# then the agents. pnpm (not npm) is the only package manager used here (S2).
# --allow-build is required because pnpm >= 10 blocks lifecycle scripts by
# default, and opencode-ai's postinstall selects the real native binary for
# the platform (without it, only a placeholder shim lands on PATH).
RUN set -eu \
    && export PNPM_VERSION="${PNPM_VERSION}" \
    && export SHELL=bash \
    && curl -fsSL https://get.pnpm.io/install.sh | sh - \
    && pnpm --version \
    && pnpm add -g --allow-build=opencode-ai opencode-ai \
    && opencode --version
