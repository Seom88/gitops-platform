# engram is a Go binary. Build it in a throwaway stage so the runtime image
# keeps no Go toolchain (see S8 in odd/tasks/devcontainer-hardening.md).
# v3.6.0 declares `go 1.26.10`, so the builder must be >= 1.26.
FROM golang:1.26-bookworm AS engram
ARG ENGRAM_VERSION=v3.6.0
ENV GOBIN=/out
RUN mkdir -p /out \
    && go install "github.com/Gentleman-Programming/engram/v3/cmd/engram@${ENGRAM_VERSION}" \
    && test -x /out/engram

FROM mcr.microsoft.com/devcontainers/base:debian13@sha256:6ee2b4097c75d33e9a94d941577a3286e5d629434fba384688b06daeeaaeac99

LABEL org.opencontainers.image.title="secured-gitops-tailscale-homelab devcontainer"
LABEL org.opencontainers.image.description="Podman devcontainer with gentle-ai agents, kubectl pointed at the tailnet API server; no tailscale client, no host toolchain, no inherited credentials."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/Seom88/secured-gitops-tailscale-homelab"

# Args
ARG KUBECTL_VERSION=v1.37.1
ARG HELM_VERSION=v3.22.1
ARG STARSHIP_VERSION=v1.27.0
ARG NODE_VERSION=24.22.0
ARG PNPM_VERSION=12.15.0
ARG GENTLE_AI_VERSION=v4.2.0
ARG GENTLE_AI_SHA256=552c1642fd10f5d96cfe9bb1cc3b66b30eb47d3074cc7ca0559b598eb086defc
ARG VELERO_VERSION=v1.18.4
ARG K9S_VERSION=v0.51.0
ARG K9S_SHA256=c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7

ARG DEBIAN_FRONTEND=noninteractive

# Image contents: the AI agents (opencode, gentle-ai, pi, engram) plus the
# operator toolchain (kubectl, helm, velero, k9s), node/pnpm, python3 + uv + a
# venv, and shellcheck for the native pre-commit hook. Deliberately absent: no
# tailscale client, no container-engine socket, no Go toolchain (engram is built
# in a throwaway stage), and none of the host's toolchains are inherited.
# Cache mounts need a BuildKit-capable builder (Buildah 1.33+ / podman).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion \
        ca-certificates \
        curl \
        fish \
        git \
        jq \
        less \
        pipx \
        procps \
        ripgrep \
        wl-clipboard \
        xclip \
        xz-utils \
        iputils-ping \
        traceroute \
        dnsutils \
        telnet \
        shellcheck \
        yq \
        python3 \
        python3-venv \
        python3-pip \
    && (grep -qxF /usr/bin/fish /etc/shells || printf '%s\n' /usr/bin/fish >> /etc/shells) \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# My shell config: starship prompt (gruvbox-rainbow preset) and fish shell.
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --version "${STARSHIP_VERSION}" \
    && starship --version \
    && install -d -o vscode -g vscode /home/vscode/.config/fish/conf.d \
    && starship preset gruvbox-rainbow -o /home/vscode/.config/starship.toml \
    && sed -i 's/^\$username\\$/${env_var.project}\\/' /home/vscode/.config/starship.toml \
    && printf '%s\n' \
        '' \
        '[env_var.project]' \
        'variable = "PROJECT_NAME"' \
        'default = "gitops"' \
        'format = "[$env_value ]($style)"' \
        'style = "bg:color_orange fg:color_fg0"' \
        >> /home/vscode/.config/starship.toml \
    && grep -Fq '${env_var.project}' /home/vscode/.config/starship.toml \
    && printf '%s\n' 'starship init fish | source' > /home/vscode/.config/fish/conf.d/starship.fish \
    && chown -R vscode:vscode /home/vscode/.config

# Fish is the login shell for the vscode user (installed via apt above).
RUN usermod -s /usr/bin/fish vscode

RUN install -d -m 700 -o vscode -g vscode /run/user/1000

# Vscode's devcontainer extension expects the vscode user to have a writable home
RUN install -d -o vscode -g vscode /home/vscode/.cache \
    && install -d -o vscode -g vscode /home/vscode/.cache/pip \
    && install -d -o vscode -g vscode /home/vscode/.cache/pycache \
    && install -d -o vscode -g vscode /home/vscode/.local \
    && install -d -o vscode -g vscode /home/vscode/.local/share \
    && install -d -o vscode -g vscode /home/vscode/.local/share/pnpm \
    && install -d -o vscode -g vscode /home/vscode/.local/share/pnpm/bin \
    && install -d -o vscode -g vscode /home/vscode/.local/state \
    && install -d -m 0755 -o vscode -g vscode /home/vscode/.local/bin

RUN install -d -m 700 -o vscode -g vscode /home/vscode/.ssh \
    && install -d -m 700 -o vscode -g vscode /home/vscode/.kube

# Prebuilt engram (the engram MCP plugin hardcodes this path).
COPY --from=engram --chown=vscode:vscode /out/engram /home/vscode/.local/bin/engram

# K8s
RUN set -eu \
    && curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    && echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c \
    && install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && kubectl version --client \
    && rm -f /tmp/kubectl /tmp/kubectl.sha256

# k9s (pinned tarball, checksum-verified; avoids webi's bootstrap and root $HOME)
RUN set -eu \
    && curl -fsSLo /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    && echo "${K9S_SHA256}  /tmp/k9s.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/k9s.tar.gz -C /tmp k9s \
    && install -m 0755 /tmp/k9s /usr/local/bin/k9s \
    && rm -rf /tmp/k9s* \
    && command -v k9s \
    && k9s version

# Helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION="${HELM_VERSION}" bash \
    && helm version

# Velero
RUN set -eu \
    && curl -fsSLo /tmp/velero.tar.gz "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/velero.tar.gz -C /tmp \
    && install -m 0755 /tmp/velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/velero \
    && rm -rf /tmp/velero*

# python
COPY --from=ghcr.io/astral-sh/uv:0.8.0 /uv /uvx /usr/local/bin/
ENV PYTHONPYCACHEPREFIX=/home/vscode/.cache/pycache

ENV VIRTUAL_ENV=/opt/venv \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN python3 -m venv "${VIRTUAL_ENV}" \
    && chown -R vscode:vscode "${VIRTUAL_ENV}"
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# My slop config
RUN curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh | bash

USER vscode
RUN --mount=type=cache,target=/home/vscode/.cache/pip,uid=1000,gid=1000 \
    pip install \
        pre-commit \
        ruff \
        pyyaml \
        requests \
        jinja2

# nodejs
ENV FNM_DIR=/home/vscode/.local/share/fnm \
    PNPM_HOME=/home/vscode/.local/share/pnpm
ENV PATH="${FNM_DIR}:${FNM_DIR}/aliases/default/bin:${PNPM_HOME}/bin:${PNPM_HOME}:/home/vscode/.local/bin:${PATH}"

# The fnm installer itself is not version-pinned; the node version it installs is.
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "${FNM_DIR}" --skip-shell \
    && fnm install "${NODE_VERSION}" \
    && fnm default "${NODE_VERSION}" \
    && node --version \
    && npm --version

# pnpm. PNPM_HOME and its bin/ are pre-created as vscode above: the cache mount
# below only creates $PNPM_HOME/store, and if it also had to create the parent
# it would leave it root-owned, making `pnpm setup` fail to create bin/.
RUN npm install -g pnpm@${PNPM_VERSION} \
    && pnpm setup \
    && pnpm --version

# Install opencode and pi agent
RUN --mount=type=cache,target=/home/vscode/.local/share/pnpm/store,uid=1000,gid=1000 \
    set -eu \
    && pnpm add -g --allow-build=opencode-ai opencode-ai@1.19.4 \
    && pnpm add -g @colbymchenry/codegraph@1.6.2 \
    && pnpm add -g --ignore-scripts @earendil-works/pi-coding-agent 
