<#
-------------------------------------------------------------------------------
Editor.psm1
-------------------------------------------------------------------------------
Shared editor launch + wait helpers (git-rebase-like flows).

Editor selection precedence:
  1) UTILITY_HUB_EDITOR
  2) VISUAL
  3) EDITOR
  4) notepad.exe (fallback)

Notes:
  - If VS Code is used, '--wait' is auto-added.
  - If gVim is used, '-f' is auto-added.
  - Terminal editors (vim/nvim/vi) run in-terminal and naturally block.
  - For GUI editors, a small wait loop supports:
      - 'c' continue now (keep editor open)
      - 'q' abort

Exported functions:
  - Invoke-UtilityHubEditor
-------------------------------------------------------------------------------
#>

function Split-UtilityHubCommandLine {
    [CmdletBinding()]
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

function Test-UtilityHubExecutableAvailable {
    [CmdletBinding()]
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

function Resolve-UtilityHubEditorCommand {
    [CmdletBinding()]
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
        $parts = Split-UtilityHubCommandLine -CommandLine $candidate
        if (-not $parts -or $parts.Count -lt 1) {
            continue
        }

        $exe = $parts[0]
        if (-not (Test-UtilityHubExecutableAvailable -Exe $exe)) {
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
            Exe          = $exe
            ArgumentList = @($editorParams + @($FilePath))
            RunInTerminal = $isTerminalEditor
        }
    }

    if ($userSpecifiedSource) {
        Write-Host "Editor from ${userSpecifiedSource} not found: ${userSpecifiedCommand}" -ForegroundColor DarkYellow
    }
    throw "No supported editor found. Set UTILITY_HUB_EDITOR/VISUAL/EDITOR to a valid editor command."
}

function Invoke-UtilityHubEditor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $cmd = Resolve-UtilityHubEditorCommand -FilePath $FilePath
    Write-Host "Opening editor: $($cmd.Exe) $($cmd.ArgumentList -join ' ')" -ForegroundColor DarkGray

    if ($cmd.RunInTerminal) {
        & $cmd.Exe @($cmd.ArgumentList)
        if ($LASTEXITCODE -ne 0) {
            throw ("Editor exited with code {0} ({1})" -f $LASTEXITCODE, $cmd.Exe)
        }
        return [pscustomobject]@{ Mode = 'closed' }
    }

    $proc = Start-Process -FilePath $cmd.Exe -ArgumentList $cmd.ArgumentList -PassThru

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
            Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Mode = 'closed' }
        }

        Start-Sleep -Milliseconds 200
    }
}

Export-ModuleMember -Function Invoke-UtilityHubEditor
