# utility-hub: New Client Monthly Report params (example)
#
# Save a copy to:
#   %LOCALAPPDATA%\utility-hub\data\entity\New-ClientMonthlyReport.psd1
# or just run the curated automation from App-Main and it will create it for you.
#
# Commands (rebase-like):
#   - Set _Command = 'abort' to exit without running
#   - Set _Command = 'reset' to regenerate defaults and reopen
#
# Notes:
#   - DirectoryPath must be the REMOTE path only (no 'gdrive:' prefix).
#   - The pipeline constructs RemoteSpec as: <RemoteName>:<DirectoryPath>

@{
    _Command       = $null
    RemoteName     = 'gdrive'
    DirectoryPath  = 'path/on/drive/where/month/folders/live'
    StartYear      = 2026
    NewFolderPrefix = '_'
}
