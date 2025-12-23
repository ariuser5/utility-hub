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

# Paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ensureScriptPath = Join-Path $scriptDir "scripts\Ensure-MonthFolder.ps1"
$copyScriptPath = Join-Path $scriptDir "scripts\Copy-ToMonthFolder.ps1"
$templateFolder = Join-Path $scriptDir "resources\monthly_report_template"

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
Write-Host "[1/2] Creating month folder on Google Drive..." -ForegroundColor Yellow
try {
    $ensureOutput = & $ensureScriptPath `
        -RemoteName $RemoteName `
        -DirectoryPath $DirectoryPath `
        -Year $Year `
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
        -SourceFolder $templateFolder `
        -TargetPath $createdPath
    
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
