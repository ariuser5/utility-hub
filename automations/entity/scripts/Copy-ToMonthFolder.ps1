
# -----------------------------------------------------------------------------
# Copy-ToMonthFolder.ps1
# -----------------------------------------------------------------------------
# Copies all files from a local source folder to a specified Google Drive folder.
#
# Usage:
#   .\Copy-ToMonthFolder.ps1 -SourceFolder "C:\local\files" -TargetPath "gdrive:path/to/_jan-2025"
#
# Parameters:
#   -SourceFolder   Local folder to copy files from (required)
#   -TargetPath     Full Google Drive path to copy files to (e.g., gdrive:path/to/_jan-2025)
#
# Behavior:
#   - Validates the source folder exists
#   - Uses rclone to copy all files (recursively) to the target Google Drive folder
#   - Prints progress and summary output
# -----------------------------------------------------------------------------
param(
    [Parameter(Mandatory=$true)]
    [string]$SourceFolder,

    # Full target path on Google Drive (e.g., "gdrive:path/to/folder")
    [Parameter(Mandatory=$true)]
    [string]$TargetPath
)

$ErrorActionPreference = "Stop"

# Validate source folder exists
if (-not (Test-Path $SourceFolder -PathType Container)) {
    Write-Error "Source folder does not exist: $SourceFolder"
    exit 1
}

Write-Host "Preparing to copy files..." -ForegroundColor Cyan

# Count files to copy
$itemCount = (Get-ChildItem -Path $SourceFolder -Recurse -File).Count
Write-Host "Copying $itemCount file(s) from:" -ForegroundColor Cyan
Write-Host "  Source: $SourceFolder" -ForegroundColor Gray
Write-Host "  Destination: $TargetPath" -ForegroundColor Gray
Write-Host ""

# Copy files using rclone
try {
    $result = rclone copy $SourceFolder $TargetPath --progress --verbose
    if ($LASTEXITCODE -ne 0) {
        Write-Error "rclone copy failed with exit code $LASTEXITCODE"
        exit 2
    }
} catch {
    Write-Error "Failed to copy files: $_"
    exit 2
}

Write-Host "`n✓ Successfully copied files to: $TargetPath" -ForegroundColor Green
Write-Output "COPIED:$TargetPath"
exit 0
