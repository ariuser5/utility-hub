<#
-------------------------------------------------------------------------------
AutomationConfig.psm1
-------------------------------------------------------------------------------
Shared helpers for entity automation command config.

Responsibilities:
    - Resolve config file path
  - Parse/validate config JSON entries
    - Build merged automation entries
  - Execute automation commands

Exported functions:
  - Get-AutomationConfigPaths
  - Get-Automations
  - Invoke-AutomationCommand
-------------------------------------------------------------------------------
#>

function Get-AutomationConfigPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot
    )

    $publicConfigPath = Join-Path $AppRoot 'automations.json'

    return [pscustomobject]@{
        Public = $publicConfigPath
    }
}

function Read-AutomationEntriesFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter()][hashtable]$Visited = @{}
    )

    function Read-AutomationEntriesFromFileCore {
        param(
            [Parameter(Mandatory = $true)][string]$CurrentPath,
            [Parameter(Mandatory = $true)][hashtable]$VisitedMap
        )

        if (-not (Test-Path -LiteralPath $CurrentPath -PathType Leaf)) {
            return @()
        }

        $resolvedPath = $CurrentPath
        try {
            $resolvedPath = (Resolve-Path -LiteralPath $CurrentPath -ErrorAction Stop).Path
        } catch {
            return @()
        }

        if ($VisitedMap.ContainsKey($resolvedPath)) {
            return @()
        }
        $VisitedMap[$resolvedPath] = $true

        $raw = $null
        try {
            $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 -ErrorAction Stop
        } catch {
            return @()
        }

        if (-not $raw -or -not $raw.Trim()) {
            return @()
        }

        $parsed = $null
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return @()
        }

        $entries = @()
        if ($parsed -is [array]) {
            $entries = @($parsed)
        } elseif ($parsed.PSObject.Properties.Name -contains 'automations') {
            $entries = @($parsed.automations)
        } else {
            return @()
        }

        $baseDir = Split-Path -Parent $resolvedPath
        $result = @()

        foreach ($entry in $entries) {
            if ($null -eq $entry) { continue }

            $hasImport = $entry.PSObject.Properties.Name -contains 'import'
            $hasAlias = $entry.PSObject.Properties.Name -contains 'alias'
            $hasCommand = $entry.PSObject.Properties.Name -contains 'command'

            if ($hasImport) {
                $importSpec = $entry.import
                if ($null -eq $importSpec) { continue }

                if (-not ($importSpec.PSObject.Properties.Name -contains 'path')) {
                    continue
                }

                $importValue = ([string]$importSpec.path ?? '').Trim()
                if (-not $importValue) { continue }

                try {
                    $importValue = $ExecutionContext.InvokeCommand.ExpandString($importValue)
                } catch {
                    continue
                }

                $importPath = if ([System.IO.Path]::IsPathRooted($importValue)) {
                    $importValue
                } else {
                    Join-Path -Path $baseDir -ChildPath $importValue
                }

                $result += @(Read-AutomationEntriesFromFileCore -CurrentPath $importPath -VisitedMap $VisitedMap)
                continue
            }

            if (-not $hasAlias -or -not $hasCommand) { continue }

            $alias = ([string]$entry.alias ?? '').Trim()
            $command = ([string]$entry.command ?? '').Trim()
            if (-not $alias -or -not $command) { continue }

            $result += [pscustomobject]@{
                Name    = $alias
                Alias   = $alias
                Command = $command
                Source  = $resolvedPath
            }
        }

        return @($result)
    }

    return @(Read-AutomationEntriesFromFileCore -CurrentPath $ConfigPath -VisitedMap $Visited)
}

function Get-Automations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot
    )

    $paths = Get-AutomationConfigPaths -AppRoot $AppRoot

    $mergedByAlias = @{}
    $orderedAliases = @()

    $configs = @($paths.Public)

    foreach ($configPath in $configs) {
        $entries = @(Read-AutomationEntriesFromFile -ConfigPath $configPath)
        foreach ($entry in $entries) {
            if (-not $mergedByAlias.ContainsKey($entry.Alias)) {
                $orderedAliases += $entry.Alias
            }
            $mergedByAlias[$entry.Alias] = $entry
        }
    }

    $result = @()
    foreach ($alias in $orderedAliases) {
        $result += $mergedByAlias[$alias]
    }

    return @($result)
}

function Invoke-AutomationCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter()][string]$WorkingDirectory
    )

    $utilityHubRoot = Split-Path (Split-Path $AppRoot -Parent) -Parent
    $env:UTILITY_HUB_ROOT = $utilityHubRoot
    $env:APP_DIR = $AppRoot

    $effectiveWorkingDirectory = $AppRoot
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        try {
            $effectiveWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
        } catch {
            $effectiveWorkingDirectory = $AppRoot
        }
    }

    $escapedAppRoot = $AppRoot -replace "'", "''"
    $escapedWorkingDirectory = $effectiveWorkingDirectory -replace "'", "''"
    $composedCommand = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$PSScriptRoot = '$escapedAppRoot'"
        "Set-Location -LiteralPath '$escapedWorkingDirectory'"
        $Command
    ) -join "; "

    & pwsh -NoProfile -ExecutionPolicy Bypass -Command $composedCommand 2>&1 |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Host $_.ToString() -ForegroundColor Red
            } else {
                $_ | Out-Host
            }
        }

    if ($null -ne $LASTEXITCODE) {
        return $LASTEXITCODE
    }

    if ($?) {
        return 0
    }

    return 1
}

Export-ModuleMember -Function Get-AutomationConfigPaths, Get-Automations, Invoke-AutomationCommand
