#!/usr/bin/env bash
# post-create.sh
# Script post creating the devcontainer, to set up permissions and install dependencies.

set -euo pipefail

echo "🔧 Set permissions"

sudo chown -R vscode:vscode \
    /home/vscode/.cache \
    /home/vscode/.local \
    /home/vscode/.local/share \
    /home/vscode/.local/state

# Named volumes mount root-owned, so re-own the dotdirs that live on them.
sudo chown -R vscode:vscode /home/vscode/.local/share/opencode \
    /home/vscode/.local/state/opencode \
    /home/vscode/.cache/opencode \
    /home/vscode/.engram \
    /home/vscode/.codegraph \
    /home/vscode/.gentle-ai \
    /home/vscode/.config/opencode

# Installs into $OPENCODE_CONFIG (a volume), so it stays at runtime.
opencode plugin @tarquinen/opencode-dcp@latest --global

echo "📦 Install pi config..."
# pi is still unpinned; pinning it is tracked as follow-up in the ODD task log.
mkdir -p ~/.pi/agent
ln -sf /workspace/.devcontainer/local-config/pi.lmstudio.json ~/.pi/agent/lmstudio.json
pi install npm:pi-lmstudio
pi install npm:pi-context-prune
pi install npm:pi-wtf

echo "✅ post-creation completed successfully."
echo "Note: Run gentle-ai to configure the AI agent and install dependencies, then run opencode-ai to start the OpenCode CLI."