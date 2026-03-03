Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pathModule = Join-Path $PSScriptRoot 'PathUtils.psm1'
Import-Module $pathModule -Force

function Assert-RcloneAvailable {
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        throw "rclone not found on PATH. Install it (e.g., 'winget install Rclone.Rclone') and ensure it's available in your session."
    }
}

function ConvertTo-DirectoryItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Local', 'Remote')]
        [string]$PathType,

        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('File', 'Directory')]
        [string]$ItemType
    )

    [pscustomobject]@{
        Name     = $Name
        ItemType = $ItemType
        PathType = $PathType
        Path     = (Join-UnifiedPath -Base $BasePath -Child $Name -PathType $PathType)
    }
}

function Get-Items {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [ValidateSet('Auto', 'Local', 'Remote')]
        [string]$PathType = 'Auto',

        [Parameter()]
        [ValidateSet('All', 'Files', 'Directories')]
        [string]$ItemType = 'All'
    )

    $baseInfo = Resolve-UnifiedPath -Path $Path -PathType $PathType

    if ($baseInfo.PathType -eq 'Local') {
        if (-not (Test-Path -LiteralPath $baseInfo.LocalPath -PathType Container)) {
            throw "Directory does not exist: $($baseInfo.LocalPath)"
        }

        $items = switch ($ItemType) {
            'Files'       { Get-ChildItem -LiteralPath $baseInfo.LocalPath -File -ErrorAction Stop }
            'Directories' { Get-ChildItem -LiteralPath $baseInfo.LocalPath -Directory -ErrorAction Stop }
            default       { Get-ChildItem -LiteralPath $baseInfo.LocalPath -ErrorAction Stop }
        }

        foreach ($item in @($items)) {
            $resolvedItemType = if ($item.PSIsContainer) { 'Directory' } else { 'File' }

            ConvertTo-DirectoryItem `
                -Name $item.Name `
                -PathType 'Local' `
                -BasePath $baseInfo.Normalized `
                -ItemType $resolvedItemType
        }

        return
    }

    Assert-RcloneAvailable

    $rcloneArgs = @('lsf', $baseInfo.Normalized)
    switch ($ItemType) {
        'Files' { $rcloneArgs += '--files-only' }
        'Directories' { $rcloneArgs += '--dirs-only' }
        default { }
    }

    $rawItems = & rclone @rcloneArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list remote directory '$($baseInfo.Normalized)' (exit code $LASTEXITCODE)."
    }

    foreach ($raw in @($rawItems)) {
        $entry = ($raw ?? '').ToString().Trim()
        if (-not $entry) { continue }

        $isDirectory = $entry.EndsWith('/')
        $name = if ($isDirectory) { $entry.TrimEnd('/') } else { $entry }
        if (-not $name) { continue }

        $resolvedItemType = if ($isDirectory) { 'Directory' } else { 'File' }

        ConvertTo-DirectoryItem `
            -Name $name `
            -PathType 'Remote' `
            -BasePath $baseInfo.Normalized `
            -ItemType $resolvedItemType
    }
}

function Get-Files {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [ValidateSet('Auto', 'Local', 'Remote')]
        [string]$PathType = 'Auto'
    )

    Get-Items -Path $Path -PathType $PathType -ItemType 'Files'
}

function Get-Folders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [ValidateSet('Auto', 'Local', 'Remote')]
        [string]$PathType = 'Auto'
    )

    Get-Items -Path $Path -PathType $PathType -ItemType 'Directories'
}

Export-ModuleMember -Function Get-Items, Get-Files, Get-Folders
