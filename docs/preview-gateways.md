# Preview gateways

How a previewed app reaches the browser, why there is more than one way, and where
each way's cost lands. Two gateways are shipped (`PathProxy`, `SubdomainProxy`);
a third (port-per-task) is designed but **not implemented** — §5 records that design
so a future session can pick it up. Mechanics of the shipped pieces live in
ADR-0008/0011 and `configuration.md`; this document is the comparison and the
reasoning.

## 1. The problem, and the trilemma

CodeLead's proxy never rewrites response bodies (ADR-0008, upheld by ADR-0011).
Body rewriting looks like the free lunch — proxy under any path, fix up the HTML —
but it can never be complete: URLs built in JavaScript by string concatenation,
`fetch` targets, service-worker scopes, sourcemaps, WASM-embedded paths. The result
would be "all apps *mostly* work, and the failures are undebuggable," which is a
worse contract than "some apps need a base-path flag." That rejection stands.

With bodies untouchable, a preview URL has to be honest about where the app lives,
and every gateway design becomes a choice of who pays. Three properties are on the
table; **any gateway gets two**:

1. **No project adaptation** — an unmodified repo previews correctly.
2. **Zero operator configuration** — the standard compose-on-Linux stack works with
   nothing set.
3. **No response-body rewriting** — the proxy stays transparent and debuggable.

- `PathProxy` picks 2 + 3 and gives up 1 — hence the `PREVIEW_BASE_PATH` contract.
- `SubdomainProxy` picks 1 + 3 and gives up 2 — one wildcard DNS record and a
  DNS-01 wildcard certificate, once per instance.
- Body rewriting is the only route to 1 + 2, and it is rejected.

The port-per-task gateway (§5) is the observation that on a **domainless** instance
(LAN/IP, homelab) there is a second way to mint per-task origins — ports instead of
hostnames — that softens the trilemma: the operator configuration it needs (a
published port range) is static enough to ship enabled in the default compose stack,
so in the standard deployment it *behaves* like 1 + 2 + 3.

## 2. What "project adaptation" actually costs

The `PREVIEW_BASE_PATH` tax is not uniform, and the distinction matters:

- **CLI-flag frameworks** (Vite and friends): the flag rides in the repository's
  `preview_command` *inside CodeLead* — `npm run dev -- --base "$PREVIEW_BASE_PATH/"`.
  The repo source is untouched. This is CodeLead-side configuration, not project
  adaptation.
- **Config-file-only frameworks** (Next.js `basePath`, Phoenix `url: [path:]`,
  Rails `relative_url_root`): the repo itself must read the env var in its own
  config. This is the adaptation worth designing away — a project should not need
  CodeLead-specific code to be usable with CodeLead.

Separate from base paths, every preview (under any gateway) expects two things that
are deliberately *not* counted as adaptation, being ordinary dev-server behavior:
bind `$PREVIEW_PORT` (usually a `--port` flag in `preview_command`), and for
container tasks bind `0.0.0.0` so the relay sidecar can reach it.

## 3. The three gateways

All three share one proxy core — `Forwarder` (HTTP via streamed `Req`, websockets
via a `Mint.WebSocket` relay), header hygiene, `Upstream` resolution, and for
container tasks the socat relay sidecar (ADR-0009). A gateway is only two things:
how the browser-facing URL is minted (`PreviewGateway.url_for/1`) and which rewrite
policy applies (`CodeLeadWeb.PreviewProxy.Policy`). Exactly one gateway is active
per instance (ADR-0011).

### 3.1 `PathProxy` — shipped, the default

- **Origin:** none of its own. The preview lives at `/preview/<task_id>/` on
  CodeLead's origin.
- **Auth:** the existing CodeLead session, via the `:preview` router pipeline.
  Nothing new to hand shake — the cheapest auth story of the three.
- **Operator cost:** zero. Works through any reverse proxy, any deployment, because
  it is just more paths on the one port. This is why it is the default and why it
  can never be removed entirely: a 443-only reverse proxy or PaaS-style deployment
  has no other option.
- **Project cost:** the app is reachable under a prefix it doesn't know about.
  The proxy rewrites root-relative `Location` headers and namespaces cookies
  (`sid` → `_clp<id>_sid`, path-scoped), but bodies pass untouched — so absolute
  asset paths, `fetch('/api/...')`, and absolutely-built websocket URLs miss the
  mount unless the app honors `PREVIEW_BASE_PATH`.
- **What stays broken even when honored:** double-submit CSRF (Django, Laravel,
  Angular) 403s on AJAX writes, because client JS looks for the cookie's real name
  and finds the namespaced one. This is structural to sharing an origin under a
  prefix; no amount of adaptation fixes it.
- **Profile served:** every deployment, as the lowest common denominator; the only
  choice for 443-only topologies.

### 3.2 `SubdomainProxy` — shipped, opt-in via `PREVIEW_DOMAIN`

- **Origin:** a real one per task, `task-<id>.<PREVIEW_DOMAIN>`, matched before the
  regular pipeline in an overridden `Endpoint.call/2`.
- **Auth:** the CodeLead session cookie is host-only and doesn't travel to the
  preview origin, so the launch route mints a 60-second task-scoped `Phoenix.Token`
  which the preview host exchanges for its own `_clp_session` cookie (ADR-0011).
- **Operator cost:** wildcard DNS for `*.<PREVIEW_DOMAIN>` plus, under TLS, a
  DNS-01 wildcard certificate — once per instance. Must stay same-site with
  `PHX_HOST` (boot warning otherwise). Dev is free: `PREVIEW_DOMAIN=preview.localhost`
  resolves with zero setup.
- **Project cost:** none. Apps serve at their origin's root; `PREVIEW_BASE_PATH`
  is emitted as `""`; no cookies renamed, no Locations rewritten; `__Host-` cookies
  and double-submit CSRF work as designed. This is the zero-adaptation gold
  standard.
- **Profile served:** instances with a domain. A domainless LAN instance cannot use
  it — that gap is what §5 exists for.

### 3.3 Port-per-task — designed, **not implemented**

- **Origin:** per task via the port: `http://<host>:<port>/`, one port from a
  published range, terminated by CodeLead itself.
- **Auth:** the ADR-0011 token handshake reused, with a per-task session cookie
  *name* — browsers scope cookies by host and ignore the port, so a single
  `_clp_session` would collide across previews and with CodeLead itself.
- **Operator cost:** a published port range. Static enough to ship open in the
  default compose stack, making the standard deployment zero-config. Firewall
  footprint is the honest price; the ports are auth-gated by CodeLead, nothing
  bypasses login.
- **Project cost:** none — same root-origin story as subdomains.
- **Structural weakness:** cookie isolation. Same host ⇒ shared cookie jar across
  ports: two concurrent previews see each other's real-named app cookies (task A's
  Django `sessionid` is sent to task B's Django), and CodeLead's own session cookie
  must be stripped before forwarding upstream. Decided **acceptable** for the
  self-hosted single-operator posture — it is the operator's own tasks on the
  operator's own box — but it is the one dimension where ports are strictly weaker
  than subdomains, and the reason subdomains remain the recommendation wherever a
  domain exists.
- **Profile served:** domainless instances — LAN/IP, homelab, offline.

### 3.4 Side by side

| | `PathProxy` | `SubdomainProxy` | Port-per-task |
|---|---|---|---|
| Status | shipped, default | shipped, `PREVIEW_DOMAIN` opt-in | designed, not built |
| Unmodified repo previews | only prefix-tolerant apps | yes | yes |
| Operator setup | none | wildcard DNS + DNS-01 cert | port range (default-open in compose) |
| Works offline / by IP | yes | no | yes |
| Works behind 443-only proxy | yes | yes (same 443) | no |
| Cookie isolation between tasks | namespaced (renaming breaks double-submit CSRF) | full (real origins) | shared jar (accepted bleed) |
| Auth | app session | 60 s token handshake | token handshake, per-task cookie name |
| Response rewrites | `Location` + cookie renaming | none | none |
| `PREVIEW_BASE_PATH` | required | `""` | `""` |

## 4. Current state of implementation

Shipped today:

- The seam: `CodeLead.PreviewGateway` (`url_for/1`, `upstream_for/1`,
  `preview_env/2` emitting `PREVIEW_BASE_PATH`/`PREVIEW_ORIGIN`/`PREVIEW_PORT`).
  The one browser-facing entry point is `GET /preview/launch/:task_id`.
- Gateway selection in `config/runtime.exs`: `PREVIEW_DOMAIN` set → `SubdomainProxy`,
  else `PathProxy`. The inactive gateway's URLs fail loudly.
- Rewrites as policy: `CodeLeadWeb.PreviewProxy.Policy` — path gateway gets
  `mount_path`/cookie prefix/`Location` rewriting, subdomain gateway gets none.
- The shared core under `lib/code_lead_web/preview_proxy/` and the container-task
  plumbing (`Relay`, `Address`, `Upstream`) — gateway-independent, reusable as-is
  by a third gateway.

References: ADR-0008 (path proxy, no-body-rewriting), ADR-0009 (relay sidecar),
ADR-0011 (new-tab-only, subdomain gateway, token handshake);
`configuration.md` for the `PREVIEW_BASE_PATH` recipes, cookie namespacing, and
`PREVIEW_DOMAIN` setup; `web-ui.md` for the Review tab's preview strip.

## 5. The port gateway design (future work)

Decided direction (design discussion, 2026-08-22): build the port gateway and make
it the **default**, demoting `PathProxy` to an explicit opt-in.

- **Selection rule:** `PREVIEW_DOMAIN` set → `SubdomainProxy` (unchanged, still the
  recommendation for instances with a domain). Otherwise → port gateway, the new
  default. An explicit switch keeps `PathProxy` for 443-only topologies, where the
  whole `PREVIEW_BASE_PATH` machinery and its per-framework recipes survive
  unchanged — they just stop being part of the default operator experience.
- **Compose ships the range open.** Convention over configuration: the default
  stack publishes the preview port range out of the box, so a domainless instance
  previews unmodified repos with zero setup. CodeLead terminates those ports itself
  and runs the same auth gate; the relay sidecar's host ports stay unpublished as
  today.
- **Why plain-http extra ports are viable at all:** ADR-0011's new-tab-only
  decision. With no iframe there is no mixed-content constraint, so a preview tab
  on `http://host:41042/` is fine even when CodeLead itself sits behind TLS.

Design wrinkles recorded for the implementer (settle these first):

1. **The seam contract bends.** `url_for/1` builds URLs from config alone today; a
   port-gateway URL must name a *host*, and on a domainless instance no config
   value knows it (`PHX_HOST` is often `localhost` or wrong). The only trustworthy
   source is the Host header of the launch request — the browser demonstrably
   reached us on it. The launch controller (already the single URL-producing
   surface) has to feed the request host into the seam; this is the one contract
   change to ADR-0011's shape, everything else is additive.
2. **Port↔task assignment is a state question.** Deterministic (id → port) is
   stateless but collides once tasks outlive the range; dynamic assignment keeps a
   table and recycles ports, making stale tabs die silently. Lean: dynamic with a
   table — URLs are minted per click at the launch route, so stale tabs are the
   same accepted-casualty class ADR-0011 already signed off for gateway switches.
3. **A new ADR is required at implementation time.** Shipping this partially
   supersedes ADR-0011 ("the zero-config default remains the path gateway") the
   same way 0011 partially superseded 0008. The decisions above are direction, not
   an accepted ADR.

Known costs, accepted with eyes open: cross-task cookie bleed (§3.3), a third
gateway implementation to maintain, and the port-range firewall footprint of the
default stack.

## 6. Rejected alternatives

- **Body rewriting** (make `PathProxy` transparent by fixing up HTML/JS): rejected
  in ADR-0008 and re-examined here — still rejected, see §1.
- **Magic DNS** (`PREVIEW_DOMAIN=<ip-with-dashes>.nip.io` to get subdomains without
  owning a domain): works mechanically with the shipped `SubdomainProxy`, but fails
  the exact profile it targets. It needs internet-reachable DNS from every client
  (offline/air-gapped is out), and consumer routers with DNS-rebind protection
  (FRITZ!Box being the canonical case) silently refuse public DNS answers that
  resolve to private IPs — the failure mode is "previews don't load and nothing
  says why." Usable as a documented trick, not as the domainless story.
- **Exposing the relay ports directly** (skip the proxy for container tasks): the
  proxy *is* the auth gate; direct exposure would put previews on the network with
  no login. Ports must terminate at CodeLead.
