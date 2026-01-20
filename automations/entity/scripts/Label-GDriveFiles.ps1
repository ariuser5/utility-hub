<#
-------------------------------------------------------------------------------
Label-GDriveFiles.ps1
-------------------------------------------------------------------------------
Interactively adds a bracketed label prefix to files in a Google Drive folder
(using rclone) when they are not already labeled.

Key behaviors:
  - Top-level files only (no recursion)
  - Never changes sharing permissions
  - Skips already-labeled files only when the label is one of the configured labels
  - Supports an optional exclude regex (basenames only)
  - Auto-suffixes on name collisions: "(2)", "(3)", ...
  - Can open the selected file in the browser (Drive UI URL based on item ID)

Examples:
    # Label any file that does not already start with a label
  .\Label-GDriveFiles.ps1 -FolderPath "clients/acme/inbox" -Labels INVOICE,BALANCE,EXPENSE

  # Exclude some names entirely from processing
  .\Label-GDriveFiles.ps1 -FolderPath "clients/acme/inbox" -ExcludeNameRegex '^(README|_ignore)\\b' -Labels INVOICE,BALANCE,EXPENSE

  # Read labels from file
  .\Label-GDriveFiles.ps1 -FolderPath "clients/acme/inbox" -LabelsFilePath "..\resources\gdrive-labels.txt"
-------------------------------------------------------------------------------
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Unified')]
param(
    # Base folder path (local folder or rclone remote spec, e.g. "gdrive:clients/acme/inbox").
    [Parameter(Mandatory = $true, ParameterSetName = 'Unified')]
    [string]$Path,

    [Parameter(ParameterSetName = 'Unified')]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$PathType = 'Auto',

    [Parameter(ParameterSetName = 'LegacyRemote')]
    [string]$RemoteName = "gdrive",

    # Remote folder path on Google Drive (no trailing slash needed)
    [Parameter(Mandatory = $true, ParameterSetName = 'LegacyRemote')]
    [string]$FolderPath,

    # If provided, files with basenames matching this regex are excluded from processing entirely
    [Parameter()]
    [string]$ExcludeNameRegex,

    # If provided, runs in non-interactive mode and applies this single label to all eligible files
    [Parameter()]
    [string]$AutoLabel,

    # Provide labels directly
    [Parameter(ParameterSetName = 'Labels')]
    [string[]]$Labels = @("INVOICE", "BALANCE", "EXPENSE"),

    # Provide labels via a file (one label per line)
    [Parameter(Mandatory = $true, ParameterSetName = 'LabelsFile')]
    [string]$LabelsFilePath
)

$ErrorActionPreference = "Stop"

# Centralized label validation (used for configured labels + AutoLabel + interactive custom label entry)
$LabelValidationPattern = '^[a-zA-Z0-9_-]+$'

function Resolve-Labels {
    param(
        [string[]]$InlineLabels,
        [string]$LabelsFile
    )

    $resolved = @()

    if ($LabelsFile) {
        if (-not (Test-Path -LiteralPath $LabelsFile -PathType Leaf)) {
            throw "Labels file not found: $LabelsFile"
        }

        $resolved = Get-Content -LiteralPath $LabelsFile -ErrorAction Stop |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    } else {
        $resolved = $InlineLabels |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    }

    $resolved = $resolved | ForEach-Object {
        $l = $_.Trim().Trim('[', ']')
        if ($l -match '[\[\]]') {
            throw "Invalid label '$l': labels cannot contain '[' or ']'."
        }
        if ($l -notmatch $LabelValidationPattern) {
			throw "Invalid label '$l': labels can only contain alphanumeric characters, hyphens, and underscores."
		}
        $l
    } | Select-Object -Unique

    if (-not $resolved -or $resolved.Count -eq 0) {
        throw "No labels resolved. Provide -Labels or -LabelsFilePath with at least one label."
    }

    return ,$resolved
}

function Split-CommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false

    for ($i = 0; $i -lt $CommandLine.Length; $i++) {
        $ch = $CommandLine[$i]
        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
            continue
        }

        if (-not $inQuotes -and [char]::IsWhiteSpace($ch)) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString()) | Out-Null
                $null = $current.Clear()
            }
            continue
        }

        $null = $current.Append($ch)
    }

    if ($current.Length -gt 0) {
        $tokens.Add($current.ToString()) | Out-Null
    }

    return ,$tokens.ToArray()
}

function Test-ExecutableAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    if (-not $Exe) { return $false }

    # If caller provided a path, test that it exists; otherwise use PATH resolution.
    if ($Exe -match '^[a-zA-Z]:\\' -or $Exe.Contains('\\') -or $Exe.Contains('/')) {
        return (Test-Path -LiteralPath $Exe -PathType Leaf)
    }

    return ($null -ne (Get-Command $Exe -ErrorAction SilentlyContinue))
}

function Resolve-EditorCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $fallbackCandidates = @(
        'notepad.exe'
    )

    $candidateLines = New-Object System.Collections.Generic.List[string]
    $userSpecifiedSource = $null
    $userSpecifiedCommand = $null

    foreach ($envName in @('UTILITY_HUB_EDITOR', 'VISUAL', 'EDITOR')) {
        $val = [Environment]::GetEnvironmentVariable($envName)
        if ($val -and $val.Trim()) {
            $userSpecifiedSource = $envName
            $userSpecifiedCommand = $val.Trim()
            $candidateLines.Add($userSpecifiedCommand) | Out-Null
            break
        }
    }

    foreach ($c in $fallbackCandidates) {
        $candidateLines.Add($c) | Out-Null
    }

    foreach ($candidate in $candidateLines) {
        $parts = Split-CommandLine -CommandLine $candidate
        if (-not $parts -or $parts.Count -lt 1) {
            continue
        }

        $exe = $parts[0]
        if (-not (Test-ExecutableAvailable -Exe $exe)) {
            if ($userSpecifiedCommand -and $candidate -eq $userSpecifiedCommand) {
                Write-Host "Editor from ${userSpecifiedSource} not found: ${userSpecifiedCommand}. Falling back..." -ForegroundColor DarkYellow
            }
            continue
        }

        $editorParams = @()
        if ($parts.Count -gt 1) {
            $editorParams = $parts[1..($parts.Count - 1)]
        }

        $exeLower = $exe.ToLowerInvariant()

        if ($exeLower -eq 'code' -or $exeLower.EndsWith('\\code.cmd') -or $exeLower.EndsWith('\\code.exe') -or $exeLower -eq 'code.cmd' -or $exeLower -eq 'code.exe') {
            if ($editorParams -notcontains '--wait') {
                $editorParams = @($editorParams + '--wait')
            }
        }

        # gVim is a GUI editor; ensure it stays attached until the file is closed.
        if ($exeLower -eq 'gvim' -or $exeLower.EndsWith('\\gvim.exe') -or $exeLower -eq 'gvim.exe') {
            if ($editorParams -notcontains '-f') {
                $editorParams = @($editorParams + '-f')
            }
        }

        $isTerminalEditor = $false
        if ($exeLower -eq 'vim' -or $exeLower.EndsWith('\\vim.exe') -or $exeLower -eq 'vim.exe' -or
            $exeLower -eq 'nvim' -or $exeLower.EndsWith('\\nvim.exe') -or $exeLower -eq 'nvim.exe' -or
            $exeLower -eq 'vi' -or $exeLower.EndsWith('\\vi.exe') -or $exeLower -eq 'vi.exe') {
            $isTerminalEditor = $true
        }

        return [pscustomobject]@{
            Exe = $exe
            ArgumentList = @($editorParams + @($FilePath))
            RunInTerminal = $isTerminalEditor
        }
    }

    if ($userSpecifiedSource) {
        Write-Host "Editor from ${userSpecifiedSource} not found: ${userSpecifiedCommand}" -ForegroundColor DarkYellow
    }
    throw "No supported editor found. Set UTILITY_HUB_EDITOR/VISUAL/EDITOR to a valid editor command."
}

function Invoke-Editor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $cmd = Resolve-EditorCommand -FilePath $FilePath
    Write-Host "Opening editor: $($cmd.Exe) $($cmd.ArgumentList -join ' ')" -ForegroundColor DarkGray

    if ($cmd.RunInTerminal) {
        & $cmd.Exe @($cmd.ArgumentList)
        if ($LASTEXITCODE -ne 0) {
            throw ("Editor exited with code {0} ({1})" -f $LASTEXITCODE, $cmd.Exe)
        }
        return [pscustomobject]@{ Mode = 'closed' }
    }

    $proc = Start-Process -FilePath $cmd.Exe -ArgumentList $cmd.ArgumentList -PassThru

    # Wait loop with manual override:
    #  - C = continue now, using current file contents, leaving editor open
    #  - Q = abort script (no changes)
    Write-Host "Waiting for editor... (press 'c' to continue now, 'q' to abort)" -ForegroundColor DarkGray

    while ($true) {
        if ($proc -and $proc.HasExited) {
            return [pscustomobject]@{ Mode = 'closed' }
        }

        try {
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                switch ($keyInfo.Key) {
                    'C' { return [pscustomobject]@{ Mode = 'continue' } }
                    'Q' { return [pscustomobject]@{ Mode = 'abort' } }
                }
            }
        } catch {
            # Some hosts may not support KeyAvailable; fall back to normal blocking wait.
            Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Mode = 'closed' }
        }

        Start-Sleep -Milliseconds 200
    }
}

function New-RebaseTodoText {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [string[]]$Labels,

        [Parameter(Mandatory = $true)]
        [regex]$AllowedLabelsRegex
    )

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("# utility-hub: Label-GDriveFiles todo")
    $null = $sb.AppendLine("#")
    $null = $sb.AppendLine("# Commands:")
    $null = $sb.AppendLine("#   pick|p <filename>             = open interactive prompt for this file")
    $null = $sb.AppendLine("#   skip|s <filename>             = do nothing")
    $null = $sb.AppendLine("#   label:<LABEL> <filename>      = apply that label without prompting")
    $null = $sb.AppendLine("#   label:<N> <filename>          = apply label number N (1-based)")
    $null = $sb.AppendLine("#   <N> <filename>                = shorthand for label:<N>")
    $null = $sb.AppendLine("#")
    $null = $sb.AppendLine("# Special:")
    $null = $sb.AppendLine("#   abort                     = exit without making changes")
    $null = $sb.AppendLine("#   reset                     = regenerate defaults and reopen editor")
    $null = $sb.AppendLine("#")
    $null = $sb.AppendLine("# Configured labels:")
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $n = $i + 1
        $null = $sb.AppendLine("#   $n) $($Labels[$i])")
    }
    $null = $sb.AppendLine("#")
    $null = $sb.AppendLine("# Default: unlabeled => pick, already-labeled (configured) => skip")
    $null = $sb.AppendLine("#")

    foreach ($it in ($Items | Sort-Object Basename)) {
        $basename = $it.Basename
        $defaultAction = if ($AllowedLabelsRegex -and $AllowedLabelsRegex.IsMatch($basename)) { 'skip' } else { 'pick' }
        $escapedName = $basename -replace '\\', '\\\\'
        $escapedName = $escapedName -replace '"', '\"'
        $null = $sb.AppendLine($defaultAction + ' "' + $escapedName + '"')
    }

    return $sb.ToString()
}

function Read-RebaseTodo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TodoPath
    )

    $lines = Get-Content -LiteralPath $TodoPath -ErrorAction Stop
    $ops = New-Object System.Collections.Generic.List[object]

    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        if ($line -ieq 'abort') {
            return [pscustomobject]@{ Mode = 'abort' }
        }
        if ($line -ieq 'reset') {
            return [pscustomobject]@{ Mode = 'reset' }
        }

        if ($line -notmatch '^(?<action>\S+)\s+(?<name>.+)$') {
            throw "Invalid todo line: '$line' (expected: <action> <filename>)"
        }

        $action = $Matches['action']
        $nameRaw = $Matches['name'].Trim()
        if (-not $nameRaw) { throw "Invalid todo line: '$line' (missing filename)" }

        $name = $null
        if ($nameRaw.StartsWith('"')) {
            if ($nameRaw -notmatch '^"(?<inner>(?:\\.|[^"\\])*)"\s*$') {
                throw "Invalid quoted filename in todo line: '$line'"
            }

            $inner = $Matches['inner']
            $sbName = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $inner.Length; $i++) {
                $ch = $inner[$i]
                if ($ch -eq '\\') {
                    if ($i + 1 -ge $inner.Length) { throw "Invalid escape sequence in todo line: '$line'" }
                    $next = $inner[$i + 1]
                    switch ($next) {
                        '"' { $null = $sbName.Append('"') }
                        '\\' { $null = $sbName.Append('\\') }
                        default { $null = $sbName.Append($next) }
                    }
                    $i++
                    continue
                }
                $null = $sbName.Append($ch)
            }
            $name = $sbName.ToString()
        } else {
            $name = $nameRaw
        }

        if (-not $name) { throw "Invalid todo line: '$line' (missing filename)" }

        $ops.Add([pscustomobject]@{ Action = $action; Basename = $name }) | Out-Null
    }

    return [pscustomobject]@{ Mode = 'apply'; Ops = $ops }
}

function Test-RebaseTodoOps {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Ops,

        [Parameter(Mandatory = $true)]
        [hashtable]$ItemByBasename,

        [Parameter(Mandatory = $true)]
        [string[]]$ResolvedLabels
    )

    foreach ($op in $Ops) {
        $basename = $op.Basename
        if (-not $ItemByBasename.ContainsKey($basename)) {
            return [pscustomobject]@{ IsValid = $false; Error = "Todo references unknown file '$basename' (it may have been renamed/removed)." }
        }

        $action = $op.Action
        if ($action -match '^\d+$') {
            $action = "label:$action"
        }

        if ($action -ieq 'p' -or $action -ieq 'pick') { continue }
        if ($action -ieq 's' -or $action -ieq 'skip') { continue }

        if ($action -ieq 'label') {
            return [pscustomobject]@{ IsValid = $false; Error = "Invalid action 'label' for '$basename'. Use 'label:<LABEL> $basename' or 'label:<N> $basename'." }
        }

        if ($action -match '^label:(?<lbl>.+)$') {
            $lbl = $Matches['lbl'].Trim()
            if (-not $lbl) {
                return [pscustomobject]@{ IsValid = $false; Error = "Invalid action '$action' for '$basename': missing label after 'label:'." }
            }

            if ($lbl -match '^\d+$') {
                $idx = [int]$lbl
                if ($idx -lt 1 -or $idx -gt $ResolvedLabels.Count) {
                    return [pscustomobject]@{ IsValid = $false; Error = "Label index '$lbl' out of range for '$basename'. Valid range: 1..$($ResolvedLabels.Count)" }
                }
                continue
            }

            if ($ResolvedLabels -notcontains $lbl) {
                return [pscustomobject]@{ IsValid = $false; Error = "Label '$lbl' in todo is not in configured labels. Use one of: 1..$($ResolvedLabels.Count) or: $($ResolvedLabels -join ', ')" }
            }

            continue
        }

        return [pscustomobject]@{ IsValid = $false; Error = "Unknown action '$action' for '$basename'. Allowed: pick|p, skip|s, label:<LABEL>, label:<N>, or <N>." }
    }

    return [pscustomobject]@{ IsValid = $true }
}

function Write-RebaseTodoErrorHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TodoPath,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    $lines = Get-Content -LiteralPath $TodoPath -ErrorAction Stop

    $begin = '# ERROR-BEGIN'
    $end = '# ERROR-END'

    $beginIndex = -1
    $endIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($beginIndex -lt 0 -and $lines[$i].Trim() -eq $begin) { $beginIndex = $i; continue }
        if ($beginIndex -ge 0 -and $lines[$i].Trim() -eq $end) { $endIndex = $i; break }
    }

    if ($beginIndex -ge 0 -and $endIndex -ge $beginIndex) {
        if ($beginIndex -eq 0) {
            $lines = $lines[($endIndex + 1)..($lines.Count - 1)]
        } else {
            $before = $lines[0..($beginIndex - 1)]
            $after = if ($endIndex + 1 -le ($lines.Count - 1)) { $lines[($endIndex + 1)..($lines.Count - 1)] } else { @() }
            $lines = @($before + $after)
        }
    }

    $header = @(
        $begin,
        "# ERROR: $ErrorMessage",
        "# Fix the todo and save+close to continue.",
        $end,
        "#"
    )

    Set-Content -LiteralPath $TodoPath -Value ($header + $lines) -Encoding UTF8
}

function Invoke-InteractiveForItem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Basename,

        [Parameter(Mandatory = $true)]
        [string]$RemoteItem,

        [Parameter(Mandatory = $true)]
        [string[]]$ResolvedLabels,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$ExistingNames,

        [Parameter(Mandatory = $true)]
        [int]$DefaultChoiceIndex
    )

    $actionChoices = @(
        [System.Management.Automation.Host.ChoiceDescription]::new("&Label", "Select a label from the configured list"),
        [System.Management.Automation.Host.ChoiceDescription]::new("&Custom", "Enter a custom label"),
        [System.Management.Automation.Host.ChoiceDescription]::new("&Skip", "Skip this file"),
        [System.Management.Automation.Host.ChoiceDescription]::new("&Open", "Open this file in your browser"),
        [System.Management.Automation.Host.ChoiceDescription]::new("&Quit", "Stop processing")
    )

    while ($true) {
        $choice = $Host.UI.PromptForChoice("Action", "Choose an action for: $Basename", $actionChoices, $DefaultChoiceIndex)

        if ($choice -eq 4) {
            return [pscustomobject]@{ Outcome = 'quit' }
        }

        if ($choice -eq 3) {
            $url = Get-DriveBrowserUrl -RemoteItemPath $RemoteItem -FallbackQuery $Basename
            Write-Host "Opening: $url" -ForegroundColor Gray
            Start-Process $url | Out-Null
            Write-Host "(If it doesn't open correctly, Drive search fallback is used automatically when ID lookup fails.)" -ForegroundColor DarkGray
            continue
        }

        if ($choice -eq 2) {
            Write-Host "Skipped." -ForegroundColor DarkGray
            return [pscustomobject]@{ Outcome = 'skipped' }
        }

        $label = $null

        if ($choice -eq 1) {
            $label = (Read-Host "Enter label (without brackets)").Trim()
            if (-not $label) {
                Write-Host "Empty label; try again." -ForegroundColor DarkYellow
                continue
            }

            $label = $label.Trim('[', ']')
            if ($label -match '[\[\]]') {
                Write-Host "Label cannot contain '[' or ']'. Try again." -ForegroundColor DarkYellow
                continue
            }
			if ($label -notmatch $LabelValidationPattern) {
				Write-Host "Invalid label: labels can only contain alphanumeric characters, hyphens, and underscores." -ForegroundColor DarkYellow
				continue
			}
        }

        if ($choice -eq 0) {
            $label = Select-Label -Labels $ResolvedLabels
            if (-not $label) {
                Write-Host "No label selected; try again." -ForegroundColor DarkYellow
                continue
            }
        }

        $desired = "[$label] $Basename"
        $targetBasename = Get-UniqueBasename -DesiredBasename $desired -ExistingNames $ExistingNames
        $targetRemote = "$remoteFolder/$targetBasename"

        if ($PSCmdlet.ShouldProcess($RemoteItem, "Rename to $targetRemote")) {
            Write-Host "Renaming to: $targetBasename" -ForegroundColor Yellow
            & rclone moveto $RemoteItem $targetRemote
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Rename failed (exit $LASTEXITCODE): $Basename -> $targetBasename"
                continue
            }

            [void]$ExistingNames.Remove($Basename)
            [void]$ExistingNames.Add($targetBasename)

            Write-Host "✓ Renamed" -ForegroundColor Green
            return [pscustomobject]@{ Outcome = 'renamed'; NewBasename = $targetBasename }
        }

        return [pscustomobject]@{ Outcome = 'noop' }
    }
}

function Get-RcloneJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RcloneArguments
    )

    $raw = & rclone @RcloneArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "rclone failed (exit $exitCode): rclone $($RcloneArguments -join ' ')"
    }

    if (-not $raw) {
        return @()
    }

    return ($raw | ConvertFrom-Json)
}

function Get-DriveBrowserUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteItemPath,

        [Parameter(Mandatory = $true)]
        [string]$FallbackQuery
    )

    try {
        $stat = Get-RcloneJson -RcloneArguments @('lsjson', '--stat', '--original', $RemoteItemPath)
        # --stat returns a single object (not array) for supported backends
        $id = $null
        if ($null -ne $stat) {
            if ($stat.PSObject.Properties.Name -contains 'OrigID' -and $stat.OrigID) {
                $id = $stat.OrigID
            } elseif ($stat.PSObject.Properties.Name -contains 'ID' -and $stat.ID) {
                $id = $stat.ID
            }
        }

        if ($id) {
            return "https://drive.google.com/open?id=$id"
        }
    } catch {
        # fall through to search URL
    }

    $encoded = [System.Uri]::EscapeDataString($FallbackQuery)
    return "https://drive.google.com/drive/search?q=$encoded"
}

function Get-UniqueBasename {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DesiredBasename,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$ExistingNames
    )

    if (-not $ExistingNames.Contains($DesiredBasename)) {
        return $DesiredBasename
    }

    $ext = [System.IO.Path]::GetExtension($DesiredBasename)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($DesiredBasename)

    for ($i = 2; $i -lt 10000; $i++) {
        $candidate = "$stem ($i)$ext"
        if (-not $ExistingNames.Contains($candidate)) {
            return $candidate
        }
    }

    throw "Unable to find a unique name for '$DesiredBasename'."
}

function Select-Label {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Labels
    )

    $choices = @()
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $n = $i + 1
        $label = $Labels[$i]
        # Hotkeys 1..9 for first 9 labels
        $prefix = if ($n -le 9) { "&$n " } else { "" }
        $choices += [System.Management.Automation.Host.ChoiceDescription]::new("$prefix$label", "Use label '$label'")
    }

    $selectedIndex = $Host.UI.PromptForChoice("Select label", "Pick a label to add:", $choices, 0)
    if ($selectedIndex -lt 0 -or $selectedIndex -ge $Labels.Count) {
        return $null
    }

    return $Labels[$selectedIndex]
}

function New-AllowedLabelsRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ResolvedLabels
    )

    $escaped = $ResolvedLabels | ForEach-Object { [regex]::Escape($_) }
    if (-not $escaped -or $escaped.Count -eq 0) {
        return $null
    }

    $pattern = "^\[(?:$($escaped -join '|'))\]\s+"
    return [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Resolve labels
$resolvedLabels = Resolve-Labels -InlineLabels $Labels -LabelsFile $LabelsFilePath

if ($AutoLabel) {
    $auto = $AutoLabel.Trim().Trim('[', ']')
    if ($auto -match '[\[\]]') {
        throw "Invalid -AutoLabel '$auto': labels cannot contain '[' or ']'."
    }
	if ($auto -notmatch $LabelValidationPattern) {
        throw "Invalid -AutoLabel '$auto': labels can only contain alphanumeric characters, hyphens, and underscores."
    }
    if ($resolvedLabels -notcontains $auto) {
        $resolvedLabels = @($resolvedLabels + $auto)
    }
}

# Regexes (basename only)
$anyBracketLabelRegex = [regex]'^\[[^\]]+\]\s*'
$allowedLabelsRegex = New-AllowedLabelsRegex -ResolvedLabels $resolvedLabels

$excludeRegexObj = $null
if ($ExcludeNameRegex) {
    $excludeRegexObj = [regex]$ExcludeNameRegex
}

$pathModule = Join-Path $PSScriptRoot '..\helpers\Path.psm1'
Import-Module $pathModule -Force

$baseInfo = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'LegacyRemote') {
        $normalizedFolderPath = ($FolderPath -replace '\\','/').Trim().Trim('/').TrimEnd('/')
        $baseInfo = Resolve-UtilityHubPath -Path ("{0}:{1}" -f $RemoteName, $normalizedFolderPath) -PathType 'Remote'
    } else {
        $baseInfo = Resolve-UtilityHubPath -Path $Path -PathType $PathType
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

if ($baseInfo.PathType -eq 'Local') {
    if (-not (Test-Path -LiteralPath $baseInfo.LocalPath -PathType Container)) {
        Write-Error "Folder does not exist: $($baseInfo.LocalPath)"
        exit 1
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Local Labeling" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Folder: $($baseInfo.LocalPath)" -ForegroundColor Gray
    Write-Host "Labels: $($resolvedLabels -join ', ')" -ForegroundColor Gray
    if ($allowedLabelsRegex) { Write-Host "Already-labeled pattern: $($allowedLabelsRegex.ToString())" -ForegroundColor DarkGray }
    if ($ExcludeNameRegex) { Write-Host "ExcludeNameRegex: $ExcludeNameRegex" -ForegroundColor Gray }
    Write-Host ""

    function Get-LocalRenameTarget {
        param(
            [Parameter(Mandatory = $true)][string]$Folder,
            [Parameter(Mandatory = $true)][string]$Label,
            [Parameter(Mandatory = $true)][string]$OriginalName
        )

        $baseNew = "[{0}] {1}" -f $Label, $OriginalName
        $candidate = $baseNew
        $i = 2
        while (Test-Path -LiteralPath (Join-Path $Folder $candidate) -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($baseNew)
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($baseNew)
            if ($ext) {
                $candidate = "{0} ({1}){2}" -f $stem, $i, $ext
            } else {
                $candidate = "{0} ({1})" -f $stem, $i
            }
            $i++
            if ($i -gt 1000) { throw "Too many name collisions for '$OriginalName'" }
        }

        return $candidate
    }

    $all = Get-ChildItem -LiteralPath $baseInfo.LocalPath -File
    if ($excludeRegexObj) {
        $all = $all | Where-Object { -not $excludeRegexObj.IsMatch($_.Name) }
    }

    if (-not $all -or $all.Count -eq 0) {
        Write-Host "No files to review (all excluded or none found)." -ForegroundColor Green
        exit 0
    }

    $processed = 0
    $renamed = 0
    $alreadyLabeledSkipped = 0
    $skipped = 0
    $failed = 0

    foreach ($fi in $all) {
        $processed++
        $basename = $fi.Name

        $isAlready = ($allowedLabelsRegex -and $allowedLabelsRegex.IsMatch($basename)) -or (-not $allowedLabelsRegex -and $anyBracketLabelRegex.IsMatch($basename))
        if ($isAlready) {
            $alreadyLabeledSkipped++
            continue
        }

        $chosen = $null
        if ($AutoLabel) {
            $chosen = $AutoLabel.Trim().Trim('[', ']')
        } else {
            Write-Host "File: $basename" -ForegroundColor Cyan
            for ($i = 0; $i -lt $resolvedLabels.Count; $i++) {
                Write-Host ("  {0}) {1}" -f ($i + 1), $resolvedLabels[$i]) -ForegroundColor Gray
            }
            $ans = Read-Host "Pick label number (Enter=skip)"
            if (-not $ans) {
                $skipped++
                continue
            }
            $idx = 0
            if (-not [int]::TryParse($ans, [ref]$idx) -or $idx -lt 1 -or $idx -gt $resolvedLabels.Count) {
                Write-Host "Invalid selection; skipping." -ForegroundColor DarkYellow
                $skipped++
                continue
            }
            $chosen = $resolvedLabels[$idx - 1]
        }

        try {
            $targetName = Get-LocalRenameTarget -Folder $baseInfo.LocalPath -Label $chosen -OriginalName $basename
            $src = $fi.FullName
            $dst = Join-Path $baseInfo.LocalPath $targetName

            if ($PSCmdlet.ShouldProcess($src, "Rename to $targetName")) {
                Rename-Item -LiteralPath $src -NewName $targetName
                $renamed++
            }
        } catch {
            Write-Error "Rename failed: $basename. $_"
            $failed++
        }
    }

    Write-Host "" 
    Write-Host "Processed:       $processed" -ForegroundColor Gray
    Write-Host "Renamed:         $renamed" -ForegroundColor Gray
    Write-Host "Already labeled: $alreadyLabeledSkipped" -ForegroundColor Gray
    Write-Host "Skipped:         $skipped" -ForegroundColor Gray
    Write-Host "Failed:          $failed" -ForegroundColor Gray

    exit (if ($failed -gt 0) { 2 } else { 0 })
}

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Error "rclone not found on PATH. Install it (e.g., 'winget install Rclone.Rclone') and ensure it's available in your session."
    exit 1
}

$remoteFolder = $baseInfo.Normalized.TrimEnd('/')

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "GDrive Labeling" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Remote folder: $remoteFolder" -ForegroundColor Gray
Write-Host "Labels: $($resolvedLabels -join ', ')" -ForegroundColor Gray
if ($allowedLabelsRegex) { Write-Host "Already-labeled pattern: $($allowedLabelsRegex.ToString())" -ForegroundColor DarkGray }
if ($ExcludeNameRegex) { Write-Host "ExcludeNameRegex: $ExcludeNameRegex" -ForegroundColor Gray }
Write-Host "" 

# List files (top-level only)
try {
    $files = Get-RcloneJson -RcloneArguments @('lsjson', $remoteFolder, '--files-only')
} catch {
    Write-Error "Failed to list files in '$remoteFolder'. Ensure rclone is configured and the path exists. $_"
    exit 1
}

# Build items and detect duplicates (Drive can contain duplicate titles; rclone path operations become ambiguous)
$items = @()
$nameCounts = @{}
foreach ($f in $files) {
    $relPath = $null
    if ($f.PSObject.Properties.Name -contains 'Path' -and $f.Path) {
        $relPath = $f.Path
    } elseif ($f.PSObject.Properties.Name -contains 'Name' -and $f.Name) {
        $relPath = $f.Name
    }

    $basename = if ($relPath) { Split-Path -Path $relPath -Leaf } else { $null }
    if (-not $basename) { continue }

    $lower = $basename.ToLowerInvariant()
    if ($nameCounts.ContainsKey($lower)) {
        $nameCounts[$lower] = $nameCounts[$lower] + 1
    } else {
        $nameCounts[$lower] = 1
    }

    $items += [pscustomobject]@{
        Basename = $basename
        RemoteRelPath = $relPath
    }
}

$dups = $nameCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 } | Sort-Object Name
if ($dups -and $dups.Count -gt 0) {
    Write-Error "Duplicate basenames detected in '$remoteFolder'. Aborting to avoid ambiguous operations."
    foreach ($d in $dups) {
        Write-Host " - $($d.Name) ($($d.Value)x)" -ForegroundColor Red
    }
    exit 1
}

# Build existing basename set for collision detection
$existingNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($it in $items) {
    if ($it.Basename) {
        [void]$existingNames.Add($it.Basename)
    }
}

# Exclude items
$includedItems = if ($excludeRegexObj) {
    $items | Where-Object { -not $excludeRegexObj.IsMatch($_.Basename) }
} else {
    $items
}

if (-not $includedItems -or $includedItems.Count -eq 0) {
    Write-Host "No files to review (all excluded or none found)." -ForegroundColor Green
    exit 0
}

if ($AutoLabel) {
    Write-Host "Auto mode: applying label '$AutoLabel'" -ForegroundColor Yellow
    $processed = 0
    $renamed = 0
    $alreadyLabeledSkipped = 0
    $failed = 0

    foreach ($it in $includedItems) {
        $processed++
        $basename = $it.Basename
        $remoteItem = "$remoteFolder/$($it.RemoteRelPath)"

        $isAlready = ($allowedLabelsRegex -and $allowedLabelsRegex.IsMatch($basename)) -or (-not $allowedLabelsRegex -and $anyBracketLabelRegex.IsMatch($basename))
        if ($isAlready) {
            $alreadyLabeledSkipped++
            continue
        }

        $desired = "[$AutoLabel] $basename"
        $targetBasename = Get-UniqueBasename -DesiredBasename $desired -ExistingNames $existingNames
        $targetRemote = "$remoteFolder/$targetBasename"

        try {
            if ($PSCmdlet.ShouldProcess($remoteItem, "Rename to $targetRemote")) {
                Write-Host "Renaming: $basename -> $targetBasename" -ForegroundColor Yellow
                & rclone moveto $remoteItem $targetRemote
                if ($LASTEXITCODE -ne 0) {
                    throw "rclone moveto failed (exit $LASTEXITCODE)"
                }

                [void]$existingNames.Remove($basename)
                [void]$existingNames.Add($targetBasename)
                $renamed++
            }
        } catch {
            $failed++
            Write-Error "Auto rename failed: $basename -> $targetBasename. $_"
            continue
        }
    }

    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Done (Auto)" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Reviewed:        $processed" -ForegroundColor Gray
    Write-Host "Renamed:         $renamed" -ForegroundColor Gray
    Write-Host "Already-labeled: $alreadyLabeledSkipped" -ForegroundColor Gray
    Write-Host "Failed:          $failed" -ForegroundColor Gray

    if ($failed -gt 0) { exit 1 }
    exit 0
}

# Phase 1: rebase-style todo in editor
$tmpTodo = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("utility-hub-label-gdrivefiles-{0}.todo" -f ([guid]::NewGuid().ToString('N')))
$resetCount = 0

$todoInitialized = $false
$regenerateTodo = $true

while ($true) {
    if ($regenerateTodo -or -not $todoInitialized) {
        $todoText = New-RebaseTodoText -Items $includedItems -Labels $resolvedLabels -AllowedLabelsRegex $allowedLabelsRegex
        Set-Content -LiteralPath $tmpTodo -Value $todoText -Encoding UTF8
        $todoInitialized = $true
        $regenerateTodo = $false
    }

    $editResult = Invoke-Editor -FilePath $tmpTodo
    if ($editResult -and $editResult.Mode -eq 'abort') {
        Write-Host "Aborted (no changes made)." -ForegroundColor Yellow
        Remove-Item -LiteralPath $tmpTodo -ErrorAction SilentlyContinue
        exit 0
    }

    $parsed = Read-RebaseTodo -TodoPath $tmpTodo
    if ($parsed.Mode -eq 'abort') {
        Write-Host "Aborted (no changes made)." -ForegroundColor Yellow
        Remove-Item -LiteralPath $tmpTodo -ErrorAction SilentlyContinue
        exit 0
    }
    if ($parsed.Mode -eq 'reset') {
        $resetCount++
        if ($resetCount -ge 5) {
            throw "Too many resets; exiting."
        }
        $regenerateTodo = $true
        continue
    }

    # Validate todo; on errors, reopen editor with error prepended, preserving user's current todo content.
    $ops = $parsed.Ops
    if (-not $ops -or $ops.Count -eq 0) {
        Write-RebaseTodoErrorHeader -TodoPath $tmpTodo -ErrorMessage "Todo is empty. Add at least one action line or write 'abort'."
        continue
    }

    $itemByBasename = @{}
    foreach ($it in $includedItems) { $itemByBasename[$it.Basename] = $it }

    $validation = Test-RebaseTodoOps -Ops $ops -ItemByBasename $itemByBasename -ResolvedLabels $resolvedLabels
    if (-not $validation.IsValid) {
        Write-RebaseTodoErrorHeader -TodoPath $tmpTodo -ErrorMessage $validation.Error
        continue
    }

    break
}

# Map ops to existing items (validated already)
$itemByBasename = @{}
foreach ($it in $includedItems) { $itemByBasename[$it.Basename] = $it }

$toPick = New-Object System.Collections.Generic.List[object]
$renamed = 0
$skipped = 0
$failed = 0

foreach ($op in $ops) {
    $basename = $op.Basename
    if (-not $itemByBasename.ContainsKey($basename)) {
        throw "Todo references unknown file '$basename' (it may have been renamed/removed)."
    }

    $action = $op.Action
    if ($action -match '^\d+$') {
        $action = "label:$action"
    }

    if ($action -ieq 's' -or $action -ieq 'skip') {
        $skipped++
        continue
    }

    if ($action -ieq 'p' -or $action -ieq 'pick') {
        $toPick.Add($itemByBasename[$basename]) | Out-Null
        continue
    }

    if ($action -match '^label:(?<lbl>.+)$') {
        $lbl = $Matches['lbl'].Trim()
        if (-not $lbl) { throw "Invalid action '$action' for '$basename': missing label after 'label:'" }

        if ($lbl -match '^\d+$') {
            $idx = [int]$lbl
            if ($idx -lt 1 -or $idx -gt $resolvedLabels.Count) {
                throw "Label index '$lbl' out of range for '$basename'. Valid range: 1..$($resolvedLabels.Count)"
            }
            $lbl = $resolvedLabels[$idx - 1]
        }

        # Enforce label is from configured list
        if ($resolvedLabels -notcontains $lbl) {
            throw "Label '$lbl' in todo is not in configured labels: $($resolvedLabels -join ', ')"
        }

        $remoteItem = "$remoteFolder/$($itemByBasename[$basename].RemoteRelPath)"
        $desired = "[$lbl] $basename"
        $targetBasename = Get-UniqueBasename -DesiredBasename $desired -ExistingNames $existingNames
        $targetRemote = "$remoteFolder/$targetBasename"

        try {
            if ($PSCmdlet.ShouldProcess($remoteItem, "Rename to $targetRemote")) {
                Write-Host "Renaming: $basename -> $targetBasename" -ForegroundColor Yellow
                & rclone moveto $remoteItem $targetRemote
                if ($LASTEXITCODE -ne 0) {
                    throw "rclone moveto failed (exit $LASTEXITCODE)"
                }

                [void]$existingNames.Remove($basename)
                [void]$existingNames.Add($targetBasename)
                $renamed++
            }
        } catch {
            $failed++
            Write-Error "Rename failed: $basename -> $targetBasename. $_"
        }

        continue
    }

    if ($action -ieq 'label') {
        throw "Invalid action 'label' for '$basename'. Use 'label:<LABEL> $basename'"
    }

    throw "Unknown action '$action' for '$basename'. Allowed: pick, skip, label:<LABEL>"
}

# Phase 2: interactive prompt for 'pick' items
$pickedProcessed = 0
$pickRenamed = 0
$pickSkipped = 0

for ($i = 0; $i -lt $toPick.Count; $i++) {
    $pickedProcessed++
    $it = $toPick[$i]
    $basename = $it.Basename
    $remoteItem = "$remoteFolder/$($it.RemoteRelPath)"

    $isAlready = ($allowedLabelsRegex -and $allowedLabelsRegex.IsMatch($basename)) -or (-not $allowedLabelsRegex -and $anyBracketLabelRegex.IsMatch($basename))
    $defaultChoice = if ($isAlready) { 2 } else { 0 }

    Write-Host "[pick $pickedProcessed/$($toPick.Count)] $basename" -ForegroundColor Cyan
    $result = Invoke-InteractiveForItem -Basename $basename -RemoteItem $remoteItem -ResolvedLabels $resolvedLabels -ExistingNames $existingNames -DefaultChoiceIndex $defaultChoice

    if ($result.Outcome -eq 'quit') {
        Write-Host "Stopping at user request." -ForegroundColor Yellow
        break
    }
    if ($result.Outcome -eq 'renamed') { $pickRenamed++ }
    elseif ($result.Outcome -eq 'skipped') { $pickSkipped++ }

    Write-Host "" 
}

Remove-Item -LiteralPath $tmpTodo -ErrorAction SilentlyContinue

Write-Host "========================================" -ForegroundColor Green
Write-Host "Done" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Todo renamed:    $renamed" -ForegroundColor Gray
Write-Host "Todo skipped:    $skipped" -ForegroundColor Gray
Write-Host "Todo failed:     $failed" -ForegroundColor Gray
Write-Host "Pick renamed:    $pickRenamed" -ForegroundColor Gray
Write-Host "Pick skipped:    $pickSkipped" -ForegroundColor Gray

if ($failed -gt 0) { exit 1 }
