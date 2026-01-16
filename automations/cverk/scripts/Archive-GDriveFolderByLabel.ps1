<#
-------------------------------------------------------------------------------
Archive-GDriveFolderByLabel.ps1
-------------------------------------------------------------------------------
CVERK helper: creates one archive per label for top-level files in a Google Drive
folder and uploads the archives back to Google Drive.

Label format matches Label-GDriveFiles.ps1:
  "[LABEL] filename.ext"

This script intentionally reuses the generic GDrive archiver:
  automations/gdrive/Archive-GDriveFolder.ps1

Examples:
  # Default: zip archives uploaded to <FolderPath>/archives
  .\Archive-GDriveFolderByLabel.ps1 -FolderPath "clients/acme/inbox"

  # Use 7z
  .\Archive-GDriveFolderByLabel.ps1 -FolderPath "clients/acme/inbox" -ArchiveExtension "7z"

  # Use tar.gz and upload elsewhere
  .\Archive-GDriveFolderByLabel.ps1 -FolderPath "clients/acme/inbox" -ArchiveExtension "tar.gz" -ArchiveDestinationPath "clients/acme/archives"
-------------------------------------------------------------------------------
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$RemoteName = "gdrive",

    # Remote folder path on Google Drive (no trailing slash needed)
    [Parameter(Mandatory = $true)]
    [string]$FolderPath,

    # Destination folder path on Google Drive to upload archives to.
    # Defaults to a subfolder named 'archives' under -FolderPath.
    [Parameter()]
    [string]$ArchiveDestinationPath,

    # Archive extension / format: zip (default), 7z, tar, tar.gz, tgz
    [Parameter()]
    [string]$ArchiveExtension = "zip",

    # For 7z archives: executable name or full path (default: 7z)
    [Parameter()]
    [string]$SevenZipExe = "7z",

    # If provided, files with basenames matching this regex are excluded from processing entirely
    [Parameter()]
    [string]$ExcludeNameRegex,

    # Include unlabeled files (grouped under -UnlabeledGroupName)
    [Parameter()]
    [switch]$IncludeUnlabeled,

    [Parameter()]
    [string]$UnlabeledGroupName = "UNLABELED",

    # Overwrite existing archive on upload (archive names include timestamps, so usually not needed)
    [Parameter()]
    [switch]$Overwrite
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Error "rclone not found on PATH. Install it (e.g., 'winget install Rclone.Rclone') and ensure it's available in your session."
    exit 1
}

function Get-LabelFromBasename {
    param([Parameter(Mandatory = $true)][string]$Basename)

    if ($Basename -match '^\[([^\]]+)\]\s*') {
        return $Matches[1]
    }

    return $null
}

function Convert-ArchiveExtension {
    param([Parameter(Mandatory = $true)][string]$Ext)

    $e = $Ext.Trim()
    if ($e.StartsWith('.')) { $e = $e.TrimStart('.') }
    $e = $e.ToLowerInvariant()
    if ($e -eq 'targz') { return 'tar.gz' }
    return $e
}

function Get-LabelFileSelector {
    param([Parameter(Mandatory = $true)][string]$Label)

    # FileNames selectors support '*' as a wildcard, while treating brackets literally.
    # This matches files like: "[INVOICE] something.pdf"
    return "[$Label] *"
}

if (-not $ArchiveDestinationPath -or -not $ArchiveDestinationPath.Trim()) {
    $ArchiveDestinationPath = "$FolderPath/archives"
}

$archiveExt = Convert-ArchiveExtension -Ext $ArchiveExtension

$remoteFolder = "${RemoteName}:${FolderPath}"

Write-Host "Starting CVERK label archive process..." -ForegroundColor Cyan
Write-Host "  Remote folder: $remoteFolder" -ForegroundColor Gray
Write-Host "  Archive format: $archiveExt" -ForegroundColor Gray
Write-Host "  Upload to: ${RemoteName}:$ArchiveDestinationPath" -ForegroundColor Gray

if ($ExcludeNameRegex) {
    Write-Host "  Excluding basenames matching: $ExcludeNameRegex" -ForegroundColor Gray
}

# Locate reusable scripts
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$archiveFolderScript = Join-Path $repoRoot 'automations\gdrive\Archive-GDriveFolder.ps1'
$uploadScript = Join-Path $repoRoot 'automations\gdrive\Upload-ToGDrive.ps1'

if (-not (Test-Path -LiteralPath $archiveFolderScript -PathType Leaf)) {
    throw "Archive helper script not found: $archiveFolderScript"
}
if (-not (Test-Path -LiteralPath $uploadScript -PathType Leaf)) {
    throw "Upload helper script not found: $uploadScript"
}

Write-Host "`nListing files..." -ForegroundColor Yellow
$basenames = rclone lsf "$remoteFolder" --files-only

if (-not $basenames) {
    Write-Warning "No files found in '$remoteFolder'"
    return
}

$items = foreach ($b in $basenames) {
    $name = "$b".TrimEnd("`r", "`n")
    if (-not $name) { continue }

    if ($ExcludeNameRegex -and ($name -match $ExcludeNameRegex)) {
        continue
    }

    $label = Get-LabelFromBasename -Basename $name
    if (-not $label) {
        if ($IncludeUnlabeled) {
            $label = $UnlabeledGroupName
        } else {
            continue
        }
    }

    [pscustomobject]@{
        Label = $label
        Basename = $name
    }
}

if (-not $items -or $items.Count -eq 0) {
    if ($IncludeUnlabeled) {
        Write-Warning "No files matched (after exclusions)."
    } else {
        Write-Warning "No labeled files matched. (Tip: pass -IncludeUnlabeled to include unlabeled files.)"
    }
    return
}

$groups = $items | Group-Object -Property Label | Sort-Object Name

Write-Host "Found label groups:" -ForegroundColor Green
foreach ($g in $groups) {
    Write-Host ("  - {0}: {1} file(s)" -f $g.Name, $g.Count) -ForegroundColor Gray
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Build archives locally, then upload
$workRoot = Join-Path $env:TEMP ("utility-hub_cverk_label-archive_" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    foreach ($g in $groups) {
        $label = $g.Name
        $labelDirSafe = ($label -replace '[^a-zA-Z0-9_-]', '_')

        $archiveFileName = "${labelDirSafe}_${timestamp}.$archiveExt"
        $archivePath = Join-Path $workRoot $archiveFileName

        if ($PSCmdlet.ShouldProcess("${RemoteName}:$ArchiveDestinationPath", "Create + upload archive for label '$label'")) {
            Write-Host "`n[$label] Creating archive..." -ForegroundColor Yellow

            $include = $null
            $exclude = $null
            $fileNames = $null
            if ($label -eq $UnlabeledGroupName) {
                # Unlabeled = explicit set of basenames (avoid rclone glob escaping issues)
                $fileNames = @(
                    $g.Group |
                        ForEach-Object { $_.Basename } |
                        Where-Object { $_ -and $_.Trim() }
                )
            } else {
                $fileNames = @(Get-LabelFileSelector -Label $label)
            }

            # Reuse generic archiver to produce the archive locally
            if ($fileNames) {
                $created = & $archiveFolderScript -RemoteName $RemoteName -FolderPath $FolderPath -FileNames $fileNames -ArchiveExtension $archiveExt -SevenZipExe $SevenZipExe -OutputPath $archivePath
            } else {
                $created = & $archiveFolderScript -RemoteName $RemoteName -FolderPath $FolderPath -FilePattern $include -ExcludePattern $exclude -ArchiveExtension $archiveExt -SevenZipExe $SevenZipExe -OutputPath $archivePath
            }
            if (-not $created) {
                throw "Archive creation produced no output path for label '$label'."
            }

            Write-Host "[$label] Uploading archive..." -ForegroundColor Yellow
            & $uploadScript -RemoteName $RemoteName -DestinationPath $ArchiveDestinationPath -LocalFilePath $archivePath -Overwrite:$Overwrite

            Write-Host "[$label] ✓ Done" -ForegroundColor Green
        }
    }

    Write-Host "`n✓ All label archives completed." -ForegroundColor Green
}
catch {
    Write-Error "Label archive process failed: $($_.Exception.Message)"
    throw
}
finally {
    Write-Host "`nCleaning up temp directory..." -ForegroundColor Gray
    try {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Cleanup complete." -ForegroundColor Gray
    } catch {
        Write-Host "Cleanup failed. Temp directory remains at: $workRoot" -ForegroundColor DarkYellow
    }
}
