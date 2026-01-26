# Google Drive Automations

PowerShell scripts for Google Drive tasks.

> Prerequisite: Install and configure rclone before using these scripts.
>
> Quick setup:
> - Install: `winget install Rclone.Rclone`
> - Configure: `rclone config` (create a remote, e.g., `gdrive`)

## Scripts

### Archive-GDriveFolder.ps1

Archives files from a Google Drive folder to a local archive.

**Usage:**
```powershell
.\automations\gdrive\Archive-GDriveFolder.ps1 -Path "gdrive:MyFolder/Documents"
.\automations\gdrive\Archive-GDriveFolder.ps1 -Path "gdrive:Reports" -FilePattern "*.pdf" -OutputPath ".\backup.zip"

# 7z (requires 7-Zip)
.\automations\gdrive\Archive-GDriveFolder.ps1 -Path "gdrive:Reports" -FilePattern "*.pdf" -ArchiveExtension "7z" -OutputPath ".\reports.7z"

# Files labeled like "[INVOICE] ..." (FileNames treats brackets literally; '*' is a wildcard)
.\automations\gdrive\Archive-GDriveFolder.ps1 -Path "gdrive:clients/acme/inbox" -FileNames "[INVOICE] *" -OutputPath ".\invoices.zip"
```

**Parameters:**
- `-Path`: Base folder path (local folder or rclone remote spec like `gdrive:clients/foo`) (required)
- `-PathType`: Auto|Local|Remote (default: Auto)
- `-FileNames`: Optional selectors (exact names or `*`/`?` wildcards; brackets are literal). When set, ignores `-FilePattern`/`-ExcludePattern`.
- `-FilePattern`: File pattern to match (default: "*")
- `-ExcludePattern`: Exclude pattern (optional)
- `-ArchiveExtension`: zip|7z|tar|tar.gz|tgz (default: zip)
- `-SevenZipExe`: 7-Zip executable name/path (default: `7z`)
- `-OutputPath`: Local path for the archive (default: auto-generated with timestamp)

**Dependencies:**
- [rclone](https://rclone.org/) must be installed and configured
  - Install: `winget install Rclone.Rclone`
  - Configure: `rclone config` (set up Google Drive remote)

### Upload-ToGDrive.ps1

Uploads a local file to a destination folder on Google Drive.

**Usage:**
```powershell
.\automations\gdrive\Upload-ToGDrive.ps1 -Destination "gdrive:Backups" -LocalFilePath ".\archive.zip"
.\automations\gdrive\Upload-ToGDrive.ps1 -Destination "gdrive:Backups" -LocalFilePath ".\archive.zip" -Overwrite
.\automations\gdrive\Upload-ToGDrive.ps1 -Destination "gdrive:Backups" -LocalFilePath ".\archive.zip" -NoCreate
```

**Parameters:**
- `-Destination`: Destination folder remote spec like `gdrive:Backups` (required)
- `-DestinationPathType`: Auto|Remote (default: Auto)
- `-LocalFilePath`: Local file path to upload (required)
- `-Overwrite`: Overwrite existing file with same name (optional)
- `-NoCreate`: Suppress auto-creation of destination folder (optional)
