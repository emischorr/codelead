#!/bin/sh
# A scripted stand-in for the docker CLI, selected via the :docker_cli
# config as ["sh", <this file>, <scenario>] — the same swap pattern as
# the fake ACP agent behind :harnesses.
#
#   sh fake_docker.sh <scenario> <docker args...>
#
# The scenario names the world state the "daemon" reports; because every
# CLI call is a fresh process, state lives in the scenario, not here.
# A scenario may carry an ACP scenario after a plus sign — for `exec`,
# the script execs the fake ACP agent with it, inheriting stdio so the
# whole Port/JSON-RPC bridge runs for real:
#
#   absent+happy        no container, image present; exec bridges "happy"
#   running             container running with $FAKE_DOCKER_IMAGE
#   running_published   running, with $FAKE_DOCKER_PREVIEW_PORT published
#                       to 127.0.0.1:$FAKE_DOCKER_HOST_PORT
#   stopped             container exists, not running
#   image_mismatch      running, but with a different image than declared
#   no_image            no container, image missing, pull succeeds
#   pull_fails          image missing and the pull fails
#   daemon_down         every command fails with the connect error
#   socket_missing      same, in the newer CLI's wording (socket not mounted)
#   socket_denied       same, but the socket is there and unreadable by our uid
#   start_fails         create ok, start fails (no `sleep` in the image)
#   exec_dies           exec exits 137 (container killed mid-run)
#   orphans             `ps` lists two reapable containers
#   build_fails         `run` (the harness build) fails with a registry error
#
# `run` is the one-shot harness build: it succeeds under every scenario
# except build_fails, simulating the build by scanning argv for the
# discrete `-e OUT=<path>` flag and writing a fake binary there — that
# flag exists precisely so this script never has to parse the sh -c
# build script.
#
# An `exec` whose argv mentions ld-musl is the libc probe: it answers
# $FAKE_DOCKER_LIBC (default glibc) instead of bridging the agent.
#
# Every invocation's argv is appended to $FAKE_DOCKER_LOG (one line per
# call) for tests to assert on.

scenario="$1"
shift

if [ -n "$FAKE_DOCKER_LOG" ]; then
  printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
fi

docker_scenario="${scenario%%+*}"
acp_scenario="${scenario#*+}"

if [ "$docker_scenario" = "daemon_down" ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
  exit 1
fi

if [ "$docker_scenario" = "socket_missing" ]; then
  echo "failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory"
  exit 1
fi

if [ "$docker_scenario" = "socket_denied" ]; then
  echo "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock"
  exit 1
fi

case "$1" in
  container) # container inspect --format '{{.State.Running}}|{{.Config.Image}}|{{json .HostConfig.PortBindings}}' <name>
    bindings="{\"${FAKE_DOCKER_PREVIEW_PORT:-5173}/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"${FAKE_DOCKER_HOST_PORT:-55001}\"}]}"
    case "$docker_scenario" in
      running) echo "true|${FAKE_DOCKER_IMAGE:-img}|null" ;;
      running_published) echo "true|${FAKE_DOCKER_IMAGE:-img}|$bindings" ;;
      stopped) echo "false|${FAKE_DOCKER_IMAGE:-img}|null" ;;
      image_mismatch) echo "true|some-other-image|null" ;;
      *) echo "Error: No such object" && exit 1 ;;
    esac
    ;;
  port) # port <name> <port>/tcp
    case "$docker_scenario" in
      running_published) echo "127.0.0.1:${FAKE_DOCKER_HOST_PORT:-55001}" ;;
      *) echo "Error: No public port published" && exit 1 ;;
    esac
    ;;
  image) # image inspect <ref>
    case "$docker_scenario" in
      no_image | pull_fails) echo "Error: No such image" && exit 1 ;;
      *) echo "[]" ;;
    esac
    ;;
  pull)
    case "$docker_scenario" in
      pull_fails) echo "Error response from daemon: manifest unknown" && exit 1 ;;
      *) echo "pulled" ;;
    esac
    ;;
  create)
    echo "f4k3c0ntain3rid"
    ;;
  start)
    case "$docker_scenario" in
      start_fails) echo 'exec: "sleep": executable file not found in $PATH' && exit 1 ;;
      *) echo "started" ;;
    esac
    ;;
  ps)
    case "$docker_scenario" in
      orphans)
        # Task ids are test-data dependent, so a test may override the
        # listing (newlines included) via FAKE_DOCKER_ORPHANS.
        if [ -n "$FAKE_DOCKER_ORPHANS" ]; then
          printf '%s\n' "$FAKE_DOCKER_ORPHANS"
        else
          printf 'abc123 41\ndef456 42\n'
        fi
        ;;
      *) : ;;
    esac
    ;;
  rm)
    echo "removed"
    ;;
  exec)
    case "$*" in
      *ld-musl*)
        echo "${FAKE_DOCKER_LIBC:-glibc}"
        exit 0
        ;;
    esac
    case "$docker_scenario" in
      exec_dies) exit 137 ;;
      *) exec elixir "$(dirname "$0")/fake_acp_agent.exs" "$acp_scenario" ;;
    esac
    ;;
  run)
    # The one-shot harness staging. Simulates the staged runtime
    # directory (wrapper + bun) at the OUT path scanned from argv.
    # Matched against the whole scenario so it composes with a docker
    # state, e.g. "running+build_fails".
    case "$scenario" in
      *build_fails*) echo "error: unable to connect to registry.npmjs.org" && exit 1 ;;
      *)
        out=""
        for arg in "$@"; do
          case "$arg" in OUT=*) out="${arg#OUT=}" ;; esac
        done
        if [ -n "$out" ]; then
          mkdir -p "$out"
          printf 'fake-harness' > "$out/claude-agent-acp"
          printf 'fake-bun' > "$out/bun"
          chmod 755 "$out/claude-agent-acp" "$out/bun"
        fi
        echo "staged"
        ;;
    esac
    ;;
  *)
    echo "fake docker: unhandled command $1" && exit 64
    ;;
esac
