<#
.SYNOPSIS
    Checks all repositories available to the authenticated GitHub user for:
    - New branches that are not fully merged into the default branch
    - New open pull requests
    - Merged-PR branches that still exist

.DESCRIPTION
    Designed to run in GitHub Actions (pwsh 7 on ubuntu-latest) using the gh CLI.
    Current state is compared to the previous snapshot. A report issue is created only
    when new items matching a monitored condition are found.

    Branch ownership and purpose are inferred because GitHub has no native fields for
    either: an open PR's author and title take precedence; otherwise the latest commit
    author and the branch name are used.

.PARAMETER PreviousStateJson
    Path to the previous state JSON file. If not found, treats all current items as new.

.PARAMETER OutputStateJson
    Path where the current state will be written.

.PARAMETER RepoName
    The repository where report issues will be created, for example
    "Gneu/GitHub-Perso-Manager".

.PARAMETER DryRun
    Prints the report but does not create an issue.
#>
[CmdletBinding()]
param(
    [string]$PreviousStateJson = "state.json",
    [string]$OutputStateJson = "state.json",
    [string]$RepoName = "Gneu/GitHub-Perso-Manager",
    [switch]$DryRun
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# --- GitHub data retrieval ---

function Get-AllRepos {
    <# Fetches all non-archived, non-fork repositories accessible to the token. #>
    $raw = gh repo list --no-archived --source --json nameWithOwner --limit 200 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list GitHub repositories. Verify GH_PAT access and validity."
    }

    $joined = ($raw -join "`n")
    if ($joined.Trim() -eq "" -or $joined.Trim() -eq "[]") {
        return ,@()
    }

    $parsed = @($joined | ConvertFrom-Json)
    [string[]]$names = @($parsed | ForEach-Object { $_.nameWithOwner })
    Write-Host "  (gh repo list returned $($names.Count) repositories)"
    return ,$names
}

function Get-RepoBranches {
    <# Gets all branches other than the repository's default branch. #>
    param([string]$Repo)

    $defaultBranch = (gh repo view $Repo --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $defaultBranch) {
        throw "Unable to find the default branch for $Repo."
    }
    $defaultBranch = ($defaultBranch -join "").Trim()

    $branchLines = gh api "repos/$Repo/branches" --paginate --jq '.[].name' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list branches for $Repo."
    }

    [string[]]$branches = @()
    foreach ($line in $branchLines) {
        $name = $line.Trim()
        if ($name -ne "" -and $name -ne $defaultBranch) {
            $branches += $name
        }
    }

    return @{ branches = $branches; defaultBranch = $defaultBranch }
}

function Get-OpenPRs {
    <# Gets all open pull requests for a repository. #>
    param([string]$Repo)

    $raw = (gh pr list --repo $Repo --state open --json number,title,author,headRefName,createdAt,url --limit 200 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list open pull requests for $Repo."
    }
    if (-not $raw -or $raw.Trim() -eq "[]") {
        return ,@()
    }

    return ,@($raw | ConvertFrom-Json)
}

function Get-MergedPRsWithStaleBranches {
    <# Finds merged PRs whose head branches still exist in the repository. #>
    param([string]$Repo, [string[]]$ExistingBranches)

    if (-not $ExistingBranches -or $ExistingBranches.Count -eq 0) {
        return ,@()
    }

    $raw = (gh pr list --repo $Repo --state merged --json number,title,author,headRefName,mergedAt,url --limit 200 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list merged pull requests for $Repo."
    }
    if (-not $raw -or $raw.Trim() -eq "[]") {
        return ,@()
    }

    $mergedPRs = $raw | ConvertFrom-Json
    $stale = @()
    foreach ($pr in $mergedPRs) {
        if ($ExistingBranches -contains ($pr.headRefName)) {
            $stale += $pr
        }
    }

    return $stale
}

function Test-BranchMergedIntoDefault {
    <#
    .SYNOPSIS
        Returns true when the complete branch tip is already contained in the default
        branch. A branch with commits after a prior merge returns false (diverged).
    #>
    param(
        [string]$Repo,
        [string]$DefaultBranch,
        [string]$Branch
    )

    $base = [System.Uri]::EscapeDataString($DefaultBranch)
    $head = [System.Uri]::EscapeDataString($Branch)
    $status = gh api "repos/$Repo/compare/$base...$head" --jq '.status' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $status) {
        throw "Unable to determine whether branch '$Branch' is merged into '$DefaultBranch' in $Repo."
    }

    return (($status -join "").Trim() -in @("behind", "identical"))
}

function Get-BranchOwnershipAndPurpose {
    <#
    .SYNOPSIS
        Infers ownership and purpose. Open PR metadata wins; the latest commit author
        and branch name are used when no open PR exists.
    #>
    param(
        [string]$Repo,
        [string]$Branch,
        [object[]]$OpenPRs
    )

    $pr = @($OpenPRs | Where-Object { $_.headRefName -eq $Branch } | Select-Object -First 1)[0]
    if ($pr) {
        $owner = if ($pr.author -and $pr.author.login) { $pr.author.login } else { "unknown" }
        return @{
            owner   = $owner
            purpose = $pr.title
            source  = "Open PR #$($pr.number)"
        }
    }

    $encodedBranch = [System.Uri]::EscapeDataString($Branch)
    $owner = gh api "repos/$Repo/commits/$encodedBranch" --jq '.author.login // .commit.author.name // "unknown"' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to find the latest commit author for branch '$Branch' in $Repo."
    }
    $owner = ($owner -join "").Trim()
    if (-not $owner) { $owner = "unknown" }

    return @{
        owner   = $owner
        purpose = "No open PR; inferred from branch name"
        source  = "Latest commit author"
    }
}

# --- Presentation helpers ---

function ConvertTo-MarkdownTableCell {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value -or [string]$Value -eq "") { "-" } else { [string]$Value }
    $text = $text -replace '[\r\n]+', ' '
    return ($text -replace '\|', '\|')
}

function Format-GitHubTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]$Value -eq "") { return "-" }
    try {
        return ([DateTimeOffset]::Parse([string]$Value)).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
    }
    catch {
        return [string]$Value
    }
}

# --- Main ---

Write-Host "=== GitHub Perso Manager - Daily Check ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"

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
    Write-Host "No previous state found - first run; all current monitored items will be reported."
}

$currentState = @{ branches = @{}; prs = @{}; stale_branches = @{} }
$repos = Get-AllRepos
Write-Host "Found $($repos.Count) repositories to scan."

foreach ($repo in $repos) {
    Write-Host "  Scanning: $repo" -ForegroundColor Gray

    $branchResult = Get-RepoBranches -Repo $repo
    $allBranches = @($branchResult.branches | Where-Object { -not ($repo -eq $RepoName -and $_ -eq "data") })
    $defaultBranch = $branchResult.defaultBranch
    $openPRs = Get-OpenPRs -Repo $repo
    $staleBranches = Get-MergedPRsWithStaleBranches -Repo $repo -ExistingBranches $allBranches

    # Only branches not fully merged into the default branch belong in this state.
    foreach ($branch in $allBranches) {
        if (Test-BranchMergedIntoDefault -Repo $repo -DefaultBranch $defaultBranch -Branch $branch) {
            continue
        }

        $details = Get-BranchOwnershipAndPurpose -Repo $repo -Branch $branch -OpenPRs $openPRs
        $key = "$repo/$branch"
        $currentState.branches[$key] = @{
            repo           = $repo
            branch         = $branch
            owner          = $details.owner
            purpose        = $details.purpose
            purpose_source = $details.source
        }
    }

    foreach ($pr in $openPRs) {
        $author = if ($pr.author -and $pr.author.login) { $pr.author.login } else { "unknown" }
        $key = "$repo/#$($pr.number)"
        $currentState.prs[$key] = @{
            repo        = $repo
            number      = $pr.number
            title       = $pr.title
            author      = $author
            head_branch = $pr.headRefName
            created_at  = $pr.createdAt
            url         = $pr.url
        }
    }

    foreach ($stale in $staleBranches) {
        $author = if ($stale.author -and $stale.author.login) { $stale.author.login } else { "unknown" }
        $key = "$repo/$($stale.headRefName)"
        $currentState.stale_branches[$key] = @{
            repo        = $repo
            number      = $stale.number
            title       = $stale.title
            author      = $author
            head_branch = $stale.headRefName
            merged_at   = $stale.mergedAt
            url         = $stale.url
        }
    }
}

# --- State comparison ---

$newBranches = @($currentState.branches.Keys | Where-Object { -not $previousState.branches.ContainsKey($_) } | ForEach-Object { $currentState.branches[$_] })
$newPRs = @($currentState.prs.Keys | Where-Object { -not $previousState.prs.ContainsKey($_) } | ForEach-Object { $currentState.prs[$_] })
$newStaleBranches = @($currentState.stale_branches.Keys | Where-Object { -not $previousState.stale_branches.ContainsKey($_) } | ForEach-Object { $currentState.stale_branches[$_] })
$hasChanges = ($newBranches.Count -gt 0) -or ($newPRs.Count -gt 0) -or ($newStaleBranches.Count -gt 0)

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "New unmerged branches: $($newBranches.Count)"
Write-Host "New open PRs: $($newPRs.Count)"
Write-Host "New stale merged branches: $($newStaleBranches.Count)"
Write-Host "Changes detected: $hasChanges"

if ($hasChanges) {
    $date = Get-Date -Format "yyyy-MM-dd"
    $titleParts = @()
    if ($newBranches.Count -gt 0) { $titleParts += "$($newBranches.Count) new branch(es)" }
    if ($newPRs.Count -gt 0) { $titleParts += "$($newPRs.Count) new PR(s)" }
    if ($newStaleBranches.Count -gt 0) { $titleParts += "$($newStaleBranches.Count) stale merged branch(es)" }
    $title = "[Daily Report] " + ($titleParts -join ", ") + " - $date"

    $body = "# Daily GitHub Monitor Report`n`n"
    $body += "**Date:** $date`n`n"

    if ($newBranches.Count -gt 0) {
        $body += "## New branches not merged into the default branch`n`n"
        $body += "| Repo | Branch | Owner | Purpose | Source |`n|---|---|---|---|---|`n"
        foreach ($branch in $newBranches | Sort-Object repo, branch) {
            $body += "| ``$(ConvertTo-MarkdownTableCell $branch.repo)`` | ``$(ConvertTo-MarkdownTableCell $branch.branch)`` | @$(ConvertTo-MarkdownTableCell $branch.owner) | $(ConvertTo-MarkdownTableCell $branch.purpose) | $(ConvertTo-MarkdownTableCell $branch.purpose_source) |`n"
        }
        $body += "`n"
    }

    if ($newPRs.Count -gt 0) {
        $body += "## New open PRs`n`n"
        $body += "| Repo | PR | Title | Author | Created |`n|---|---|---|---|---|`n"
        foreach ($pr in $newPRs | Sort-Object repo, number) {
            $body += "| ``$(ConvertTo-MarkdownTableCell $pr.repo)`` | [#$($pr.number)]($($pr.url)) | $(ConvertTo-MarkdownTableCell $pr.title) | @$(ConvertTo-MarkdownTableCell $pr.author) | $(Format-GitHubTimestamp $pr.created_at) |`n"
        }
        $body += "`n"
    }

    if ($newStaleBranches.Count -gt 0) {
        $body += "## Merged PR branches not deleted`n`n"
        $body += "| Repo | Branch | PR | Purpose | Author | Merged at |`n|---|---|---|---|---|---|`n"
        foreach ($stale in $newStaleBranches | Sort-Object repo, head_branch) {
            $body += "| ``$(ConvertTo-MarkdownTableCell $stale.repo)`` | ``$(ConvertTo-MarkdownTableCell $stale.head_branch)`` | [#$($stale.number)]($($stale.url)) | $(ConvertTo-MarkdownTableCell $stale.title) | @$(ConvertTo-MarkdownTableCell $stale.author) | $(Format-GitHubTimestamp $stale.merged_at) |`n"
        }
        $body += "`n"
    }

    $body += "---`n*Owner and purpose are inferred from an open PR where available; otherwise, from the latest commit author and branch name.*`n`n"
    $body += "*Generated by [GitHub Perso Manager](https://github.com/$RepoName)*"

    if ($DryRun) {
        Write-Host ""
        Write-Host "=== DRY RUN - Would create issue ===" -ForegroundColor Yellow
        Write-Host "Title: $title"
        Write-Host "Body:"
        Write-Host $body
    }
    else {
        Write-Host "Creating issue in $RepoName..."
        $issueUrl = $body | gh issue create --repo $RepoName --title $title --label "daily-report" --body-file -
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create the daily report issue in $RepoName."
        }
        Write-Host "Issue created: $issueUrl" -ForegroundColor Green
    }
}
else {
    Write-Host "No changes detected. No issue created." -ForegroundColor Green
}

Write-Host "Saving state to: $OutputStateJson"
$currentState | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputStateJson -Encoding UTF8

Write-Host "Done."
