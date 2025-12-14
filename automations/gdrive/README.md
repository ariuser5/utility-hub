# Google Drive Automations

PowerShell scripts for Google Drive tasks.

> Prerequisite: Install and configure rclone before using these scripts.
>
> Quick setup:
> - Install: `winget install Rclone.Rclone`
> - Configure: `rclone config` (create a remote, e.g., `gdrive`)

## Scripts

### Archive-GDriveFolder.ps1

Archives all files from a Google Drive folder to a local ZIP file.

**Usage:**
```powershell
.\automations\gdrive\scripts\Archive-GDriveFolder.ps1 -FolderPath "MyFolder/Documents"
.\automations\gdrive\scripts\Archive-GDriveFolder.ps1 -FolderPath "Reports" -FilePattern "*.pdf" -OutputPath ".\backup.zip"
```

**Parameters:**
- `-RemoteName`: rclone remote name (default: "gdrive")
- `-FolderPath`: Path to the Google Drive folder (required)
- `-FilePattern`: File pattern to match (default: "*")
- `-OutputPath`: Local path for the archive (default: auto-generated with timestamp)

**Dependencies:**
- [rclone](https://rclone.org/) must be installed and configured
  - Install: `winget install Rclone.Rclone`
  - Configure: `rclone config` (set up Google Drive remote)

### Upload-ToGDrive.ps1

Uploads a local file to a destination folder on Google Drive.

**Usage:**
```powershell
.\automations\gdrive\scripts\Upload-ToGDrive.ps1 -DestinationPath "Backups" -LocalFilePath ".\archive.zip"
.\automations\gdrive\scripts\Upload-ToGDrive.ps1 -DestinationPath "Backups" -LocalFilePath ".\archive.zip" -Overwrite
.\automations\gdrive\scripts\Upload-ToGDrive.ps1 -DestinationPath "Backups" -LocalFilePath ".\archive.zip" -NoCreate
```

**Parameters:**
- `-RemoteName`: rclone remote name (default: "gdrive")
- `-DestinationPath`: Google Drive destination folder path (required)
- `-LocalFilePath`: Local file path to upload (required)
- `-Overwrite`: Overwrite existing file with same name (optional)
- `-NoCreate`: Suppress auto-creation of destination folder (optional)
