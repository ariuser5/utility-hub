# -----------------------------------------------------------------------------
# Get-LastMonth.ps1
# -----------------------------------------------------------------------------
# Returns the latest month-pattern value from input values.
#
# Input format: optional underscore(s) + month + dash + year
#   [_]mon-YYYY
#
# Examples:
#   .\Get-LastMonth.ps1 -Values @("jan-2026", "_apr-2026")
#   .\Get-LastMonth.ps1 -Values @("jan-2026", "invalid", "_apr-2026") -SkipInvalid
# -----------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Values,

    [Parameter()]
    [switch]$SkipInvalid
)

$months = @("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")

$monthItems = @()
foreach ($value in $Values) {
    $cleanValue = ($value ?? '').ToString().TrimEnd('/')

    if ($cleanValue -match '^(_*)([a-z]{3})-(\d{4})$') {
        $prefix = $matches[1]
        $monthName = $matches[2]
        $year = [int]$matches[3]

        $monthIdx = $months.IndexOf($monthName.ToLower())
        if ($monthIdx -ge 0) {
            $monthItems += [PSCustomObject]@{
                Value = $cleanValue
                Year = $year
                Month = $monthIdx
                Prefix = $prefix
            }
        }
        elseif (-not $SkipInvalid) {
            throw "Invalid month name in value '$cleanValue'. Expected format: [_]mon-YYYY where mon is jan-dec."
        }
    }
    elseif (-not $SkipInvalid) {
        throw "Invalid format: '$cleanValue'. Expected format: [_]mon-YYYY (e.g., 'jan-2026', '_apr-2026')."
    }
}

if ($monthItems.Count -eq 0) {
    return $null
}

$sorted = $monthItems | Sort-Object -Property @{Expression = { $_.Year }; Descending = $true }, @{Expression = { $_.Month }; Descending = $true }
return $sorted[0].Value
