
# -----------------------------------------------------------------------------
# Ensure-MonthFolder.ps1
# -----------------------------------------------------------------------------
# Creates the next missing month folder (with prefix) in a Google Drive directory.
#
# Usage:
#   .\Ensure-MonthFolder.ps1 -RemoteName "gdrive" -DirectoryPath "path/to/dir" [-StartYear 2025] [-NewFolderPrefix "_"]
#
# Parameters:
#   -RemoteName        Name of rclone remote (default: "gdrive")
#   -DirectoryPath     Path on remote where month folders live (required)
#   -StartYear         Year to start searching for missing months (default: current year)
#   -NewFolderPrefix   Prefix for new folders (default: "_")
#
# Behavior:
#   - Scans the target directory for folders named "mon-YYYY" or "_mon-YYYY" (e.g., "jan-2025", "_jan-2025")
#   - Finds the latest existing month for each year, starting from StartYear
#   - If all months exist for a year, continues to the next year
#   - Creates the next missing month folder with the specified prefix
#   - Outputs CREATED:<full-path> if a folder is created, or NOOP if all months exist
# -----------------------------------------------------------------------------
param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteName = "gdrive",

    # Remote directory path on Google Drive where month folders live
    [Parameter(Mandatory=$true)]
    [string]$DirectoryPath,

    # Start year to check (default: current year)
    [int]$StartYear = (Get-Date).Year,

    # Prefix to use when creating a fresh folder (default: underscore)
    [string]$NewFolderPrefix = "_"
)

$ErrorActionPreference = "Stop"


# Month short names mapping in order (jan..dec)
$months = @("jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec")

function Get-LatestMonth {
    param(
        [int]$Year
    )
    $remoteBase = "${RemoteName}:${DirectoryPath}"
    try {
        $existingDirs = rclone lsf "$remoteBase" --dirs-only
    } catch {
        Write-Error "Failed to list remote directory '$remoteBase'. Ensure rclone is configured and the path exists."
        exit 1
    }
    $existingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $existingDirs) {
        $name = $d.TrimEnd('/')
        [void]$existingSet.Add($name)
    }
    $latestIdx = -1
    for ($i = 0; $i -lt $months.Count; $i++) {
        $m = $months[$i]
        $expected = "$m-$Year"
        $prefixed = "$NewFolderPrefix$expected"
        if ($existingSet.Contains($expected) -or $existingSet.Contains($prefixed)) {
            $latestIdx = $i
        }
    }
    return $latestIdx
}

$remoteBase = "${RemoteName}:${DirectoryPath}"
Write-Host "Scanning Google Drive directory: $remoteBase" -ForegroundColor Cyan

# List existing subfolders
try {
    $existingDirs = rclone lsf "$remoteBase" --dirs-only
} catch {
    Write-Error "Failed to list remote directory '$remoteBase'. Ensure rclone is configured and the path exists."
    exit 1
}

# Normalize to lower for comparison
$existingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($d in $existingDirs) {
    # rclone lsf returns names with trailing '/'; trim it
    $name = $d.TrimEnd('/')
    [void]$existingSet.Add($name)
}

# Find the next month to create, recursing to next year if needed
$currentYear = $StartYear
while ($true) {
    $latestIdx = Get-LatestMonth -Year $currentYear
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
    $targetPath = "${RemoteName}:${DirectoryPath}/$newFolderName"
    break
}

# rclone mkdir will create nested paths as needed
$targetPath = "$remoteBase/$newFolderName"

# Create folder
rclone mkdir $targetPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create folder '$newFolderName' at '$remoteBase' (exit code $LASTEXITCODE)."
    exit 2
}

Write-Host "✓ Created folder: $newFolderName" -ForegroundColor Green
Write-Host "  Path: $targetPath" -ForegroundColor Gray
Write-Output "CREATED:$targetPath"
exit 0
