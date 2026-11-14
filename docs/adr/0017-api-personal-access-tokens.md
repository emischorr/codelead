# ADR-0017: API authentication via user-bound personal access tokens, gated as a license feature

Date: 2026-11-14
Status: accepted

## Context

External clients — first a CLI driven from Claude Code sessions, later
perhaps an MCP adapter — need to file tasks into a project without a
browser. The app so far authenticates only browser sessions
(`phx.gen.auth`), and authorization (ADR-0014) runs through a `Scope`
built per request. API access is aimed at companies rather than solo
hobby use, so it is a licensed feature from day one.

## Decision

- **Personal access tokens, bound to one user, acting as that user.** A
  token resolves to exactly the `Scope` a browser session for its user
  gets — instance role plus project memberships — so contexts and
  `Policy` work unchanged and no new authorization rule exists. The
  scope additionally carries the token's id and name, used only for
  provenance.
- **Own table, `api_tokens`.** Name (required), optional expiry,
  `last_used_at`, and a SHA-256 hash of the token — never the plaintext,
  which is shown once at creation. Tokens carry an `fs_pat_` prefix so
  they are greppable and visible to secret scanners. Revoking is a hard
  delete; the user foreign key cascades. `last_used_at` is written at
  most once per five minutes, guarded in the `UPDATE`'s `WHERE`.
- **A separate `/api/v1` pipeline, bearer-only.** No session, cookies or
  CSRF; the browser pipeline never reads `Authorization`. Gates run in
  the order setup → license → token, so an unlicensed instance refuses
  every request the same way. A project the caller cannot see is `404`,
  never `403`. One error shape with a machine-readable `code`.
- **Thin controllers.** They call the same context functions as the
  LiveViews with the token's `Scope`; authorization stays in
  `Policy.authorize` at the context boundary.
- **Provenance is recorded, atomically.** A task created through the API
  gets a `:created` step naming the token, inserted in the same
  transaction as the task. The token name is copied into the step, so
  the trail outlives revocation.
- **`:api_access` is one gated feature** covering the endpoints and token
  creation. It is checked per request in the pipeline and in
  `Accounts.create_api_token/2`; the UI mirrors it. The `:owner` tier
  gets it automatically; no paid tier baseline exists yet, so customer
  keys grant it explicitly. Tokens survive a lapse untouched and work
  again when the feature returns; listing and revoking are never gated.
- **Minting requires sudo mode** on its own page, the per-action pattern
  of the email and password pages; listing and revoking do not.

## Rejected alternatives

- **Storing PATs in `users_tokens`.** That table has no name, expiry or
  last-used columns, stores session tokens unhashed, and — decisively —
  its rows are deleted wholesale on every password change and magic-link
  login, which would silently revoke API credentials.
- **Reusing session tokens** as API credentials: they expire on a
  session clock, are tied to a browser login, are not hashed, and could
  not be named, listed or revoked individually.
- **Per-token scopes / permissions.** A second authorization axis beside
  `Policy`, before any client needs less than its user's rights.
- **Project-bound tokens.** Same objection; a narrower credential can be
  added later as a restriction on top of the user's scope.
- **OAuth (authorization-code or device flow).** Heavy for a self-hosted
  instance and a CLI; nothing a third-party client needs yet.
- **An ungated API.** API access is a company feature; the license seam
  exists for exactly this.
- **Deleting tokens when the license lapses.** Destroys user-created
  credentials over a billing state; refusing at the gate is enough and
  reverses itself when the feature returns.
- **Recording provenance for board-created tasks too.** The timeline's
  start marker already is a board task's creation; only the API path has
  a credential to name.

## Consequences

- External clients get a stable, minimal surface; every new endpoint is
  a thin controller over an existing scoped context function.
- A leaked token carries its user's full rights until it expires or is
  revoked. Expiry is optional; the UI defaults to 90 days.
- No rate limiting, pagination or admin oversight of other users' tokens
  yet.
- `Tasks.list_tasks/3` and `Projects.fetch_project/2` are new scoped
  reads; the board's own `Tasks.board/1` stays unscoped behind the
  router's project-access gate.
