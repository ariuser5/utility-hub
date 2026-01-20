[
    CmdletBinding(DefaultParameterSetName = 'Unified')
]
param(
    # Destination folder path (remote spec, e.g. "gdrive:clients/acme/archives")
    [Parameter(Mandatory = $true, ParameterSetName = 'Unified')]
    [Alias('DestinationPath')]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Unified')]
    [ValidateSet('Auto', 'Remote')]
    [string]$DestinationPathType = 'Auto',

    [Parameter(Mandatory = $true, ParameterSetName = 'LegacyRemote')]
    [string]$RemoteName = "gdrive",

    # Destination folder path on Google Drive (remote-path-only; legacy)
    [Parameter(Mandatory = $true, ParameterSetName = 'LegacyRemote')]
    [string]$DestinationPath,

    # Local file to upload
    [Parameter(Mandatory=$true)]
    [string]$LocalFilePath,

    [switch]$Overwrite,

    # Suppress destination folder auto-creation when missing
    [switch]$NoCreate
)

$ErrorActionPreference = "Stop"

$pathModule = Join-Path $PSScriptRoot '..\entity\helpers\Path.psm1'
Import-Module $pathModule -Force

$destInfo = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'LegacyRemote') {
        $DestinationPath = ($DestinationPath ?? '').Replace('\\', '/').TrimStart('/')
        $destInfo = Resolve-UtilityHubPath -Path ("{0}:{1}" -f $RemoteName, $DestinationPath) -PathType 'Remote'
    } else {
        $destInfo = Resolve-UtilityHubPath -Path $Destination -PathType $DestinationPathType
        if ($destInfo.PathType -ne 'Remote') {
            throw "Destination must be an rclone remote spec like '<remote>:<path>'. Destination='$Destination'"
        }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-Host "Starting Google Drive upload..." -ForegroundColor Cyan
Write-Host "  Remote: $($destInfo.Normalized)" -ForegroundColor Gray
Write-Host "  Local File: $LocalFilePath" -ForegroundColor Gray

if (-not (Test-Path -LiteralPath $LocalFilePath)) {
    Write-Error "File not found: $LocalFilePath"
    exit 1
}

$remotePath = $destInfo.Normalized

# Ensure destination folder exists (create if missing) unless suppressed
if (-not $NoCreate) {
    try {
        $exists = rclone lsf "$remotePath" --dirs-only 2>$null
    } catch {
        $exists = $null
    }
    if (-not $exists) {
        Write-Host "Destination folder may not exist; attempting to create..." -ForegroundColor Yellow
        # Create empty placeholder to force folder path creation
        $tmp = New-TemporaryFile
        try {
            rclone copy $tmp.FullName "$remotePath" 2>$null
            rclone delete "$remotePath/$(Split-Path $tmp.Name -Leaf)" 2>$null
        } finally {
            Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Host "Destination auto-creation suppressed (-NoCreate)." -ForegroundColor Yellow
}

# Upload
$flags = @("--progress")
if ($Overwrite) { $flags += "--ignore-existing=false" } else { $flags += "--ignore-existing" }

Write-Host "Uploading..." -ForegroundColor Yellow
rclone copy "$LocalFilePath" "$remotePath" @flags

if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Upload completed" -ForegroundColor Green
    Write-Host "  Destination: $remotePath/$(Split-Path $LocalFilePath -Leaf)" -ForegroundColor Gray
} else {
    Write-Error "Upload failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
