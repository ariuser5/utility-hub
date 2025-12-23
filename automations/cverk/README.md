# cverk automations

Workspace for CVERK-related automation. Pipelines will live here; the `scripts` folder holds small, reusable bricks those pipelines can call.

**Prerequisite**
- rclone (for Google Drive access)
	- Install (Windows): `winget install Rclone.Rclone`
	- Configure once: `rclone config` → create a `drive` remote (e.g., `gdrive`) → verify with `rclone lsf gdrive:`

## Layout

- `pipelines/`: end-to-end flows for CVERK processing and distribution.
- `scripts/`: focused helpers that pipelines can compose.
