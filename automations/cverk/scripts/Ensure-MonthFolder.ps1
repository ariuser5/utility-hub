param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteName = "gdrive",

    # Remote directory path on Google Drive where month folders live
    [Parameter(Mandatory=$true)]
    [string]$DirectoryPath,

    # Year to check (default: current year)
    [int]$Year = (Get-Date).Year,

    # Prefix to use when creating a fresh folder (default: underscore)
    [string]$NewFolderPrefix = "_"
)

$ErrorActionPreference = "Stop"

# Month short names mapping in order (jan..dec)
$months = @("jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec")

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

# Find the first missing month for the given year, skipping any prefixed month that already exists
$missing = $null
foreach ($m in $months) {
    $expected = "$m-$Year"

    # If the unprefixed month exists, continue to next month
    if ($existingSet.Contains($expected)) {
        continue
    }

    $prefixed = "$NewFolderPrefix$expected"

    # If the prefixed folder already exists, skip to avoid overwrite
    if ($existingSet.Contains($prefixed)) {
        Write-Host "Skipping $expected because prefixed folder already exists: $prefixed" -ForegroundColor DarkYellow
        continue
    }

    $missing = $expected
    break
}

if ($null -eq $missing) {
    Write-Output "NOOP: no month to create for $Year (either present or prefixed already exists)"
    exit 1
}

$newFolderName = "$NewFolderPrefix$missing"
Write-Host "Creating new folder: $newFolderName" -ForegroundColor Yellow

# rclone mkdir will create nested paths as needed
$targetPath = "$remoteBase/$newFolderName"

# Create folder
$r = rclone mkdir $targetPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create folder '$newFolderName' at '$remoteBase' (exit code $LASTEXITCODE)."
    exit 2
}

Write-Host "✓ Created folder: $newFolderName" -ForegroundColor Green
Write-Host "  Path: $targetPath" -ForegroundColor Gray
Write-Output "CREATED:$targetPath"
exit 0
