#!/usr/bin/env sh
set -eu

# up.sh exists because devcontainer.json mounts are static, and a bind mount
# whose source is a missing Wayland socket aborts `devcontainer up`. This
# wrapper finds the real host socket only when it exists, prepends the matching
# --mount, ensures the kubeconfig staging directory exists, and forwards every
# extra argument.

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(dirname -- "$(dirname -- "$script_dir")")

docker_path=${DOCKER_PATH:-podman}

# devcontainer.json pins these inside the container:
#   XDG_RUNTIME_DIR=/run/user/1000, WAYLAND_DISPLAY=wayland-0
container_runtime_dir="/run/user/1000"
wayland_target="$container_runtime_dir/wayland-0"

uid=$(id -u 2>/dev/null || echo 0)
preferred=${WAYLAND_DISPLAY:-}

# Build the explicitly named candidate first. XDG_RUNTIME_DIR is often NOT
# exported when VS Code or the devcontainer CLI invoke this script.
explicit=""
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
	case "$WAYLAND_DISPLAY" in
		/*) explicit=$WAYLAND_DISPLAY ;;
		*)
			if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
				explicit="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
			fi
			;;
	esac
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
	explicit="$XDG_RUNTIME_DIR/wayland-0"
fi

# find_socket selects from the runtime-dir globs without word-splitting any
# command substitution. With an argument it only accepts a basename match;
# without one it accepts the first socket found.
find_socket() {
	_want=$1
	for _f in /run/user/"$uid"/wayland-* /run/"$uid"/wayland-*; do
		[ -S "$_f" ] || continue
		if [ -z "$_want" ] || [ "${_f##*/}" = "$_want" ]; then
			wayland_socket=$_f
			return 0
		fi
	done
	return 1
}

wayland_socket=""
if [ -n "$explicit" ] && [ -S "$explicit" ]; then
	wayland_socket=$explicit
elif find_socket "$preferred"; then
	:
elif find_socket ""; then
	:
fi

if [ -n "$wayland_socket" ]; then
	# --mount is a devcontainer up option; bind the host socket at the path
	# devcontainer.json advertises. The target name is always wayland-0, even
	# when the host uses wayland-1: deriving it from the host would break the
	# pinned WAYLAND_DISPLAY.
	set -- \
		--mount "type=bind,source=$wayland_socket,target=$wayland_target" \
		"$@"
elif [ -n "${DISPLAY:-}" ]; then
	printf '%s\n' "up.sh: no Wayland socket, X11 session detected - starting without clipboard." >&2
else
	printf '%s\n' "up.sh: no graphical session detected - starting without clipboard." >&2
fi

# devcontainer.json bind-mounts these subdirectories read-only. initializeCommand
# populates them before creation, but create them here too so a manual
# `devcontainer up --skip-post-create` cannot fail on a missing mount source.
mkdir -p "$HOME/.kube/devcontainer/prod" "$HOME/.kube/devcontainer/dev"

# devcontainer-cli's final build stage (dev_containers_target_stage) leaves
# /home/vscode, .local and .local/share owned by root under podman/buildah.
# The CLI then can't write its lifecycle markers in ~/.devcontainer and
# silently skips postCreate/postStart. Fix ownership, then re-run the hooks.
rc=0
devcontainer up --workspace-folder "$workspace_dir" --docker-path "$docker_path" "$@" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

cid=$("$docker_path" ps -q --filter "label=devcontainer.local_folder=$workspace_dir" | head -n1)
"$docker_path" exec -u root "$cid" chown vscode:vscode /home/vscode /home/vscode/.local /home/vscode/.local/share
exec devcontainer run-user-commands --workspace-folder "$workspace_dir" --docker-path "$docker_path"
