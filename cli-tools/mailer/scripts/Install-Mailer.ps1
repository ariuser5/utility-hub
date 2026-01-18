[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[string] $SourcePath,

	[string] $ProjectPath = (Join-Path $PSScriptRoot "..\src\cli\mailer.csproj"),

	[ValidateSet("Debug", "Release")]
	[string] $Configuration = "Release",

	[string] $InstallRoot = (Join-Path $env:LOCALAPPDATA "utility-hub\mailer"),

	[ValidateSet("User", "Machine")]
	[string] $PathScope = "User",

	[switch] $NoAddToPath
)

$ErrorActionPreference = "Stop"

function Assert-DirectoryExists([string] $Path) {
	if (-not (Test-Path -LiteralPath $Path)) {
		throw "Path does not exist: $Path"
	}
	if (-not (Get-Item -LiteralPath $Path).PSIsContainer) {
		throw "Path is not a directory: $Path"
	}
}

function Get-NormalizedPath([string] $Path) {
	return [System.IO.Path]::GetFullPath($Path.TrimEnd('\\'))
}

function Add-ToPath([string] $Dir, [string] $Scope) {
	$dirFull = Get-NormalizedPath $Dir
	$current = [Environment]::GetEnvironmentVariable("Path", $Scope)

	if ([string]::IsNullOrWhiteSpace($current)) {
		$newValue = $dirFull
	}
	else {
		$parts = $current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-NormalizedPath $_ }
		if ($parts -contains $dirFull) {
			Write-Host "PATH already contains: $dirFull"
			return
		}
		$newValue = ($current.TrimEnd(';') + ";" + $dirFull)
	}

	if ($Scope -eq "Machine") {
		$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
		if (-not $isAdmin) {
			throw "-PathScope Machine requires an elevated (Admin) PowerShell."
		}
	}

	[Environment]::SetEnvironmentVariable("Path", $newValue, $Scope)
	Write-Host "Updated $Scope PATH"
}

$resolvedSource = $null
$publishTemp = $null

if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
	$resolvedSource = Get-NormalizedPath $SourcePath
}

else {
	if (-not (Test-Path -LiteralPath $ProjectPath)) {
		throw "Project path does not exist: $ProjectPath"
	}

	$publishTemp = Join-Path $env:TEMP ("utility-hub-mailer-publish-" + [Guid]::NewGuid().ToString("N"))
	New-Item -ItemType Directory -Force -Path $publishTemp | Out-Null

	Write-Host "Publishing to: $publishTemp"
	dotnet publish $ProjectPath -c $Configuration -o $publishTemp

	$resolvedSource = $publishTemp
}


Assert-DirectoryExists $resolvedSource

$binTarget = Join-Path $InstallRoot "bin"
$authTarget = Join-Path $InstallRoot "auth"

if ($PSCmdlet.ShouldProcess($InstallRoot, "Install mailer")) {
	New-Item -ItemType Directory -Force -Path $binTarget | Out-Null
	New-Item -ItemType Directory -Force -Path $authTarget | Out-Null

	# Copy published output folder contents.
	# NOTE: -LiteralPath does not expand wildcards, so copy via pipeline.
	Get-ChildItem -LiteralPath $resolvedSource -Force | Copy-Item -Destination $binTarget -Recurse -Force

	Write-Host "Installed to: $binTarget"
	Write-Host "Credentials folder: $authTarget"
	Write-Host "Place Google OAuth Desktop credentials at: $(Join-Path $authTarget 'credentials.json')"

	if (-not $NoAddToPath) {
		Add-ToPath -Dir $binTarget -Scope $PathScope
		Write-Host "Open a new terminal to pick up PATH changes."
	}
}

if ($publishTemp -and (Test-Path -LiteralPath $publishTemp)) {
	# Best-effort cleanup.
	try { Remove-Item -LiteralPath $publishTemp -Recurse -Force } catch { }
}
