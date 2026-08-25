# Making a project CodeLead-ready

Two drop-in templates for repositories you develop **with** CodeLead. Neither
is needed to run CodeLead itself.

- [`AGENTS-snippet.md`](AGENTS-snippet.md) — paste into the project's
  `CLAUDE.md` / `AGENTS.md` so agents stop breaking the live preview.
  Substitute one line from the stack table at the bottom.
- [`skills/codelead-ready/`](skills/codelead-ready) — a Claude Skill that does
  the whole job in one pass: preview port, host binding, `PREVIEW_BASE_PATH`,
  the root-absolute URLs that escape the preview mount, and `.devcontainer/`
  (scaffolded when missing, audited when present). Copy the directory into the
  project's `.claude/skills/` and run `/codelead-ready`.

  ```bash
  mkdir -p /path/to/your/project/.claude/skills
  cp -R skills/codelead-ready /path/to/your/project/.claude/skills/
  ```

  The format is Claude Code's; the content is not harness-specific — the
  procedure reads as instructions for any agent.

Why any of this is necessary — and what CodeLead ignores, so you can stop
configuring it — is in
[`docs/project-readiness.md`](../../docs/project-readiness.md).

The snippet exists twice on purpose: once here for humans, once inside the
skill (`skills/codelead-ready/references/agents-snippet.md`) so the copied
directory is self-contained. Change both or neither.
