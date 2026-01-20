Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-UtilityHubPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [ValidateSet('Auto', 'Local', 'Remote')]
        [string]$PathType = 'Auto'
    )

    $p = ($Path ?? '').ToString().Trim()
    if (-not $p) {
        throw 'Path is required.'
    }

    $isWindowsDrive = ($p -match '^[A-Za-z]:(\\|/|$)')
    $isUnc = ($p -match '^(\\\\|//)')
    $looksRemote = ($p -match '^[^\\/]+:.+$' -or $p -match '^[^\\/]+:$')
    if ($isWindowsDrive -or $isUnc) {
        $looksRemote = $false
    }

    $effectiveType = $PathType
    if ($PathType -eq 'Auto') {
        $effectiveType = if ($looksRemote) { 'Remote' } else { 'Local' }
    }

    if ($effectiveType -eq 'Local' -and ($p -match '^[^\\/]+:.+$') -and -not $isWindowsDrive) {
        throw "Path looks like an rclone remote spec. Use -PathType Remote or provide a local path. Path='$p'"
    }

    if ($effectiveType -eq 'Remote' -and -not $looksRemote) {
        throw "Path does not look like an rclone remote spec (expected '<remote>:<path>'). Path='$p'"
    }

    if ($effectiveType -eq 'Remote') {
        $idx = $p.IndexOf(':')
        $remoteName = $p.Substring(0, $idx)
        $remotePath = $p.Substring($idx + 1)
        $remotePath = ($remotePath ?? '').Replace('\\', '/').TrimStart('/')

        $normalized = if ($remotePath) { "${remoteName}:$remotePath" } else { "${remoteName}:" }

        return [pscustomobject]@{
            PathType   = 'Remote'
            Original   = $p
            Normalized = $normalized
            RemoteName = $remoteName
            RemotePath = $remotePath
            LocalPath  = $null
        }
    }

    $full = try {
        [System.IO.Path]::GetFullPath($p)
    } catch {
        $p
    }

    return [pscustomobject]@{
        PathType   = 'Local'
        Original   = $p
        Normalized = $full
        RemoteName = $null
        RemotePath = $null
        LocalPath  = $full
    }
}

function Join-UtilityHubPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,

        [Parameter(Mandatory = $true)]
        [string]$Child,

        [Parameter()]
        [ValidateSet('Auto', 'Local', 'Remote')]
        [string]$PathType = 'Auto'
    )

    $baseInfo = Resolve-UtilityHubPath -Path $Base -PathType $PathType
    $childTrim = ($Child ?? '').ToString().Trim()
    if (-not $childTrim) {
        return $baseInfo.Normalized
    }

    if ($baseInfo.PathType -eq 'Remote') {
        $b = $baseInfo.Normalized.TrimEnd('/')
        $c = $childTrim.Replace('\\', '/').Trim('/').Trim()
        return "$b/$c"
    }

    return (Join-Path -Path $baseInfo.LocalPath -ChildPath $childTrim)
}

Export-ModuleMember -Function Resolve-UtilityHubPath, Join-UtilityHubPath
