# GitHub Perso Manager

Daily automated monitor for all GitHub repos under the `Gneu` account. Creates a GitHub issue when something changes.

## What it detects

| Trigger | Example |
|---|---|
| New branch not merged to main | `feature/auth` created on `repo-x` |
| New open PR | PR #42 opened on `repo-y` |
| Merged PR branch not deleted | `fix/typo` still exists after PR #10 was merged |

## How it works

1. **GitHub Actions** runs daily at 08:00 Paris time (06:00 UTC).
2. A PowerShell script scans all owned repos via `gh` CLI.
3. Current state (branches, PRs, stale branches) is compared against the previous run's snapshot.
4. If changes are found → an issue is created in this repo with full details.
5. If nothing changed → no issue, no noise.

State is stored as `state.json` on a dedicated `data` branch.

## Structure

```
Scripts/                        PowerShell automation scripts
Scripts/_archive/               Superseded scripts
Documentation/                  Project docs
.github/workflows/              GitHub Actions workflow definitions
.kiro/steering/                 Project-local Kiro steering
```

## Manual trigger

You can run the workflow manually from the Actions tab → "Daily GitHub Monitor" → "Run workflow".

## Local testing

```powershell
# Dry run (no issue created, just prints what would be reported)
./Scripts/Check-GitHubChanges.ps1 -DryRun
```

## Requirements

- `gh` CLI authenticated (`gh auth status`)
- PowerShell 7+ (for local runs; Actions uses ubuntu pwsh)
