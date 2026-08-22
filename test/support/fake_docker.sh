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
#   absent+happy        no task container; exec bridges "happy"
#   running             the task's devcontainer is running
#   stopped             the task's devcontainer exists, not running
#   daemon_down         every command fails with the connect error
#   socket_missing      same, in the newer CLI's wording (socket not mounted)
#   socket_denied       same, but the socket is there and unreadable by our uid
#   exec_dies           exec exits 137 (container killed mid-run)
#   orphans             `ps` lists reapable containers
#   build_fails         `run` (the harness build) fails with a registry error
#
# `run` is the one-shot harness build: it succeeds under every scenario
# except build_fails, simulating the build by scanning argv for the
# discrete `-e OUT=<path>` flag and writing a fake binary there — that
# flag exists precisely so this script never has to parse the sh -c
# build script.
#
# An `exec` whose argv mentions ld-musl is the libc probe: it answers
# $FAKE_DOCKER_LIBC (default glibc) instead of bridging the agent. An
# `exec` carrying `kill -0` is preview adoption's liveness probe and
# answers $FAKE_DOCKER_PID_ALIVE (default 0, i.e. gone); one carrying
# `kill -TERM` is a session stopper and always succeeds, leaving only
# its argv in the log.
#
# The preview relay sidecar reads its own knobs: `inspect` of the task
# container's networks reports the task container on the bridge at
# $FAKE_DOCKER_TASK_IP (default 172.17.0.5) whenever the scenario has a
# running container; `inspect` of the relay reports the relay per
# $FAKE_DOCKER_RELAY (unset = absent, running, stopped) with the target
# label $FAKE_DOCKER_RELAY_TARGET; `port` answers
# $FAKE_DOCKER_PUBLISH_IP:$FAKE_DOCKER_HOST_PORT (defaults
# 127.0.0.1:55001); a relay `run -d` just logs and reports an id.
#
# The devcontainer executor's lookups: `ps` filtered on the
# task_container id-label answers the scenario's container state with
# the id $FAKE_DEVCONTAINER_CONTAINER_ID (default f4k3devc0ntainer,
# matching fake_devcontainer.sh); `inspect` of the compose-project
# label answers $FAKE_DOCKER_COMPOSE_PROJECT (default none); `inspect`
# of devcontainer.metadata answers $FAKE_DOCKER_METADATA (default []);
# `compose` (project down) just logs.
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
  inspect) # inspect -f <format> <name> — the executor's/relay's lookups
    case "$*" in
      *NetworkSettings.Networks*) # the task container's network + ip
        case "$docker_scenario" in
          running | exec_dies)
            echo "{\"bridge\":{\"IPAddress\":\"${FAKE_DOCKER_TASK_IP:-172.17.0.5}\"}}"
            ;;
          *) echo "Error: No such object" && exit 1 ;;
        esac
        ;;
      *preview_target*) # the relay's running state + target label
        case "$FAKE_DOCKER_RELAY" in
          running) echo "true|${FAKE_DOCKER_RELAY_TARGET}" ;;
          stopped) echo "false|${FAKE_DOCKER_RELAY_TARGET}" ;;
          *) echo "Error: No such object" && exit 1 ;;
        esac
        ;;
      *com.docker.compose.project*) # is the primary part of a compose project?
        echo "${FAKE_DOCKER_COMPOSE_PROJECT:-}"
        ;;
      *devcontainer.metadata*) # the merged devcontainer config (exec user)
        echo "${FAKE_DOCKER_METADATA:-[]}"
        ;;
      *) echo "fake docker: unhandled inspect $*" && exit 64 ;;
    esac
    ;;
  network) # network inspect bridge -f <format> — the bridge gateway probe
    echo "${FAKE_DOCKER_BRIDGE_GATEWAY:-172.17.0.1}"
    ;;
  port) # port <relay name> <port>/tcp
    echo "${FAKE_DOCKER_PUBLISH_IP:-127.0.0.1}:${FAKE_DOCKER_HOST_PORT:-55001}"
    ;;
  ps)
    # The devcontainer executor resolves the task's primary container by
    # its id-labels; the docker state scenarios answer for it.
    case "$*" in
      *label=codelead.task_container=true*)
        case "$docker_scenario" in
          running | exec_dies | orphans) echo "${FAKE_DEVCONTAINER_CONTAINER_ID:-f4k3devc0ntainer}|running" ;;
          stopped) echo "${FAKE_DEVCONTAINER_CONTAINER_ID:-f4k3devc0ntainer}|exited" ;;
          *) : ;;
        esac
        exit 0
        ;;
    esac
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
  compose)
    # compose -p <project> down --volumes --remove-orphans
    echo "compose ok"
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
      *"kill -0"*)
        # Preview adoption's liveness probe: is the recorded pid still
        # serving inside the container?
        [ "${FAKE_DOCKER_PID_ALIVE:-0}" = "1" ] && exit 0
        exit 1
        ;;
      *"kill -TERM"*)
        # A stopper. Only the argv log matters; it always succeeds.
        exit 0
        ;;
    esac
    case "$docker_scenario" in
      exec_dies) exit 137 ;;
      *) exec elixir "$(dirname "$0")/fake_acp_agent.exs" "$acp_scenario" ;;
    esac
    ;;
  run)
    # A relay `run -d --name codelead-preview-<id> ...` only needs an id.
    case "$*" in
      *codelead-preview-*)
        echo "f4k3r3l4yid"
        exit 0
        ;;
    esac
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
