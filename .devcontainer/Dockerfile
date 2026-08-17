# Matches .tool-versions and the prod Dockerfile's pins (Elixir 1.20.3 /
# Erlang 28.5.0.5). Debian rather than prod's Alpine: glibc, apt, and
# script(1) for CodeLead's PTY terminal come for free in a dev image.
FROM hexpm/elixir:1.20.3-erlang-28.5.0.5-debian-trixie-20260803

# git: deps (heroicons is a git dep) and the product's own workflow;
# build-essential: the bcrypt_elixir NIF; inotify-tools: Phoenix live
# reload on Linux; postgresql-client: psql against the db service.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential inotify-tools postgresql-client ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root, uid 1000: the devcontainer CLI remaps it to the workspace
# owner on Linux (updateRemoteUserUID), and CodeLead execs run as it
# via remoteUser.
RUN useradd -m -u 1000 -s /bin/bash dev

# Hex/rebar outside $HOME: CodeLead execs override HOME per task (the
# agent home), so the toolchain must not live there.
#
# MIX_BUILD_ROOT off the workspace mount: a host checkout's _build holds
# host-compiled artifacts (the bcrypt NIF, esbuild/tailwind binaries)
# that would poison Linux builds — and vice versa. Compiles in here land
# in a container-local dir instead and persist for the container's life.
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex MIX_BUILD_ROOT=/opt/build LANG=C.UTF-8
RUN mkdir -p /opt/mix /opt/hex /opt/build && chown -R dev:dev /opt/mix /opt/hex /opt/build

USER dev
RUN mix local.hex --force && mix local.rebar --force
