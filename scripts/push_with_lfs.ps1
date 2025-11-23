<#
Helper script to migrate large binary files (default: *.psd) to Git LFS and force-push.

Usage (PowerShell, run from repo root):
  pwsh -File .\scripts\push_with_lfs.ps1

Optional parameters:
  -IncludePatterns "*.psd,*.psb"  # Comma-separated list of glob patterns to migrate
  -NoPush                          # Perform migrate but skip pushing

Notes:
  - This script rewrites history (git lfs migrate import) and force-pushes all refs.
  - Ensure collaborators are informed; they must reset to the rewritten history.
  - If branch protection blocks force-push on your default branch, temporarily disable it or push to a new branch and update default.
#>

param(
  # Default includes both lower/upper case PSD/PSB to avoid case-miss
  [string]$IncludePatterns = "*.psd,*.PSD,*.psb,*.PSB",
  [switch]$NoPush
)

function Stop-WithMessage($msg) {
  Write-Host "[ERROR] $msg" -ForegroundColor Red
  exit 1
}

Write-Host "=== uiTK: Git LFS migrate and push helper ===" -ForegroundColor Cyan

# 1) Sanity checks
if (-not (Test-Path -LiteralPath ".git")) {
  Stop-WithMessage "This script must be run from the repository root (where .git folder exists)."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-WithMessage "Git is not installed or not in PATH. Install Git and try again."
}

$gitVersion = (& git --version) 2>$null
Write-Host "Git: $gitVersion"

if (-not (Get-Command git-lfs -ErrorAction SilentlyContinue)) {
  Stop-WithMessage "Git LFS is not installed. Install from https://git-lfs.github.com or 'choco install git-lfs', then rerun."
}

# 2) Ensure working tree is clean
$status = (& git status --porcelain)
if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Failed to get git status." }
if ($status) {
  Write-Host "[INFO] You have uncommitted changes:" -ForegroundColor Yellow
  Write-Host $status
  Stop-WithMessage "Please commit or stash changes before running migration."
}

# 3) Ensure remote is set
$remotes = (& git remote -v)
if (-not $remotes) {
  Stop-WithMessage "No git remotes configured. Add a remote (e.g., 'git remote add origin https://github.com/NhomNhem/uiTK.git') and rerun."
}
Write-Host "Remotes:\n$remotes"

# 4) Initialize git lfs
Write-Host "[STEP] Initializing Git LFS" -ForegroundColor Cyan
& git lfs install
if ($LASTEXITCODE -ne 0) { Stop-WithMessage "git lfs install failed." }

# 5) Ensure .gitattributes has LFS tracking for requested patterns
$gitattributes = ".gitattributes"
if (-not (Test-Path -LiteralPath $gitattributes)) {
  New-Item -ItemType File -Path $gitattributes -Force | Out-Null
}

$existing = Get-Content -LiteralPath $gitattributes -ErrorAction SilentlyContinue
$patterns = $IncludePatterns.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }

$addedAny = $false
foreach ($pat in $patterns) {
  $rule = "$pat filter=lfs diff=lfs merge=lfs -text"
  if (-not ($existing -and ($existing -match [regex]::Escape($rule)))) {
    Add-Content -LiteralPath $gitattributes -Value $rule
    $addedAny = $true
    Write-Host "[INFO] Added LFS tracking rule: $rule"
  }
}

if ($addedAny) {
  & git add .gitattributes
  & git commit -m "chore: track large assets with Git LFS ($IncludePatterns)"
  if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Failed to commit .gitattributes update." }
} else {
  Write-Host "[INFO] .gitattributes already contains required LFS rules."
}

# 6) Create a backup branch for safety
$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
if (-not $currentBranch) { Stop-WithMessage "Unable to determine current branch." }
$backupBranch = "backup/pre-lfs-" + (Get-Date -Format "yyyyMMdd-HHmmss")
Write-Host "[STEP] Creating backup branch: $backupBranch from $currentBranch" -ForegroundColor Cyan
& git branch $backupBranch
if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Failed to create backup branch." }

# 7) Update local refs
Write-Host "[STEP] Fetching latest and rebasing" -ForegroundColor Cyan
& git fetch --all --prune
& git pull --rebase
if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] pull --rebase failed or not applicable; continuing." -ForegroundColor Yellow }

# 8) Run LFS migration across all refs
$includeArg = $patterns -join ","
Write-Host "[STEP] Migrating history to LFS for: $includeArg" -ForegroundColor Cyan
& git lfs migrate import --everything --include="$includeArg"
if ($LASTEXITCODE -ne 0) { Stop-WithMessage "git lfs migrate import failed." }

# 9) Verify tracked files
Write-Host "[STEP] Verifying LFS tracking" -ForegroundColor Cyan
& git lfs track
& git lfs ls-files

# 9b) Ensure no >100MB git blobs remain (defense-in-depth)
Write-Host "[STEP] Checking for remaining >100MB Git blobs" -ForegroundColor Cyan
$large = @()
& git rev-list --objects --all | ForEach-Object {
  $parts = $_ -split ' ', 2
  if ($parts.Count -ge 1 -and $parts[0]) {
    $sha = $parts[0]
    $path = if ($parts.Count -ge 2) { $parts[1] } else { "" }
    $size = (& git cat-file -s $sha) 2>$null
    if ($LASTEXITCODE -eq 0 -and $size -match '^\d+$') {
      if ([int64]$size -ge 100MB) {
        $large += ("{0:n2} MB`t{1}`t{2}" -f ([double]$size/1MB), $sha, $path)
      }
    }
  }
}
if ($large.Count -gt 0) {
  Write-Host "[ERROR] Large Git blobs remain after migration:" -ForegroundColor Red
  $large | ForEach-Object { Write-Host $_ }
  Stop-WithMessage "Please add missing patterns to LFS and rerun migration (e.g., use -IncludePatterns)."
}

# 10) Force-push all refs and tags (unless -NoPush)
if ($NoPush) {
  Write-Host "[INFO] Migration complete. Skipping push due to -NoPush." -ForegroundColor Yellow
  exit 0
}

Write-Host "[STEP] Force-pushing all branches" -ForegroundColor Cyan
& git push origin --force --all
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Force-pushing branches failed. This is often caused by branch protection on your default branch." -ForegroundColor Red
  Write-Host "[HINT] You can push to a new branch without force and switch default later:" -ForegroundColor Yellow
  Write-Host "       git push origin HEAD:lfs-migrated" -ForegroundColor Yellow
  Stop-WithMessage "Force-push blocked. See hint above or temporarily relax branch protection and rerun."
}

Write-Host "[STEP] Force-pushing tags" -ForegroundColor Cyan
& git push origin --force --tags
if ($LASTEXITCODE -ne 0) {
  Stop-WithMessage "Force-pushing tags failed."
}

Write-Host "[SUCCESS] Push completed. Verify on GitHub that large files are stored via LFS." -ForegroundColor Green
