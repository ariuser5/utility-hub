<#
TODO:
 - Implement a new interactive batch mode, that operates just like git's interactive rebase,
   allowing the user to pick actions (label, skip, open, quit) for each file in sequence.
   For files the "open" or if labeling failed, the batch interactive mode should run again,
   but skipping already-processed files.
#>

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

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Labels')]
param(
    [Parameter()]
    [string]$RemoteName = "gdrive",

    # Remote folder path on Google Drive (no trailing slash needed)
    [Parameter(Mandatory = $true)]
    [string]$FolderPath,

    # If provided, files with basenames matching this regex are excluded from processing entirely
    [Parameter()]
    [string]$ExcludeNameRegex,

    # Provide labels directly
    [Parameter(ParameterSetName = 'Labels')]
    [string[]]$Labels = @("INVOICE", "BALANCE", "EXPENSE"),

    # Provide labels via a file (one label per line)
    [Parameter(Mandatory = $true, ParameterSetName = 'LabelsFile')]
    [string]$LabelsFilePath
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Error "rclone not found on PATH. Install it (e.g., 'winget install Rclone.Rclone') and ensure it's available in your session."
    exit 1
}

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
		if ($l -notmatch '^[a-zA-Z0-9_-]+$') {
			throw "Invalid label '$l': labels can only contain alphanumeric characters, hyphens, and underscores."
		}
        $l
    } | Select-Object -Unique

    if (-not $resolved -or $resolved.Count -eq 0) {
        throw "No labels resolved. Provide -Labels or -LabelsFilePath with at least one label."
    }

    return ,$resolved
}

function Get-RcloneJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $raw = & rclone @Args
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "rclone failed (exit $exitCode): rclone $($Args -join ' ')"
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
        $stat = Get-RcloneJson -Args @('lsjson', '--stat', '--original', $RemoteItemPath)
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

# Resolve labels
$resolvedLabels = Resolve-Labels -InlineLabels $Labels -LabelsFile $LabelsFilePath

# Regexes (basename only)
$anyBracketLabelRegex = [regex]'^\[[^\]]+\]\s*'

$escapedLabels = $resolvedLabels | ForEach-Object { [regex]::Escape($_) }
$pattern = "^\[(?:$($escapedLabels -join '|'))\]\s+"
$allowedLabelsRegex = $null
if ($escapedLabels -and $escapedLabels.Count -gt 0) {
    $allowedLabelsRegex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

$excludeRegexObj = $null
if ($ExcludeNameRegex) {
    $excludeRegexObj = [regex]$ExcludeNameRegex
}

$normalizedFolderPath = ($FolderPath -replace '\\','/').Trim().Trim('/').TrimEnd('/')
$remoteFolder = ("${RemoteName}:${normalizedFolderPath}").TrimEnd('/')

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
    $files = Get-RcloneJson -Args @('lsjson', $remoteFolder, '--files-only')
} catch {
    Write-Error "Failed to list files in '$remoteFolder'. Ensure rclone is configured and the path exists. $_"
    exit 1
}

# Build existing basename set for collision detection
$existingNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $files) {	
    $relPath = $null
    if ($f.PSObject.Properties.Name -contains 'Path' -and $f.Path) {
        $relPath = $f.Path
    } elseif ($f.PSObject.Properties.Name -contains 'Name' -and $f.Name) {
        $relPath = $f.Name
    }

    $base = if ($relPath) { Split-Path -Path $relPath -Leaf } else { $null }
    if ($base) {
        [void]$existingNames.Add($base)
    }
}

$candidates = @()
foreach ($f in $files) {
    $relPath = $null
    if ($f.PSObject.Properties.Name -contains 'Path' -and $f.Path) {
        $relPath = $f.Path
    } elseif ($f.PSObject.Properties.Name -contains 'Name' -and $f.Name) {
        $relPath = $f.Name
    }

    $basename = if ($relPath) { Split-Path -Path $relPath -Leaf } else { $null }
    if (-not $basename) { continue }
	
    # Skip already labeled ONLY if it matches one of the configured labels.
    # If we can't build the configured-label regex for some reason, fall back to any "[...]" prefix.
    if (($allowedLabelsRegex -and $allowedLabelsRegex.IsMatch($basename)) -or (-not $allowedLabelsRegex -and $anyBracketLabelRegex.IsMatch($basename))) {
        continue
    }

    # Skip excluded
    if ($excludeRegexObj -and $excludeRegexObj.IsMatch($basename)) {
        continue
    }

    $candidates += [pscustomobject]@{
        Basename = $basename
        RemoteRelPath = $relPath
    }
}

if ($candidates.Count -eq 0) {
    Write-Host "No files need labeling." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($candidates.Count) file(s) requiring review." -ForegroundColor Yellow
Write-Host "" 

$actionChoices = @(
    [System.Management.Automation.Host.ChoiceDescription]::new("&Label", "Select a label from the configured list"),
    [System.Management.Automation.Host.ChoiceDescription]::new("&Custom", "Enter a custom label"),
    [System.Management.Automation.Host.ChoiceDescription]::new("&Skip", "Skip this file"),
    [System.Management.Automation.Host.ChoiceDescription]::new("&Open", "Open this file in your browser"),
    [System.Management.Automation.Host.ChoiceDescription]::new("&Quit", "Stop processing")
)

$processed = 0
$renamed = 0
$skipped = 0

foreach ($c in $candidates) {
    $processed++

    $basename = $c.Basename
    $remoteItem = "$remoteFolder/$($c.RemoteRelPath)"

    Write-Host "[$processed/$($candidates.Count)] $basename" -ForegroundColor Cyan

    while ($true) {
        $choice = $Host.UI.PromptForChoice("Action", "Choose an action for: $basename", $actionChoices, 0)

        if ($choice -eq 4) {
            Write-Host "Stopping at user request." -ForegroundColor Yellow
            break 2
        }

        if ($choice -eq 3) {
            $url = Get-DriveBrowserUrl -RemoteItemPath $remoteItem -FallbackQuery $basename
            Write-Host "Opening: $url" -ForegroundColor Gray
            Start-Process $url | Out-Null
            Write-Host "(If it doesn't open correctly, Drive search fallback is used automatically when ID lookup fails.)" -ForegroundColor DarkGray
            continue
        }

        if ($choice -eq 2) {
            $skipped++
            Write-Host "Skipped." -ForegroundColor DarkGray
            break
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
        }

        if ($choice -eq 0) {
            $label = Select-Label -Labels $resolvedLabels
            if (-not $label) {
                Write-Host "No label selected; try again." -ForegroundColor DarkYellow
                continue
            }
        }

        $desired = "[$label] $basename"
        $targetBasename = Get-UniqueBasename -DesiredBasename $desired -ExistingNames $existingNames
        $targetRemote = "$remoteFolder/$targetBasename"

        if ($PSCmdlet.ShouldProcess($remoteItem, "Rename to $targetRemote")) {
            Write-Host "Renaming to: $targetBasename" -ForegroundColor Yellow
            & rclone moveto $remoteItem $targetRemote
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Rename failed (exit $LASTEXITCODE): $basename -> $targetBasename"
                # Keep in loop so user can retry/skip/open
                continue
            }

            # Update collision set
            [void]$existingNames.Remove($basename)
            [void]$existingNames.Add($targetBasename)

            $renamed++
            Write-Host "✓ Renamed" -ForegroundColor Green
        }

        break
    }

    Write-Host "" 
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "Done" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Reviewed: $processed" -ForegroundColor Gray
Write-Host "Renamed:  $renamed" -ForegroundColor Gray
Write-Host "Skipped:  $skipped" -ForegroundColor Gray
