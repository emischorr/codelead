# 0006 — Harness binaries per libc flavor, matched by probing the task image

## Status

Accepted (2026-08-15)

## Context

The first real container run failed at agent start with
`exec …/harness/0.66.0/claude-agent-acp: no such file or directory` for
a file that existed. The staged binary was
`ELF … dynamically linked, interpreter /lib/ld-musl-aarch64.so.1` — a
musl-*dynamic* executable — while the declared task image
(`elixir:1.18-otp-27`) is Debian-based: no musl loader, so `execve`
fails with ENOENT for the missing *interpreter*, not the file.

Two assumptions from ADR-0004 turned out false, verified empirically:

- **Bun's musl builds are dynamically linked, not static.** A
  musl-compiled standalone binary runs only on musl images; a
  glibc-compiled one only on glibc images. One binary cannot serve both
  libc families.
- **A same-platform `--target` does nothing.** Compiling with
  `--target=bun-linux-arm64` from the alpine bun produced a
  byte-identical musl binary (same BuildID) — for the running platform,
  bun embeds *itself*, so the libc of the *build image* is the libc of
  the output.

## Decision

- **Stage one harness binary per libc flavor**:
  `harness/<version>/<flavor>/claude-agent-acp`, `flavor ∈ {musl,
  glibc}`. The deployed image bakes both (built in two Dockerfile
  stages, `oven/bun:1-alpine` and `oven/bun:1`, each compiling
  natively); `HARNESS_SOURCE` becomes the directory holding them. The
  lazy in-docker build (ADR-0005) selects the flavor by build image the
  same way.
- **The task image's libc is probed at spawn time** — one `docker exec
  … sh -c` checking for a musl loader in the already-running container,
  per spawn, ~50 ms. Staging therefore moves from preflight to spawn:
  `available?/1` is back to cheap checks (the flavor is unknowable
  before a container exists), and a first-per-flavor build now happens
  after the clone, inside the driver's `start_run`, surfacing through
  the same dispatch-failure path (verified end to end).
- The glibc flavor was validated against the failing image itself: the
  `oven/bun:1`-built binary starts cleanly inside
  `elixir:1.18-otp-27`.

Rejected:

- **A single flavor plus an image-family contract** ("use Alpine-based
  images" or "use Debian-based images") — the very first real user
  image already violated whichever family we would have picked.
- **Requiring the missing loader in user images** (gcompat on Alpine,
  musl on Debian) — pushes our packaging problem into every project
  image, exactly what "project images owe us nothing" forbids.

## Consequences

- The first container run per *libc family* pays the one-time build
  (unless the flavor was baked); a mixed fleet of Alpine and Debian
  images pays it twice.
- The glibc flavor inherits the build image's glibc floor (`oven/bun:1`
  is Debian bookworm): task images with an older glibc fail with a
  version error rather than ENOENT.
- The probe requires `sh` in the task image — already part of the image
  contract (`sleep`, shell, git).
- ADR-0004's "musl-static runs everywhere" claim is corrected here;
  0004 and 0005 stay unedited (ADRs are immutable) and are refined, not
  contradicted, in their decisions' substance: mounted binaries, lazy
  serialized builds.
