<#
-------------------------------------------------------------------------------
App-Main.ps1
-------------------------------------------------------------------------------
Interactive entrypoint for entity automations.

Goals:
    - Read-only navigation/preview of folder structures (interactive, folder-only navigation)
  - Works against local filesystem OR Google Drive via rclone
    - Provides lightweight “automation launcher” placeholders (open or print command)

Notes:
  - This script intentionally does NOT implement workflow logic (month close, labels,
    archival, emailing, etc). It only helps you explore and jump into existing tools.
    - The navigation preview UI is implemented by: automations/utils/Preview.ps1
-------------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
    # Optional JSON config file.
    # If not provided, defaults to: %LOCALAPPDATA%\utility-hub\data\contacts-data.json (if it exists).
    # Precedence rules:
    #   - If -StaticDataFile is NOT provided: CLI parameters override config values.
    #   - If -StaticDataFile IS provided: values are merged (for Clients, entries are combined; CLI wins on duplicate aliases).
    [Parameter()]
    [Alias('ConfigPath')]
    [string]$StaticDataFile,

    # Root folder for accountant.
    # Can be a filesystem path (e.g., C:\Data\entity\accountant) or an rclone remote spec (e.g., gdrive:accountant).
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
# Helpers
# -----------------------------------------------------------------------------

$entityConfigModule = Join-Path $PSScriptRoot '.\helpers\EntityConfig.psm1'
Import-Module $entityConfigModule -Force

$init = Initialize-EntityConfig -StaticDataFile $StaticDataFile -AccountantRoot $AccountantRoot -Clients $Clients -BoundParameters $PSBoundParameters
$Config = $init.Config
$defaultStaticDataFile = $init.DefaultStaticDataFile
$resolvedStaticDataFile = $init.ResolvedStaticDataFile

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

function Request-Quit {
    $script:__ShouldQuit = $true
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
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Items,
        [Parameter()][string]$ItemLabel = 'item',
        [Parameter()][switch]$AllowQuit
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
    if ($AllowQuit) {
        Write-Info "Type a number, 'b' to go back, or 'q' to quit."
    } else {
        Write-Info "Type a number, or 'b' to go back."
    }

    while ($true) {
        $raw = Read-Host 'Select'
        if ($null -eq $raw) { continue }
        $raw = $raw.Trim()

        if ($raw.Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        if ($AllowQuit -and $raw.Equals('q', [System.StringComparison]::OrdinalIgnoreCase)) {
            Request-Quit
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
    $clients = Resolve-Clients -Config $Config

    while ($true) {
        Clear-Host
        Write-Heading 'Clients'
        Write-Info "Count: $($clients.Count)"
        Write-Host ''

        $client = Select-FromList -Title 'Select client' -Items $clients -ItemLabel 'clients' -AllowQuit
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

function Get-AutomationScripts {
    $allFiles = @()

    # 1. Built-in automations (relative to this script)
    $builtInDir = Join-Path $PSScriptRoot '.\automation-scripts'
    if (Test-Path -LiteralPath $builtInDir -PathType Container) {
        $builtInFiles = @(Get-ChildItem -LiteralPath $builtInDir -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
        if ($builtInFiles -and $builtInFiles.Count -gt 0) {
            $allFiles += $builtInFiles
        }
    }

    # 2. User automations (LOCALAPPDATA)
    if ($env:LOCALAPPDATA) {
        $userDir = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'utility-hub') 'automations') 'automation-scripts'
        if (Test-Path -LiteralPath $userDir -PathType Container) {
            $userFiles = @(Get-ChildItem -LiteralPath $userDir -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
            if ($userFiles -and $userFiles.Count -gt 0) {
                $allFiles += $userFiles
            }
        }
    }

    # 3. Custom user-defined location (via environment variable)
    if ($env:AUTOMATION_SCRIPTS_PATH) {
        $customDir = $env:AUTOMATION_SCRIPTS_PATH.Trim()
        if ($customDir -and (Test-Path -LiteralPath $customDir -PathType Container)) {
            $customFiles = @(Get-ChildItem -LiteralPath $customDir -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
            if ($customFiles -and $customFiles.Count -gt 0) {
                $allFiles += $customFiles
            }
        }
    }

    if ($allFiles.Count -eq 0) {
        return @()
    }

    return $allFiles |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name     = $_.Name
                FullPath = $_.FullName
            }
        }
}

function Run-Automation {
    param([Parameter(Mandatory = $true)][string]$AutomationPath)

    if (-not (Test-Path -LiteralPath $AutomationPath -PathType Leaf)) {
        throw "Automation not found: $AutomationPath"
    }

    # Set environment variables for automations
    $utilityHubRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $env:UTILITY_HUB_ROOT = $utilityHubRoot
    $env:APP_DIR = $PSScriptRoot

    Write-Host ''
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $AutomationPath
    $exitCode = $LASTEXITCODE

    Write-Host ''
    Write-Info "Automation finished (exit code: $exitCode)"
    Write-Host ''
}


function Automations-Menu {
    while ($true) {
        Clear-Host
        Write-Heading 'Automations'
        Write-Info 'Available automations.'
        Write-Host ''

        $automations = @(Get-AutomationScripts)
        if (-not $automations -or $automations.Count -eq 0) {
            Write-Warn 'No automations found.'
            Write-Host ''
            Read-Host 'Press Enter to go back'
            return
        }

        $automation = Select-FromList -Title 'Select automation' -Items $automations -ItemLabel 'automations' -AllowQuit
        if ($null -eq $automation -or -not $automation.FullPath) { return }

        Run-Automation -AutomationPath $automation.FullPath
    }
}

function Show-Settings {
    Clear-Host
    Write-Heading 'Settings'

    Write-Info "AccountantRoot: $($Config.AccountantRoot)"

    $clients = Resolve-Clients -Config $Config
    if (-not $clients -or $clients.Count -eq 0) {
        Write-Warn 'Clients: (none configured)'
    } else {
        Write-Info "Clients ($($clients.Count)):\n"
        foreach ($c in $clients) {
            Write-Host ("- {0} -> {1}" -f $c.Name, $c.Root) -ForegroundColor Gray
        }
    }

    Write-Host ''
    if ($resolvedStaticDataFile) {
        Write-Info "Static data file: $resolvedStaticDataFile"
    } else {
        if ($defaultStaticDataFile) {
            Write-Info "Static data file: (none loaded) - create $defaultStaticDataFile or pass -StaticDataFile"
        } else {
            Write-Info "Static data file: (none loaded) - set LOCALAPPDATA or pass -StaticDataFile"
        }
    }
    Write-Info 'CLI parameters override by default; when -StaticDataFile is provided, Clients are merged.'
    Write-Host ''
    Read-Host 'Press Enter to go back'
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

Assert-Interactive

while ($true) {
    if ($script:__ShouldQuit) { break }
    Clear-Host

    Write-Heading 'Entity automation entrypoint'
    $clientCount = (Resolve-Clients -Config $Config).Count
    Write-Info "Clients: $clientCount"
    Write-Host ''

    Write-Host '[1] Browse clients (navigation preview)' -ForegroundColor Gray
    Write-Host '[2] Preview accountant (navigation preview)' -ForegroundColor Gray
    Write-Host '[3] Automations' -ForegroundColor Gray
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
            '3' { Automations-Menu }
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
