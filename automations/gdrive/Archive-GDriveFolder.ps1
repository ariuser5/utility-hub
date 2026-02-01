[CmdletBinding()]
param(
    # Base folder path (local folder or rclone remote spec, e.g. "gdrive:clients/acme/inbox").
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter()]
    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$PathType = 'Auto',

    # Optional list of file selectors (top-level basenames).
    # Each entry can be an exact name or a simple wildcard pattern using:
    #   *  = match any sequence of characters
    #   ?  = match any single character
    # All other characters (including '[' and ']') are treated literally.
    # When set, -FilePattern / -ExcludePattern are ignored.
    [string[]]$FileNames,

    # Include pattern (rclone --include)
    [string]$FilePattern = "*",

    # Optional exclude pattern (rclone --exclude)
    [string]$ExcludePattern,

    # Archive extension / format: zip (default), 7z, tar, tar.gz, tgz
    [string]$ArchiveExtension = "zip",

    # For 7z archives: executable name or full path (default: 7z)
    [string]$SevenZipExe = "7z",

    # Local output file path. If omitted, a timestamped name is generated based on -ArchiveExtension.
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

$pathModule = Join-Path $PSScriptRoot '..\utils\Path.psm1'
Import-Module $pathModule -Force

$baseInfo = $null
try {
    $baseInfo = Resolve-UtilityHubPath -Path $Path -PathType $PathType
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

function ConvertTo-ArchiveExtension {
    param([Parameter(Mandatory = $true)][string]$Ext)

    $e = $Ext.Trim()
    if ($e.StartsWith('.')) { $e = $e.TrimStart('.') }
    $e = $e.ToLowerInvariant()

    if ($e -eq 'targz') { return 'tar.gz' }
    return $e
}

function Test-ExecutableAvailable {
    param([Parameter(Mandatory = $true)][string]$Exe)

    if (-not $Exe) { return $false }

    if ($Exe -match '^[a-zA-Z]:\\' -or $Exe.Contains('\\') -or $Exe.Contains('/')) {
        return (Test-Path -LiteralPath $Exe -PathType Leaf)
    }

    return ($null -ne (Get-Command $Exe -ErrorAction SilentlyContinue))
}

function ConvertTo-SimpleWildcardRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    # Supports only:
    #   * => any sequence
    #   ? => any single char
    # Everything else is treated literally (including '[' and ']').
    $escaped = [regex]::Escape($Pattern)

    # Regex.Escape turns '*' into '\*' and '?' into '\?'
    $escaped = $escaped -replace '\\x2a', '.*'
    $escaped = $escaped -replace '\\x3f', '.'
    $escaped = $escaped -replace '\\x2A', '.*'
    $escaped = $escaped -replace '\\x3F', '.'
    $escaped = $escaped -replace '\\\*', '.*'
    $escaped = $escaped -replace '\\\?', '.'

    return '^' + $escaped + '$'
}

function New-ArchiveFile {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$InputDir,
        [Parameter(Mandatory = $true)][string]$ArchiveExt,
        [Parameter(Mandatory = $true)][string]$SevenZipExe
    )

    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
        throw "Input directory not found: $InputDir"
    }

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    $ext = ConvertTo-ArchiveExtension -Ext $ArchiveExt

    switch ($ext) {
        'zip' {
            Compress-Archive -Path (Join-Path $InputDir '*') -DestinationPath $ArchivePath -CompressionLevel Optimal
            return
        }
        '7z' {
            if (-not (Test-ExecutableAvailable -Exe $SevenZipExe)) {
                throw "7-Zip executable not found: '$SevenZipExe'. Install 7-Zip or pass -SevenZipExe with a valid path."
            }

            Push-Location $InputDir
            try {
                & $SevenZipExe a -t7z $ArchivePath . | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "7z failed with exit code $LASTEXITCODE"
                }
            } finally {
                Pop-Location
            }
            return
        }
        'tar' {
            if (-not (Test-ExecutableAvailable -Exe 'tar')) {
                throw "'tar' not found on PATH. Install tar (Windows ships bsdtar) or add it to PATH."
            }
            & tar -cf $ArchivePath -C $InputDir .
            if ($LASTEXITCODE -ne 0) {
                throw "tar failed with exit code $LASTEXITCODE"
            }
            return
        }
        'tar.gz' {
            if (-not (Test-ExecutableAvailable -Exe 'tar')) {
                throw "'tar' not found on PATH. Install tar (Windows ships bsdtar) or add it to PATH."
            }
            & tar -czf $ArchivePath -C $InputDir .
            if ($LASTEXITCODE -ne 0) {
                throw "tar failed with exit code $LASTEXITCODE"
            }
            return
        }
        'tgz' {
            if (-not (Test-ExecutableAvailable -Exe 'tar')) {
                throw "'tar' not found on PATH. Install tar (Windows ships bsdtar) or add it to PATH."
            }
            & tar -czf $ArchivePath -C $InputDir .
            if ($LASTEXITCODE -ne 0) {
                throw "tar failed with exit code $LASTEXITCODE"
            }
            return
        }
        default {
            throw "Unsupported archive extension '$ArchiveExt'. Supported: zip, 7z, tar, tar.gz, tgz"
        }
    }
}

$archiveExt = ConvertTo-ArchiveExtension -Ext $ArchiveExtension

if (-not $OutputPath -or -not $OutputPath.Trim()) {
    $OutputPath = ".\\archive_$(Get-Date -Format 'yyyyMMdd_HHmmss').$archiveExt"
}

Write-Host "Starting Google Drive archive process..." -ForegroundColor Cyan
Write-Host "  Folder: $($baseInfo.Normalized)" -ForegroundColor Gray
if ($FileNames -and $FileNames.Count -gt 0) {
    Write-Host "  FileNames: $($FileNames.Count) selector(s)" -ForegroundColor Gray
} else {
    Write-Host "  Include: $FilePattern" -ForegroundColor Gray
    if ($ExcludePattern) { Write-Host "  Exclude: $ExcludePattern" -ForegroundColor Gray }
}
Write-Host "  Format: $archiveExt" -ForegroundColor Gray
Write-Host "  Output: $OutputPath" -ForegroundColor Gray

# Create temp directory for downloads
$tempDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir | Out-Null

$filesFrom = $null

# Track created files for precise cleanup
$createdFiles = New-Object System.Collections.Generic.List[string]

try {
    Write-Host "`nListing files..." -ForegroundColor Yellow
    $remotePath = $baseInfo.Normalized

    if ($baseInfo.PathType -eq 'Remote') {
        if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
            Write-Error "rclone not found on PATH. Install it and ensure it's available in your session."
            exit 1
        }
    } else {
        if (-not (Test-Path -LiteralPath $baseInfo.LocalPath -PathType Container)) {
            throw "Input folder not found: $($baseInfo.LocalPath)"
        }
    }

    $filterArgs = @('--include', "$FilePattern")
    if ($ExcludePattern) {
        $filterArgs += @('--exclude', "$ExcludePattern")
    }

    if ($FileNames -and $FileNames.Count -gt 0) {
        $allFiles = $null
        if ($baseInfo.PathType -eq 'Remote') {
            $allFiles = rclone lsf "$remotePath" --files-only
        } else {
            $allFiles = Get-ChildItem -LiteralPath $baseInfo.LocalPath -File | Select-Object -ExpandProperty Name
        }

        $selectors = @($FileNames | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $selectors -or $selectors.Count -eq 0) {
            throw "-FileNames was provided but contained no non-empty selectors."
        }

        $selectorRegexes = @($selectors | ForEach-Object { [regex] (ConvertTo-SimpleWildcardRegex -Pattern $_) })
        $selectorMatched = @{}
        foreach ($s in $selectors) { $selectorMatched[$s] = $false }

        $matched = New-Object System.Collections.Generic.List[string]
        foreach ($f in $allFiles) {
            $name = "$f".TrimEnd("`r", "`n")
            if (-not $name) { continue }

            for ($i = 0; $i -lt $selectorRegexes.Count; $i++) {
                if ($selectorRegexes[$i].IsMatch($name)) {
                    $matched.Add($name) | Out-Null
                    $selectorMatched[$selectors[$i]] = $true
                    break
                }
            }
        }

        $files = $matched | Select-Object -Unique

        $unmatched = @($selectorMatched.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
        if ($unmatched.Count -gt 0) {
            Write-Host "Warning: some FileNames selectors matched no files:" -ForegroundColor DarkYellow
            $unmatched | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
        }
    } else {
        if ($baseInfo.PathType -eq 'Remote') {
            $files = rclone lsf "$remotePath" --files-only @filterArgs
        } else {
            # Local mode: implement include/exclude as simple wildcards over basenames.
            $includeRegex = if ($FilePattern) { [regex](ConvertTo-SimpleWildcardRegex -Pattern $FilePattern) } else { $null }
            $excludeRegex = if ($ExcludePattern) { [regex](ConvertTo-SimpleWildcardRegex -Pattern $ExcludePattern) } else { $null }
            $files = Get-ChildItem -LiteralPath $baseInfo.LocalPath -File | ForEach-Object { $_.Name } | Where-Object {
                $n = $_
                if ($includeRegex -and -not $includeRegex.IsMatch($n)) { return $false }
                if ($excludeRegex -and $excludeRegex.IsMatch($n)) { return $false }
                return $true
            }
        }
    }

    if (-not $files) {
        if ($FileNames -and $FileNames.Count -gt 0) {
            Write-Warning "No files matched -FileNames selectors."
        } else {
            Write-Warning "No files found matching pattern '$FilePattern'"
        }
        return
    }

    Write-Host "Found files:" -ForegroundColor Green
    $files | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

    Write-Host "`nDownloading files..." -ForegroundColor Yellow

    if ($baseInfo.PathType -eq 'Remote') {
        if ($FileNames -and $FileNames.Count -gt 0) {
            # Use --files-from for exact selection (robust for bracketed filenames).
            $filesFrom = Join-Path $env:TEMP ("rclone_files-from_" + [System.Guid]::NewGuid().ToString() + ".txt")
            Set-Content -LiteralPath $filesFrom -Value ($files | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -Encoding UTF8
            $createdFiles.Add($filesFrom)

            rclone copy "$remotePath" $tempDir --files-from $filesFrom --progress
        } else {
            rclone copy "$remotePath" $tempDir @filterArgs --progress
        }
    } else {
        foreach ($f in $files) {
            $src = Join-Path $baseInfo.LocalPath $f
            Copy-Item -LiteralPath $src -Destination $tempDir -Force
        }
    }

    # Record downloaded files (only files, not directories)
    Get-ChildItem -Path $tempDir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $createdFiles.Add($_.FullName)
    }

    Write-Host "`nCreating archive..." -ForegroundColor Yellow
    New-ArchiveFile -ArchivePath $OutputPath -InputDir $tempDir -ArchiveExt $archiveExt -SevenZipExe $SevenZipExe

    Write-Host "`n✓ Archive created successfully!" -ForegroundColor Green
    Write-Host "  Location: $OutputPath" -ForegroundColor Gray

    # Return the created archive path for callers
    Write-Output $OutputPath
}
catch {
    Write-Error "Archive process failed: $($_.Exception.Message)"
    throw
}
finally {
    Write-Host "`nCleaning up temp directory..." -ForegroundColor Gray
    try {
        if ($filesFrom -and (Test-Path -LiteralPath $filesFrom)) {
            Remove-Item -LiteralPath $filesFrom -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Cleanup complete." -ForegroundColor Gray
    } catch {
        Write-Host "Cleanup failed. Temp directory remains at: $tempDir" -ForegroundColor DarkYellow
    }
}

function ConvertTo-SimpleWildcardRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    # We only treat '*' and '?' as wildcards.
    # Everything else is literal (including '[' and ']').
    $escaped = [regex]::Escape($Pattern)
    $escaped = $escaped -replace '\\\*', '.*'
    $escaped = $escaped -replace '\\\?', '.'
    return '^' + $escaped + '$'
}