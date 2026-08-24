---
inclusion: always
---

# GitHub Perso Manager — Project Steering

## Project identity

- **Name:** GitHub Perso Manager
- **Purpose:** Manage personal GitHub repositories, configurations, and workflows from a single orchestration point.
- **Scope:** This project lives in a single folder and is itself a GitHub-hosted repository.

## Project code and profile

- **Project code:** GHPMGR1
- **Profile:** Standard feature

## Folder structure

| Folder | Purpose |
|---|---|
| `Scripts/` | Reusable PowerShell scripts for GitHub operations |
| `Scripts/_archive/` | Superseded scripts |
| `Documentation/` | Project docs, evolution log, generated references |
| `.kiro/steering/` | Project-local steering (committed) |

Folders deliberately skipped (not applicable to this code-only project):
`Inputs/`, `Backups/`, `Exports/`, `PQ/`.

## Technology

- **Language:** PowerShell (primary), potentially Python for GitHub API work.
- **External APIs:** GitHub REST/GraphQL API via `gh` CLI or direct HTTP.
- **Credentials:** GitHub PAT or `gh` CLI auth — never stored in tracked files. Use `gh auth` or environment variables.

## Conventions

- Scripts target PowerShell 5.1+ (Windows built-in) unless a feature requires pwsh 7.
- Use `gh` CLI where practical; fall back to REST API with `Invoke-RestMethod` when `gh` lacks coverage.
- All scripts are idempotent where feasible.
