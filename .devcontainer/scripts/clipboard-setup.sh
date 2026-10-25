#!/usr/bin/env bash
# clipboard-setup.sh
# Auto-start a compositor-independent Wayland clipboard provider inside the container.
#
# up.sh mounts the host compositor's socket at /run/user/1000/wayland-0. Any client
# speaking the primary-selection protocol can own that clipboard, and KDE Plasma,
# Hyprland, Niri and Sway all expose it identically - so we run a persistent
# wl-copy bound to that socket. No host-side config needed; works today on KDE and
# will keep working if you move to Hyprland, Niri or any other compositor later.

set -eu

container_runtime_dir="/run/user/1000"
container_display="${WAYLAND_DISPLAY:-wayland-0}"
socket="$container_runtime_dir/$container_display"

# Only meaningful when the Wayland socket is mounted (X11 / no graphical session -> skip).
if [ ! -S "$socket" ]; then
	exit 0
fi

export XDG_RUNTIME_DIR="/run/user/1000"
export WAYLAND_DISPLAY="$container_display"

# Idempotent: if a provider already owns the clipboard, don't start another.
if command -v pgrep >/dev/null 2>&1 && pgrep -x wl-copy >/dev/null 2>&1; then
	exit 0
fi

# Persistent owner: stays alive (setsid detaches it from this command) and serves
# whatever clients copy through the compositor's primary-selection protocol.
if command -v wl-copy >/dev/null 2>&1; then
	setsid wl-copy </dev/null >/dev/null 2>&1 &
fi

exit 0
