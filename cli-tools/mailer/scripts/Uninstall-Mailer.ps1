[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA "utility-hub\mailer"),

  [ValidateSet("User", "Machine")]
  [string] $PathScope = "User",

  [switch] $RemoveFromPath,

  [switch] $PurgeTokens
)

$ErrorActionPreference = "Stop"

function Get-NormalizedPath([string] $Path) {
  return [System.IO.Path]::GetFullPath($Path.TrimEnd('\\'))
}

function Remove-FromPath([string] $Dir, [string] $Scope) {
  $dirFull = Get-NormalizedPath $Dir
  $current = [Environment]::GetEnvironmentVariable("Path", $Scope)
  if ([string]::IsNullOrWhiteSpace($current)) { return }

  $partsRaw = $current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $parts = @()
  foreach ($p in $partsRaw) {
    $norm = Get-NormalizedPath $p
    if ($norm -ne $dirFull) { $parts += $p }
  }

  $newValue = ($parts -join ';')

  if ($Scope -eq "Machine") {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
      throw "-PathScope Machine requires an elevated (Admin) PowerShell."
    }
  }

  [Environment]::SetEnvironmentVariable("Path", $newValue, $Scope)
  Write-Host "Removed entry from $Scope PATH (if present): $dirFull"
}

$binTarget = Join-Path $InstallRoot "bin"

if ($PSCmdlet.ShouldProcess($InstallRoot, "Uninstall mailer")) {
  if ($RemoveFromPath) {
    Remove-FromPath -Dir $binTarget -Scope $PathScope
    Write-Host "Open a new terminal to pick up PATH changes."
  }

  if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    Write-Host "Removed: $InstallRoot"
  }

  if ($PurgeTokens) {
    $tokenStore = Join-Path $env:LOCALAPPDATA "utility-hub\mailer-data\token-store"
    if (Test-Path -LiteralPath $tokenStore) {
      Remove-Item -LiteralPath $tokenStore -Recurse -Force
      Write-Host "Removed token cache: $tokenStore"
    }
  }
}
