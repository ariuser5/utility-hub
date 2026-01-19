<#
-------------------------------------------------------------------------------
App-Cverk.ps1
-------------------------------------------------------------------------------
Interactive entrypoint for CVERK automations.

Goals:
    - Read-only navigation/preview of folder structures (interactive, folder-only navigation)
  - Works against local filesystem OR Google Drive via rclone
  - Provides lightweight “pipeline launcher” placeholders (open or print command)

Notes:
  - This script intentionally does NOT implement workflow logic (month close, labels,
    archival, emailing, etc). It only helps you explore and jump into existing tools.
    - The navigation preview UI is implemented by: automations/utils/Preview.ps1
-------------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
    # Root folder for accountant.
    # Can be a filesystem path (e.g., C:\Data\CVERK\accountant) or an rclone remote spec (e.g., gdrive:accountant).
    [Parameter()]
    [string]$AccountantRoot,

    # Client roots. Provide one or more entries.
    #
    # Accepted forms:
    #   - Hashtable/dictionary: @{ Client1 = 'C:\path'; Client2 = 'gdrive:clients/foo' }
    #   - String array entries:
    #       - 'Alias=C:\path with spaces'
    #       - 'Alias=gdrive:clients/foo'
    #       - 'C:\some\client'  (alias auto-derived from last segment)
    #       - 'gdrive:clients/foo' (alias auto-derived)
    [Parameter()]
    [object]$Clients
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Config (edit defaults here)
# -----------------------------------------------------------------------------

$Config = [pscustomobject]@{
    # If you don't pass -Clients/-AccountantRoot, set your defaults here.
    # Examples:
    #   AccountantRoot = 'C:\CVERK\accountant'
    #   Clients = @(
    #       'ClientA=C:\CVERK\clients\ClientA'
    #       'gdrive:Documents/work/cverk/clienti/ClientB'
    #   )
    AccountantRoot = ''
    Clients        = @()

    # Optional: prevent going too deep in previews. 0 = unlimited.
    PreviewMaxDepth = 0
}

if ($PSBoundParameters.ContainsKey('AccountantRoot')) { $Config.AccountantRoot = $AccountantRoot }
if ($PSBoundParameters.ContainsKey('Clients'))        { $Config.Clients = $Clients }

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

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

function Write-Err {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host $Text -ForegroundColor Red
}

function Assert-Interactive {
    # Fail fast in non-interactive contexts.
    if (-not $Host.UI -or -not $Host.UI.RawUI) {
        throw 'This script is interactive and requires a console host.'
    }
}

function Get-AliasFromPath {
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

function Start-Preview {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $previewScript = Join-Path $PSScriptRoot '..\utils\Preview.ps1'
    $previewScript = (Resolve-Path -LiteralPath $previewScript -ErrorAction Stop).Path

    $previewRoot = ($Root ?? '').Trim()
    if (-not $previewRoot) {
        throw 'Empty preview root.'
    }

    $previewArgs = @(
        '-Root', $previewRoot,
        '-Title', $Title
    )

    if ($Config.PreviewMaxDepth -and $Config.PreviewMaxDepth -gt 0) {
        $previewArgs += @('-MaxDepth', [string]$Config.PreviewMaxDepth)
    }

    # Invoke via pwsh to avoid argument-binding edge cases when invoking a script path directly.
    & pwsh -NoProfile -File $previewScript @previewArgs
}

function Prompt-Choice {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string[]]$Valid
    )

    while ($true) {
        $c = (Read-Host $Prompt)
        if ($null -eq $c) { continue }
        $c = $c.Trim()
        foreach ($v in $Valid) {
            if ($c.Equals($v, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $v
            }
        }
        Write-Warn "Invalid choice. Valid: $($Valid -join ', ')"
    }
}

function Select-FromList {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter()][string]$ItemLabel = 'item'
    )

    Write-Heading $Title

    if (-not $Items -or $Items.Count -eq 0) {
        Write-Warn "No $ItemLabel found."
        Write-Host ''
        Read-Host 'Press Enter to go back'
        return $null
    }

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $n = $i + 1
        Write-Host ("[{0}] {1}" -f $n, $Items[$i].Name) -ForegroundColor Gray
    }

    Write-Host ''
    Write-Info "Type a number, or 'b' to go back."

    while ($true) {
        $raw = Read-Host 'Select'
        if ($null -eq $raw) { continue }
        $raw = $raw.Trim()

        if ($raw.Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        $n = 0
        if ([int]::TryParse($raw, [ref]$n)) {
            if ($n -ge 1 -and $n -le $Items.Count) {
                return $Items[$n - 1]
            }
        }

        Write-Warn 'Invalid selection.'
    }
}

function Browse-Clients {
    $clients = Resolve-Clients

    while ($true) {
        Clear-Host
        Write-Heading 'Clients'
        Write-Info "Count: $($clients.Count)"
        Write-Host ''

        $client = Select-FromList -Title 'Select client' -Items $clients -ItemLabel 'clients'
        if (-not $client) { return }

        Start-Preview -Root $client.Root -Title "Client preview: $($client.Name)"
    }
}

function Preview-Accountant {
    $root = ($Config.AccountantRoot ?? '').Trim()
    if (-not $root) {
        throw 'AccountantRoot is not configured. Pass -AccountantRoot or set Config.AccountantRoot.'
    }

    Start-Preview -Root $root -Title 'Accountant preview'
}

function Get-PipelineScripts {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
    $pipelinesDir = Join-Path $repoRoot 'automations\cverk\pipelines'

    if (-not (Test-Path -LiteralPath $pipelinesDir -PathType Container)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $pipelinesDir -File -Filter '*.ps1' -ErrorAction Stop |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name     = $_.Name
                FullPath = $_.FullName
            }
        }
}

function Open-InEditor {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Simple editor selection (aligned with README expectations).
    $editor = $env:UTILITY_HUB_EDITOR
    if (-not $editor) { $editor = $env:VISUAL }
    if (-not $editor) { $editor = $env:EDITOR }
    if (-not $editor) { $editor = 'notepad.exe' }

    # If user specifies just 'code', ensure it waits.
    if ($editor.Trim().Equals('code', [System.StringComparison]::OrdinalIgnoreCase)) {
        $editor = 'code --wait'
    }

    Write-Info "Opening in editor: $editor"

    try {
        # Keep it simple: use PowerShell's command line parsing rules.
        & $editor $Path
    } catch {
        Write-Warn "Failed to open editor '$editor'. Try setting UTILITY_HUB_EDITOR to a valid command (e.g., 'code --wait')."
        Write-Warn $_.Exception.Message
    }
}

function Pipelines-Menu {
    while ($true) {
        Clear-Host
        Write-Heading 'Pipelines'
        Write-Info 'These are placeholders: open scripts or print suggested commands.'
        Write-Host ''

        $pipelines = Get-PipelineScripts
        $p = Select-FromList -Title 'Select pipeline' -Items $pipelines -ItemLabel 'pipelines'
        if (-not $p) { return }

        while ($true) {
            Clear-Host
            Write-Heading "Pipeline: $($p.Name)"
            Write-Info "Path: $($p.FullPath)"
            Write-Host ''

            $action = Prompt-Choice -Prompt "Actions: [o] open, [c] show command, [b] back" -Valid @('o','c','b')
            if ($action -ieq 'b') { break }

            if ($action -ieq 'o') {
                Open-InEditor -Path $p.FullPath
                continue
            }

            if ($action -ieq 'c') {
                Write-Host ''
                Write-Info 'Suggested command:'
                Write-Host ('pwsh -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $p.FullPath) -ForegroundColor Gray
                Write-Host ''
                Read-Host 'Press Enter to continue'
                continue
            }
        }
    }
}

function Show-Settings {
    Clear-Host
    Write-Heading 'Settings'

    Write-Info "AccountantRoot: $($Config.AccountantRoot)"

    $clients = Resolve-Clients
    if (-not $clients -or $clients.Count -eq 0) {
        Write-Warn 'Clients: (none configured)'
    } else {
        Write-Info "Clients ($($clients.Count)):\n"
        foreach ($c in $clients) {
            Write-Host ("- {0} -> {1}" -f $c.Name, $c.Root) -ForegroundColor Gray
        }
    }

    Write-Host ''
    Write-Info 'Edit the config block near the top of this script to change defaults.'
    Write-Host ''
    Read-Host 'Press Enter to go back'
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

Assert-Interactive

while ($true) {
    Clear-Host

    Write-Heading 'CVERK automation entrypoint'
    $clientCount = (Resolve-Clients).Count
    Write-Info "Clients: $clientCount"
    Write-Host ''

    Write-Host '[1] Browse clients (navigation preview)' -ForegroundColor Gray
    Write-Host '[2] Preview accountant (navigation preview)' -ForegroundColor Gray
    Write-Host '[3] Pipelines (placeholders)' -ForegroundColor Gray
    Write-Host '[4] Settings' -ForegroundColor Gray
    Write-Host '[q] Quit' -ForegroundColor Gray

    Write-Host ''
    $choice = Read-Host 'Select'
    if ($null -eq $choice) { continue }
    $choice = $choice.Trim()

    if ($choice.Equals('q', [System.StringComparison]::OrdinalIgnoreCase)) {
        break
    }

    try {
        switch ($choice) {
            '1' { Browse-Clients }
            '2' { Preview-Accountant }
            '3' { Pipelines-Menu }
            '4' { Show-Settings }
            default { Write-Warn 'Invalid selection.'; Start-Sleep -Milliseconds 700 }
        }
    } catch {
        Write-Err 'Error:'
        Write-Err $_.Exception.Message
        Write-Host ''
        Read-Host 'Press Enter to continue'
    }
}
