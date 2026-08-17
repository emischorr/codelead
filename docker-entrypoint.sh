#!/bin/sh
set -e

# Operator overrode the user (compose `user:`) — hardened mode: no setup,
# host preparation (DATA_ROOT ownership, docker group) is theirs again.
if [ "$(id -u)" != "0" ]; then
  exec "$@"
fi

# The daemon auto-creates a missing DATA_ROOT bind source root-owned; hand
# the roots to the app user. Non-recursive on purpose: contents are created
# by the app itself (and a migrated volume copy already carries uid 1000) —
# a recursive chown over a large workspace on every boot is waste.
for dir in "${WORKSPACE_ROOT:-/data/workspace}" "${HOME:-/data/home}"; do
  mkdir -p "$dir"
  chown elixir:elixir "$dir" "$(dirname "$dir")"
done

# Join whatever group owns the docker socket (naming the gid if no group
# has it yet), so the dropped user can drive sibling task containers.
# No socket mounted, nothing to do.
SOCK=/var/run/docker.sock
if [ -S "$SOCK" ]; then
  gid="$(stat -c %g "$SOCK")"
  group="$(getent group "$gid" | cut -d: -f1)"
  [ -n "$group" ] || { group=docksock; addgroup -g "$gid" "$group"; }
  addgroup elixir "$group" 2>/dev/null || true
fi

# su-exec applies supplementary groups via initgroups, so the membership
# granted above is live for the app without any restart.
exec su-exec elixir "$@"
