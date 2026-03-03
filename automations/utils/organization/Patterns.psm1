$MonthNames = @("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
$MonthPattern = '^(_*)([a-z]{3})-(\d{4})$'

Export-ModuleMember -Variable MonthNames, MonthPattern
