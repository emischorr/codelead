# Once:
# - docker buildx create --name multiarch --driver docker-container --use
# - docker login ghcr.io
# build & push it:
# docker buildx build --platform=linux/amd64,linux/arm64 --no-cache -t ghcr.io/emischorr/codelead:0.1.0 -t ghcr.io/emischorr/codelead:latest --push .

ARG RELEASE_NAME=code_lead

ARG ELIXIR_VERSION="1.20.3"
ARG ERLANG_VERSION="28.5.0.5"
ARG ALPINE_VERSION="3.23.5"

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

# Keep in sync with the harness_version default in config/runtime.exs.
ARG CLAUDE_ACP_VERSION=0.66.0

# The devcontainer CLI provisioning task environments (ADR-0009).
ARG DEVCONTAINER_CLI_VERSION=0.88.0

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

# devcontainer-cli stage
# Bundle the devcontainer CLI the same way as the harness: built on the
# runner image so npm resolves musl-flavored packages, copied in below,
# resolved through PATH by the nodejs already in the runner.
FROM ${RUNNER_IMAGE} AS devcontainer-cli

ARG DEVCONTAINER_CLI_VERSION

# `devcontainer --version` fails the build loudly if the CLI's node
# floor ever outruns Alpine's nodejs.
RUN apk add --no-cache nodejs npm \
  && npm install -g --prefix /opt/devcontainer --no-fund --no-audit \
  "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}" \
  && /opt/devcontainer/bin/devcontainer --version


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
#
# The rest is the agent's own toolbox — an ACP session runs shell commands, and
# on a bare Alpine it has none of this:
# bash: BusyBox ships no `bash` applet, and the harness's shell tool invokes
#   bash, so without it every shell call the agent makes fails.
# coreutils/findutils/grep/sed/diffutils: the GNU builds. BusyBox applets carry
#   the same names but reject flags agents reach for by habit (`grep -P`,
#   `find -printf`, `sort -V`, `date -d`); a silently-different flag is worse
#   than a missing binary.
# curl/jq/ripgrep: near-universal in agent-authored commands.
# openssh-client: git remotes over ssh.
#
# docker-cli: the container executor drives sibling task containers through
#   the host daemon (`/var/run/docker.sock` mounted by the compose stack) —
#   the CLI only, no daemon.
# docker-cli-compose/-buildx: the devcontainer CLI orchestrates
#   compose-based configs and builds Dockerfile-based ones (ADR-0009).
#
# `bash --version` fails the build loudly if the package ever goes missing,
# the same guard the harness stage puts on node.
RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates git nodejs \
  bash coreutils findutils grep sed diffutils curl jq ripgrep openssh-client \
  docker-cli docker-cli-compose docker-cli-buildx su-exec \
  && bash --version

ENV USER="elixir"

WORKDIR "/app"

# Create  unprivileged user to run the release
RUN \
  addgroup \
  -g 1000 \
  -S "${USER}" \
  && adduser \
  -s /bin/bash \
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

# The bundled devcontainer CLI, same mechanism.
COPY --from=devcontainer-cli /opt/devcontainer /opt/devcontainer
ENV PATH="/opt/devcontainer/bin:${PATH}"

# The container-execution harness is NOT baked into this image: it is a
# staged runtime directory (bun + package tree, ADR-0007), built lazily
# onto the workspace volume via the docker socket on the first container
# run per libc flavor. HARNESS_VERSION pins which adapter version that
# staging installs.
ARG CLAUDE_ACP_VERSION
ENV HARNESS_VERSION=${CLAUDE_ACP_VERSION}

# The one-shot harness build container runs as this uid:gid so files it
# writes to the shared volume stay owned by the service user below. Task
# containers get their user from the repo's devcontainer config instead
# (ADR-0009).
ENV CONTAINER_USER=1000:1000

# Alpine's /etc/profile assigns PATH outright rather than extending it, so a
# *login* shell starts with none of the ENV above. That matters because the
# agent harness builds its shell snapshot from a login shell: without this,
# anything installed outside the profile's fixed list — the harness here, and
# any toolchain an operator layers on in /opt or $HOME — is invisible to every
# command the agent runs.
RUN printf 'export PATH="/opt/harness/bin:/opt/devcontainer/bin:$PATH"\n' > /etc/profile.d/codelead-path.sh

# Mutable state, kept out of the release directory. Mount a volume here:
# `home` is where the agent harness writes its own config and session state,
# `workspace` holds base clones, task worktrees and task folders.
RUN mkdir -p /data/home /data/workspace && chown -R "${USER}":"${USER}" /data
ENV HOME=/data/home
ENV WORKSPACE_ROOT=/data/workspace

# The harness reads `$SHELL` to decide what to run agent commands under, and a
# container inherits none. Naming it here beats letting it fall back.
ENV SHELL=/bin/bash

# copy release executables
COPY --from=builder --chown="${USER}":"${USER}" /app/_build/"${MIX_ENV}"/rel/"${RELEASE_NAME}" ./

# The image starts as root on purpose: the entrypoint owns the DATA_ROOT
# bind's roots and grants itself the docker socket's group — the two things
# an unprivileged container would need host preparation for — then drops to
# the service user via su-exec before starting the release. A compose
# `user: "1000:1000"` override skips all of it (hardened mode).
COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["/app/bin/server"]
