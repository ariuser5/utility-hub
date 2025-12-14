param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteName = "gdrive",
    
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,
    
    [string]$FilePattern = "*",
    
    [string]$OutputPath = ".\archive_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
)

$ErrorActionPreference = "Stop"

Write-Host "Starting Google Drive archive process..." -ForegroundColor Cyan
Write-Host "  Remote: $RemoteName`:$FolderPath" -ForegroundColor Gray
Write-Host "  Pattern: $FilePattern" -ForegroundColor Gray
Write-Host "  Output: $OutputPath" -ForegroundColor Gray

# Create temp directory for downloads
$tempDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir | Out-Null

# Track created files for precise cleanup
$createdFiles = New-Object System.Collections.Generic.List[string]

try {
    Write-Host "`nListing files..." -ForegroundColor Yellow
    $remotePath = "${RemoteName}:${FolderPath}"
    $files = rclone lsf "$remotePath" --files-only --include "$FilePattern"

    if (-not $files) {
        Write-Warning "No files found matching pattern '$FilePattern'"
        return
    }

    Write-Host "Found files:" -ForegroundColor Green
    $files | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

    Write-Host "`nDownloading files..." -ForegroundColor Yellow
    # Download files; then enumerate what appeared to track them
    rclone copy "$remotePath" $tempDir --include "$FilePattern" --progress

    # Record downloaded files (only files, not directories)
    Get-ChildItem -Path $tempDir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $createdFiles.Add($_.FullName)
    }

    Write-Host "`nCreating archive..." -ForegroundColor Yellow
    Compress-Archive -Path "$tempDir\*" -DestinationPath $OutputPath -CompressionLevel Optimal

    Write-Host "`n✓ Archive created successfully!" -ForegroundColor Green
    Write-Host "  Location: $OutputPath" -ForegroundColor Gray
}
catch {
    Write-Error "Archive process failed: $($_.Exception.Message)"
    throw
}
finally {
    Write-Host "`nCleaning up temp directory..." -ForegroundColor Gray
    try {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Cleanup complete." -ForegroundColor Gray
    } catch {
        Write-Host "Cleanup failed. Temp directory remains at: $tempDir" -ForegroundColor DarkYellow
    }
}