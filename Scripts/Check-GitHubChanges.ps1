<#
.SYNOPSIS
    Checks all repos under the authenticated GitHub user for:
    - New branches not merged to main/master
    - New open PRs
    - Merged PR branches that haven't been deleted
    Compares against previous state and creates a GitHub issue if changes detected.

.DESCRIPTION
    Designed to run in GitHub Actions (pwsh 7 on ubuntu-latest).
    Uses gh CLI for all API calls. Avoids --paginate parsing issues by using
    gh's native --json flag which handles pagination internally.

.PARAMETER PreviousStateJson
    Path to the previous state JSON file. If not found, treats everything as new (first run).

.PARAMETER OutputStateJson
    Path where the current state will be written.

.PARAMETER RepoName
    The repo where issues will be created (e.g., "Gneu/GitHub-Perso-Manager").

.PARAMETER DryRun
    If set, prints what would be reported but does not create an issue.
#>
[CmdletBinding()]
param(
    [string]$PreviousStateJson = "state.json",
    [string]$OutputStateJson = "state.json",
    [string]$RepoName = "Gneu/GitHub-Perso-Manager",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Helper functions ---

function Get-AllRepos {
    <#
    .SYNOPSIS
        Fetches all non-archived, non-fork repos owned by the authenticated user.
        Uses 'gh repo list' which handles pagination natively.
    #>
    $json = gh repo list --no-archived --source --json nameWithOwner --limit 200 2>$null
    if (-not $json) { return @() }
    $repos = ($json | ConvertFrom-Json)
    return @($repos | ForEach-Object { $_.nameWithOwner })
}

function Get-RepoBranches {
    <#
    .SYNOPSIS
        Gets all branches for a repo excluding the default branch.
        Uses gh api with --jq to output clean newline-separated names.
    #>
    param([string]$Repo)

    # Get default branch
    $defaultBranch = (gh repo view $Repo --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null)
    if (-not $defaultBranch) { $defaultBranch = "main" }
    $defaultBranch = $defaultBranch.Trim()

    # Get all branch names as newline-separated text
    $branchNames = gh api "repos/$Repo/branches" --paginate --jq '.[].name' 2>$null
    if (-not $branchNames) { return @(), $defaultBranch }

    $branches = @($branchNames | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -ne $defaultBranch })
    return $branches, $defaultBranch
}

function Get-OpenPRs {
    <#
    .SYNOPSIS
        Gets all open PRs for a repo using gh pr list (handles pagination natively).
    #>
    param([string]$Repo)

    $json = gh pr list --repo $Repo --state open --json number,title,author,headRefName,createdAt,url --limit 200 2>$null
    if (-not $json) { return @() }
    $prs = @($json | ConvertFrom-Json)
    return $prs
}

function Get-MergedPRsWithStaleBranches {
    <#
    .SYNOPSIS
        Finds recently merged PRs whose head branch still exists.
    #>
    param([string]$Repo, [string[]]$ExistingBranches)

    if (-not $ExistingBranches -or $ExistingBranches.Count -eq 0) { return @() }

    # Get recently closed (merged) PRs
    $json = gh pr list --repo $Repo --state merged --json number,title,headRefName,mergedAt,url --limit 200 2>$null
    if (-not $json) { return @() }
    $mergedPRs = @($json | ConvertFrom-Json)

    $stale = @()
    foreach ($pr in $mergedPRs) {
        if ($ExistingBranches -contains $pr.headRefName) {
            $stale += $pr
        }
    }
    return $stale
}

# --- Main logic ---

Write-Host "=== GitHub Perso Manager - Daily Check ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"

# Load previous state
$previousState = @{ branches = @{}; prs = @{}; stale_branches = @{} }
if (Test-Path $PreviousStateJson) {
    $content = Get-Content $PreviousStateJson -Raw
    if ($content -and $content.Trim() -ne "" -and $content.Trim() -ne "{}") {
        Write-Host "Loading previous state from: $PreviousStateJson"
        $loaded = $content | ConvertFrom-Json
        if ($loaded.branches) {
            $loaded.branches.PSObject.Properties | ForEach-Object { $previousState.branches[$_.Name] = $_.Value }
        }
        if ($loaded.prs) {
            $loaded.prs.PSObject.Properties | ForEach-Object { $previousState.prs[$_.Name] = $_.Value }
        }
        if ($loaded.stale_branches) {
            $loaded.stale_branches.PSObject.Properties | ForEach-Object { $previousState.stale_branches[$_.Name] = $_.Value }
        }
    }
    else {
        Write-Host "Previous state file is empty - first run."
    }
}
else {
    Write-Host "No previous state found - first run, will report all current items."
}

# Build current state
$currentState = @{ branches = @{}; prs = @{}; stale_branches = @{} }

$repos = Get-AllRepos
Write-Host "Found $($repos.Count) repos to scan."

foreach ($repo in $repos) {
    Write-Host "  Scanning: $repo" -ForegroundColor Gray

    $branchResult = Get-RepoBranches -Repo $repo
    $branches = $branchResult[0]
    $defaultBranch = $branchResult[1]

    # Track branches (non-default)
    foreach ($branch in $branches) {
        $key = "$repo/$branch"
        $currentState.branches[$key] = @{
            repo   = $repo
            branch = $branch
        }
    }

    # Track open PRs
    $openPRs = Get-OpenPRs -Repo $repo
    foreach ($pr in $openPRs) {
        $key = "$repo/#$($pr.number)"
        $currentState.prs[$key] = @{
            repo        = $repo
            number      = $pr.number
            title       = $pr.title
            author      = $pr.author.login
            head_branch = $pr.headRefName
            created_at  = $pr.createdAt
            url         = $pr.url
        }
    }

    # Track stale merged-PR branches
    $staleBranches = Get-MergedPRsWithStaleBranches -Repo $repo -ExistingBranches $branches
    foreach ($stale in $staleBranches) {
        $key = "$repo/$($stale.headRefName)"
        $currentState.stale_branches[$key] = @{
            repo        = $repo
            number      = $stale.number
            title       = $stale.title
            head_branch = $stale.headRefName
            merged_at   = $stale.mergedAt
            url         = $stale.url
        }
    }
}

# --- Diff against previous state ---

$newBranches = @()
foreach ($key in $currentState.branches.Keys) {
    if (-not $previousState.branches.ContainsKey($key)) {
        $newBranches += $currentState.branches[$key]
    }
}

$newPRs = @()
foreach ($key in $currentState.prs.Keys) {
    if (-not $previousState.prs.ContainsKey($key)) {
        $newPRs += $currentState.prs[$key]
    }
}

$newStaleBranches = @()
foreach ($key in $currentState.stale_branches.Keys) {
    if (-not $previousState.stale_branches.ContainsKey($key)) {
        $newStaleBranches += $currentState.stale_branches[$key]
    }
}

$hasChanges = ($newBranches.Count -gt 0) -or ($newPRs.Count -gt 0) -or ($newStaleBranches.Count -gt 0)

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "New unmerged branches: $($newBranches.Count)"
Write-Host "New open PRs: $($newPRs.Count)"
Write-Host "New stale merged branches: $($newStaleBranches.Count)"
Write-Host "Changes detected: $hasChanges"

# --- Build issue body if changes ---

if ($hasChanges) {
    $date = Get-Date -Format "yyyy-MM-dd"
    $title = "[Daily Report] "
    $parts = @()
    if ($newBranches.Count -gt 0) { $parts += "$($newBranches.Count) new branch(es)" }
    if ($newPRs.Count -gt 0) { $parts += "$($newPRs.Count) new PR(s)" }
    if ($newStaleBranches.Count -gt 0) { $parts += "$($newStaleBranches.Count) stale merged branch(es)" }
    $title += ($parts -join ", ") + " - $date"

    $body = "# Daily GitHub Monitor Report`n`n"
    $body += "**Date:** $date`n`n"

    if ($newBranches.Count -gt 0) {
        $body += "## New unmerged branches`n`n"
        $body += "| Repo | Branch |`n|---|---|`n"
        foreach ($b in $newBranches) {
            $body += "| ``$($b.repo)`` | ``$($b.branch)`` |`n"
        }
        $body += "`n"
    }

    if ($newPRs.Count -gt 0) {
        $body += "## New open PRs`n`n"
        $body += "| Repo | PR | Title | Author | Created |`n|---|---|---|---|---|`n"
        foreach ($pr in $newPRs) {
            $body += "| ``$($pr.repo)`` | [#$($pr.number)]($($pr.url)) | $($pr.title) | @$($pr.author) | $($pr.created_at) |`n"
        }
        $body += "`n"
    }

    if ($newStaleBranches.Count -gt 0) {
        $body += "## Merged PR branches not deleted`n`n"
        $body += "| Repo | Branch | PR | Merged at |`n|---|---|---|---|`n"
        foreach ($s in $newStaleBranches) {
            $body += "| ``$($s.repo)`` | ``$($s.head_branch)`` | [#$($s.number)]($($s.url)) | $($s.merged_at) |`n"
        }
        $body += "`n"
    }

    $body += "---`n*Generated by [GitHub Perso Manager](https://github.com/$RepoName)*"

    if ($DryRun) {
        Write-Host ""
        Write-Host "=== DRY RUN - Would create issue ===" -ForegroundColor Yellow
        Write-Host "Title: $title"
        Write-Host "Body:"
        Write-Host $body
    }
    else {
        Write-Host "Creating issue in $RepoName..."
        $body | gh issue create --repo $RepoName --title $title --label "daily-report" --body-stdin
        Write-Host "Issue created." -ForegroundColor Green
    }
}
else {
    Write-Host "No changes detected. No issue created." -ForegroundColor Green
}

# --- Save current state ---

Write-Host "Saving state to: $OutputStateJson"
$currentState | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputStateJson -Encoding UTF8

Write-Host "Done."
