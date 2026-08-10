# Configuration (last updated: 2026-08-10)

All environment variables are read in `config/runtime.exs` and accessed in
application code via `Application.get_env(:code_lead, ...)` — never
`System.get_env/1` outside of config files (see CODING_GUIDE.md).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ENCRYPTION_KEY` | fixed dev/test key; **required in prod** | Base64-encoded 32-byte key for `CodeLead.Vault` (Cloak AES-GCM). Encrypts provider credentials and the project env store. Generate: `32 \|> :crypto.strong_rand_bytes() \|> Base.encode64()` |
| `WORKSPACE_ROOT` | `<repo>/workspace` (dev/prod), `<repo>/tmp/test_workspace` (test) | Root for CodeLead-managed working state: base clones, per-task git worktrees, task folders. Gitignored. |
| `MAX_CONCURRENT_RUNS` | `2` | Cap on simultaneously executing task runs; excess stays queued. |
| `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, … | — | Standard Phoenix/Ecto prod settings (see `config/runtime.exs`). |

Local dev secrets live in `.envrc` (gitignored, direnv).

## Application config keys

- `:workspace_root` — see above.
- `:max_concurrent_runs` — see above.
- `CodeLead.Vault` — Cloak cipher config (set from `ENCRYPTION_KEY`).
- `Oban` — queues: `rollups` (nightly cost rollups). Test uses
  `testing: :manual`; drain with `Oban.drain_queue/1`.

## Workspace layout (planned)

```
<WORKSPACE_ROOT>/
  repos/<repo-name>/        # managed base clone per linked repository
  worktrees/task-<id>/      # git worktree per :repo-target task
  tasks/<id>/               # task folder per :folder-target task
```
