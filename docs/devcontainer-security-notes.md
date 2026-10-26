# Dev Container security considerations

These are review notes, not approved changes. The current setup is intentionally useful for local development; this document records security tradeoffs and possible mitigations for later review.

## Clipboard and the host Wayland socket

The devcontainer bind-mounts the host Wayland socket so OpenCode can use `wl-copy`. A Wayland socket is a connection to the compositor, not a clipboard-only capability. A process in the container may be able to access more desktop functionality than clipboard operations. Marking a socket mount read-only does not restrict protocol requests over the socket.

**Possible direction:** test whether the actual OpenCode + terminal workflow supports OSC 52 for copying without mounting the host socket. If not, investigate a narrowly scoped clipboard bridge that exposes only clipboard operations. Do not assume either option works until tested. OpenCode's Linux code also uses `wl-paste` for reading clipboard images, so image paste may need separate consideration.

**Tradeoff:** removing the socket reduces host desktop exposure, but may break clipboard integration. A bridge adds a component to maintain and must be reviewed for its own access controls.

## Environment variables and `.env`

The repository `.env` is used by host-side commands as well as being passed to the devcontainer with `--env-file`. Passing it as an env file makes its variables available to processes inside the container; mounting `/dev/null` over `/workspace/.env` does not undo variables already injected into the process environment.

**Possible direction:** separate host-only values from values the container genuinely needs, and pass only the latter into the container. Preserve the host workflows that require Git, kubeconfig, or other local commands; do not simply remove `.env` support.

## SSH credentials

The private SSH key is bind-mounted read-only. Read-only prevents modification through that mount, but processes in the container can still read the key contents.

**Possible direction:** use the host SSH agent instead of mounting the private key. This avoids exposing the key file, but the container can still request signatures while it has access to the agent socket. Treat agent access as sensitive and limit its scope accordingly.

## Kubernetes credentials

Broad access to a development cluster is an intentional workflow requirement. The important boundary is preventing production credentials, especially admin credentials, from being selected or copied into the development credential staging area.

**Possible direction:** strengthen the production-credential detection so it does not rely only on source file paths, and keep production and development staging clearly separated. Review the service-account token handling separately, including whether it is exposed in process arguments during kubeconfig generation.

## Deferred review

- Confirm the actual host compositor, terminal, and OpenCode clipboard behavior before changing the Wayland integration.
- Validate every proposed mitigation against the existing host-side and container-side workflows.
- No runtime rebuild or credential-flow test has been performed for these notes.
