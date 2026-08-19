# Roadmap

Ideas and capabilities that are **not planned and not built** — the
holding pen for things worth doing eventually, so a later session picks
them up with the reasoning intact instead of rediscovering it.

Two neighbours own their own lists; nothing here should duplicate them:

- **Product features** for the MVP target state live in
  `codelead-product-spec.md` §11 ("Designed-for-now, built later" and
  "Out of scope on purpose") and `codelead-architecture-spec.md`. Those
  are commitments; this file is not.
- **Decisions already taken** live in `docs/adr/`. An entry here that
  gets built ends up as an ADR or a design note, not as an edit to the
  history.

An item graduates off this list the moment someone plans it properly.

## Preview & terminal

The Review-tab preview and the Terminal tab shipped across ADR-0008,
ADR-0009, ADR-0010, and ADR-0011 (which removed the embedded iframe —
previews open in a new tab — and built `SubdomainProxy` as the
`PREVIEW_DOMAIN` opt-in). Of the three prerequisites this list used to
carry for `SubdomainProxy`, the foreign-origin auth handshake and the
wildcard-DNS/TLS story shipped with ADR-0011, and the `postMessage`
toolbar channel became moot when the iframe went away. What is left:

- **`ExternalPreview` gateway** — for operators who already have a
  branch-deploy pipeline (Coolify PR environments, Vercel/Netlify,
  Heroku-style review apps): the repository declares a URL template
  (`https://task-{id}.preview.example.com`,
  `https://{branch}--app.netlify.app`) or a webhook that returns a URL
  after the agent pushes the branch; CodeLead's contribution is URL
  construction plus a readiness poll — no proxying at all. Honest
  limits: every iteration pays the pipeline's build-and-deploy latency,
  and the repo must be branch-deployable. It is also the correct home
  for stable-URL needs an ephemeral preview can never satisfy —
  registered OAuth callback URLs, webhook receivers under test.
- **Static HTML snapshot** — an enhancement *of* the live preview, not
  a rival to it: automatically capture a static render of declared URLs
  when a run ends, and show it instantly as a "preview image" when the
  task opens, before (or without) starting the live server. Kept future
  by its prerequisites: a per-task/per-repo URL list, seed fixtures for
  meaningful pages, and a bootstrapped session for auth-gated ones.
- **Preview config auto-detection** — pre-fill a repository's
  `preview_port`/`preview_command` from `package.json` or `mix.exs`.
  Explicit config stays the truth; detection only seeds the form.
- **Preview for folder-target tasks** — `PreviewGateway.preview_port/1`
  is repo-only, because the port is declared on the repository. A
  folder task has nowhere to declare one. The terminal covers folder
  targets since ADR-0010; the preview does not.
- **Exec-tunnel upstream fallback** — a `docker exec` socat/nc hop for
  networks where publishing a port is impossible. Named as a fallback
  candidate in ADR-0008, then largely obsoleted by ADR-0009's relay
  sidecar, which joins the task's own network and needs no publishable
  interface beyond the host. Revisit only if a real deployment turns up
  that the sidecar cannot serve.

## Considered and rejected

Kept because the reasoning is easy to lose and the ideas are easy to
re-propose. (The rejections that shaped shipped architecture —
`ReverseProxyPlug`, a shared docker network, response-body rewriting,
`docker exec -t`, a Phoenix channel for the terminal — are in ADR-0008
and ADR-0009 instead.)

- **Screenshot capture as the review mechanism.** Needs a URL list, and
  misses interaction, animation, and UX entirely — exactly what a diff
  already fails to show. May return as a *supplement* on top of the URL
  contract (snapshots into the review record), never as a replacement
  for it.
- **External QA / PR-preview pipelines as *the* answer.** Done already
  pushes a branch or PR, so Vercel/Netlify-style previews come free
  downstream. But judging the work has to be possible *inside* the
  Review gate, or the gate is theater.
- **The embedded preview iframe + toolbar.** Shipped in ADR-0008's
  iteration, removed in ADR-0011: the browser tab's own URL bar,
  history, and devtools are strictly better tooling than a slim
  toolbar could ever be, mobile UX is better in a tab, and deleting the
  frame deleted the entire cross-origin problem class — the
  `contentWindow` guards, the history-stack juggling, and the
  `postMessage` channel a cross-origin toolbar would have needed. Do
  not reintroduce an embedded frame; anything it could show, a tab
  shows better. This also settles two ideas that only made sense inside
  a frame: *viewport presets* (device emulation in the tab's devtools
  is strictly better) and the *shim-page `postMessage` design* (moot
  with no frame to shim).
- **Capture-phase click interception in the preview frame.** Would give
  full host-history isolation for classic multi-page apps, but
  `preventDefault` on a document-level capture listener downgrades
  SPA-router and LiveView links to full page reloads. Moot since
  ADR-0011 — a separate tab has its own history, so the isolation now
  comes free. Kept for the reasoning should an embedded surface ever be
  re-proposed.
- **A `DirectPort` gateway** (exposing each preview's host port to the
  browser directly, no proxy). Only serves LAN/bare-IP installs — which
  `PathProxy` already serves with auth and zero exposed ports — and
  publishes unauthenticated ports everywhere else. No niche left
  between the two shipped gateways.
- **Review-artifact types as preview substitutes** — interaction
  traces, screen recordings, route-diffs captured during the run and
  attached to the review. Each needs per-repo conventions (what to
  record, which routes, what fixtures) that cost more than "start the
  server and look", and all of them cap out below a live preview.
  Snapshots may still land as a *supplement* (see the roadmap entry
  above); the others stay out.
- **Softening the preview cookie namespacing to make double-submit CSRF
  work.** Two variants were weighed when the namespacing shipped, both
  aimed at letting Django/Laravel/Angular JS find `csrftoken` /
  `XSRF-TOKEN` by name inside a preview. *Collision-only renaming*:
  path-scope every cookie to the mount as today, but rename only what
  CodeLead's own pipeline reads on a preview request (`_code_lead_key`,
  `_code_lead_web_user_remember_me`, `request_logger`) plus `__Host-` /
  `__Secure-`, which browsers reject outright once re-pathed. It works —
  RFC 6265 path-matching already isolates `/preview/43` cookies from
  `/preview/42` requests, so renaming is only needed against host
  cookies at `Path=/` — but it trades a provable invariant ("nothing
  un-namespaced reaches the origin") for a denylist that must be kept in
  step with every cookie CodeLead ever reads. *A `document.cookie` shim*
  injected into HTML responses is stronger still and invisible to the
  previewed app, but it breaks the no-body-rewriting decision and has to
  survive gzip, streaming, and the previewed app's own CSP. Both were
  declined in favour of `SubdomainProxy`, which since ADR-0011 removes
  the problem instead of managing it (set `PREVIEW_DOMAIN`).
- **An npm/node-pty toolchain.** xterm.js is vendored like topbar;
  node-pty would drag a native build chain into the project for the
  sake of one ioctl — and ADR-0010 got the resize without it.
