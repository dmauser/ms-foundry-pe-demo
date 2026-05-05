# Copilot Instructions

## Project Overview

This is **ms-foundry-pe-demo**, a project managed by [Squad](https://github.com/bradygaster/squad) — an AI team orchestration framework. The repo uses Squad's multi-agent coordination system with persistent team state in `.squad/`.

## Architecture

- `.squad/` — Team state (roster, decisions, agent histories, orchestration logs). User-owned; never overwritten by upgrades.
- `.squad/templates/` — Reference templates (Squad-owned, overwritten on upgrade).
- `.squad/agents/{name}/` — Per-agent charter and history files.
- `.squad/decisions.md` — Canonical decision ledger (append-only, shared by all agents).
- `.squad/decisions/inbox/` — Drop-box for parallel decision writes (Scribe merges into decisions.md).
- `.github/agents/squad.agent.md` — Coordinator prompt (Squad-owned).
- `.copilot/skills/` — Copilot-level process skills (git workflow, test discipline, reviewer protocol, etc.).
- `.squad/skills/` — Team-level skills discovered during work.

## Key Conventions

### Git Workflow

- **Three-branch model:** `main` (released) → `dev` (integration) → `insiders` (early access).
- **All feature work branches from `dev`, never `main`.**
- Branch naming: `squad/{issue-number}-{kebab-case-slug}`
- PRs always target `dev`. Direct commits to `main` or `dev` are prohibited.

### Squad State Files

- `.squad/decisions.md`, `agents/*/history.md`, and `orchestration-log/` are **append-only** — never rewrite or reorder entries.
- `.gitattributes` declares `merge=union` on append-only files for conflict-free merging across branches.
- Agents write decisions to `decisions/inbox/{agent-name}-{slug}.md`; Scribe merges them.

### Security

- **Never read** `.env`, `.env.local`, or `.env.production` files.
- **Never write secrets** to any `.squad/` file — Scribe auto-commits these to git.
- Use environment variable references (`${VAR_NAME}`) instead of literal values.

### Test Discipline

- API/interface changes require test updates in the **same commit**.
- Test assertion arrays (expected counts, file lists) must stay in sync with disk reality.

### Reviewer Protocol

- Rejected work triggers **strict lockout** — the original author cannot self-revise.
- A different agent must own the revision. The coordinator enforces this mechanically.

## GitHub Workflows

| Workflow | Purpose |
|----------|---------|
| `squad-heartbeat.yml` | Event-based health checks |
| `squad-issue-assign.yml` | Auto-assigns issues based on `squad:*` labels |
| `squad-triage.yml` | Triggers lead triage on new `squad`-labeled issues |
| `sync-squad-labels.yml` | Syncs team roster to GitHub labels |
