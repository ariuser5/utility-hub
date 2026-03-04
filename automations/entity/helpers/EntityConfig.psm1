<#
-------------------------------------------------------------------------------
EntityConfig.psm1
-------------------------------------------------------------------------------
Shared static-data/config helpers for entity automations.

Responsibilities:
    - Discover default parties config file path
  - Parse/merge JSON config into defaults
  - Normalize and resolve client entries (aliases + roots)

Exported functions:
  - Initialize-EntityConfig
    - Resolve-Accountants
  - Resolve-Clients
-------------------------------------------------------------------------------
#>

function New-EntityConfig {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        AccountantRoot  = ''
        Accountants     = @()
        Clients         = @()
        PreviewMaxDepth = 0
    }
}

function Get-DefaultEntityPartiesFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot
    )

    return Join-Path $AppRoot 'parties.json'
}

function Import-EntityConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if (-not $raw -or -not $raw.Trim()) {
        throw "Config file is empty: $Path"
    }

    try {
        return $raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        throw "Failed to parse JSON config: $Path. $($_.Exception.Message)"
    }
}

function Get-ConfigPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            foreach ($key in $Object.Keys) {
                if ([string]$key -ieq $name) {
                    return $Object[$key]
                }
            }
        }
    }

    if ($null -ne $Object.PSObject -and $null -ne $Object.PSObject.Properties) {
        foreach ($name in $Names) {
            foreach ($property in $Object.PSObject.Properties) {
                if ($property.Name -ieq $name) {
                    return $property.Value
                }
            }
        }
    }

    return $null
}

function Get-EntryName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entry)

    $name = Get-ConfigPropertyValue -Object $Entry -Names @('name')
    return ([string]($name ?? '')).Trim()
}

function Get-EntryLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entry)

    $data = Get-ConfigPropertyValue -Object $Entry -Names @('data')
    if ($null -ne $data) {
        $nestedLocation = Get-ConfigPropertyValue -Object $data -Names @('location')
        $nested = ([string]($nestedLocation ?? '')).Trim()
        if ($nested) { return $nested }
    }

    $flatLocation = Get-ConfigPropertyValue -Object $Entry -Names @('location', 'path', 'root')
    return ([string]($flatLocation ?? '')).Trim()
}

function Merge-EntityConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][object]$Source
    )

    if ($null -eq $Source) { return }

    $accountantsValue = Get-ConfigPropertyValue -Object $Source -Names @('accountants')
    if ($null -ne $accountantsValue) {
        $existingAccountants = @()
        if ($null -ne $Target.Accountants) {
            $existingAccountants = @($Target.Accountants)
        }

        $incomingAccountants = @($accountantsValue)
        if ($existingAccountants.Count -gt 0) {
            $Target.Accountants = @($existingAccountants + $incomingAccountants)
        } else {
            $Target.Accountants = $accountantsValue
        }

        $accountants = @($accountantsValue)
        foreach ($acc in $accountants) {
            if ($null -eq $acc) { continue }

            $accRoot = Get-EntryLocation -Entry $acc

            if ($accRoot) {
                $Target.AccountantRoot = $accRoot
                break
            }
        }
    }

    $clientsValue = Get-ConfigPropertyValue -Object $Source -Names @('clients')
    if ($null -ne $clientsValue) {
        $existingClients = @()
        if ($null -ne $Target.Clients) {
            $existingClients = @($Target.Clients)
        }

        $incomingClients = @($clientsValue)
        if ($existingClients.Count -gt 0) {
            $Target.Clients = @($existingClients + $incomingClients)
        } else {
            $Target.Clients = $clientsValue
        }
    }

    $accountantRoot = Get-ConfigPropertyValue -Object $Source -Names @('accountantRoot')
    if ($null -ne $accountantRoot) {
        $Target.AccountantRoot = $accountantRoot
    }

    $previewMaxDepth = Get-ConfigPropertyValue -Object $Source -Names @('previewMaxDepth')
    if ($null -ne $previewMaxDepth) {
        $Target.PreviewMaxDepth = $previewMaxDepth
    }
}

function Resolve-Accountants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config
    )

    $results = @()

    $inputVal = Get-ConfigPropertyValue -Object $Config -Names @('accountants')
    if ($null -eq $inputVal) { return @() }

    $entries = @()
    if ($inputVal -is [string]) {
        $entries = @($inputVal)
    } elseif ($inputVal -is [object[]]) {
        $entries = @($inputVal)
    } else {
        $entries = @($inputVal)
    }

    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }

        if ($entry -is [pscustomobject] -or $entry -is [System.Collections.IDictionary]) {
            $name = Get-EntryName -Entry $entry
            $root = Get-EntryLocation -Entry $entry

            if (-not $root) { continue }
            if (-not $name) { $name = Get-AliasFromPath -Path $root }
            if (-not $name) { continue }

            $results += [pscustomobject]@{ Name = $name; Root = $root }
            continue
        }

        $s = $entry.ToString().Trim()
        if (-not $s) { continue }

        $name = ''
        $root = ''

        $eqIdx = $s.IndexOf('=')
        if ($eqIdx -gt 0) {
            $name = $s.Substring(0, $eqIdx).Trim()
            $root = $s.Substring($eqIdx + 1).Trim()
        } else {
            $root = $s
            $name = Get-AliasFromPath -Path $root
        }

        if (-not $root) { continue }
        if (-not $name) { $name = Get-AliasFromPath -Path $root }
        if (-not $name) { continue }

        $results += [pscustomobject]@{ Name = $name; Root = $root }
    }

    $dupes = $results | Group-Object Name | Where-Object { $_.Count -gt 1 }
    if ($dupes) {
        $names = ($dupes | ForEach-Object { $_.Name }) -join ', '
        throw "Duplicate accountant aliases detected: $names"
    }

    return $results | Sort-Object Name
}

function Get-AliasFromPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $p = ($Path ?? '').Trim()
    if (-not $p) { return '' }

    # rclone remote spec: remote:path
    if ($p -match '^[^:]+:(.*)$') {
        $m = [regex]::Match($p, '^([^:]+):(.*)$')
        $remote = $m.Groups[1].Value
        $rest = ($m.Groups[2].Value ?? '').Replace('\\', '/').Trim('/')

        if (-not $rest) {
            return $remote
        }

        $segs = $rest.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($segs.Count -gt 0) { return $segs[$segs.Count - 1] }
        return $remote
    }

    # filesystem / generic path
    $leaf = ''
    try {
        $leaf = Split-Path -Path $p -Leaf
    } catch {
        $leaf = ''
    }

    if (-not $leaf) {
        $pp = $p.Replace('\\', '/').TrimEnd('/')
        $segs = $pp.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($segs.Count -gt 0) { return $segs[$segs.Count - 1] }
    }

    return $leaf
}

function Resolve-Clients {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config
    )

    $results = @()

    $inputVal = Get-ConfigPropertyValue -Object $Config -Names @('clients')
    if ($null -eq $inputVal) { return @() }

    if ($inputVal -is [System.Collections.IDictionary]) {
        foreach ($k in $inputVal.Keys) {
            $name = ($k ?? '').ToString().Trim()
            $root = ($inputVal[$k] ?? '').ToString().Trim()
            if (-not $root) { continue }
            if (-not $name) { $name = Get-AliasFromPath -Path $root }
            if (-not $name) { continue }
            $results += [pscustomobject]@{ Name = $name; Root = $root }
        }
        return $results | Sort-Object Name
    }

    # JSON object (ConvertFrom-Json) becomes PSCustomObject with properties
    # e.g. { "ClientA": "C:\\path", "ClientB": "gdrive:..." }
    if ($inputVal -is [pscustomobject]) {
        foreach ($p in $inputVal.PSObject.Properties) {
            $name = ($p.Name ?? '').ToString().Trim()
            $root = ($p.Value ?? '').ToString().Trim()
            if (-not $root) { continue }
            if (-not $name) { $name = Get-AliasFromPath -Path $root }
            if (-not $name) { continue }
            $results += [pscustomobject]@{ Name = $name; Root = $root }
        }
        return $results | Sort-Object Name
    }

    $entries = @()
    if ($inputVal -is [string]) {
        $entries = @($inputVal)
    } elseif ($inputVal -is [object[]]) {
        $entries = @($inputVal)
    } else {
        $entries = @($inputVal)
    }

    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }

        if ($entry -is [pscustomobject] -or $entry -is [System.Collections.IDictionary]) {
            $name = Get-EntryName -Entry $entry
            $root = Get-EntryLocation -Entry $entry

            if (-not $root) { continue }
            if (-not $name) { $name = Get-AliasFromPath -Path $root }
            if (-not $name) { continue }

            $results += [pscustomobject]@{ Name = $name; Root = $root }
            continue
        }

        $s = $entry.ToString().Trim()
        if (-not $s) { continue }

        $name = ''
        $root = ''

        $eqIdx = $s.IndexOf('=')
        if ($eqIdx -gt 0) {
            $name = $s.Substring(0, $eqIdx).Trim()
            $root = $s.Substring($eqIdx + 1).Trim()
        } else {
            $root = $s
            $name = Get-AliasFromPath -Path $root
        }

        if (-not $root) { continue }
        if (-not $name) { $name = Get-AliasFromPath -Path $root }
        if (-not $name) { continue }

        $results += [pscustomobject]@{ Name = $name; Root = $root }
    }

    # Prevent confusing duplicate display names
    $dupes = $results | Group-Object Name | Where-Object { $_.Count -gt 1 }
    if ($dupes) {
        $names = ($dupes | ForEach-Object { $_.Name }) -join ', '
        throw "Duplicate client aliases detected: $names"
    }

    return $results | Sort-Object Name
}

function Initialize-EntityConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot
    )

    $config = New-EntityConfig

    # Ensure environment variables used in config imports are available during startup.
    $utilityHubRoot = Split-Path (Split-Path $AppRoot -Parent) -Parent
    $env:UTILITY_HUB_ROOT = $utilityHubRoot
    $env:APP_DIR = $AppRoot
    $env:UTILS_ROOT = Join-Path $utilityHubRoot 'automations\utils'

    function Load-EntityConfigWithImports {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][hashtable]$Visited
        )

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }

        $resolvedPath = $Path
        try {
            $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        } catch {
            return $null
        }

        if ($Visited.ContainsKey($resolvedPath)) {
            return $null
        }
        $Visited[$resolvedPath] = $true

        $jsonConfig = $null
        try {
            $jsonConfig = Import-EntityConfigJson -Path $resolvedPath
        } catch {
            return $null
        }

        if ($null -eq $jsonConfig) {
            return $null
        }

        $merged = New-EntityConfig

        $importSpec = Get-ConfigPropertyValue -Object $jsonConfig -Names @('import')
        if ($null -ne $importSpec) {
            $importPath = ([string](Get-ConfigPropertyValue -Object $importSpec -Names @('path')) ?? '').Trim()
            if ($importPath) {
                try {
                    $importPath = $ExecutionContext.InvokeCommand.ExpandString($importPath)
                } catch {
                    $importPath = ''
                }

                if ($importPath) {
                    if (-not [System.IO.Path]::IsPathRooted($importPath)) {
                        $importPath = Join-Path (Split-Path -Parent $resolvedPath) $importPath
                    }

                    $importedConfig = Load-EntityConfigWithImports -Path $importPath -Visited $Visited
                    if ($null -ne $importedConfig) {
                        Merge-EntityConfig -Target $merged -Source $importedConfig
                    }
                }
            }
        }

        Merge-EntityConfig -Target $merged -Source $jsonConfig
        return $merged
    }

    $partiesPath = Get-DefaultEntityPartiesFile -AppRoot $AppRoot
    $visited = @{}
    $loadedConfig = Load-EntityConfigWithImports -Path $partiesPath -Visited $visited
    if ($null -ne $loadedConfig) {
        Merge-EntityConfig -Target $config -Source $loadedConfig
    }

    return [pscustomobject]@{ Config = $config }
}

Export-ModuleMember -Function Initialize-EntityConfig, Resolve-Accountants, Resolve-Clients
