
# -----------------------------------------------------------------------------
# Copy-ToMonthFolder.ps1
# -----------------------------------------------------------------------------
# Copies all files from a source folder to a destination folder.
# Supports local filesystem paths and/or rclone remote specs.
#
# Usage:
#   .\Copy-ToMonthFolder.ps1 -SourcePath "C:\local\files" -DestinationPath "gdrive:path/to/_jan-2025"
#   .\Copy-ToMonthFolder.ps1 -SourceFolder "C:\local\files" -TargetPath "gdrive:path/to/_jan-2025"  # legacy
#
# Parameters:
#   -SourcePath        Source folder path (local or rclone remote spec)
#   -DestinationPath   Destination folder path (local or rclone remote spec)
#   -SourcePathType    Auto|Local|Remote (default: Auto)
#   -DestinationPathType Auto|Local|Remote (default: Auto)
#
# Behavior:
#   - Validates the source folder exists
#   - Uses native Copy-Item for local -> local
#   - Uses rclone for any copy where either side is remote
#   - Prints progress and summary output
# -----------------------------------------------------------------------------
[
    CmdletBinding()
]
param(
    [Parameter(Mandatory = $true)]
    [Alias('SourceFolder')]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [Alias('TargetPath')]
    [string]$DestinationPath,

    [Parameter()]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$SourcePathType = 'Auto',

    [Parameter()]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$DestinationPathType = 'Auto'
)

$ErrorActionPreference = "Stop"

$pathModule = Join-Path $PSScriptRoot '..\\helpers\\Path.psm1'
Import-Module $pathModule -Force

$src = Resolve-UtilityHubPath -Path $SourcePath -PathType $SourcePathType
$dst = Resolve-UtilityHubPath -Path $DestinationPath -PathType $DestinationPathType

# Validate source folder exists
if ($src.PathType -eq 'Local') {
    if (-not (Test-Path -LiteralPath $src.LocalPath -PathType Container)) {
        Write-Error "Source folder does not exist: $($src.LocalPath)"
        exit 1
    }
} else {
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-Error "rclone not found on PATH. Install rclone and/or restart the shell."
        exit 1
    }
    try {
        & rclone lsf $src.Normalized --max-depth 1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "rclone lsf failed (exit $LASTEXITCODE)"
        }
    } catch {
        Write-Error "Source folder not accessible: $($src.Normalized)"
        exit 1
    }
}

Write-Host "Preparing to copy files..." -ForegroundColor Cyan

# Count files to copy (only when local)
$itemCount = $null
if ($src.PathType -eq 'Local') {
    $itemCount = (Get-ChildItem -LiteralPath $src.LocalPath -Recurse -File).Count
}

if ($null -ne $itemCount) {
    Write-Host "Copying $itemCount file(s) from:" -ForegroundColor Cyan
} else {
    Write-Host "Copying files from:" -ForegroundColor Cyan
}

Write-Host "  Source: $($src.Normalized)" -ForegroundColor Gray
Write-Host "  Destination: $($dst.Normalized)" -ForegroundColor Gray
Write-Host ""

if ($src.PathType -eq 'Local' -and $dst.PathType -eq 'Local') {
    try {
        if (-not (Test-Path -LiteralPath $dst.LocalPath -PathType Container)) {
            New-Item -ItemType Directory -Path $dst.LocalPath -Force | Out-Null
        }

        Copy-Item -Path (Join-Path -Path $src.LocalPath -ChildPath '*') -Destination $dst.LocalPath -Recurse -Force
    } catch {
        Write-Error "Failed to copy files: $_"
        exit 2
    }
} else {
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-Error "rclone not found on PATH. Install rclone and/or restart the shell."
        exit 2
    }

    try {
        $null = rclone copy $src.Normalized $dst.Normalized --progress --verbose
        if ($LASTEXITCODE -ne 0) {
            Write-Error "rclone copy failed with exit code $LASTEXITCODE"
            exit 2
        }
    } catch {
        Write-Error "Failed to copy files: $_"
        exit 2
    }
}

Write-Host "`n✓ Successfully copied files to: $($dst.Normalized)" -ForegroundColor Green
Write-Output "COPIED:$($dst.Normalized)"
exit 0
