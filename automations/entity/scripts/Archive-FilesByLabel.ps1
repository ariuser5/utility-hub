<#
-------------------------------------------------------------------------------
Archive-GDriveFolderByLabel.ps1
-------------------------------------------------------------------------------
Helper: creates one archive per label for top-level files in a Google Drive
folder and uploads the archives back to Google Drive.

Label format matches Label-GDriveFiles.ps1:
  "[LABEL] filename.ext"

This script intentionally reuses the generic GDrive archiver:
  automations/gdrive/Archive-GDriveFolder.ps1

Examples:
    # Default: zip archives uploaded to <Path>/archives
    .\Archive-GDriveFolderByLabel.ps1 -Path "gdrive:clients/acme/inbox"

  # Use 7z
    .\Archive-GDriveFolderByLabel.ps1 -Path "gdrive:clients/acme/inbox" -ArchiveExtension "7z"

  # Use tar.gz and upload elsewhere
    .\Archive-GDriveFolderByLabel.ps1 -Path "gdrive:clients/acme/inbox" -ArchiveExtension "tar.gz" -ArchiveDestinationPath "gdrive:clients/acme/archives"
-------------------------------------------------------------------------------
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Unified')]
param(
    # Base folder path (local folder or rclone remote spec, e.g. "gdrive:clients/acme/inbox")
    [Parameter(Mandatory = $true, ParameterSetName = 'Unified')]
    [string]$Path,

    [Parameter(ParameterSetName = 'Unified')]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$PathType = 'Auto',

    # Destination folder path on Google Drive to upload archives to.
    # Defaults to a subfolder named 'archives' under -Path.
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

$pathModule = Join-Path $PSScriptRoot '..\helpers\Path.psm1'
Import-Module $pathModule -Force

$baseInfo = $null
try {
    $baseInfo = Resolve-UtilityHubPath -Path $Path -PathType $PathType
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

if ($baseInfo.PathType -eq 'Remote') {
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-Error "rclone not found on PATH. Install it (e.g., 'winget install Rclone.Rclone') and ensure it's available in your session."
        exit 1
    }
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
    $ArchiveDestinationPath = Join-UtilityHubPath -Base $baseInfo.Normalized -Child 'archives' -PathType $baseInfo.PathType
}

$archiveExt = Convert-ArchiveExtension -Ext $ArchiveExtension

$remoteFolder = $null
$uploadRemoteName = $null
$uploadRemotePath = $null

if ($baseInfo.PathType -eq 'Remote') {
    $remoteFolder = $baseInfo.Normalized

    # Destination may be a full remote spec or a remote-path-only. Parse it.
    $destInfo = $null
    if ($ArchiveDestinationPath -match '^[^\\/]+:.+$' -or $ArchiveDestinationPath -match '^[^\\/]+:$') {
        $destInfo = Resolve-UtilityHubPath -Path $ArchiveDestinationPath -PathType 'Remote'
    } else {
        $destInfo = Resolve-UtilityHubPath -Path ("{0}:{1}" -f $baseInfo.RemoteName, $ArchiveDestinationPath) -PathType 'Remote'
    }

    $uploadRemoteName = $destInfo.RemoteName
    $uploadRemotePath = $destInfo.RemotePath
}

Write-Host "Starting label archive process..." -ForegroundColor Cyan
Write-Host "  Folder: $($baseInfo.Normalized)" -ForegroundColor Gray
Write-Host "  Archive format: $archiveExt" -ForegroundColor Gray
if ($baseInfo.PathType -eq 'Remote') {
    Write-Host "  Upload to: ${uploadRemoteName}:$uploadRemotePath" -ForegroundColor Gray
} else {
    Write-Host "  Copy to: $ArchiveDestinationPath" -ForegroundColor Gray
}

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

$basenames = $null
if ($baseInfo.PathType -eq 'Remote') {
    $basenames = rclone lsf "$remoteFolder" --files-only
} else {
    try {
        $basenames = Get-ChildItem -LiteralPath $baseInfo.LocalPath -File | Select-Object -ExpandProperty Name
    } catch {
        Write-Error "Failed to list files in '$($baseInfo.LocalPath)'."
        exit 1
    }
}

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
$workRoot = Join-Path $env:TEMP ("utility-hub_label-archive_" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $workRoot | Out-Null

function Test-ExecutableAvailable {
    param([Parameter(Mandatory = $true)][string]$Exe)

    if (-not $Exe) { return $false }

    if ($Exe -match '^[a-zA-Z]:\\' -or $Exe.Contains('\\') -or $Exe.Contains('/')) {
        return (Test-Path -LiteralPath $Exe -PathType Leaf)
    }

    return ($null -ne (Get-Command $Exe -ErrorAction SilentlyContinue))
}

function New-ArchiveFile {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$InputDir,
        [Parameter(Mandatory = $true)][string]$ArchiveExt,
        [Parameter(Mandatory = $true)][string]$SevenZipExe
    )

    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
        throw "Input directory not found: $InputDir"
    }

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    switch ($ArchiveExt) {
        'zip' {
            Compress-Archive -Path (Join-Path $InputDir '*') -DestinationPath $ArchivePath -CompressionLevel Optimal
            return
        }
        '7z' {
            if (-not (Test-ExecutableAvailable -Exe $SevenZipExe)) {
                throw "7-Zip executable not found: '$SevenZipExe'. Install 7-Zip or pass -SevenZipExe with a valid path."
            }
            Push-Location $InputDir
            try {
                & $SevenZipExe a -t7z $ArchivePath . | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "7z failed with exit code $LASTEXITCODE" }
            } finally {
                Pop-Location
            }
            return
        }
        'tar' {
            if (-not (Test-ExecutableAvailable -Exe 'tar')) {
                throw "'tar' not found on PATH. Install tar (Windows ships bsdtar) or add it to PATH."
            }
            & tar -cf $ArchivePath -C $InputDir .
            if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
            return
        }
        'tar.gz' {
            if (-not (Test-ExecutableAvailable -Exe 'tar')) {
                throw "'tar' not found on PATH. Install tar (Windows ships bsdtar) or add it to PATH."
            }
            & tar -czf $ArchivePath -C $InputDir .
            if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
            return
        }
        'tgz' {
            if (-not (Test-ExecutableAvailable -Exe 'tar')) {
                throw "'tar' not found on PATH. Install tar (Windows ships bsdtar) or add it to PATH."
            }
            & tar -czf $ArchivePath -C $InputDir .
            if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
            return
        }
        default {
            throw "Unsupported archive extension '$ArchiveExt'. Supported: zip, 7z, tar, tar.gz, tgz"
        }
    }
}

try {
    foreach ($g in $groups) {
        $label = $g.Name
        $labelDirSafe = ($label -replace '[^a-zA-Z0-9_-]', '_')

        $archiveFileName = "${labelDirSafe}_${timestamp}.$archiveExt"
        $archivePath = Join-Path $workRoot $archiveFileName

        if ($baseInfo.PathType -eq 'Remote') {
            if ($PSCmdlet.ShouldProcess("${uploadRemoteName}:$uploadRemotePath", "Create + upload archive for label '$label'")) {
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
                $created = & $archiveFolderScript -Path $baseInfo.Normalized -PathType 'Remote' -FileNames $fileNames -ArchiveExtension $archiveExt -SevenZipExe $SevenZipExe -OutputPath $archivePath
            } else {
                $created = & $archiveFolderScript -Path $baseInfo.Normalized -PathType 'Remote' -ArchiveExtension $archiveExt -SevenZipExe $SevenZipExe -OutputPath $archivePath
            }
            if (-not $created) {
                throw "Archive creation produced no output path for label '$label'."
            }

            Write-Host "[$label] Uploading archive..." -ForegroundColor Yellow
            & $uploadScript -Destination ("{0}:{1}" -f $uploadRemoteName, $uploadRemotePath) -LocalFilePath $archivePath -Overwrite:$Overwrite

            Write-Host "[$label] ✓ Done" -ForegroundColor Green
        }
        } else {
            if ($PSCmdlet.ShouldProcess($ArchiveDestinationPath, "Create archive for label '$label'")) {
                Write-Host "`n[$label] Creating archive..." -ForegroundColor Yellow

                $labelWork = Join-Path $workRoot ("work_" + $labelDirSafe)
                if (Test-Path -LiteralPath $labelWork) {
                    Remove-Item -LiteralPath $labelWork -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -ItemType Directory -Path $labelWork | Out-Null

                foreach ($fi in $g.Group) {
                    $srcFile = Join-Path $baseInfo.LocalPath $fi.Basename
                    if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
                        Copy-Item -LiteralPath $srcFile -Destination $labelWork -Force
                    }
                }

                New-ArchiveFile -ArchivePath $archivePath -InputDir $labelWork -ArchiveExt $archiveExt -SevenZipExe $SevenZipExe

                if (-not (Test-Path -LiteralPath $ArchiveDestinationPath -PathType Container)) {
                    New-Item -ItemType Directory -Path $ArchiveDestinationPath -Force | Out-Null
                }

                $destFile = Join-Path $ArchiveDestinationPath $archiveFileName
                if ((Test-Path -LiteralPath $destFile) -and -not $Overwrite) {
                    Write-Host "[$label] Destination exists; skipping (no -Overwrite): $destFile" -ForegroundColor DarkYellow
                } else {
                    Move-Item -LiteralPath $archivePath -Destination $destFile -Force
                    Write-Host "[$label] ✓ Done" -ForegroundColor Green
                }
            }
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
