# entity automations

Workspace for entity-related automation. Pipelines will live here; the `scripts` folder holds small, reusable bricks those pipelines can call.

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

- `pipelines/`: end-to-end flows for entity processing and distribution.
- `scripts/`: focused helpers that pipelines can compose.

## Entrypoint

Use [App-Main.ps1](automations/entity/App-Main.ps1) as the interactive entrypoint for browsing client/accountant folders (read-only) and jumping into pipelines.

Automation menu source:

- `App-Main.ps1` reads commands from JSON config files (no script auto-discovery).
- Public config (tracked in repo): `automations/entity/automations.json`

Automation config schema:

- Preferred: object with `automations` array
- Also supported: top-level array
- Each item is either:
	- `alias`: string
	- `command`: string (PowerShell command executed by `pwsh -Command`)
	- OR `import`: object with:
		- `path`: string (path to another automations JSON file)

Import behavior:

- Imported automations are expanded in-place, preserving declared order.
- `import.path` can be absolute or relative (relative paths resolve from the JSON file containing the `import`).
- `import.path` supports environment-variable expansion (for example: `$env:UTILITY_HUB_ROOT\\_submodules\\automation-scripts\\scripts\\export.json`).
- If an import file is missing or invalid, it is ignored (non-breaking).
- Automation commands run with working directory set to the folder of the JSON file that declared that automation.

Example:

```json
{
	"automations": [
		{
			"alias": "label-files",
			"command": "& (Join-Path $env:APP_DIR '../utils/organization/Label-Files.ps1')"
		},
		{
			"import": {
				"path": "$env:UTILITY_HUB_ROOT\\_submodules\\automation-scripts\\scripts\\export.json"
			}
		}
	]
}
```

Examples:

- Default (loads parties config from `automations/entity/parties.json`):
	- `./App-Main.ps1`

Configure roots:

- Configure `automations/entity/parties.json` (see `samples/parties.example.json`).

Config file schema (`parties.json`):

- `import` (optional): object with:
	- `path`: string (absolute/relative path to another parties JSON; env variables supported)
- `accountants`: array of objects with:
	- `name`: string
	- `data.location`: string
- `clients`: array of objects with:
	- `name`: string
	- `data.location`: string

Notes:

- Imported parties are loaded recursively; missing/invalid imports are ignored.
- If duplicate client names exist after merge, startup fails with a duplicate-alias error.
- `data.location` can be a filesystem path or an rclone remote spec like `gdrive:clients/foo`.

Navigation preview commands:

Navigation preview controls (in the preview window):

- Up/Down: move selection
- Right/Enter: enter selected folder (or `../`)
- Left/Backspace: go up
- `q` or Esc: quit preview

Implementation: the preview UI is shared and lives in [automations/utils/Preview-Location.ps1](automations/utils/Preview-Location.ps1).

## Scripts

### Archive-FilesByLabel.ps1

Creates one archive per label for top-level files in a Google Drive folder (labels like `[INVOICE] file.pdf`) and uploads the archives back to Google Drive.

Examples:

- Create ZIP archives under `<Path>/archives`:
	- `../utils/organization/Archive-FilesByLabel.ps1 -Path "gdrive:clients/acme/inbox"`
- Use 7z:
	- `../utils/organization/Archive-FilesByLabel.ps1 -Path "gdrive:clients/acme/inbox" -ArchiveExtension 7z`
- Use tar.gz and upload elsewhere:
	- `../utils/organization/Archive-FilesByLabel.ps1 -Path "gdrive:clients/acme/inbox" -ArchiveExtension tar.gz -ArchiveDestinationPath "gdrive:clients/acme/archives"`
