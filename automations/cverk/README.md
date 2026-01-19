# cverk automations

Workspace for CVERK-related automation. Pipelines will live here; the `scripts` folder holds small, reusable bricks those pipelines can call.

**Prerequisite**
- rclone (for Google Drive access)
	- Install (Windows): `winget install Rclone.Rclone`
	- Configure once: `rclone config` → create a `drive` remote (e.g., `gdrive`) → verify with `rclone lsf gdrive:`

## Editor selection (interactive todo screens)

Some pipelines open a temporary “todo” file in an editor (git-rebase style) and wait until you close it.

Editor resolution order:

1. `UTILITY_HUB_EDITOR`
2. `VISUAL`
3. `EDITOR`
4. If none are set:
	- `notepad.exe`

Wait behavior details:

- VS Code: if you set `UTILITY_HUB_EDITOR` to `code`, `--wait` is ensured automatically, so the pipeline resumes when you close the file.
- Vim/Neovim: if you set `UTILITY_HUB_EDITOR` to `vim`/`nvim`, it runs in the current terminal; the pipeline resumes when you quit the editor.
- gVim: if you set `UTILITY_HUB_EDITOR` to `gvim`, `-f` is ensured automatically (foreground), so the pipeline resumes when you close the file.
- Notepad: the default fallback; waits until the Notepad process exits (tabbed Notepad won’t resume on just closing the tab).

While the pipeline is waiting for a GUI editor to close, you can use these shortcuts in the same terminal:

- Press `c` to continue immediately using the current contents of the todo file (leaves the editor open).
- Press `q` to abort the pipeline immediately (no changes made; leaves the editor open).

Examples (PowerShell):

- For the current session: `$env:UTILITY_HUB_EDITOR = 'code --wait'`
- Persist for future shells: `setx UTILITY_HUB_EDITOR "code --wait"`
- Use Vim: `$env:UTILITY_HUB_EDITOR = 'vim'`

## Layout

- `pipelines/`: end-to-end flows for CVERK processing and distribution.
- `scripts/`: focused helpers that pipelines can compose.

## Entrypoint

Use [App-Cverk.ps1](automations/cverk/App-Cverk.ps1) as the interactive entrypoint for browsing client/accountant folders (read-only) and jumping into pipelines.

Examples:

- Default (uses the config block inside the script):
	- `./App-Cverk.ps1`

- Provide roots directly:
	- `./App-Cverk.ps1 -AccountantRoot "C:\\CVERK\\accountant" -Clients @("ClientA=C:\\CVERK\\clients\\ClientA", "gdrive:Documents/work/cverk/clienti/ClientB")`

- Provide clients as a hashtable:
	- `./App-Cverk.ps1 -Clients @{ ClientA = "C:\\CVERK\\clients\\ClientA"; ClientB = "gdrive:Documents/work/cverk/clienti/ClientB" }`

Configure roots:

- Edit `AccountantRoot` and `Clients` in the config block inside the script.
- Or pass `-AccountantRoot` / `-Clients` on the command line.

Notes:

- Each client entry can be `Alias=Path` or just `Path`.
- If no alias is provided, the alias is derived from the last path segment.
- `Path` can be a filesystem path or an rclone remote spec like `gdrive:clients/foo`.

Navigation preview commands:

Navigation preview controls (in the preview window):

- Up/Down: move selection
- Right/Enter: enter selected folder (or `../`)
- Left/Backspace: go up
- `q` or Esc: quit preview

Implementation: the preview UI is shared and lives in [automations/utils/Preview.ps1](automations/utils/Preview.ps1).

## Scripts

### Archive-GDriveFolderByLabel.ps1

Creates one archive per label for top-level files in a Google Drive folder (labels like `[INVOICE] file.pdf`) and uploads the archives back to Google Drive.

Examples:

- Create ZIP archives under `<FolderPath>/archives`:
	- `./scripts/Archive-GDriveFolderByLabel.ps1 -FolderPath "clients/acme/inbox"`
- Use 7z:
	- `./scripts/Archive-GDriveFolderByLabel.ps1 -FolderPath "clients/acme/inbox" -ArchiveExtension 7z`
- Use tar.gz and upload elsewhere:
	- `./scripts/Archive-GDriveFolderByLabel.ps1 -FolderPath "clients/acme/inbox" -ArchiveExtension tar.gz -ArchiveDestinationPath "clients/acme/archives"`
