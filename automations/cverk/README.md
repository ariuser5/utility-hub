# cverk automations

Workspace for CVERK-related automation. Pipelines will live here; the `scripts` folder holds small, reusable bricks those pipelines can call.

**Prerequisite**
- rclone (for Google Drive access)
	- Install (Windows): `winget install Rclone.Rclone`
	- Configure once: `rclone config` → create a `drive` remote (e.g., `gdrive`) → verify with `rclone lsf gdrive:`

## Layout

- `pipelines/` (planned): end-to-end flows for CV processing and distribution.
- `scripts/`: focused helpers that pipelines can compose.

## Current bricks

- **Ensure-MonthFolder.ps1** — ensures the first missing month folder exists for a given year (e.g., `_mar-2025`).

Minimal use from repo root (PowerShell):

```powershell
./scripts/Ensure-MonthFolder.ps1 -RemoteName gdrive -DirectoryPath "/path/to/cv" -Year 2025
```

Notes: uses `rclone lsf` to detect existing months and `rclone mkdir` to create the next missing one; only creates, never modifies existing folders.
