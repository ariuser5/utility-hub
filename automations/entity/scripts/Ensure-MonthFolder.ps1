
# -----------------------------------------------------------------------------
# Ensure-MonthFolder.ps1
# -----------------------------------------------------------------------------
# Creates the next missing month folder (with prefix) in a directory.
# Supports both local filesystem paths and rclone remote specs.
#
# Usage:
#   .\Ensure-MonthFolder.ps1 -Path "gdrive:path/to/dir" [-PathType Auto|Local|Remote] [-StartYear 2025] [-NewFolderPrefix "_"]
#
# Parameters:
#   -Path              Base folder where month folders live (local path or rclone remote spec)
#   -PathType          Auto|Local|Remote (default: Auto)
#   -StartYear         Year to start searching for missing months (default: current year)
#   -NewFolderPrefix   Prefix for new folders (default: "_")
#
# Behavior:
#   - Scans the target directory for folders named "mon-YYYY" or "_mon-YYYY" (e.g., "jan-2025", "_jan-2025")
#   - Finds the latest existing month for each year, starting from StartYear
#   - If all months exist for a year, continues to the next year
#   - Creates the next missing month folder with the specified prefix
#   - Outputs CREATED:<path> if a folder is created, or NOOP if all months exist
# -----------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter()]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$PathType = 'Auto',

    # Start year to check (default: current year)
    [int]$StartYear = (Get-Date).Year,

    # Prefix to use when creating a fresh folder (default: underscore)
    [string]$NewFolderPrefix = "_"
)

$ErrorActionPreference = "Stop"


# Month short names mapping in order (jan..dec)
$months = @("jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec")

$pathModule = Join-Path $PSScriptRoot '..\..\utils\Path.psm1'
Import-Module $pathModule -Force

$monthPatternModule = Join-Path $PSScriptRoot '..\helpers\MonthPattern.psm1'
Import-Module $monthPatternModule -Force

$baseInfo = $null
$baseInfo = Resolve-UtilityHubPath -Path $Path -PathType $PathType

# Get list of existing directories
$existingDirs = @()
if ($baseInfo.PathType -eq 'Remote') {
    try {
        $existingDirs = rclone lsf $baseInfo.Normalized --dirs-only
    } catch {
        Write-Error "Failed to list remote directory '$($baseInfo.Normalized)'. Ensure rclone is configured and the path exists."
        exit 1
    }
} else {
    try {
        $existingDirs = Get-ChildItem -LiteralPath $baseInfo.LocalPath -Directory -ErrorAction Stop | Select-Object -ExpandProperty Name
    } catch {
        Write-Error "Failed to list local directory '$($baseInfo.LocalPath)'. Ensure the path exists."
        exit 1
    }
}

$where = if ($baseInfo.PathType -eq 'Remote') { 'remote' } else { 'local' }
Write-Host "Scanning $where directory: $($baseInfo.Normalized)" -ForegroundColor Cyan

# Find the next month to create, recursing to next year if needed
$currentYear = $StartYear
while ($true) {
    # Filter directories for the current year
    $yearDirs = $existingDirs | Where-Object { $_ -match "^_*[a-z]{3}-$currentYear$" }
    
    # Get the latest month for this year using the MonthPattern module
    $latestMonth = Get-LatestMonthPattern -Values $yearDirs -SkipInvalid $true
    
    # Extract month index from the latest month
    $latestIdx = -1
    if ($latestMonth -and $latestMonth -match '^_*([a-z]{3})-\d{4}$') {
        $monthName = $matches[1]
        $latestIdx = $months.IndexOf($monthName.ToLower())
    }
    if ($latestIdx -eq ($months.Count - 1)) {
        Write-Host "All months exist for $currentYear. Moving to next year..." -ForegroundColor Cyan
        $currentYear++
        continue
    }
    $nextIdx = $latestIdx + 1
    if ($nextIdx -ge $months.Count) {
        # Should not happen, but just in case
        Write-Host "Unexpected: nextIdx out of range for $currentYear. Moving to next year..." -ForegroundColor DarkYellow
        $currentYear++
        continue
    }
    $missing = "$($months[$nextIdx])-$currentYear"
    $newFolderName = "$NewFolderPrefix$missing"
    Write-Host "Creating new folder: $newFolderName" -ForegroundColor Yellow
    $targetPath = Join-UtilityHubPath -Base $baseInfo.Normalized -Child $newFolderName -PathType $baseInfo.PathType
    break
}

if ($baseInfo.PathType -eq 'Remote') {
    rclone mkdir $targetPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create folder '$newFolderName' at '$($baseInfo.Normalized)' (exit code $LASTEXITCODE)."
        exit 2
    }
} else {
    try {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    } catch {
        Write-Error "Failed to create folder '$newFolderName' at '$($baseInfo.LocalPath)'."
        exit 2
    }
}

Write-Host "✓ Created folder: $newFolderName" -ForegroundColor Green
Write-Host "  Path: $targetPath" -ForegroundColor Gray
Write-Output "CREATED:$targetPath"
exit 0
