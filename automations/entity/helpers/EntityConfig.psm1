<#
-------------------------------------------------------------------------------
EntityConfig.psm1
-------------------------------------------------------------------------------
Shared static-data/config helpers for entity automations.

Responsibilities:
  - Discover default static data file path
  - Parse/merge JSON config into defaults
  - Apply CLI override/merge rules
  - Normalize and resolve client entries (aliases + roots)

Exported functions:
  - Initialize-EntityConfig
  - Resolve-Clients
-------------------------------------------------------------------------------
#>

function New-EntityConfig {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        AccountantRoot  = ''
        Clients         = @()
        PreviewMaxDepth = 0
    }
}

function Get-DefaultEntityStaticDataFile {
    [CmdletBinding()]
    param()

    if (-not $env:LOCALAPPDATA) {
        return $null
    }

    return Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'utility-hub') 'data') 'contacts-data.json'
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

function Merge-EntityConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][object]$Source
    )

    if ($null -eq $Source) { return }

    foreach ($propName in @('AccountantRoot', 'Clients', 'PreviewMaxDepth')) {
        $p = $Source.PSObject.Properties[$propName]
        if ($null -ne $p -and $null -ne $p.Value) {
            $Target.$propName = $p.Value
        }
    }
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

function ConvertTo-ClientMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$ClientsValue
    )

    $map = [ordered]@{}
    if ($null -eq $ClientsValue) { return $map }

    if ($ClientsValue -is [System.Collections.IDictionary]) {
        foreach ($k in $ClientsValue.Keys) {
            $name = ($k ?? '').ToString().Trim()
            $root = ($ClientsValue[$k] ?? '').ToString().Trim()
            if (-not $root) { continue }
            if (-not $name) { $name = Get-AliasFromPath -Path $root }
            if (-not $name) { continue }
            $map[$name] = $root
        }
        return $map
    }

    # JSON object becomes PSCustomObject (properties -> values)
    if ($ClientsValue -is [pscustomobject]) {
        foreach ($p in $ClientsValue.PSObject.Properties) {
            $name = ($p.Name ?? '').ToString().Trim()
            $root = ($p.Value ?? '').ToString().Trim()
            if (-not $root) { continue }
            if (-not $name) { $name = Get-AliasFromPath -Path $root }
            if (-not $name) { continue }
            $map[$name] = $root
        }
        if ($map.Count -gt 0) { return $map }
        # If it wasn't a client object, fall through and treat as list.
    }

    $entries = @()
    if ($ClientsValue -is [string]) {
        $entries = @($ClientsValue)
    } elseif ($ClientsValue -is [object[]]) {
        $entries = @($ClientsValue)
    } else {
        $entries = @($ClientsValue)
    }

    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
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

        $map[$name] = $root
    }

    return $map
}

function Merge-Clients {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$BaseClients,
        [Parameter(Mandatory = $true)][AllowNull()]$OverlayClients
    )

    $baseMap = ConvertTo-ClientMap -ClientsValue $BaseClients
    $overlayMap = ConvertTo-ClientMap -ClientsValue $OverlayClients

    $merged = [ordered]@{}
    foreach ($k in $baseMap.Keys) { $merged[$k] = $baseMap[$k] }
    foreach ($k in $overlayMap.Keys) { $merged[$k] = $overlayMap[$k] }
    return $merged
}

function Resolve-Clients {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config
    )

    $results = @()

    $inputVal = $Config.Clients
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
        [Parameter()][string]$StaticDataFile,
        [Parameter()][string]$AccountantRoot,
        [Parameter()][object]$Clients,
        [Parameter(Mandatory = $true)][hashtable]$BoundParameters
    )

    $config = New-EntityConfig

    # Load config from JSON (if provided, or if default exists), then apply CLI overrides/merges.
    $defaultStaticDataFile = Get-DefaultEntityStaticDataFile

    $resolvedStaticDataFile = $null
    if ($BoundParameters.ContainsKey('StaticDataFile')) {
        $resolvedStaticDataFile = $StaticDataFile
    } elseif ($defaultStaticDataFile -and (Test-Path -LiteralPath $defaultStaticDataFile -PathType Leaf)) {
        $resolvedStaticDataFile = $defaultStaticDataFile
    }

    $resolvedStaticDataFilePath = $null
    if ($resolvedStaticDataFile) {
        $resolvedStaticDataFilePath = (Resolve-Path -LiteralPath $resolvedStaticDataFile -ErrorAction Stop).Path
        $jsonConfig = Import-EntityConfigJson -Path $resolvedStaticDataFilePath
        Merge-EntityConfig -Target $config -Source $jsonConfig
    }

    $staticDataFileExplicit = $BoundParameters.ContainsKey('StaticDataFile')

    if ($BoundParameters.ContainsKey('AccountantRoot')) {
        # AccountantRoot is scalar: CLI always wins when provided.
        $config.AccountantRoot = $AccountantRoot
    }

    if ($BoundParameters.ContainsKey('Clients')) {
        if ($staticDataFileExplicit -and $resolvedStaticDataFilePath) {
            # Explicit config path: merge client entries.
            $config.Clients = Merge-Clients -BaseClients $config.Clients -OverlayClients $Clients
        } else {
            # No explicit config path: CLI overrides config.
            $config.Clients = $Clients
        }
    }

    return [pscustomobject]@{
        Config                = $config
        DefaultStaticDataFile = $defaultStaticDataFile
        ResolvedStaticDataFile = $resolvedStaticDataFilePath
    }
}

Export-ModuleMember -Function Initialize-EntityConfig, Resolve-Clients
