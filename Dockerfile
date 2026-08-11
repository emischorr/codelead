# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
# https://hub.docker.com/_/ubuntu/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260112-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: docker.io/hexpm/elixir:1.18.4-erlang-27.2.3-debian-trixie-20260112-slim
#
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.2.3
ARG DEBIAN_VERSION=trixie-20260112-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# The ACP harness is a Node package and needs Node >= 22, which Debian
# trixie does not ship. Take Node from the official image of the *same*
# Debian release so the binary we copy into the runner matches its
# glibc/libstdc++.
ARG NODE_IMAGE="docker.io/node:22-trixie-slim"
ARG CLAUDE_ACP_VERSION=0.66.0

# Bundle the Claude Code ACP harness. This stage reads nothing from the
# repo, so it caches independently of the application source.
FROM ${NODE_IMAGE} AS harness

ARG CLAUDE_ACP_VERSION

# --prefix keeps npm itself out of what we copy: the package lands in
# /opt/harness/lib/node_modules and is linked as
# /opt/harness/bin/claude-agent-acp (a relative symlink, so COPY keeps it).
RUN npm install -g --prefix /opt/harness --no-fund --no-audit \
  "@agentclientprotocol/claude-agent-acp@${CLAUDE_ACP_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

# git is required at runtime: the app clones workspace repos, manages task
# worktrees, and pushes task branches to origin from inside the release.
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Node plus the bundled ACP harness. libstdc++6 (installed above) is the
# only shared library Node needs beyond libc. `#!/usr/bin/env node` in
# the harness bin script resolves through PATH.
COPY --from=harness /usr/local/bin/node /usr/local/bin/node
COPY --from=harness /opt/harness /opt/harness
ENV PATH="/opt/harness/bin:${PATH}"

WORKDIR "/app"
RUN chown nobody /app

# Mutable state, kept out of the release directory. Mount a volume here:
# `home` is where the agent harness writes its own config and session
# state, `workspace` holds base clones, task worktrees and task folders.
RUN mkdir -p /data/home /data/workspace && chown -R nobody /data
ENV HOME=/data/home
ENV WORKSPACE_ROOT=/data/workspace

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/code_lead ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
