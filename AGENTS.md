# AGENTS.md

## Agent skills

### Issue tracker

Issues live in GitHub Issues at `imyifeng/meridian`, accessed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five canonical default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: `CONTEXT.md` at the repo root + `docs/adr/`. See `docs/agents/domain.md`.

## Development workflow

One ticket per session: claim → branch → implement → review & merge → close. `/clear` between sessions.

- **Claim**: `gh issue edit <n> --add-assignee @me` (ticket conventions in `docs/agents/issue-tracker.md`)
- **Branch**: cut `t<N>-<slug>` from latest main (e.g. `t2-minimal-loop`). main is merged only via PR
- **Implement**: `/implement` drives the `/tdd` red-green loop. Server integration tests boot the real binary against a temp SQLite file — no containers. Test seams: spec (#1)
- **Review & merge**: after `/code-review` passes (Standards axis against this file, Spec axis against the ticket and spec #1), open a PR, `gh pr merge --squash`, and delete the branch
- **Close**: post a wrap-up comment on the ticket, then close it

**Definition of Done** — verify each item before ending a session:

- [ ] PR squash-merged and branch deleted
- [ ] Ticket commented and closed
- [ ] Every background process started this session (dev server, local instance, watcher) stopped
- [ ] Containers torn down (`podman compose down -v`); containers appear only in compose deployment verification work
- [ ] `git status` clean — nothing uncommitted, nothing untracked
