<#
-------------------------------------------------------------------------------
New-ClientMonthlyReport.ps1 (Curated)
-------------------------------------------------------------------------------
Curated automation wrapper that provides a git-rebase-like "edit then resume" flow
for running the pipeline:
  automations/entity/pipelines/New-ClientMonthlyReport.ps1

It opens a .psd1 params file in your editor, validates it, and then executes the
pipeline in a separate pwsh process.

Persisted config (separate from contacts static data):
  %LOCALAPPDATA%\utility-hub\data\entity\New-ClientMonthlyReport.psd1
-------------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
    # Optional: override persisted params file path.
    [Parameter()]
    [string]$ParamsPath,

    # Optional: skip opening editor; just run using current params file.
    [Parameter()]
    [switch]$NoEdit,

    # Optional: do not write back the last successful params to the persisted file.
    [Parameter()]
    [switch]$NoSave
)

$ErrorActionPreference = 'Stop'

function New-MonthlyReportParamsPsd1Text {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    $remoteName = ($Values.RemoteName ?? 'gdrive').ToString()
    $directoryPath = ($Values.DirectoryPath ?? '').ToString()
    $startYear = $Values.StartYear
    if (-not $startYear) { $startYear = (Get-Date).Year }
    $newFolderPrefix = ($Values.NewFolderPrefix ?? '_').ToString()

    # .psd1 uses single-quoted strings here; escape embedded single quotes.
    $remoteName = $remoteName.Replace("'", "''")
    $directoryPath = $directoryPath.Replace("'", "''")
    $newFolderPrefix = $newFolderPrefix.Replace("'", "''")

    @(
        "# utility-hub: New Client Monthly Report params",
        "#",
        "# Edit values below, then close the editor to continue.",
        "#",
        "# Commands (rebase-like):",
        "#   - Set _Command = 'abort' to exit without running",
        "#   - Set _Command = 'reset' to regenerate defaults and reopen",
        "#",
        "# Notes:",
        "#   - DirectoryPath must be the REMOTE path only (no 'gdrive:' prefix).",
        "#   - The pipeline constructs RemoteSpec as: <RemoteName>:<DirectoryPath>",
        "",
        "@{",
        "    _Command       = $null",
        "    RemoteName     = '$remoteName'",
        "    DirectoryPath  = '$directoryPath'",
        "    StartYear      = $startYear",
        "    NewFolderPrefix = '$newFolderPrefix'",
        "}"
    ) -join [Environment]::NewLine
}

function Write-ParamsErrorHeader {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ErrorMessage
    )

    $existing = ''
    if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $FilePath -Raw -ErrorAction SilentlyContinue
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $header = @(
        "# ERROR ($stamp)",
        "# $ErrorMessage",
        "# Fix and close the editor to continue.",
        ""
    ) -join [Environment]::NewLine

    Set-Content -LiteralPath $FilePath -Value ($header + ($existing ?? '')) -Encoding UTF8
}

function Get-DefaultParamsPath {
    if ($ParamsPath -and $ParamsPath.Trim()) {
        return $ParamsPath
    }

    if (-not $env:LOCALAPPDATA) {
        # Fallback: keep it per-machine temp if LOCALAPPDATA isn't available.
        return (Join-Path ([System.IO.Path]::GetTempPath()) 'utility-hub-New-ClientMonthlyReport.psd1')
    }

    return (Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'utility-hub') 'data') 'entity') 'New-ClientMonthlyReport.psd1')
}

$persistedPath = Get-DefaultParamsPath

# Ensure persisted parent directory exists (when using LOCALAPPDATA layout).
try {
    $persistedDir = Split-Path -Parent $persistedPath
    if ($persistedDir -and -not (Test-Path -LiteralPath $persistedDir -PathType Container)) {
        New-Item -ItemType Directory -Path $persistedDir -Force | Out-Null
    }
} catch {
    # Directory creation failure should be handled later; allow temp-only flow.
}

# Seed values from persisted file if possible.
$seed = @{}
if (Test-Path -LiteralPath $persistedPath -PathType Leaf) {
    try {
        $loaded = Import-PowerShellDataFile -Path $persistedPath
        if ($loaded -is [hashtable]) {
            $seed = $loaded
        }
    } catch {
        # We'll surface parse errors in the edit loop.
    }
}

$tmpEdit = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("utility-hub-new-client-monthly-report-{0}.psd1" -f ([guid]::NewGuid().ToString('N')))
$resetCount = 0

# Write initial temp file.
Set-Content -LiteralPath $tmpEdit -Value (New-MonthlyReportParamsPsd1Text -Values $seed) -Encoding UTF8

$editorModule = Join-Path $PSScriptRoot '..\helpers\Editor.psm1'
Import-Module $editorModule -Force

while ($true) {
    if (-not $NoEdit) {
        $editResult = Invoke-UtilityHubEditor -FilePath $tmpEdit
        if ($editResult -and $editResult.Mode -eq 'abort') {
            Write-Host 'Aborted (no changes made).' -ForegroundColor Yellow
            Remove-Item -LiteralPath $tmpEdit -ErrorAction SilentlyContinue
            exit 0
        }
    }

    $paramsData = $null
    try {
        $paramsData = Import-PowerShellDataFile -Path $tmpEdit
    } catch {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage ("Params file failed to parse as .psd1: {0}" -f $_.Exception.Message)
        $NoEdit = $false
        continue
    }

    if (-not ($paramsData -is [hashtable])) {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage 'Params file must evaluate to a hashtable (@{ ... }).'
        $NoEdit = $false
        continue
    }

    $cmd = ($paramsData['_Command'] ?? '').ToString().Trim()
    if ($cmd) {
        if ($cmd.Equals('abort', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host 'Aborted (no changes made).' -ForegroundColor Yellow
            Remove-Item -LiteralPath $tmpEdit -ErrorAction SilentlyContinue
            exit 0
        }

        if ($cmd.Equals('reset', [System.StringComparison]::OrdinalIgnoreCase)) {
            $resetCount++
            if ($resetCount -ge 5) {
                throw 'Too many resets; exiting.'
            }
            Set-Content -LiteralPath $tmpEdit -Value (New-MonthlyReportParamsPsd1Text -Values @{}) -Encoding UTF8
            $NoEdit = $false
            continue
        }

        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage "Unknown _Command '$cmd'. Use 'abort' or 'reset'."
        $NoEdit = $false
        continue
    }

    $remoteName = ($paramsData['RemoteName'] ?? 'gdrive').ToString().Trim()
    $directoryPath = ($paramsData['DirectoryPath'] ?? '').ToString().Trim()
    $startYearRaw = ($paramsData['StartYear'] ?? (Get-Date).Year)
    $newFolderPrefix = ($paramsData['NewFolderPrefix'] ?? '_').ToString()

    if (-not $remoteName) {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage 'RemoteName is empty.'
        $NoEdit = $false
        continue
    }

    if (-not $directoryPath) {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage 'DirectoryPath is required.'
        $NoEdit = $false
        continue
    }

    # Normalize slashes for rclone.
    $directoryPath = $directoryPath.Replace('\\', '/').Trim('/')

    # Prevent common mistake: include remote prefix in DirectoryPath.
    if ($directoryPath -match '^[^:]+:.+$') {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage "DirectoryPath must NOT include a remote prefix (e.g. 'gdrive:'). Put the remote name in RemoteName."
        $NoEdit = $false
        continue
    }

    $startYear = 0
    if (-not [int]::TryParse($startYearRaw.ToString(), [ref]$startYear)) {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage 'StartYear must be an integer.'
        $NoEdit = $false
        continue
    }
    if ($startYear -lt 2000 -or $startYear -gt 2100) {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage 'StartYear looks out of range (expected 2000..2100).'
        $NoEdit = $false
        continue
    }

    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage "rclone not found on PATH. Install rclone and/or restart the shell."
        $NoEdit = $false
        continue
    }

    $remoteSpec = "${remoteName}:$directoryPath"

    # Quick sanity check that the remote path is accessible.
    try {
        & rclone lsf $remoteSpec --max-depth 1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "rclone lsf failed (exit $LASTEXITCODE)"
        }
    } catch {
        Write-ParamsErrorHeader -FilePath $tmpEdit -ErrorMessage ("Remote path not accessible: {0}. {1}" -f $remoteSpec, $_.Exception.Message)
        $NoEdit = $false
        continue
    }

    # Persist last good params (separate from contacts static data).
    if (-not $NoSave) {
        $toSave = @{
            RemoteName      = $remoteName
            DirectoryPath   = $directoryPath
            StartYear       = $startYear
            NewFolderPrefix = $newFolderPrefix
        }
        try {
            Set-Content -LiteralPath $persistedPath -Value (New-MonthlyReportParamsPsd1Text -Values $toSave) -Encoding UTF8
        } catch {
            Write-Host "Warning: failed to write params file: $persistedPath" -ForegroundColor DarkYellow
            Write-Host $_.Exception.Message -ForegroundColor DarkYellow
        }
    }

    $pipelineScript = Join-Path $PSScriptRoot '..\pipelines\New-ClientMonthlyReport.ps1'
    $pipelineScript = (Resolve-Path -LiteralPath $pipelineScript -ErrorAction Stop).Path

    Write-Host ''
    Write-Host "Running monthly report automation..." -ForegroundColor Cyan
    Write-Host "  Script: $pipelineScript" -ForegroundColor DarkGray
    Write-Host "  Remote: $remoteName" -ForegroundColor DarkGray
    Write-Host "  Path:   $directoryPath" -ForegroundColor DarkGray
    Write-Host ''

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $pipelineScript -RemoteName $remoteName -DirectoryPath $directoryPath -StartYear $startYear -NewFolderPrefix $newFolderPrefix
    $exitCode = $LASTEXITCODE

    Remove-Item -LiteralPath $tmpEdit -ErrorAction SilentlyContinue
    exit $exitCode
}
