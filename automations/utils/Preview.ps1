<#
-------------------------------------------------------------------------------
Preview.ps1
-------------------------------------------------------------------------------
Read-only interactive folder preview / navigator.

- Lists folders + files at the current location.
- Lets you navigate down (into folders) and up (..) without executing arbitrary
  commands.
- Enforces a fixed root boundary (cannot go above -Root).
- Optional -MaxDepth to prevent navigating too deep.

Supported navigators:
  - filesystem  (local folders)
  - rclone      (Google Drive / other remotes via rclone)

Examples:
  # Local folder
    ./Preview.ps1 "C:\Data\clients"

  # rclone remote root (full remote spec)
      ./Preview.ps1 "gdrive:Documents/work/clients"
-------------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
    # Navigator selection.
    # - auto: infer from -Root (filesystem path vs rclone remote spec)
    # - filesystem: local folders
    # - rclone: Google Drive / other remotes via rclone
    [Parameter()]
    [ValidateSet('auto', 'filesystem', 'rclone')]
    [string]$Navigator = 'auto',

    # Root folder to preview. Preview cannot go above this.
    # - filesystem: full path
    # - rclone: full remote spec "remote:path" (e.g., "gdrive:Documents/work")
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Root,

    # Maximum depth (relative to root). 0 or empty means unlimited.
    [Parameter()]
    [int]$MaxDepth = 0,

    [Parameter()]
    [string]$Title = 'Preview',

    # Selection mode:
    # - disabled: navigation only (default)
    # - single: allows selecting one item and returns its full path
    [Parameter()]
    [ValidateSet('disabled', 'single')]
    [string]$Selection = 'disabled'
)

$ErrorActionPreference = 'Stop'

function Write-Heading {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host $Text -ForegroundColor Gray
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Get-WindowHeight {
    try {
        if ($Host.UI -and $Host.UI.RawUI) {
            return [int]$Host.UI.RawUI.WindowSize.Height
        }
    } catch {
        # ignore
    }
    return 24
}

function Get-WindowWidth {
    try {
        if ($Host.UI -and $Host.UI.RawUI) {
            return [int]$Host.UI.RawUI.WindowSize.Width
        }
    } catch {
        # ignore
    }
    return 120
}

function Clamp-Int {
    param(
        [Parameter(Mandatory = $true)][int]$Value,
        [Parameter(Mandatory = $true)][int]$Min,
        [Parameter(Mandatory = $true)][int]$Max
    )

    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Truncate-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$MaxWidth
    )

    if ($MaxWidth -le 0) { return '' }
    if (-not $Text) { return '' }
    if ($Text.Length -le $MaxWidth) { return $Text }
    if ($MaxWidth -le 1) { return $Text.Substring(0, 1) }
    return ($Text.Substring(0, $MaxWidth - 1) + '…')
}

function Assert-Interactive {
    if (-not $Host.UI -or -not $Host.UI.RawUI) {
        throw 'This script is interactive and requires a console host.'
    }
}

function Assert-Rclone {
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        throw "rclone not found on PATH. Install it (e.g., 'winget install Rclone.Rclone') and ensure it's available in your session."
    }
}

function ConvertTo-RclonePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    # rclone prefers forward slashes even on Windows.
    $p = $Path.Trim()
    $p = $p -replace '\\', '/'

    # Avoid accidental "//" runs.
    while ($p.Contains('//')) { $p = $p -replace '//', '/' }

    return $p
}

function Test-WindowsDrivePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Matches: C:\..., D:/...
    return ($Path -match '^[a-zA-Z]:[\\/]')
}

function Resolve-Navigator {
    param(
        [Parameter(Mandatory = $true)][string]$NavigatorName,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    if ($NavigatorName -and $NavigatorName -ne 'auto') {
        return $NavigatorName
    }

    # Prefer filesystem if the path exists locally (or is clearly a drive path).
    if (Test-WindowsDrivePath -Path $RootPath) {
        return 'filesystem'
    }

    if (Test-Path -LiteralPath $RootPath -PathType Container -ErrorAction SilentlyContinue) {
        return 'filesystem'
    }

    # If it looks like an rclone remote spec (remote:path) and not a Windows drive, use rclone.
    $trimmed = $RootPath.Trim()
    if ($trimmed -match '^[^:]+:.+') {
        return 'rclone'
    }

    # Fallback: filesystem (will error later if the folder doesn't exist).
    return 'filesystem'
}

function Split-RcloneRemoteSpec {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Very simple remote spec detection: "name:rest".
    # This is good enough for rclone remotes.
    $p = $Path.Trim()
    $idx = $p.IndexOf(':')
    if ($idx -le 0) {
        return $null
    }

    $remote = $p.Substring(0, $idx)
    $rest = $p.Substring($idx + 1)

    return [pscustomobject]@{ Remote = $remote; Path = $rest }
}

function Resolve-RcloneRootSpec {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    $rootNorm = ConvertTo-RclonePath -Path $RootPath

    $split = Split-RcloneRemoteSpec -Path $rootNorm
    if ($split) {
        $remote = $split.Remote
        $pathPart = $split.Path.TrimStart('/')
        return [pscustomobject]@{
            Remote   = $remote
            RootPath = $pathPart
        }
    }

    throw "Navigator=rclone: -Root must be a full rclone remote spec in the form 'remote:path'. Root: '$RootPath'"
}

function Get-BackendLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Nav,
        [Parameter()][string]$Remote
    )

    if ($Nav -eq 'rclone') {
        if ($Remote) { return "rclone ($Remote)" }
        return 'rclone'
    }

    return 'filesystem'
}

function Join-Relative {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $b = $Base.TrimEnd('/')
    $c = $Child.TrimStart('/').TrimEnd('/')

    if (-not $b) { return $c }
    if (-not $c) { return $b }
    return "$b/$c"
}

function Get-RelSegments {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Rel = ''
    )

    $r = $Rel.Trim().Trim('/')
    if (-not $r) { return @() }
    return @($r.Split('/') | Where-Object { $_ })
}

function Set-RelSegments {
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Segments
    )

    if (-not $Segments -or $Segments.Count -eq 0) { return '' }
    return ($Segments -join '/')
}

function Get-PathSegments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $p = $Path.Trim()

    # Strip wrapping quotes: ls "../x" or ls '../x'
    if (($p.StartsWith('"') -and $p.EndsWith('"')) -or ($p.StartsWith("'") -and $p.EndsWith("'"))) {
        if ($p.Length -ge 2) { $p = $p.Substring(1, $p.Length - 2) }
    }

    $p = $p.Trim()
    if (-not $p) { return @() }

    # Disallow absolute paths.
    if ($p.StartsWith('/') -or $p.StartsWith('\\') -or (Test-WindowsDrivePath -Path $p) -or ($p -match '^[^:]+:.+')) {
        throw "Path must be relative (no drive letters, no leading '/', no remote:path): '$Path'"
    }

    $norm = $p -replace '\\', '/'
    return @($norm.Split('/') | Where-Object { $_ })
}

function Resolve-RelativeUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$BaseRel,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($s in (Get-RelSegments -Rel $BaseRel)) {
        $null = $segments.Add([string]$s)
    }

    foreach ($part in (Get-PathSegments -Path $RelativePath)) {
        if ($part -eq '.' -or $part -eq '') { continue }
        if ($part -eq '..') {
            if ($segments.Count -eq 0) {
                throw "Refusing to resolve path above root: '$RelativePath'"
            }
            $segments.RemoveAt($segments.Count - 1)
            continue
        }

        $null = $segments.Add([string]$part)
    }

    return (Set-RelSegments -Segments $segments.ToArray())
}

function Show-PreviewHelp {
    param([Parameter()][string]$SelectionMode = 'disabled')
    
    if ($SelectionMode -eq 'single') {
        Write-Host 'Navigation: Up/Down move, Right/Enter enter dir, Left/Backspace go back, Space mark/unmark, Enter(on marked) submit, r refresh, q quit' -ForegroundColor DarkCyan
    } else {
        Write-Host 'Navigation: Up/Down select, Right/Enter enter dir, Left/Backspace go back, r refresh, Esc cancel fetch (or quit), q quit' -ForegroundColor DarkCyan
    }
}

function Get-CombinedEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Nav,
        [Parameter()][string]$FsFullPath,
        [Parameter()][string]$RcloneRemote,
        [Parameter()][string]$RclonePath,
        [Parameter()][bool]$IncludeParent = $false
    )

    if ($Nav -eq 'filesystem') {
        if (-not $FsFullPath -or -not $FsFullPath.Trim()) {
            throw 'Navigator=filesystem requires a non-empty filesystem path.'
        }
    }

    $dirs = Get-PreviewFolders -Nav $Nav -FsFullPath $FsFullPath -RcloneRemote $RcloneRemote -RclonePath $RclonePath
    $files = Get-PreviewFiles -Nav $Nav -FsFullPath $FsFullPath -RcloneRemote $RcloneRemote -RclonePath $RclonePath

    $items = @()

    if ($IncludeParent) {
        $items += [pscustomobject]@{
            Name    = '..'
            IsDir   = $true
            Display = '../'
        }
    }
    foreach ($d in ($dirs | Sort-Object)) {
        $items += [pscustomobject]@{
            Name      = [string]$d
            IsDir     = $true
            Display   = ([string]$d + '/')
        }
    }

    foreach ($f in ($files | Sort-Object)) {
        $items += [pscustomobject]@{
            Name      = [string]$f
            IsDir     = $false
            Display   = [string]$f
        }
    }

    return ,$items
}

function Render-SelectorScreen {
    param(
        [Parameter(Mandatory = $true)][string]$TitleText,
        [Parameter(Mandatory = $true)][string]$BackendLabel,
        [Parameter(Mandatory = $true)][string]$LocationText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][int]$SelectedIndex,
        [Parameter(Mandatory = $true)][int]$ScrollOffset,
        [Parameter()][int]$MaxDepth,
        [Parameter()][int]$Depth,
        [Parameter()][int]$SpinnerIndex = -1,
        [Parameter()][int]$SpinnerDots = 0,
        [Parameter()][string]$SelectionMode = 'disabled',
        [Parameter()][int]$MarkedIndex = -1
    )

    Clear-Host

    Write-Heading $TitleText
    Write-Info "Backend: $BackendLabel"
    Write-Info "Location: $LocationText"
    Show-PreviewHelp -SelectionMode $SelectionMode
    Clear-Host

    Write-Heading $TitleText
    Write-Info "Backend: $BackendLabel"
    Write-Info "Location: $LocationText"
    Show-PreviewHelp

    if ($MaxDepth -gt 0) {
        Write-Info "Depth: $Depth / $MaxDepth"
    }

    Write-Host ''

    $windowHeight = Get-WindowHeight
    $windowWidth = Get-WindowWidth

    # Header takes ~5-6 lines; keep 1 footer line worth of slack.
    $reserved = 7
    $visible = [Math]::Max(3, $windowHeight - $reserved)

    if (-not $Entries -or $Entries.Count -eq 0) {
        if ($SpinnerDots -gt 0) {
            $d = Clamp-Int -Value $SpinnerDots -Min 1 -Max 3
            Write-Host ("Fetching" + ('.' * $d)) -ForegroundColor Yellow
        } else {
            Write-Warn '(empty)'
        }
        return
    }

    $maxOffset = [Math]::Max(0, $Entries.Count - $visible)
    $offset = Clamp-Int -Value $ScrollOffset -Min 0 -Max $maxOffset
    $endExclusive = [Math]::Min($Entries.Count, $offset + $visible)

    $selectedBg = 'DarkBlue'

    for ($i = $offset; $i -lt $endExclusive; $i++) {
        $e = $Entries[$i]
        $isMarked = ($SelectionMode -eq 'single' -and $i -eq $MarkedIndex)
        
        $marker = ''
        $markerColor = 'DarkGray'
        $prefix = ''
        
        # Add selection marker prefix if item is marked
        if ($isMarked) {
            $prefix = '[✓] '
        }
        
        if ($isSelected) {
            if ($SpinnerDots -gt 0 -and $i -eq $SpinnerIndex) {
                $d = Clamp-Int -Value $SpinnerDots -Min 1 -Max 3
                $marker = (' <-' + ('.' * $d))
                $markerColor = 'Yellow'
            } elseif ($e.IsDir) {
                $marker = ' <-o'
                $markerColor = 'Green'
            } else {
                $marker = ' <-x'
                $markerColor = 'Red'
            }
        }

        $entryColor = if ($e.IsDir) { 'Cyan' } else { 'Gray' }
        if ($isSelected) { $entryColor = 'White' }
        if ($isMarked -and -not $isSelected) { $entryColor = 'Yellow' }

        $maxEntryWidth = $windowWidth
        if ($marker) {
            $maxEntryWidth = [Math]::Max(1, $windowWidth - $marker.Length)
        }
        if ($prefix) {
            $maxEntryWidth = [Math]::Max(1, $maxEntryWidth - $prefix.Length)
        }

        $displayText = $prefix + (Truncate-Text -Text ([string]$e.Display) -MaxWidth $maxEntryWidth)

        if ($isSelected -and $marker) {
            Write-Host $displayText -NoNewline -ForegroundColor $entryColor -BackgroundColor $selectedBg
            Write-Host $marker -ForegroundColor $markerColor -BackgroundColor $selectedBg
        } else {
            if ($isSelected) {
                Write-Host $displayText -ForegroundColor $entryColor -BackgroundColor $selectedBg
            } else {
                Write-Host $displayText -ForegroundColor $entryColor
            }
        }
    }

    if ($Entries.Count -gt $visible) {
        Write-Host ''
        Write-Host ("Showing {0}-{1} of {2}" -f ($offset + 1), $endExclusive, $Entries.Count) -ForegroundColor DarkGray
    }
}

function Wait-RcloneJobWithInlineSpinner {
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][string]$TitleText,
        [Parameter(Mandatory = $true)][string]$BackendLabel,
        [Parameter(Mandatory = $true)][string]$LocationText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][int]$SelectedIndex,
        [Parameter(Mandatory = $true)][int]$ScrollOffset,
        [Parameter()][int]$MaxDepth,
        [Parameter()][int]$Depth,
        [Parameter()][string]$SelectionMode = 'disabled',
        [Parameter()][int]$MarkedIndex = -1
    )

    $dots = 1
    while ($true) {
        $state = $Job.State
        if ($state -ne 'Running' -and $state -ne 'NotStarted') { break }

        # Allow canceling a slow fetch.
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq [ConsoleKey]::Escape) {
                    try { Stop-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
                    return $false
                }
            }
        } catch {
            # Ignore key polling errors; spinner still renders.
        }

        $spinnerIdx = if ($Entries -and $Entries.Count -gt 0) { $SelectedIndex } else { -1 }
        Render-SelectorScreen -TitleText $TitleText -BackendLabel $BackendLabel -LocationText $LocationText -Entries $Entries -SelectedIndex $SelectedIndex -ScrollOffset $ScrollOffset -MaxDepth $MaxDepth -Depth $Depth -SpinnerIndex $spinnerIdx -SpinnerDots $dots -SelectionMode $SelectionMode -MarkedIndex $MarkedIndex
        Start-Sleep -Milliseconds 180
        $dots = ($dots % 3) + 1
    }

    return $true
}

function Invoke-RcloneLsfWithInlineSpinner {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteSpec,
        [Parameter(Mandatory = $true)][string]$TitleText,
        [Parameter(Mandatory = $true)][string]$BackendLabel,
        [Parameter(Mandatory = $true)][string]$LocationText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][int]$SelectedIndex,
        [Parameter(Mandatory = $true)][int]$ScrollOffset,
        [Parameter()][int]$MaxDepth,
        [Parameter()][int]$Depth,
        [Parameter()][string]$SelectionMode = 'disabled',
        [Parameter()][int]$MarkedIndex = -1
    )

    $job = Start-Job -ScriptBlock {
        param($spec)
        & rclone lsf $spec --format p 2>$null
    } -ArgumentList $RemoteSpec
    $lines = @()
    $completed = $false
    try {
        $completed = Wait-RcloneJobWithInlineSpinner -Job $job -TitleText $TitleText -BackendLabel $BackendLabel -LocationText $LocationText -Entries $Entries -SelectedIndex $SelectedIndex -ScrollOffset $ScrollOffset -MaxDepth $MaxDepth -Depth $Depth -SelectionMode $SelectionMode -MarkedIndex $MarkedIndex
        if ($completed) {
            $received = Receive-Job -Job $job -ErrorAction Stop
            if ($received) { $lines = @($received) }
        }
    } catch {
        $lines = @()
        $completed = $false
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Completed = [bool]$completed
        Lines     = $lines
    }
}

function Convert-RcloneLsfLinesToEntries {
    param(
        [Parameter()][string[]]$Lines = @(),
        [Parameter()][bool]$IncludeParent = $false
    )

    $dirs = @()
    $files = @()

    foreach ($line in ($Lines ?? @())) {
        if ($null -eq $line) { continue }
        $s = $line.ToString().Trim()
        if (-not $s) { continue }

        if ($s.EndsWith('/')) {
            $n = $s.Substring(0, $s.Length - 1)
            if ($n) { $dirs += $n }
        } else {
            $files += $s
        }
    }

    $items = @()

    if ($IncludeParent) {
        $items += [pscustomobject]@{ Name = '..'; IsDir = $true; Display = '../' }
    }

    foreach ($d in ($dirs | Sort-Object)) {
        $items += [pscustomobject]@{ Name = [string]$d; IsDir = $true; Display = ([string]$d + '/') }
    }

    foreach ($f in ($files | Sort-Object)) {
        $items += [pscustomobject]@{ Name = [string]$f; IsDir = $false; Display = [string]$f }
    }

    return ,$items
}

# -----------------------------------------------------------------------------
# Navigator impls (listing only)
# -----------------------------------------------------------------------------

function Get-PreviewFolders {
    param(
        [Parameter(Mandatory = $true)][string]$Nav,
        [Parameter()][string]$FsFullPath,
        [Parameter()][string]$RcloneRemote,
        [Parameter()][string]$RclonePath
    )

    if ($Nav -eq 'filesystem') {
        if (-not (Test-Path -LiteralPath $FsFullPath -PathType Container)) { return @() }
        return Get-ChildItem -LiteralPath $FsFullPath -Directory -Force -ErrorAction Stop |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    }

    Assert-Rclone

    if (-not $RcloneRemote -or -not $RcloneRemote.Trim()) {
        throw 'Navigator=rclone: missing remote name.'
    }

    $remoteSpec = if ($RclonePath) { ('{0}:{1}' -f $RcloneRemote, $RclonePath) } else { ('{0}:' -f $RcloneRemote) }

    $names = @()
    try {
        $names = & rclone lsf $remoteSpec --dirs-only --format p 2>$null
    } catch {
        return @()
    }

    return $names |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        ForEach-Object {
            $n = $_
            if ($n.EndsWith('/')) { $n.Substring(0, $n.Length - 1) } else { $n }
        } |
        Sort-Object
}

function Get-PreviewFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Nav,
        [Parameter()][string]$FsFullPath,
        [Parameter()][string]$RcloneRemote,
        [Parameter()][string]$RclonePath
    )

    if ($Nav -eq 'filesystem') {
        if (-not (Test-Path -LiteralPath $FsFullPath -PathType Container)) { return @() }
        return Get-ChildItem -LiteralPath $FsFullPath -File -Force -ErrorAction Stop |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    }

    Assert-Rclone

    if (-not $RcloneRemote -or -not $RcloneRemote.Trim()) {
        throw 'Navigator=rclone: missing remote name.'
    }

    $remoteSpec = if ($RclonePath) { ('{0}:{1}' -f $RcloneRemote, $RclonePath) } else { ('{0}:' -f $RcloneRemote) }

    $names = @()
    try {
        $names = & rclone lsf $remoteSpec --files-only --format p 2>$null
    } catch {
        return @()
    }

    return $names |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Sort-Object
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Assert-Interactive

if ($MaxDepth -lt 0) { throw '-MaxDepth cannot be negative.' }

$nav = Resolve-Navigator -NavigatorName $Navigator -RootPath $Root

if ($nav -eq 'filesystem') {
    $resolved = Resolve-Path -LiteralPath $Root -ErrorAction Stop
    $rootFull = $resolved.Path
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "Root folder does not exist: $rootFull"
    }

    $rclone = $null
} else {
    $rclone = Resolve-RcloneRootSpec -RootPath $Root
    if (-not $rclone.Remote -or -not $rclone.Remote.Trim()) {
        throw 'Navigator=rclone: remote name could not be resolved.'
    }
}

$relative = ''

# Cache listings per location so selection moves are instant (especially for rclone).
# Keyed by navigator + root + relative path.
$dirCache = [System.Collections.Generic.Dictionary[string, object]]::new()
$forceRefresh = $false

# Track marked item for selection mode
$script:__markedIndex = -1
$script:__markedLocation = $null

while ($true) {
    try {
        $backendLabel = Get-BackendLabel -Nav $nav -Remote ($rclone.Remote)

        # Ensure selector state exists (also used for inline spinners during fetch).
        if ($null -eq $script:__selectedIndex) { $script:__selectedIndex = 0 }
        if ($null -eq $script:__scrollOffset) { $script:__scrollOffset = 0 }

        $cacheKey = if ($nav -eq 'filesystem') {
            "filesystem|$rootFull|$relative"
        } else {
            "rclone|$($rclone.Remote)|$($rclone.RootPath)|$relative"
        }

        $locationText = ''
        $entries = @()
        $depth = 0

        if (-not $forceRefresh -and $dirCache.ContainsKey($cacheKey)) {
            $cached = $dirCache[$cacheKey]
            $locationText = $cached.LocationText
            $entries = $cached.Entries
            $depth = $cached.Depth
        } else {
            if ($nav -eq 'filesystem') {
                $currentFull = $rootFull
                if ($relative) {
                    foreach ($seg in (Get-RelSegments -Rel $relative)) {
                        $currentFull = Join-Path $currentFull $seg
                    }
                }
                $locationText = $currentFull
                $entries = Get-CombinedEntries -Nav $nav -FsFullPath $currentFull -IncludeParent ($relative -ne '')
                $depth = (Get-RelSegments -Rel $relative).Count
            } else {
                $pathPart = $rclone.RootPath
                if ($relative) {
                    $pathPart = Join-Relative -Base $pathPart -Child $relative
                }
                $pathPart = ConvertTo-RclonePath -Path $pathPart
                $remoteSpec = if ($pathPart) { ('{0}:{1}' -f $rclone.Remote, $pathPart) } else { ('{0}:' -f $rclone.Remote) }
                $locationText = $remoteSpec
                $depth = (Get-RelSegments -Rel $relative).Count

                # rclone listing (single call). If this is a cache miss, we fetch synchronously here.
                $fetch = Invoke-RcloneLsfWithInlineSpinner -RemoteSpec $remoteSpec -TitleText $Title -BackendLabel $backendLabel -LocationText $locationText -Entries $entries -SelectedIndex $script:__selectedIndex -ScrollOffset $script:__scrollOffset -MaxDepth $MaxDepth -Depth $depth -SelectionMode $Selection -MarkedIndex $script:__markedIndex
                if (-not $fetch.Completed) {
                    # Canceled: keep view as-is (entries stays empty for this cache miss).
                    $entries = @()
                } else {
                    $entries = Convert-RcloneLsfLinesToEntries -Lines $fetch.Lines -IncludeParent ($relative -ne '')
                }
            }

            $dirCache[$cacheKey] = [pscustomobject]@{
                LocationText = $locationText
                Entries      = $entries
                Depth        = $depth
            }
            $forceRefresh = $false
        }

        if (-not $entries) { $entries = @() }

        # Stateful selector.
        if ($null -eq $script:__selectedIndex) { $script:__selectedIndex = 0 }
        if ($null -eq $script:__scrollOffset) { $script:__scrollOffset = 0 }

        if ($script:__selectedIndex -ge $entries.Count) { $script:__selectedIndex = [Math]::Max(0, $entries.Count - 1) }
        if ($script:__selectedIndex -lt 0) { $script:__selectedIndex = 0 }

        # Keep selection visible.
        $windowHeight = Get-WindowHeight
        $reserved = 7
        $visible = [Math]::Max(3, $windowHeight - $reserved)
        $maxOffset = [Math]::Max(0, $entries.Count - $visible)

        # Check if marked item is still valid at this location
        $currentLocation = $cacheKey
        if ($script:__markedLocation -ne $currentLocation) {
            $script:__markedIndex = -1
            $script:__markedLocation = $null
        }

        if ($script:__selectedIndex -lt $script:__scrollOffset) { $script:__scrollOffset = $script:__selectedIndex }
        if ($script:__selectedIndex -ge ($script:__scrollOffset + $visible)) { $script:__scrollOffset = $script:__selectedIndex - $visible + 1 }
        $script:__scrollOffset = Clamp-Int -Value $script:__scrollOffset -Min 0 -Max $maxOffset

        Render-SelectorScreen -TitleText $Title -BackendLabel $backendLabel -LocationText $locationText -Entries $entries -SelectedIndex $script:__selectedIndex -ScrollOffset $script:__scrollOffset -MaxDepth $MaxDepth -Depth $depth -SelectionMode $Selection -MarkedIndex $script:__markedIndex

        # Read a single key.
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $vk = [int]$key.VirtualKeyCode
        if ($vk -eq 27 -or ($key.Character -and ($key.Character -eq 'q' -or $key.Character -eq 'Q'))) {
            break
        }

        # Handle Space bar - toggle mark/unmark in selection mode
        if ($vk -eq 32 -and $Selection -eq 'single') {
            if ($entries -and $entries.Count -gt 0) {
                $selected = $entries[$script:__selectedIndex]
                # Don't allow marking the parent directory
                if (-not ($selected.IsDir -and $selected.Name -eq '..')) {
                    if ($script:__markedIndex -eq $script:__selectedIndex) {
                        # Unmark
                        $script:__markedIndex = -1
                        $script:__markedLocation = $null
                    } else {
                        # Mark this item
                        $script:__markedIndex = $script:__selectedIndex
                        $script:__markedLocation = $currentLocation
                    }
                }
            }
            continue
        }

        # Handle Enter on marked item - submit selection
        if ($vk -eq 13 -and $Selection -eq 'single' -and $script:__markedIndex -ge 0 -and $script:__markedIndex -lt $entries.Count) {
            $selected = $entries[$script:__markedIndex]

            # Build full path
            $fullPath = ''
            if ($nav -eq 'filesystem') {
                $currentFull = $rootFull
                if ($relative) {
                    foreach ($seg in (Get-RelSegments -Rel $relative)) {
                        $currentFull = Join-Path $currentFull $seg
                    }
                }
                $fullPath = Join-Path $currentFull $selected.Name
            } else {
                $pathPart = $rclone.RootPath
                if ($relative) {
                    $pathPart = Join-Relative -Base $pathPart -Child $relative
                }
                $pathPart = Join-Relative -Base $pathPart -Child $selected.Name
                $pathPart = ConvertTo-RclonePath -Path $pathPart
                $fullPath = if ($pathPart) { ('{0}:{1}' -f $rclone.Remote, $pathPart) } else { ('{0}:' -f $rclone.Remote) }
            }

            Write-Output $fullPath
            return
        }

        if ($key.Character -and ($key.Character -eq 'r' -or $key.Character -eq 'R')) {
            if ($nav -eq 'rclone') {
                # Refresh current location with inline spinner.
                $pathPart = $rclone.RootPath
                if ($relative) {
                    $pathPart = Join-Relative -Base $pathPart -Child $relative
                }
                $pathPart = ConvertTo-RclonePath -Path $pathPart
                $remoteSpec = if ($pathPart) { ('{0}:{1}' -f $rclone.Remote, $pathPart) } else { ('{0}:' -f $rclone.Remote) }

                $fetch = Invoke-RcloneLsfWithInlineSpinner -RemoteSpec $remoteSpec -TitleText $Title -BackendLabel $backendLabel -LocationText $locationText -Entries $entries -SelectedIndex $script:__selectedIndex -ScrollOffset $script:__scrollOffset -MaxDepth $MaxDepth -Depth $depth -SelectionMode $Selection -MarkedIndex $script:__markedIndex
                if ($fetch.Completed) {
                    $newEntries = Convert-RcloneLsfLinesToEntries -Lines $fetch.Lines -IncludeParent ($relative -ne '')
                    $dirCache[$cacheKey] = [pscustomobject]@{ LocationText = $locationText; Entries = $newEntries; Depth = $depth }
                    $forceRefresh = $false
                }
            } else {
                $forceRefresh = $true
            }
            continue
        }

        if ($vk -eq 38) {
            $script:__selectedIndex = [Math]::Max(0, $script:__selectedIndex - 1)
            continue
        }

        if ($vk -eq 40) {
            $script:__selectedIndex = [Math]::Min([Math]::Max(0, $entries.Count - 1), $script:__selectedIndex + 1)
            continue
        }

        if ($vk -eq 37 -or $vk -eq 8) {
            $segs = [System.Collections.Generic.List[string]]::new()
            foreach ($s in (Get-RelSegments -Rel $relative)) { $null = $segs.Add([string]$s) }
            if ($segs.Count -gt 0) {
                $segs.RemoveAt($segs.Count - 1)
                $targetRel = Set-RelSegments -Segments $segs.ToArray()

                if ($nav -eq 'rclone') {
                    $targetKey = "rclone|$($rclone.Remote)|$($rclone.RootPath)|$targetRel"
                    if (-not $dirCache.ContainsKey($targetKey)) {
                        $targetPath = $rclone.RootPath
                        if ($targetRel) { $targetPath = Join-Relative -Base $targetPath -Child $targetRel }
                        $targetPath = ConvertTo-RclonePath -Path $targetPath
                        $targetSpec = if ($targetPath) { ('{0}:{1}' -f $rclone.Remote, $targetPath) } else { ('{0}:' -f $rclone.Remote) }
                        $targetDepth = (Get-RelSegments -Rel $targetRel).Count

                        $fetch = Invoke-RcloneLsfWithInlineSpinner -RemoteSpec $targetSpec -TitleText $Title -BackendLabel $backendLabel -LocationText $locationText -Entries $entries -SelectedIndex $script:__selectedIndex -ScrollOffset $script:__scrollOffset -MaxDepth $MaxDepth -Depth $depth -SelectionMode $Selection -MarkedIndex $script:__markedIndex
                        if (-not $fetch.Completed) {
                            # Canceled: don't navigate.
                            continue
                        }

                        $newEntries = Convert-RcloneLsfLinesToEntries -Lines $fetch.Lines -IncludeParent ($targetRel -ne '')
                        $dirCache[$targetKey] = [pscustomobject]@{ LocationText = $targetSpec; Entries = $newEntries; Depth = $targetDepth }
                    }
                }

                $relative = $targetRel
            }
            $script:__selectedIndex = 0
            $script:__scrollOffset = 0
            # Clear marked item when navigating
            $script:__markedIndex = -1
            $script:__markedLocation = $null
            continue
        }

        if ($vk -eq 39 -or $vk -eq 13) {
            if (-not $entries -or $entries.Count -eq 0) { continue }
            $selected = $entries[$script:__selectedIndex]

            if ($selected.IsDir -and $selected.Name -eq '..') {
                $segs = [System.Collections.Generic.List[string]]::new()
                foreach ($s in (Get-RelSegments -Rel $relative)) { $null = $segs.Add([string]$s) }
                if ($segs.Count -gt 0) {
                    $segs.RemoveAt($segs.Count - 1)
                    $targetRel = Set-RelSegments -Segments $segs.ToArray()

                    if ($nav -eq 'rclone') {
                        $targetKey = "rclone|$($rclone.Remote)|$($rclone.RootPath)|$targetRel"
                        if (-not $dirCache.ContainsKey($targetKey)) {
                            $targetPath = $rclone.RootPath
                            if ($targetRel) { $targetPath = Join-Relative -Base $targetPath -Child $targetRel }
                            $targetPath = ConvertTo-RclonePath -Path $targetPath
                            $targetSpec = if ($targetPath) { ('{0}:{1}' -f $rclone.Remote, $targetPath) } else { ('{0}:' -f $rclone.Remote) }
                            $targetDepth = (Get-RelSegments -Rel $targetRel).Count

                            $fetch = Invoke-RcloneLsfWithInlineSpinner -RemoteSpec $targetSpec -TitleText $Title -BackendLabel $backendLabel -LocationText $locationText -Entries $entries -SelectedIndex $script:__selectedIndex -ScrollOffset $script:__scrollOffset -MaxDepth $MaxDepth -Depth $depth -SelectionMode $Selection -MarkedIndex $script:__markedIndex
                            if (-not $fetch.Completed) {
                                # Canceled: don't navigate.
                                continue
                            }

                            $newEntries = Convert-RcloneLsfLinesToEntries -Lines $fetch.Lines -IncludeParent ($targetRel -ne '')
                            $dirCache[$targetKey] = [pscustomobject]@{ LocationText = $targetSpec; Entries = $newEntries; Depth = $targetDepth }
                        }
                    }

                    $relative = $targetRel
                }
                $script:__selectedIndex = 0
                $script:__scrollOffset = 0
                # Clear marked item when navigating
                $script:__markedIndex = -1
                $script:__markedLocation = $null
                continue
            }

            if (-not $selected.IsDir) {
                # Files cannot be opened.
                continue
            }

            $segs = [System.Collections.Generic.List[string]]::new()
            foreach ($s in (Get-RelSegments -Rel $relative)) { $null = $segs.Add([string]$s) }
            if ($MaxDepth -gt 0 -and $segs.Count -ge $MaxDepth) {
                Write-Warn "Max depth reached ($MaxDepth). Cannot enter deeper folders."
                Start-Sleep -Milliseconds 900
                continue
            }
            $null = $segs.Add([string]$selected.Name)
            $targetRel = Set-RelSegments -Segments $segs.ToArray()

            if ($nav -eq 'rclone') {
                $targetKey = "rclone|$($rclone.Remote)|$($rclone.RootPath)|$targetRel"
                if (-not $dirCache.ContainsKey($targetKey)) {
                    $targetPath = $rclone.RootPath
                    if ($targetRel) { $targetPath = Join-Relative -Base $targetPath -Child $targetRel }
                    $targetPath = ConvertTo-RclonePath -Path $targetPath
                    $targetSpec = if ($targetPath) { ('{0}:{1}' -f $rclone.Remote, $targetPath) } else { ('{0}:' -f $rclone.Remote) }
                    $targetDepth = (Get-RelSegments -Rel $targetRel).Count

                    $fetch = Invoke-RcloneLsfWithInlineSpinner -RemoteSpec $targetSpec -TitleText $Title -BackendLabel $backendLabel -LocationText $locationText -Entries $entries -SelectedIndex $script:__selectedIndex -ScrollOffset $script:__scrollOffset -MaxDepth $MaxDepth -Depth $depth -SelectionMode $Selection -MarkedIndex $script:__markedIndex
                    if (-not $fetch.Completed) {
                        # Canceled: don't navigate.
                        continue
                    }

                    $newEntries = Convert-RcloneLsfLinesToEntries -Lines $fetch.Lines -IncludeParent ($targetRel -ne '')
                    $dirCache[$targetKey] = [pscustomobject]@{ LocationText = $targetSpec; Entries = $newEntries; Depth = $targetDepth }
                }
            }

            $relative = $targetRel
            $script:__selectedIndex = 0
            $script:__scrollOffset = 0
            # Clear marked item when navigating
            $script:__markedIndex = -1
            $script:__markedLocation = $null
            continue
        }

        # Ignore all other keys.
        continue
    } catch {
        Write-Host ''
        Write-Warn "Error: $($_.Exception.Message)"
        Write-Info 'Returning to preview root.'
        $relative = ''
        $script:__selectedIndex = 0
        $script:__scrollOffset = 0
        $forceRefresh = $true
        Write-Host ''
        Read-Host 'Press Enter to continue'
        continue
    }
}
