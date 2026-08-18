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

The Review-tab preview and the Terminal tab shipped in two iterations
(ADR-0008, extended by ADR-0009 and ADR-0010). What is left:

- **`SubdomainProxy` gateway implementation** — wildcard
  `task-<id>.preview.<host>` instead of the `/preview/:task_id/*` path
  proxy. Separates cookie origins, unlocks apps that cannot be
  path-prefix-hosted (no `PREVIEW_BASE_PATH` to honor), and is the
  prerequisite for managed hosting. It also retires the whole
  same-origin cookie apparatus — the per-task namespacing in
  `PreviewProxy.Headers`, its double-submit-CSRF limitation
  (`docs/configuration.md`, "Cookies in the preview"), the `location`
  rewrite, and the shadow-cookie eviction in `RequirePreviewAccess`.

  The `CodeLead.PreviewGateway` behaviour seam exists for exactly this
  and nothing may grow a direct dependency on `PathProxy` — but **it is
  a swap on the gateway side only.** ADR-0008 and ADR-0009 both call it
  a pure gateway swap; that is wrong, and three prerequisites have to
  land with it:

  1. **Preview auth on a foreign origin.** `RequirePreviewAccess` reads
     `current_scope` from the shared-origin session cookie, which
     `endpoint.ex` sets host-only (no `:domain`) — it is simply absent
     on `task-42.preview.<host>`. Widening it to a wildcard domain
     re-opens the clobbering hazard the namespacing closed, so this
     needs a signed-token or per-subdomain handshake. Nothing in the
     tree anticipates it.
  2. **A `postMessage` channel for the preview toolbar.** Every read in
     the `.PreviewFrame` hook (`task_live/preview_pane.ex`) goes through
     `contentWindow`, and all of it is blocked cross-origin — silently,
     behind empty `catch` blocks. The toolbar would look intact and do
     nothing: path field stuck on `(external page)`, back/forward
     disabled, refresh dead, and the path field navigating to the host
     origin instead of the preview. There is no `postMessage` anywhere
     in the repo today, and injecting the reporting side of it into
     previewed pages collides with ADR-0008's no-body-rewriting call.
  3. **Wildcard DNS and a wildcard TLS cert** (DNS-01 — HTTP-01 cannot
     do wildcards), against a zero-config default of plain HTTP behind
     the operator's own proxy. `ALLOWED_HOSTS` already accepts
     `*.example.com`, but `origin_allowed?/1` in the proxy controller
     hard-codes host equality and would need relaxing and careful
     re-tightening. This is the reason it cannot simply replace
     `PathProxy` as the default.

- **Viewport presets** — mobile/tablet/desktop widths on the preview
  iframe. Cheap, and it matches the mobile-first positioning.
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
- **Capture-phase click interception in the preview frame.** Would give
  full host-history isolation for classic multi-page apps, but
  `preventDefault` on a document-level capture listener downgrades
  SPA-router and LiveView links to full page reloads. Residual cost of
  not doing it: plain full-page link clicks inside the frame still add
  joint-history entries, so the host back button may step an MPA
  preview before it leaves the task page.
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
  declined in favour of waiting for `SubdomainProxy`, which removes the
  problem instead of managing it.
- **An npm/node-pty toolchain.** xterm.js is vendored like topbar;
  node-pty would drag a native build chain into the project for the
  sake of one ioctl — and ADR-0010 got the resize without it.
