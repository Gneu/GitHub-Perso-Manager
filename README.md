# GitHub Perso Manager

Orchestration repo for managing personal GitHub repositories, configurations, and workflows.

## Structure

```
Scripts/            Reusable PowerShell scripts for GitHub operations
Scripts/_archive/   Superseded scripts kept for reference
Documentation/      Project documentation and evolution log
.kiro/steering/     Project-local Kiro steering (committed)
```

## Technology

- **PowerShell** for automation scripts
- **GitHub CLI (`gh`)** as the primary interface to GitHub APIs
- **GitHub REST/GraphQL API** via `Invoke-RestMethod` where `gh` lacks coverage

## Getting started

1. Ensure `gh` CLI is installed and authenticated (`gh auth status`).
2. Clone this repo.
3. Run scripts from the `Scripts/` folder as needed.

## Credentials

No credentials are stored in this repository. Authentication relies on `gh auth` or environment variables.
