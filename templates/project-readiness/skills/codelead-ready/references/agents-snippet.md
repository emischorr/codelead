# The block to write into the project's `CLAUDE.md` / `AGENTS.md`

Step 6 of `SKILL.md`. Copy the block below verbatim, with `<!-- STACK LINE -->`
and `<!-- PROVISION LINE -->` replaced from the tables underneath. If the
project already has a *CodeLead preview contract* section, update that one
instead of appending a second.

> Kept identical to `templates/project-readiness/AGENTS-snippet.md` in the
> CodeLead repo — change both or neither.

```markdown
## CodeLead preview contract

This repository is developed with CodeLead. Tasks run in a git worktree and
the Review tab previews this app's dev server, so a few things have to keep
working. Check them before touching dev config, the server entrypoint, or how
URLs and assets are emitted.

CodeLead exports three variables into the preview command and into every
terminal session. All three are absent in ordinary local dev, so each rule
below must be a no-op when they are unset:

- `PREVIEW_PORT` — the port to listen on. **Bind it; never hardcode a port.**
  Fall back to this project's usual port when unset.
- `PREVIEW_BASE_PATH` — the path prefix this app is served under, e.g.
  `/preview/42`, with **no trailing slash**; empty when the app owns its own
  origin. **Honor it:** <!-- STACK LINE -->
- `PREVIEW_ORIGIN` — the browser-facing origin the preview is reached at.

The rest holds whether or not those variables are set:

- **Bind `0.0.0.0`, not `127.0.0.1`.** When the task runs in a container the
  preview reaches this app over the container network, and a socket bound to
  the container's own loopback is invisible to it.

- **Never write a root-absolute URL by hand.** The preview proxy never
  rewrites response bodies, so `href="/"`, `src="/assets/…"`, `url("/fonts/…")`
  in CSS, `fetch("/api/…")` and hardcoded websocket paths escape the prefix and
  hit CodeLead instead of this app. Use the router's own path helper; make CSS
  urls relative to where the *bundle* lands. A hardcoded socket path is the
  worst case — it makes the preview reload itself in a loop.

- **The dev server must be a single process.** Database setup and seeds belong
  in `.devcontainer` lifecycle hooks (`postCreateCommand` / `postStartCommand`),
  never chained onto the start command with `&&`.

- **Don't re-install what the image already has.** The devcontainer installs
  dependencies at image-build time, keyed on the lockfile, and the hooks have
  already run setup and migrations by the time you get a shell. Concretely:
  <!-- PROVISION LINE --> Re-running the project's setup command at the start
  of a task costs minutes and tokens for nothing — do it only after you change
  the manifest or lockfile.

- **Keep toolchain state out of `$HOME`.** CodeLead overrides `HOME` per task,
  so anything installed under `~` (nvm, rustup, pyenv, cargo, hex) is invisible
  to agents — point those at `/opt/…` in the devcontainer image instead. Build
  output belongs off the shared workspace mount for the same class of reason.
```

---

## Stack lines

Replace `<!-- STACK LINE -->` with the row for your stack. These are the same
recipes as [`docs/configuration.md`](https://github.com/emischorr/codelead/blob/main/docs/configuration.md#preview-base-path),
which stays authoritative.

| Stack | Line to paste |
|---|---|
| Vite | it rides in the CodeLead-side preview command as `--base "$PREVIEW_BASE_PATH/"`, so leave this repo's own config alone. |
| Next.js | set `basePath: process.env.PREVIEW_BASE_PATH ?? ""` in `next.config`. |
| Phoenix | set `url: [path: System.get_env("PREVIEW_BASE_PATH", "/")]` on the endpoint in `config/dev.exs`. |
| Rails | set `config.relative_url_root = ENV["PREVIEW_BASE_PATH"]`. |
| Django | set `FORCE_SCRIPT_NAME = os.environ.get("PREVIEW_BASE_PATH") or None` and derive `STATIC_URL` from it. |
| Static files | nothing to do — serve the directory and keep every asset path relative. |

Replace `<!-- PROVISION LINE -->` with the row for your stack, adjusted to the
paths the devcontainer image actually uses — the ones step 5 audited for. Say
where things landed: a name an agent can check beats a rule it has to trust.

| Stack | Line to paste |
|---|---|
| Phoenix | deps are at `$MIX_DEPS_PATH` (**not** `./deps`), `_build` is `$MIX_BUILD_ROOT`, and hex/rebar live in `$MIX_HOME`/`$HEX_HOME` — don't run `mix setup` or `mix deps.get`. |
| Rails | gems are installed under `$GEM_HOME` with `$BUNDLE_PATH` pointing at it — don't run `bundle install`. |
| Vite / Next.js | `node_modules` is installed in the image — don't run `npm install` / `pnpm install`. |
| Django | the virtualenv is at `/opt/venv` and already on `PATH` — don't create one or re-run `pip install`. |
| Static files | nothing is installed; there is nothing to skip. |

And the flag that binds every interface, if your start command needs one
spelled out:

| Stack | Flag |
|---|---|
| Phoenix | `http: [ip: {0, 0, 0, 0}]` |
| Vite | `--host` |
| Next.js | `-H 0.0.0.0` |
| Rails | `-b 0.0.0.0` |
| Django | `runserver 0.0.0.0:$PREVIEW_PORT` |
