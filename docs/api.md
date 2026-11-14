# JSON API (last updated: 2026-11-14)

A small REST API under `/api/v1` lets external clients — first a CLI used
from Claude Code sessions — **file tasks** into a project. It is deliberately
narrow: it never starts, schedules, edits or transitions anything. Humans
organize and run work on the board; the API only puts tasks into Planning.

Decision record: [ADR-0017](adr/0017-api-personal-access-tokens.md).

## Requirements

- **A license that includes `:api_access`.** API access is a licensed
  feature (see [`licensing.md`](licensing.md)). Without it every `/api`
  request is refused with `403 license_required` — with or without a token.
- **A personal access token.** Create one under *Account → API tokens*
  (`/users/settings/tokens`). Creation re-asks for your login if you
  haven't signed in during the last few minutes (sudo mode).

## Authentication

Send the token as a bearer token. Nothing else authenticates an API request
— no session cookie, no CSRF token — and a bearer token authenticates
nothing outside `/api`.

```bash
export FRONTSEAT_URL=https://frontseat.example.com
export FRONTSEAT_TOKEN=fs_pat_…

curl -H "Authorization: Bearer $FRONTSEAT_TOKEN" "$FRONTSEAT_URL/api/v1/me"
```

A token **acts as its user**: the request gets the same instance role and
project memberships a browser session for that user would get. There are no
per-token scopes and no project-bound tokens. Tokens start with `fs_pat_`,
so `grep` and secret scanners recognize them; FrontSeat stores only a hash,
so a lost token cannot be shown again — revoke it and create a new one.

Each token has a name, an optional expiry, and a last-used time (updated at
most every five minutes). Revoking deletes it, effective on the next request.
Deleting a user deletes their tokens. Changing a password or logging in by
magic link does **not** revoke tokens.

## Request pipeline

Every `/api` request passes, in order:

1. **Setup** — before the first-run wizard: `503 setup_required`.
2. **License** — without `:api_access`: `403 license_required`.
3. **Token** — missing, malformed, unknown, revoked or expired: `401
   unauthorized` (with `WWW-Authenticate: Bearer realm="FrontSeat"`). The
   response never says which.

Authorization then happens inside the contexts (`FrontSeat.Accounts.Policy`),
exactly as for the web UI. A project you cannot view answers `404` — the
same as one that does not exist.

## Errors

One shape for every error:

```json
{"error": {"code": "validation_failed",
           "message": "The request has invalid fields.",
           "fields": {"title": ["can't be blank"]}}}
```

`code` is stable and machine-readable; `message` can be shown to a person
as is; `fields` appears only on `422`.

| Status | `code` | When |
|---|---|---|
| 401 | `unauthorized` | missing, malformed, unknown, revoked or expired token |
| 403 | `license_required` | the instance's license does not include `api_access` |
| 404 | `not_found` | unknown route, unknown project, or a project you cannot view |
| 422 | `validation_failed` | invalid input; per-field messages in `fields` |
| 503 | `setup_required` | the instance has not been through first-run setup |

## Endpoints

Successful responses wrap their payload in `data`. Lists return at most 100
items; there is no pagination yet. `:project_id` is the project's numeric id
(as in the web UI's URLs, and as `GET /projects` returns it).

### `GET /api/v1/me`

The token's user, so a client can check its configuration.

```bash
curl -H "Authorization: Bearer $FRONTSEAT_TOKEN" "$FRONTSEAT_URL/api/v1/me"
# {"data": {"id": 3, "username": "enrico", "role": "member"}}
```

`role` is the instance role (`admin` or `member`).

### `GET /api/v1/projects`

The projects the caller can view: their memberships, or all projects for
an admin.

```bash
curl -H "Authorization: Bearer $FRONTSEAT_TOKEN" "$FRONTSEAT_URL/api/v1/projects"
# {"data": [{"id": 1, "name": "frontseat"}]}
```

### `GET /api/v1/projects/:project_id/tasks`

The project's tasks, archived and cancelled ones excluded, newest first —
enough to check for duplicates before creating. Optional `state` filter:
`planning`, `running`, `review` or `done`.

```bash
curl -H "Authorization: Bearer $FRONTSEAT_TOKEN" \
  "$FRONTSEAT_URL/api/v1/projects/1/tasks?state=planning"
```

```json
{"data": [{"id": 42, "title": "Add CSV export", "description": "…",
           "state": "planning",
           "creator": {"id": 3, "username": "enrico"},
           "inserted_at": "2026-11-14T15:40:00Z",
           "updated_at": "2026-11-14T15:40:00Z",
           "url": "https://frontseat.example.com/projects/1/tasks/42"}]}
```

`creator` is `null` for tasks created by the system (seeds, console). `url`
is absolute, built from the instance's configured host (`PHX_HOST`).

### `POST /api/v1/projects/:project_id/tasks`

Creates a task. Any project role — reporter and up — may.

| Field | Required | Notes |
|---|---|---|
| `title` | yes | |
| `description` | no | |
| `work_type` | no | `code` (default), `design`, `content` or `file` |

Any other field is ignored: executor, reviewers, priority and the rest are
decided on the board.

```bash
curl -X POST -H "Authorization: Bearer $FRONTSEAT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title": "Add CSV export", "description": "Export the archive as CSV."}' \
  "$FRONTSEAT_URL/api/v1/projects/1/tasks"
# 201 {"data": {"id": 43, "state": "planning", …}}
```

The task lands exactly where a board-created task does — Planning, idle,
with the same defaults (target, repository, reviewers) — and appears on
open boards immediately. Its creator is the token's user, and its timeline
records **"created via API token '<name>'"**; the token name is copied into
that entry, so the trail survives revoking the token.

## Implementation map

| Piece | Module |
|---|---|
| Token schema (hashing, prefix, expiry choices) | `FrontSeat.Accounts.ApiToken` |
| Token functions | `FrontSeat.Accounts` — `create_api_token/2`, `list_api_tokens/1`, `delete_api_token/2`, `fetch_api_token/1`, `touch_api_token/1` |
| Pipeline plugs | `FrontSeatWeb.ApiAuth` |
| Error shape | `FrontSeatWeb.Api.Error` (also used by `FrontSeatWeb.ErrorJSON`) |
| Controllers | `FrontSeatWeb.Api.MeController`, `ProjectController`, `TaskController`, `FallbackController` |
| Token pages | `FrontSeatWeb.UserLive.Settings.Tokens`, `UserLive.Settings.NewToken` |

Controllers stay thin: they parse the request and call the same context
functions the LiveViews use (`Projects.list_projects/1`,
`Projects.fetch_project/2`, `Tasks.list_tasks/3`, `Tasks.create_task/3`),
passing the token's `Scope`. The scope carries the token's id and name
(`Scope.api_token`) so the context can record provenance; it never changes
what the caller may do.
