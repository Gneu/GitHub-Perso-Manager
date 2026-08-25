# GitHub Perso Manager

Daily monitor for GitHub repositories accessible to the `Gneu` account. It creates a detailed GitHub issue and sends an email only when monitored changes occur.

## What it detects

| Trigger | Reported information |
|---|---|
| New branch not merged into the default branch | Repository, branch, inferred owner, inferred purpose and source |
| New open PR | Repository, PR link, title, author and creation time |
| Merged PR branch not deleted | Repository, branch, PR link, purpose, author and merge time |

A branch is considered merged only when its latest commit is fully contained in the default branch. A branch with commits after a prior merge remains reportable.

## Ownership and purpose inference

GitHub has no native branch-owner or branch-purpose fields, so the monitor uses this deterministic precedence:

| Information | When an open PR exists | Otherwise |
|---|---|---|
| Owner | Open PR author | Latest commit author |
| Purpose | Open PR title | `No open PR; inferred from branch name` |

These are practical signals, not formal GitHub ownership metadata.

## Delivery behaviour

When changes are found, the workflow:

1. Creates a `daily-report` issue in this repository with the full Markdown report.
2. Sends the same report as a UTF-8 plain-text email to `fabrice.r@gmail.com`, including the issue link.
3. Updates the `data` branch baseline only after email delivery succeeds.

If nothing changed, it sends no email and creates no issue.

## How it works

1. **GitHub Actions** runs daily at 08:00 Paris time (06:00 UTC).
2. The PowerShell monitor scans each repository using `gh` CLI and the `GH_PAT` secret.
3. It compares branches, PRs and stale merged branches against the state snapshot on the `data` branch.
4. A report JSON file is generated only if a reportable change exists.
5. The workflow creates the issue and sends Gmail through SMTP-over-SSL.

## Manual test

In this repository: **Actions** → **Daily GitHub Monitor** → **Run workflow**.

Enable **“Generate a report and email even when nothing changed”** to send a one-off end-to-end test report. This creates a report issue and email, but leaves the normal baseline current.

## Local dry run

A dry run reads GitHub but never creates an issue or sends an email:

```powershell
$state = Join-Path $env:TEMP "github-perso-manager-state.json"
./Scripts/Check-GitHubChanges.ps1 `
  -PreviousStateJson $state `
  -OutputStateJson $state `
  -ForceReport `
  -DryRun
```

## Required GitHub Actions secrets

| Secret | Purpose |
|---|---|
| `GH_PAT` | Fine-grained PAT for `Gneu`, with all-repository access and read access to Contents and Pull requests; Issues: Read and write remains required for issue creation. |
| `GMAIL_APP_PASSWORD` | Gmail App Password for `fabrice.r@gmail.com`, used only at runtime to send report emails. Never commit or print it. |

## Structure

```
Scripts/                        PowerShell automation scripts
Scripts/_archive/               Superseded scripts
Documentation/                  Project docs
.github/workflows/              GitHub Actions workflow definitions
.kiro/steering/                 Project-local Kiro steering
```
