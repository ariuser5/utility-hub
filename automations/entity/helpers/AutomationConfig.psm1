<#
-------------------------------------------------------------------------------
AutomationConfig.psm1
-------------------------------------------------------------------------------
Shared helpers for entity automation command config.

Responsibilities:
  - Resolve config file paths (public + private)
  - Parse/validate config JSON entries
  - Merge entries by alias (private overrides public)
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

    $privateConfigPath = $null
    if ($env:APPDATA) {
        $privateConfigPath = Join-Path (Join-Path (Join-Path $env:APPDATA 'utility-hub') 'automations') 'automations.json'
    }

    return [pscustomobject]@{
        Public  = $publicConfigPath
        Private = $privateConfigPath
    }
}

function Read-AutomationEntriesFromFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid JSON in automation config '$ConfigPath': $($_.Exception.Message)"
    }

    $entries = @()
    if ($parsed -is [array]) {
        $entries = @($parsed)
    } elseif ($parsed.PSObject.Properties.Name -contains 'automations') {
        $entries = @($parsed.automations)
    } else {
        throw "Automation config '$ConfigPath' must be either an array or an object with an 'automations' array."
    }

    $result = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        $entryIndex = $i + 1

        if ($null -eq $entry) {
            throw "Automation config '$ConfigPath' has a null entry at index $entryIndex."
        }

        $alias = if ($entry.PSObject.Properties.Name -contains 'alias') { [string]$entry.alias } else { '' }
        $command = if ($entry.PSObject.Properties.Name -contains 'command') { [string]$entry.command } else { '' }

        $alias = ($alias ?? '').Trim()
        $command = ($command ?? '').Trim()

        if (-not $alias) {
            throw "Automation config '$ConfigPath' entry $entryIndex is missing 'alias'."
        }

        if (-not $command) {
            throw "Automation config '$ConfigPath' entry $entryIndex is missing 'command'."
        }

        $result += [pscustomobject]@{
                Name    = $alias
                Alias   = $alias
                Command = $command
                Source  = $ConfigPath
            }
    }

    return @($result)
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
    if ($paths.Private) {
        $configs += $paths.Private
    }

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
        [Parameter(Mandatory = $true)][string]$AppRoot
    )

    $utilityHubRoot = Split-Path (Split-Path $AppRoot -Parent) -Parent
    $env:UTILITY_HUB_ROOT = $utilityHubRoot
    $env:APP_DIR = $AppRoot

    $escapedAppRoot = $AppRoot -replace "'", "''"
    $composedCommand = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$PSScriptRoot = '$escapedAppRoot'"
        "Set-Location -LiteralPath '$escapedAppRoot'"
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
