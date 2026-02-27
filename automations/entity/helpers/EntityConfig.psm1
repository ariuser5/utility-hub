<#
-------------------------------------------------------------------------------
EntityConfig.psm1
-------------------------------------------------------------------------------
Shared static-data/config helpers for entity automations.

Responsibilities:
  - Discover default static data file path
  - Parse/merge JSON config into defaults
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
        [Parameter(Mandatory = $true)][hashtable]$BoundParameters
    )

    $config = New-EntityConfig

    # Load config from JSON (if provided, or if default exists).
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

    return [pscustomobject]@{
        Config                = $config
        DefaultStaticDataFile = $defaultStaticDataFile
        ResolvedStaticDataFile = $resolvedStaticDataFilePath
    }
}

Export-ModuleMember -Function Initialize-EntityConfig, Resolve-Clients
