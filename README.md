# GitHub Perso Manager

Daily automated monitor for all GitHub repositories accessible to the `Gneu` account. It creates a GitHub issue only when a monitored change occurs.

## What it detects

| Trigger | Reported information |
|---|---|
| New branch not merged into the default branch | Repository, branch, inferred owner, inferred purpose and source |
| New open PR | Repository, PR link, title, author and creation time |
| Merged PR branch not deleted | Repository, branch, PR link, purpose, author and merge time |

A branch is considered merged only when its latest commit is fully contained in the repository's default branch. A branch that gained commits after a previous merge remains reportable.

## Ownership and purpose inference

GitHub does not provide native branch-owner or branch-purpose fields. The report therefore uses this deterministic precedence:

| Information | When an open PR exists | Otherwise |
|---|---|---|
| Owner | Open PR author | Latest commit author |
| Purpose | Open PR title | `No open PR; inferred from branch name` |

The report identifies the source used for each new branch. These values are practical signals, not formal GitHub ownership metadata.

## How it works

1. **GitHub Actions** runs daily at 08:00 Paris time (06:00 UTC).
2. A PowerShell script scans all repositories readable by the `GH_PAT` secret via `gh` CLI.
3. It records unmerged branches, open PRs and merged-PR branches that still exist.
4. It compares the current snapshot with the previous snapshot stored on the `data` branch.
5. If new items exist → a `daily-report` issue is created in this repository.
6. If nothing changed → no issue, no noise.

## Structure

```
Scripts/                        PowerShell automation scripts
Scripts/_archive/               Superseded scripts
Documentation/                  Project docs
.github/workflows/              GitHub Actions workflow definitions
.kiro/steering/                 Project-local Kiro steering
```

## Manual trigger

In this repository: **Actions** → **Daily GitHub Monitor** → **Run workflow**.

## Local dry run

A dry run reads GitHub but never creates an issue. Use temporary state paths so the project working tree remains untouched:

```powershell
$state = Join-Path $env:TEMP "github-perso-manager-state.json"
./Scripts/Check-GitHubChanges.ps1 `
  -PreviousStateJson $state `
  -OutputStateJson $state `
  -DryRun
```

## Requirements

- GitHub Actions secret `GH_PAT`: fine-grained token for `Gneu`, with all-repository access and read permissions for Contents and Pull requests. The current workflow also uses it to create issues, so it requires Issues: Read and write.
- `gh` CLI authenticated (`gh auth status`) for local dry runs.
- PowerShell 7+ for local runs; GitHub Actions runs pwsh on Ubuntu.
