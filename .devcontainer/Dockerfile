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
# MIX_BUILD_ROOT and MIX_DEPS_PATH off the workspace mount: a host
# checkout's _build holds host-compiled artifacts (the bcrypt NIF,
# esbuild/tailwind binaries) that would poison Linux builds — and vice
# versa — and dependency *source* has the same problem via git deps and
# NIF sources. Both land in container-local dirs instead, prewarmed
# below and shared by every task container through the image layer.
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex MIX_BUILD_ROOT=/opt/build \
    MIX_DEPS_PATH=/opt/deps LANG=C.UTF-8
RUN mkdir -p /opt/mix /opt/hex /opt/build /opt/deps /opt/src \
    && chown -R dev:dev /opt/mix /opt/hex /opt/build /opt/deps /opt/src

USER dev
RUN mix local.hex --force && mix local.rebar --force

# Prewarm deps and the standalone asset binaries at *build* time, keyed
# on mix.lock alone. The host's Docker layer cache is shared by every
# task container, so only a lockfile change pays for this again — the
# lifecycle hooks in devcontainer.json are then left reconciling a
# delta instead of doing minutes of work per task. config/ comes along
# because dep compilation reads compile-time config (same reason as the
# prod Dockerfile).
WORKDIR /opt/src
COPY --chown=dev:dev mix.exs mix.lock ./
COPY --chown=dev:dev config config
RUN mix deps.get \
    && MIX_ENV=dev mix deps.compile \
    && MIX_ENV=test mix deps.compile \
    && mix assets.setup
