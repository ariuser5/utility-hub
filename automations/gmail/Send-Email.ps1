<#
-------------------------------------------------------------------------------
Send-Email.ps1
-------------------------------------------------------------------------------
Sends a quick email using the utility-hub Mailer CLI.

This script is intended to be called by an orchestrator script.
For privacy, email parameters are NOT passed as script params; instead they are
read from a JSON config file.

Config source:
  - filesystem (default): reads JSON from local disk
  - gdrive: downloads JSON via rclone from a remote path (remote:path/file.json)
           into a temp folder, reads it, then deletes it

Supports PowerShell -WhatIf (dry-run):
  - Skips network calls (no rclone download)
  - Skips sending the email (no mailer invocation)

Usage examples:
  # Local config
  .\Send-Email.ps1 -ConfigUrl "C:\secrets\email.json"

  # GDrive config
  .\Send-Email.ps1 -UrlType gdrive -ConfigUrl "gdrive:Private/configs/email.json"

  # Dry-run (no network calls, no send)
  .\Send-Email.ps1 -UrlType gdrive -ConfigUrl "gdrive:Private/configs/email.json" -WhatIf

JSON schema (case-insensitive keys):
  {
    "to": ["a@b.com"],
    "cc": [],
    "bcc": [],
    "subject": "Hi",
    "body": "Hello" ,
    "bodyFile": "C:/path/to/body.txt",
    "attachments": ["C:/path/to/file.pdf"],
    "isHtml": false
  }
Notes:
  - Specify either body OR bodyFile (mutually exclusive)
  - bodyFile currently supports local paths only
-------------------------------------------------------------------------------
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigUrl,

    [ValidateSet('filesystem', 'gdrive')]
    [string]$UrlType = 'filesystem',

    # Optional override to use a different Mailer build.
    # Default matches installer: %LOCALAPPDATA%\utility-hub\mailer\bin\mailer.exe
    [string]$MailerExe = (Join-Path (Join-Path $env:LOCALAPPDATA 'utility-hub\mailer') 'bin\mailer.exe'),

    # Optional credentials file override for mailer.
    # This is a file path, not a secret value.
    [System.IO.FileInfo]$CredentialsFile,

    # Bypass interactive confirmation (for non-interactive orchestrators).
    [switch]$Force,

    # Preview mode:
    # - masked (default): masks recipients/subject/body preview
    # - full: shows full recipients/subject/body preview (may leak to logs)
    # - none: prints no preview
    [ValidateSet('masked', 'full', 'none')]
    [string]$PreviewMode = 'masked',

    # Max number of body characters to show in preview (default: 200).
    [ValidateRange(0, 20000)]
    [int]$PreviewBodyChars = 200
)

$ErrorActionPreference = 'Stop'

function Resolve-MailerCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferredPath
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path $PreferredPath -PathType Leaf)) {
        return $PreferredPath
    }

    $cmd = Get-Command mailer -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Path
    }

    throw "Mailer executable not found. Provide -MailerExe, or install mailer so 'mailer' is on PATH. Tried: $PreferredPath"
}

function Read-JsonFileStrict {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "JSON config file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    try {
        return $raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse JSON config (must be strict JSON; no comments/trailing commas): $Path. Error: $($_.Exception.Message)"
    }
}

function Test-EmailConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ConfigFilePath
    )

    if ($null -eq $Config) {
        throw "Config object is null (file: $ConfigFilePath)"
    }

    $hasTo = $null -ne $Config.to -and @($Config.to).Count -gt 0
    if (-not $hasTo) {
        throw "Config must include a non-empty 'to' array (file: $ConfigFilePath)"
    }

    if ([string]::IsNullOrWhiteSpace($Config.subject)) {
        throw "Config must include 'subject' (file: $ConfigFilePath)"
    }

    $hasBody = -not [string]::IsNullOrWhiteSpace($Config.body)
    $hasBodyFile = -not [string]::IsNullOrWhiteSpace($Config.bodyFile)

    if ($hasBody -and $hasBodyFile) {
        throw "Config must specify only one of 'body' or 'bodyFile' (file: $ConfigFilePath)"
    }

    if (-not $hasBody -and -not $hasBodyFile) {
        throw "Config must specify either 'body' or 'bodyFile' (file: $ConfigFilePath)"
    }

    if ($hasBodyFile) {
        # Local-path only (per requirement)
        # Reject remote-like values (e.g. gdrive:...), but allow Windows drive paths (C:\..., C:/...)
        if ($Config.bodyFile -match '^[A-Za-z][A-Za-z0-9_-]*:' -and $Config.bodyFile -notmatch '^[A-Za-z]:[\\/]') {
            throw "'bodyFile' must be a local filesystem path (not a URL/remote): '$($Config.bodyFile)' (file: $ConfigFilePath)"
        }
        if (-not (Test-Path -LiteralPath $Config.bodyFile -PathType Leaf)) {
            throw "'bodyFile' not found on disk: $($Config.bodyFile) (file: $ConfigFilePath)"
        }
    }

    if ($null -ne $Config.attachments) {
        foreach ($attachment in @($Config.attachments)) {
            if ([string]::IsNullOrWhiteSpace($attachment)) {
                continue
            }
            if (-not (Test-Path -LiteralPath $attachment -PathType Leaf)) {
                throw "Attachment not found on disk: $attachment (file: $ConfigFilePath)"
            }
        }
    }
}

function Get-BodyPreview {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    if ($MaxChars -le 0) {
        return ""
    }

    $bodyText = $null
    if ($null -ne $Config.body -and -not [string]::IsNullOrWhiteSpace([string]$Config.body)) {
        if ($Config.body -is [System.Collections.IEnumerable] -and -not ($Config.body -is [string])) {
            $bodyText = (@($Config.body) | ForEach-Object { [string]$_ }) -join "`r`n"
        } else {
            $bodyText = [string]$Config.body
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Config.bodyFile)) {
        $bodyText = Get-Content -LiteralPath $Config.bodyFile -Raw -Encoding utf8
    }

    if ($null -eq $bodyText) {
        return ""
    }

    # Some configs may store newlines as literal escape sequences ("\n" / "\r\n").
    # Interpret those for preview rendering.
    $bodyText = $bodyText -replace "\\r\\n", "`r`n"
    $bodyText = $bodyText -replace "\\n", "`r`n"
    $bodyText = $bodyText -replace "\\r", "`r`n"

    # Normalize all newline variants to CRLF for correct rendering on Windows consoles.
    $bodyText = $bodyText -replace "\r\n|\n|\r", "`r`n"
    if ($bodyText.Length -le $MaxChars) {
        return $bodyText
    }
    return $bodyText.Substring(0, $MaxChars) + "…"
}

function ConvertTo-RedactedPreview {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Text
    )

    # Redaction strategy:
    # - For each line, reveal 1-3 words from the start.
    # - Then walk through the remaining words, revealing 1-3 words occasionally,
    #   masking the rest with '*'.
    # This gives a recognizable shape without leaking full content.

    $normalizedText = $null
    if ($Text -is [System.Collections.IEnumerable] -and -not ($Text -is [string])) {
        $normalizedText = (@($Text) | ForEach-Object { [string]$_ }) -join "`r`n"
    } else {
        $normalizedText = [string]$Text
    }

    $linesList = New-Object System.Collections.Generic.List[string]
    $reader = New-Object System.IO.StringReader($normalizedText)
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) {
            break
        }
        $linesList.Add($line)
    }
    $lines = $linesList.ToArray()
    $outLines = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $line
            continue
        }

        # Tokenize on whitespace; treat tokens as "words".
        $words = @($line -split "\s+" | Where-Object { $_ -ne '' })
        if ($words.Count -eq 0) {
            $line
            continue
        }

        $revealStart = [Math]::Min((Get-Random -Minimum 1 -Maximum 4), $words.Count)
        $result = New-Object System.Collections.Generic.List[string]

        for ($i = 0; $i -lt $words.Count; $i++) {
            if ($i -lt $revealStart) {
                $result.Add($words[$i])
                continue
            }

            # After the start, reveal a small chunk occasionally.
            # Mask length and reveal length are randomized to avoid leaking patterns.
            $maskRun = Get-Random -Minimum 2 -Maximum 15
            for ($m = 0; $m -lt $maskRun -and $i -lt $words.Count; $m++) {
                $result.Add('*')
                $i++
            }
            if ($i -ge $words.Count) {
                break
            }
            $i--

            $revealRun = Get-Random -Minimum 1 -Maximum 4
            for ($r = 0; $r -lt $revealRun -and $i -lt $words.Count; $r++) {
                $result.Add($words[$i])
                $i++
            }
            $i--
        }

        ($result -join ' ')
    }

    return $outLines
}

function Get-MaskedEmailAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email
    )

    $trimmed = $Email.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or -not $trimmed.Contains('@')) {
        return $Email
    }

    $parts = $trimmed.Split('@', 2)
    $user = $parts[0]
    $domain = $parts[1]

    # Username: show first 2-3 chars + last char
    if ($user.Length -le 1) {
        $maskedUser = '*'
    } elseif ($user.Length -eq 2) {
        $maskedUser = $user.Substring(0, 1) + '*'
    } else {
        $prefixLen = [Math]::Min((Get-Random -Minimum 2 -Maximum 4), $user.Length - 1)
        $maskedUser = $user.Substring(0, $prefixLen) + ('*' * [Math]::Max(1, $user.Length - $prefixLen - 1)) + $user.Substring($user.Length - 1, 1)
    }

    # Domain: show first 2 chars of first label + full TLD (e.g. .com / .ro)
    $labels = @($domain -split '\.')
    if ($labels.Count -lt 2) {
        $domainPrefix = $domain
        $tld = ''
    } else {
        # Heuristic for compound TLDs (e.g. co.uk)
        if ($labels.Count -ge 3 -and $labels[-1].Length -le 3 -and $labels[-2].Length -le 3) {
            $tld = '.' + $labels[-2] + '.' + $labels[-1]
        } else {
            $tld = '.' + $labels[-1]
        }
        $domainPrefix = $labels[0]
    }

    $domainPrefixShown = if ($domainPrefix.Length -le 2) { $domainPrefix } else { $domainPrefix.Substring(0, 2) }
    $maskedDomain = $domainPrefixShown + ('*' * 3) + $tld

    return "$maskedUser@$maskedDomain"
}

function Get-MaskedSubject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    $s = $Subject
    if ([string]::IsNullOrWhiteSpace($s)) {
        return $s
    }

    $words = @($s -split '\s+' | Where-Object { $_ -ne '' })
    if ($words.Count -eq 0) {
        return $s
    }

    $maskedWords = New-Object System.Collections.Generic.List[string]

    for ($w = 0; $w -lt $words.Count; $w++) {
        $word = [string]$words[$w]

        if ($w -eq 0) {
            # First word: show a few chars from the start
            $show = [Math]::Min((Get-Random -Minimum 3 -Maximum 6), $word.Length)
            $maskedWords.Add($word.Substring(0, $show) + ('*' * [Math]::Max(0, $word.Length - $show)))
            continue
        }

        if ($word.Length -le 2) {
            $maskedWords.Add('*' * $word.Length)
            continue
        }

        # Next words: reveal two random 2-char pairs, mask the rest
        $chars = $word.ToCharArray()
        $mask = @('*') * $chars.Length

        if ($chars.Length -ge 2) {
            $maxStart = $chars.Length - 2
            $start1 = Get-Random -Minimum 0 -Maximum ($maxStart + 1)
            $start2 = Get-Random -Minimum 0 -Maximum ($maxStart + 1)
            if ([Math]::Abs($start2 - $start1) -lt 2) {
                $start2 = ($start1 + 2)
                if ($start2 -gt $maxStart) { $start2 = [Math]::Max(0, $maxStart - 2) }
            }

            $mask[$start1] = $chars[$start1]
            $mask[$start1 + 1] = $chars[$start1 + 1]
            $mask[$start2] = $chars[$start2]
            $mask[$start2 + 1] = $chars[$start2 + 1]
        }

        $maskedWords.Add(-join $mask)
    }

    return ($maskedWords -join ' ')
}

function Show-EmailPreview {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [int]$BodyChars,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeSensitive
    )

    $to = @($Config.to) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $cc = @($Config.cc) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $bcc = @($Config.bcc) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $attachments = @($Config.attachments) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    Write-Host "----------------------------------------" -ForegroundColor DarkCyan
    Write-Host "Preview" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor DarkCyan
    $toShown = if ($IncludeSensitive) { $to } else { $to | ForEach-Object { Get-MaskedEmailAddress -Email ([string]$_) } }
    Write-Host ("To:      " + ($toShown -join '; ')) -ForegroundColor Gray
    if ($cc.Count -gt 0) {
        $ccShown = if ($IncludeSensitive) { $cc } else { $cc | ForEach-Object { Get-MaskedEmailAddress -Email ([string]$_) } }
        Write-Host ("Cc:      " + ($ccShown -join '; ')) -ForegroundColor Gray
    }

    if ($bcc.Count -gt 0) {
        $bccShown = if ($IncludeSensitive) { $bcc } else { $bcc | ForEach-Object { Get-MaskedEmailAddress -Email ([string]$_) } }
        Write-Host ("Bcc:     " + ($bccShown -join '; ')) -ForegroundColor DarkYellow
    }

    $subjectShown = if ($IncludeSensitive) { [string]$Config.subject } else { Get-MaskedSubject -Subject ([string]$Config.subject) }
    Write-Host ("Subject: " + $subjectShown) -ForegroundColor Gray
    if ($null -ne $Config.isHtml) {
        Write-Host ("IsHtml:  " + [string]$Config.isHtml) -ForegroundColor Gray
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.bodyFile)) {
        Write-Host ("Body:    <from file> " + [string]$Config.bodyFile) -ForegroundColor Gray
    } else {
        Write-Host "Body:    <inline>" -ForegroundColor Gray
    }

    $preview = Get-BodyPreview -Config $Config -MaxChars $BodyChars
    if ($BodyChars -gt 0) {
        Write-Host "" 
        if ($IncludeSensitive) {
            Write-Host $preview -ForegroundColor Gray
        } else {
            $redactedLines = ConvertTo-RedactedPreview -Text $preview
            foreach ($redactedLine in $redactedLines) {
                Write-Host $redactedLine -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "" 
    if ($attachments.Count -gt 0) {
        Write-Host "Attachments:" -ForegroundColor Cyan
        foreach ($attachment in $attachments) {
            if ([string]::IsNullOrWhiteSpace($attachment)) {
                continue
            }
            $sizeBytes = $null
            try { $sizeBytes = (Get-Item -LiteralPath $attachment).Length } catch { }
            if ($null -ne $sizeBytes) {
                Write-Host ("  - " + $attachment + " (" + $sizeBytes + " bytes)") -ForegroundColor Gray
            } else {
                Write-Host ("  - " + $attachment) -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "Attachments: <none>" -ForegroundColor Gray
    }

    Write-Host "----------------------------------------" -ForegroundColor DarkCyan
    Write-Host "" 
}

function Confirm-Send {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [switch]$Bypass
    )

    if ($Bypass) {
        return
    }

    $code = Get-Random -Minimum 1000 -Maximum 10000
    $phrase = "SEND $code"

    # If we can't prompt safely, fail closed.
    $canPrompt = $true
    try {
        if ([Console]::IsInputRedirected) {
            $canPrompt = $false
        }
    } catch {
        # Some hosts don't expose Console.
    }

    if (-not $canPrompt) {
        throw "Non-interactive session detected; refusing to send without -Force. Required phrase would be '$phrase'."
    }

    Write-Host "Safety check: confirm send" -ForegroundColor Yellow
    Write-Host "You are about to send an email. A mistake here can leak sensitive information (wrong recipients, unintended attachments, etc.)." -ForegroundColor Yellow
    Write-Host "To reduce that risk, this script requires an explicit confirmation phrase before sending." -ForegroundColor Yellow
    Write-Host "If you are running this from a trusted orchestrator/non-interactive context, re-run with '-Force' to bypass the prompt." -ForegroundColor DarkYellow
    Write-Host "" 
    Write-Host ("Subject: " + $Subject) -ForegroundColor Gray
    Write-Host ("Type '" + $phrase + "' to send." ) -ForegroundColor Yellow
    Write-Host "Type 'abort' to cancel." -ForegroundColor DarkYellow

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $entered = $null
        try {
            $entered = Read-Host ("Confirm (attempt " + $attempt + "/3)")
        } catch {
            throw "Unable to prompt for confirmation; refusing to send without -Force. Required phrase would be '$phrase'."
        }

        $enteredTrimmed = if ($null -eq $entered) { '' } else { $entered.Trim() }
        if ($enteredTrimmed -ieq 'abort') {
            throw "Cancelled by user."
        }

        if ($enteredTrimmed -eq $phrase) {
            return
        }

        if ($attempt -lt 3) {
            Write-Host "Confirmation did not match. Try again or type 'abort' to cancel." -ForegroundColor Yellow
        }
    }

    throw "Confirmation phrase did not match after 3 attempts. Cancelled."
}

$tempDir = $null
$localConfigPath = $null
$configObj = $null

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Send Email" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "" 
Write-Host "Config source: $UrlType" -ForegroundColor Gray

try {
    if ($UrlType -eq 'filesystem') {
        $localConfigPath = $ConfigUrl

        Write-Host "[1/2] Reading config from filesystem..." -ForegroundColor Yellow
        $configObj = Read-JsonFileStrict -Path $localConfigPath
        Test-EmailConfig -Config $configObj -ConfigFilePath $localConfigPath
    } else {
        Write-Host "[1/2] Acquiring config from Google Drive (rclone)..." -ForegroundColor Yellow

        if (-not $PSCmdlet.ShouldProcess("rclone", "Download config '$ConfigUrl' to a temp folder")) {
            Write-Host "      -WhatIf: Skipping rclone download (no network calls)." -ForegroundColor Gray
            Write-Host "      -WhatIf: Skipping config parse/validation." -ForegroundColor Gray
            Write-Host "" 
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "✓ Dry-run complete" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            exit 0
        }

        $rclone = Get-Command rclone -ErrorAction SilentlyContinue
        if ($null -eq $rclone) {
            Write-Error "rclone not found on PATH. Install rclone or add it to PATH."
            exit 2
        }

        $tempDir = Join-Path $env:TEMP ("send-email-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $localConfigPath = Join-Path $tempDir "email-config.json"

        # copyto copies a single file remote -> local
        $rcloneArgs = @('copyto', $ConfigUrl, $localConfigPath)
        & $rclone.Path @rcloneArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "rclone failed with exit code $LASTEXITCODE"
            exit 2
        }

        $configObj = Read-JsonFileStrict -Path $localConfigPath
        Test-EmailConfig -Config $configObj -ConfigFilePath $localConfigPath
    }

    Write-Host "      ✓ Config loaded" -ForegroundColor Green
    Write-Host "" 

    if ($PreviewMode -ne 'none') {
        $includeSensitive = ($PreviewMode -eq 'full')
        Show-EmailPreview -Config $configObj -BodyChars $PreviewBodyChars -IncludeSensitive $includeSensitive
    }

    Write-Host "[2/2] Sending email using mailer..." -ForegroundColor Yellow

    $mailerPath = Resolve-MailerCommand -PreferredPath $MailerExe

    $mailerArgs = @('send', '--param-file', $localConfigPath)
    if ($null -ne $CredentialsFile -and -not [string]::IsNullOrWhiteSpace($CredentialsFile.FullName)) {
        $mailerArgs += @('--credentials', $CredentialsFile.FullName)
    }

    if (-not $PSCmdlet.ShouldProcess($mailerPath, ("send --param-file <redacted>"))) {
        Write-Host "      -WhatIf: Skipping mailer invocation." -ForegroundColor Gray
        Write-Host "" 
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "✓ Dry-run complete" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        exit 0
    }

    $subjectForConfirm = switch ($PreviewMode) {
        'full' { [string]$configObj.subject }
        'masked' { Get-MaskedSubject -Subject ([string]$configObj.subject) }
        default { '<hidden>' }
    }

    Confirm-Send -Subject $subjectForConfirm -Bypass:$Force

    & $mailerPath @mailerArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "mailer failed with exit code $LASTEXITCODE"
        exit 3
    }

    Write-Host "" 
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "✓ Email sent" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if ($UrlType -eq 'gdrive' -and $null -ne $tempDir -and (Test-Path $tempDir)) {
        try {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            # Best-effort cleanup
			Write-Host "Failed to clean up temp directory: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}
