# 0011 — New-tab-only preview; subdomain gateway as the `PREVIEW_DOMAIN` opt-in

## Status

Accepted (2026-08-19). Supersedes in part ADR-0008 (the embedded
preview surface — iframe, toolbar, `.PreviewFrame` hook — and the
single-gateway assumption; the path proxy itself, its `:preview`
pipeline, the no-body-rewriting contract, and the terminal decisions
all stand).

## Context

ADR-0008's preview shipped as a slim toolbar over a same-origin iframe
on the Review tab. Living with it showed the toolbar re-implementing,
worse, what every browser already has — history, an address bar,
devtools — while the iframe carried a whole problem class of its own:
`contentWindow` reads wrapped in guards, joint-session-history
juggling, `pushState` patching, and (per the roadmap analysis) a
`postMessage` channel as a hard prerequisite for any cross-origin
gateway, colliding with the no-body-rewriting decision.

Separately, the path proxy's accepted casualties had become concrete:
apps that cannot honor a base path don't preview at all, and
double-submit-CSRF frameworks (Django, Laravel, Angular) 403 on AJAX
writes because their JS cannot find the namespaced cookie
(`docs/configuration.md`). The named fix was always `SubdomainProxy`,
which ADR-0008/0009 mis-described as a pure gateway swap; the roadmap
corrected that to three prerequisites — foreign-origin auth, the
`postMessage` toolbar channel, wildcard DNS/TLS.

(ADR-0008 and ADR-0009 reference a `PREVIEW_ROADMAP.md`; its content
lives in the root `ROADMAP.md` now.)

## Decision

1. **The embedded iframe and its toolbar are removed entirely; a
   preview always opens in its own browser tab.** The Review tab keeps
   a preview strip (run status, Start/Stop, an Open-preview link); the
   tab's own URL bar, back/forward, and devtools are the preview's
   tooling. This deletes the `contentWindow`/history apparatus and
   dissolves the `postMessage` prerequisite outright — which is what
   makes a cross-origin gateway cheap enough to build now.

2. **Browser-facing preview URLs come only from the gateway seam.**
   `PreviewGateway.url_for/1` may now return an absolute URL; no
   caller may assume a path or hand-build one. The single web surface
   producing a preview URL is `GET /preview/launch/:task_id`
   (`PreviewLaunchController`), which the strip links to and which
   redirects onto whatever the active gateway yields.

3. **`SubdomainProxy` exists now, as an opt-in that replaces
   `PathProxy` instance-wide.** Selection is one rule, resolved once at
   boot in `config/runtime.exs`: `PREVIEW_DOMAIN` set → subdomain
   gateway, else path gateway. Exactly one gateway is active; the
   inactive gateway's URLs fail loudly (a stale `/preview/…` link under
   subdomain mode gets a branded page pointing at the launch route).
   There is no per-repo or per-task gateway choice.

4. **Host matching happens in an overridden `Endpoint.call/2`, before
   the plug pipeline.** Phoenix dispatches sockets before all endpoint
   plugs and `Plug.Static` serves `/` for every host, so a plug (or
   router `host:` scope — compile-time, while `PREVIEW_DOMAIN` is
   runtime) can never divert a previewed app's own `/live` websocket or
   `/assets/*` requests. The override pattern-matches
   `task-<id>.<PREVIEW_DOMAIN>` hosts into `CodeLeadWeb.PreviewHost`
   and is a nil-check no-op when the variable is unset. Phoenix's
   generated wrapper still runs outermost, so `secret_key_base` and
   error rendering stay in place.

5. **The proxy plumbing is shared; rewrites are policy.** The
   forwarding core (`PreviewProxy.Forwarder` over `HTTP` and
   `WebSocketRelay`, upstream resolution in `PreviewGateway.Upstream`
   with the ADR-0009 relay sidecar) serves both gateways unchanged.
   What differs is a `PreviewProxy.Policy` struct: under the path
   gateway, cookie namespacing and the root-relative `Location` rewrite
   as before; under the subdomain gateway neither — each task owns a
   real origin, so cookies keep their names and redirects pass through.
   `origin_allowed?/1` stays hard host equality: preview pages open
   their sockets against their own subdomain, so equality holds without
   relaxation.

6. **Foreign-origin auth is a signed-token handshake, not a widened
   cookie.** The app session cookie stays host-only. The launch
   redirect appends a 60-second, task-scoped `Phoenix.Token`
   (`?_preview_auth=`, signed with the endpoint's `secret_key_base` at
   click time); the preview host verifies it, seeds its own host-only
   session cookie (`_clp_session`, a reserved name the policy strips
   from upstream-bound requests), and strips the token via redirect to
   `/`. Authorization stays as coarse as the path gateway: the token
   proves "came from a logged-in CodeLead session", nothing
   finer-grained. Threat model note: the token transits one URL — the
   TTL and the immediate redirect bound the exposure.

7. **Same-site is a constraint, not an engineering target.** The
   documented default is `PREVIEW_DOMAIN=preview.<apex of PHX_HOST>`,
   keeping previews same-site with the app so `SameSite=Lax` cookies
   behave. A foreign registrable domain makes every preview cookie
   third-party; that configuration is unsupported and gets a prominent
   boot warning (`PreviewGateway.DomainCheck`, last-two-labels
   heuristic — no public-suffix list) instead of `Partitioned` /
   `SameSite=None` work. A `PREVIEW_DOMAIN=auto` nicety was rejected:
   deriving the apex correctly needs a public-suffix list, and a wrong
   guess would hit exactly the operators who trusted it.

## Consequences

- Reviewers get real browser tooling on every preview; the mobile
  preview is a plain tab. The Review tab always shows the diff — the
  preview/diff mode toggle and its state are gone.
- Apps that can't be path-prefix-hosted, and double-submit-CSRF apps,
  now have a supported home — at the cost of the one opt-in knob this
  feature adds (`PREVIEW_DOMAIN`) plus operator-side wildcard DNS and a
  DNS-01 wildcard certificate (`docs/deployment.md`). The zero-config
  default remains the path gateway.
- Dev exercises the real subdomain gateway with zero setup:
  `PREVIEW_DOMAIN=preview.localhost` (browsers resolve `*.localhost`
  to loopback).
- Stale subdomain URLs after switching *back* to the path gateway are
  undetectable (no domain left to match) and render the app shell —
  accepted and documented, the reverse direction fails loudly.
- `Plug.Head`'s HEAD→GET conversion applies to path-gateway previews
  (endpoint pipeline) but not subdomain ones (diverted first) —
  deliberate: the subdomain pipeline is maximally transparent.
- A previewed app using the literal cookie name `_clp_session` on a
  preview subdomain would fight the auth marker — reserved, documented,
  vanishingly unlikely.
