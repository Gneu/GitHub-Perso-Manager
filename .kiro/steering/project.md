---
inclusion: always
---

# GitHub Perso Manager — Project Steering

## What this project does

A personal tool to get visibility across all GitHub repos owned by the `Gneu` account.

**Daily automated check (GitHub Actions, 08:00 Paris / 06:00 UTC) creates an issue if:**
- A new branch exists that is not merged to main
- A new open PR exists
- A merged PR's branch has not been deleted

No notification is sent if nothing changed since the last run.

## Scope

- Single-user, personal use only.
- No delivery process, no project code, no gates. Just build and iterate.
- Global `~/.kiro/steering/` rules (delivery-process, agent-governance, etc.) do **not** apply here.

## Architecture

| Component | Location | Purpose |
|---|---|---|
| Monitoring script | `Scripts/Check-GitHubChanges.ps1` | Scans all repos, diffs state, creates issue |
| GitHub Actions workflow | `.github/workflows/daily-monitor.yml` | Cron trigger, orchestrates run |
| State file | `state.json` on `data` branch | Previous-run snapshot for change detection |
| Issues | This repo's Issues tab | Notification delivery with full detail |

**State management:** `state.json` lives on an orphan `data` branch to keep `master` clean. The workflow checks it out before the script runs, then pushes the updated version back after.

**Notification:** One issue per change-day, labelled `daily-report`. Contains markdown tables with repo, branch, PR, author, dates, and links.

## Folder structure

| Folder | Purpose |
|---|---|
| `Scripts/` | Reusable PowerShell scripts |
| `Scripts/_archive/` | Superseded scripts |
| `Documentation/` | Any docs if needed |
| `.github/workflows/` | GitHub Actions definitions |

## Technology

- **PowerShell** (pwsh 7, runs on ubuntu-latest in Actions)
- **GitHub CLI (`gh`)** — all API calls, issue creation
- **GitHub Actions** — scheduling, orchestration
- **No credentials to manage** — uses built-in `GITHUB_TOKEN`

## Conventions

- Scripts are idempotent where feasible.
- Output goes to GitHub Issues (notification) or console (debug).
- Keep it simple. No over-engineering for a personal dashboard.
