# Example `~/.salmon` runtime home

This directory shows what a user's Salmon Run runtime home looks like.
It is part of the public package as a template only; real credentials and
runtime state live under the user's own `~/.salmon` (`%SALMON_RUN_HOME%`).

## Layout

| Path | Purpose |
|------|---------|
| `.env` | Credential redirects and runtime variables. See `.env.example`. |
| `config.json` | User configuration. Copied from `config.example.json`. |
| `Tasks/Intake/` | New plan stubs and feature discovery. |
| `Tasks/Code/` | Ready-to-implement plans. |
| `Tasks/Review/` | Completed plans awaiting review. |
| `Tasks/Audit/` | Plans awaiting best-practice audit. |
| `Tasks/QA/` | Plans awaiting property/mutation tests. |
| `Tasks/Complete/` | Completed plans awaiting archival. |
| `Tasks/Archive/` | Archived plans. |
| `Tasks/Working/` | In-progress plans and lock files. |
| `Tasks/Failed/` | Failed or blocked plans. |
| `Tasks/Project/` | Large multi-session project plans. |
| `Tasks/ProjectReview/` | Project review plans. |
| `Tasks/Schedules/` | Scheduled plan files. |
| `Tasks/Logs/` | Agent and orchestrator logs. |
| `cache/` | Runtime cache. |
| `secrets/` | Local secret files (optional, never committed). |

The installer (`install.ps1`) creates these directories under the real
`~/.salmon` and copies `config.example.json` to `config.json`.
