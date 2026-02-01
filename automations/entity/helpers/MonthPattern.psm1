# =============================================================================
# MonthPattern.psm1
# =============================================================================
# Helper module for working with month-formatted strings
# =============================================================================

<#
.FUNCTION Get-LatestMonthPattern
.DESCRIPTION
    Finds the latest month-formatted string from a list (format: [_]mon-YYYY)
    based on chronological order.
.PARAMETER Values
    Array of strings to search through (e.g., @("jan-2026", "_apr-2026", "mai-2025")).
.PARAMETER SkipInvalid
    If $true, silently skips invalid values. If $false (default), throws an exception
    when encountering invalid formats.
.OUTPUTS
    [string] The latest month-formatted string (e.g., "_apr-2026"), or $null if none found.
.EXAMPLE
    $items = @("jan-2026", "feb-2026", "_mar-2026", "_apr-2026")
    $latest = Get-LatestMonthPattern -Values $items
    # Returns: "_apr-2026"
.EXAMPLE
    $items = @("jan-2026", "invalid-item", "_apr-2026")
    $latest = Get-LatestMonthPattern -Values $items -SkipInvalid $true
    # Returns: "_apr-2026" (skips "invalid-item")
#>
function Get-LatestMonthPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Values,

        [Parameter(Mandatory = $false)]
        [bool]$SkipInvalid = $false
    )

    # Month short names mapping in order (jan..dec)
    $months = @("jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec")

    # Parse month-formatted values
    $monthItems = @()
    foreach ($value in $Values) {
        $cleanValue = ($value ?? '').ToString().TrimEnd('/')
        
        # Match pattern: optional underscore(s) + month + dash + year
        if ($cleanValue -match '^(_*)([a-z]{3})-(\d{4})$') {
            $prefix = $matches[1]
            $monthName = $matches[2]
            $year = [int]$matches[3]
            
            # Find month index
            $monthIdx = $months.IndexOf($monthName.ToLower())
            if ($monthIdx -ge 0) {
                $monthItems += [PSCustomObject]@{
                    Value = $cleanValue
                    Year = $year
                    Month = $monthIdx
                    Prefix = $prefix
                }
            } else {
                # Invalid month name
                if (-not $SkipInvalid) {
                    throw "Invalid month name in value '$cleanValue'. Expected format: [_]mon-YYYY where mon is jan-dec."
                }
            }
        } else {
            # Invalid format
            if (-not $SkipInvalid) {
                throw "Invalid format: '$cleanValue'. Expected format: [_]mon-YYYY (e.g., 'jan-2026', '_apr-2026')."
            }
        }
    }

    # If no valid month values found, return null
    if ($monthItems.Count -eq 0) {
        return $null
    }

    # Sort by year (descending), then month (descending)
    $sorted = $monthItems | Sort-Object -Property @{Expression={$_.Year}; Descending=$true}, @{Expression={$_.Month}; Descending=$true}
    
    # Return the latest value
    return $sorted[0].Value
}

Export-ModuleMember -Function Get-LatestMonthPattern
