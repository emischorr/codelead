# Once:
# - docker buildx create --name multiarch --driver docker-container --use
# - docker login ghcr.io
# build & push it:
# docker buildx build --platform=linux/amd64,linux/arm64 --no-cache -t ghcr.io/emischorr/code_lead:0.1.0 -t ghcr.io/emischorr/code_lead:latest --push .

ARG RELEASE_NAME=code_lead

ARG ELIXIR_VERSION="1.20.3"
ARG ERLANG_VERSION="28.5.0.5"
ARG ALPINE_VERSION="3.23.5"

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

ARG CLAUDE_ACP_VERSION=0.66.0

# -----------------------------------------------------------------------------
ARG MIX_ENV="prod"

# harness stage
# Bundle the Claude Code ACP harness. This stage reads nothing from the repo,
# so it caches independently of the application source. It builds on the runner
# image so that the musl-specific packages npm resolves match the image the
# harness ends up in.
FROM ${RUNNER_IMAGE} AS harness

ARG CLAUDE_ACP_VERSION

# `node --version` fails the build loudly if Alpine ever ships Node < 22, which
# the harness requires.
RUN apk add --no-cache nodejs npm && node --version

# --prefix keeps npm itself out of what we copy: the package lands in
# /opt/harness/lib/node_modules and is linked as
# /opt/harness/bin/claude-agent-acp (a relative symlink, so COPY keeps it).
RUN npm install -g --prefix /opt/harness --no-fund --no-audit \
  "@agentclientprotocol/claude-agent-acp@${CLAUDE_ACP_VERSION}"


# -----------------------------------------------------------------------------

# build stage
FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apk add --no-cache build-base git python3 curl

# sets work dir
WORKDIR /app

# Needed for cross platform builds with newer erlang (27+). Also prevent Erlang from trying to initialize a TTY during the build
# see: https://elixirforum.com/t/mix-deps-get-memory-explosion-when-doing-cross-platform-docker-build/57157/3
ENV ERL_FLAGS="-noinput +JPperf true"

# install hex + rebar
RUN mix local.hex --force && \
  mix local.rebar --force

# redeclare it as it is lost after the FROM above
ARG MIX_ENV
ENV MIX_ENV="${MIX_ENV}"

COPY . /app

# install mix dependencies
RUN mix deps.get --only $MIX_ENV

# compile dependencies
RUN mix deps.compile

# compile project
RUN mix compile

# Compile assets
RUN mix assets.deploy

# assemble release
RUN mix release $RELEASE_NAME


# -----------------------------------------------------------------------------

# app stage
FROM ${RUNNER_IMAGE} AS runner

ARG RELEASE_NAME
ARG MIX_ENV

# install runtime dependencies
# git: the app clones workspace repos, manages task worktrees and pushes task
#   branches to origin from inside the release.
# ca-certificates: Alpine ships no CA bundle, without it every outbound HTTPS
#   call (LLM APIs, git over https) fails TLS verification.
# nodejs: runs the ACP harness copied in below (npm stays in the harness stage).
RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates git nodejs

ENV USER="elixir"

WORKDIR "/app"

# Create  unprivileged user to run the release
RUN \
  addgroup \
  -g 1000 \
  -S "${USER}" \
  && adduser \
  -s /bin/sh \
  -u 1000 \
  -G "${USER}" \
  -h "/home/${USER}" \
  -D "${USER}" \
  && su "${USER}" \
  && chown "${USER}":"${USER}" /app

# The bundled ACP harness. `#!/usr/bin/env node` in its bin script resolves
# through PATH to the nodejs installed above.
COPY --from=harness /opt/harness /opt/harness
ENV PATH="/opt/harness/bin:${PATH}"

# Mutable state, kept out of the release directory. Mount a volume here:
# `home` is where the agent harness writes its own config and session state,
# `workspace` holds base clones, task worktrees and task folders.
RUN mkdir -p /data/home /data/workspace && chown -R "${USER}":"${USER}" /data
ENV HOME=/data/home
ENV WORKSPACE_ROOT=/data/workspace

# run as user
USER "${USER}"

# copy release executables
COPY --from=builder --chown="${USER}":"${USER}" /app/_build/"${MIX_ENV}"/rel/"${RELEASE_NAME}" ./

CMD ["/app/bin/server"]
