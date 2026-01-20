<#
-------------------------------------------------------------------------------
New-ClientMonthlyReport.ps1
-------------------------------------------------------------------------------
Orchestrates the creation of a new monthly report folder on Google Drive and copies template files into it.

Usage:
    .\New-ClientMonthlyReport.ps1 -Path "gdrive:path/to/dir" [-PathType Auto|Local|Remote] [-StartYear 2025] [-NewFolderPrefix "_"]
    .\New-ClientMonthlyReport.ps1 -RemoteName "gdrive" -DirectoryPath "path/to/dir" [-StartYear 2025] [-NewFolderPrefix "_"]  # legacy

Parameters:
    -Path              Base folder where month folders live (local path or rclone remote spec)
    -PathType          Auto|Local|Remote (default: Auto)
    -RemoteName        Name of rclone remote (legacy)
    -DirectoryPath     Path on remote where month folders live (legacy)
    -StartYear         Year to start searching for missing months (default: current year)
    -NewFolderPrefix   Prefix for new folders (default: "_")

Behavior:
    - Calls Ensure-MonthFolder.ps1 to create the next missing month folder (with prefix)
    - If a folder is created, calls Copy-ToMonthFolder.ps1 to copy template files into it
    - Template files are sourced from resources/monthly_report_template/
    - Prints progress and summary output
-------------------------------------------------------------------------------
#>
[
    CmdletBinding(DefaultParameterSetName = 'Unified')
]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Unified')]
    [string]$Path,

    [Parameter(ParameterSetName = 'Unified')]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$PathType = 'Auto',

    [Parameter(Mandatory = $true, ParameterSetName = 'LegacyRemote')]
    [string]$RemoteName = "gdrive",

    # Remote directory path on Google Drive where month folders live (legacy)
    [Parameter(Mandatory = $true, ParameterSetName = 'LegacyRemote')]
    [string]$DirectoryPath,

    # Start year to check (default: current year)
    [int]$StartYear = (Get-Date).Year,

    # Prefix to use when creating a fresh folder (default: underscore)
    [string]$NewFolderPrefix = "_"
)

$ErrorActionPreference = "Stop"

# Paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ensureScriptPath = Join-Path $scriptDir "..\scripts\Ensure-MonthFolder.ps1"
$copyScriptPath = Join-Path $scriptDir "..\scripts\Copy-ToMonthFolder.ps1"
$templateFolder = Join-Path $scriptDir "..\resources\monthly_report_template"

$pathModule = Join-Path $scriptDir "..\helpers\Path.psm1"
Import-Module $pathModule -Force

$basePath = $null
$basePathType = 'Auto'
if ($PSCmdlet.ParameterSetName -eq 'LegacyRemote') {
    $DirectoryPath = ($DirectoryPath ?? '').Replace('\\', '/').Trim('/')
    $basePath = "{0}:{1}" -f $RemoteName, $DirectoryPath
    $basePathType = 'Remote'
} else {
    $basePath = $Path
    $basePathType = $PathType
}

$baseInfo = Resolve-UtilityHubPath -Path $basePath -PathType $basePathType

# Validate scripts exist
if (-not (Test-Path $ensureScriptPath)) {
    Write-Error "Ensure-MonthFolder.ps1 not found at: $ensureScriptPath"
    exit 1
}

if (-not (Test-Path $copyScriptPath)) {
    Write-Error "Copy-ToMonthFolder.ps1 not found at: $copyScriptPath"
    exit 1
}

if (-not (Test-Path $templateFolder -PathType Container)) {
    Write-Error "Template folder not found at: $templateFolder"
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Creating New Monthly Report" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Ensure month folder exists
Write-Host "[1/2] Creating month folder..." -ForegroundColor Yellow
try {
    $ensureOutput = & $ensureScriptPath `
        -Path $baseInfo.Normalized `
        -PathType $baseInfo.PathType `
        -StartYear $StartYear `
        -NewFolderPrefix $NewFolderPrefix
    
    $exitCode = $LASTEXITCODE
} catch {
    Write-Error "Failed to run Ensure-MonthFolder.ps1: $_"
    exit 1
}

# Parse output
$createdPath = $null
foreach ($line in $ensureOutput) {
    if ($line -match '^CREATED:(.+)$') {
        $createdPath = $Matches[1]
        break
    }
}

if ($exitCode -ne 0 -or $null -eq $createdPath) {
    Write-Host ""
    Write-Host "No new folder was created. Output from Ensure-MonthFolder.ps1:" -ForegroundColor Yellow
    $ensureOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    Write-Host ""
    Write-Host "Exiting without copying files." -ForegroundColor Yellow
    exit 0
}

Write-Host "      ✓ Folder created: $createdPath" -ForegroundColor Green
Write-Host ""

# Step 2: Copy template files to the new folder
Write-Host "[2/2] Copying template files to new folder..." -ForegroundColor Yellow
try {
    $copyOutput = & $copyScriptPath `
        -SourcePath $templateFolder `
        -DestinationPath $createdPath
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Copy-ToMonthFolder.ps1 failed with exit code $LASTEXITCODE"
        exit 2
    }
} catch {
    Write-Error "Failed to run Copy-ToMonthFolder.ps1: $_"
    exit 2
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "✓ Monthly Report Initialized" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Location: $createdPath" -ForegroundColor Gray
Write-Host ""

exit 0
