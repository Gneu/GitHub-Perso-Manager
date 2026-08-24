<#
.SYNOPSIS
    Checks all repos under the authenticated GitHub user for:
    - New branches not merged to main/master
    - New open PRs
    - Merged PR branches that haven't been deleted
    Compares against previous state and creates a GitHub issue if changes detected.

.DESCRIPTION
    Designed to run in GitHub Actions. Uses gh CLI for all API calls.
    State is read/written as JSON (passed in/out via parameters).

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
        Fetches all non-archived repos for the authenticated user.
    #>
    $repos = @()
    $page = 1
    do {
        $batch = gh api "user/repos?per_page=100&page=$page&type=owner&sort=full_name" --jq '.[].full_name' 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
        if ($batch) {
            $repos += $batch
            $page++
        }
    } while ($batch -and $batch.Count -eq 100)

    return $repos
}

function Get-DefaultBranch {
    param([string]$Repo)
    $result = gh api "repos/$Repo" --jq '.default_branch' 2>$null
    if ($result) { return $result.Trim() }
    return "main"
}

function Get-Branches {
    <#
    .SYNOPSIS
        Gets all branches for a repo, excluding the default branch.
        Returns objects with: name, repo, ismerged (into default).
    #>
    param([string]$Repo, [string]$DefaultBranch)

    $branches = @()
    $page = 1
    do {
        $batch = gh api "repos/$Repo/branches?per_page=100&page=$page" --jq '.[].name' 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" -and $_ -ne $DefaultBranch }
        if ($batch) {
            $branches += $batch
            $page++
        }
    } while ($batch -and $batch.Count -eq 100)

    return $branches
}

function Get-OpenPRs {
    <#
    .SYNOPSIS
        Gets all open PRs for a repo.
        Returns objects with: number, title, author, head_branch, created_at, url.
    #>
    param([string]$Repo)

    $prs = @()
    $page = 1
    do {
        $json = gh api "repos/$Repo/pulls?state=open&per_page=100&page=$page" 2>$null
        $batch = $json | ConvertFrom-Json
        foreach ($pr in $batch) {
            $prs += [PSCustomObject]@{
                number      = $pr.number
                title       = $pr.title
                author      = $pr.user.login
                head_branch = $pr.head.ref
                created_at  = $pr.created_at
                url         = $pr.html_url
            }
        }
        $page++
    } while ($batch -and $batch.Count -eq 100)

    return $prs
}

function Get-MergedPRsWithStaleBranches {
    <#
    .SYNOPSIS
        Finds PRs that were merged but whose head branch still exists in the repo.
    #>
    param([string]$Repo, [string[]]$ExistingBranches)

    $stale = @()
    $page = 1
    do {
        $json = gh api "repos/$Repo/pulls?state=closed&per_page=100&page=$page" 2>$null
        $batch = $json | ConvertFrom-Json
        foreach ($pr in $batch) {
            if ($pr.merged_at -and $ExistingBranches -contains $pr.head.ref) {
                $stale += [PSCustomObject]@{
                    number      = $pr.number
                    title       = $pr.title
                    head_branch = $pr.head.ref
                    merged_at   = $pr.merged_at
                    url         = $pr.html_url
                }
            }
        }
        $page++
    } while ($batch -and $batch.Count -eq 100)

    return $stale
}

# --- Main logic ---

Write-Host "=== GitHub Perso Manager - Daily Check ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"

# Load previous state
$previousState = @{ branches = @{}; prs = @{}; stale_branches = @{} }
if (Test-Path $PreviousStateJson) {
    Write-Host "Loading previous state from: $PreviousStateJson"
    $previousState = Get-Content $PreviousStateJson -Raw | ConvertFrom-Json -AsHashtable
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

    $defaultBranch = Get-DefaultBranch -Repo $repo
    $branches = Get-Branches -Repo $repo -DefaultBranch $defaultBranch

    # Track branches (non-default, non-merged)
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
            author      = $pr.author
            head_branch = $pr.head_branch
            created_at  = $pr.created_at
            url         = $pr.url
        }
    }

    # Track stale merged-PR branches
    $staleBranches = Get-MergedPRsWithStaleBranches -Repo $repo -ExistingBranches $branches
    foreach ($stale in $staleBranches) {
        $key = "$repo/$($stale.head_branch)"
        $currentState.stale_branches[$key] = @{
            repo        = $repo
            number      = $stale.number
            title       = $stale.title
            head_branch = $stale.head_branch
            merged_at   = $stale.merged_at
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
    $title += ($parts -join ", ") + " — $date"

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
