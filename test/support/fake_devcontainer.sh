#!/bin/sh
# A scripted stand-in for the devcontainer CLI, selected via the
# :devcontainer_cli config as ["sh", <this file>, <scenario>] — the same
# swap pattern as fake_docker.sh.
#
#   sh fake_devcontainer.sh <scenario> up --workspace-folder <dir> ...
#
# Like the real CLI under --log-format json, progress events go to
# stderr and the single result object is the last stdout line.
#
#   success           up succeeds with a single-container environment
#   success_compose   up succeeds; the primary belongs to a compose
#                     project ($FAKE_DEVCONTAINER_COMPOSE_PROJECT,
#                     default task-fake_devcontainer)
#   config_error      no devcontainer config found — outcome error
#   build_fails       image build fails — outcome error, build log on
#                     stderr
#   slow              success after a burst of progress events
#
# The reported container id is $FAKE_DEVCONTAINER_CONTAINER_ID (default
# f4k3devc0ntainer — matching what fake_docker.sh's `ps` reports, so the
# two fakes compose into one world).
#
# Every invocation's argv is appended to $FAKE_DEVCONTAINER_LOG (one
# line per call) for tests to assert on.

scenario="$1"
shift

if [ -n "$FAKE_DEVCONTAINER_LOG" ]; then
  printf '%s\n' "$*" >> "$FAKE_DEVCONTAINER_LOG"
fi

container_id="${FAKE_DEVCONTAINER_CONTAINER_ID:-f4k3devc0ntainer}"

progress() {
  printf '{"type":"text","level":3,"text":"%s"}\n' "$1" >&2
}

# A lifecycle milestone, the shape the real CLI emits around
# postCreateCommand and friends.
milestone() {
  printf '{"type":"progress","name":"%s","status":"%s"}\n' "$1" "$2" >&2
}

case "$scenario" in
  success)
    progress "Resolving Remote"
    printf '{"outcome":"success","containerId":"%s","remoteUser":"root","remoteWorkspaceFolder":"/workspaces/x"}\n' "$container_id"
    ;;
  success_compose)
    progress "Resolving Remote"
    project="${FAKE_DEVCONTAINER_COMPOSE_PROJECT:-task-fake_devcontainer}"
    printf '{"outcome":"success","containerId":"%s","composeProjectName":"%s","remoteUser":"root","remoteWorkspaceFolder":"/workspace"}\n' "$container_id" "$project"
    ;;
  config_error)
    printf '{"outcome":"error","message":"Dev container config (.devcontainer/devcontainer.json) not found.","description":"Dev container config not found."}\n'
    exit 1
    ;;
  build_fails)
    progress "Building image"
    progress "ERROR: failed to solve: base image not found"
    printf '{"outcome":"error","message":"Command failed: docker buildx build ...","description":"An error occurred building the image."}\n'
    exit 1
    ;;
  slow)
    progress "Installing feature ghcr.io/devcontainers/features/node:1"
    milestone "Running postCreateCommand..." "running"
    progress "mix setup"
    milestone "Running postCreateCommand..." "succeeded"
    printf '{"outcome":"success","containerId":"%s","remoteUser":"vscode","remoteWorkspaceFolder":"/workspaces/x"}\n' "$container_id"
    ;;
  *)
    echo "fake devcontainer: unhandled scenario $scenario" >&2
    exit 64
    ;;
esac
