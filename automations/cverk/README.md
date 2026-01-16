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

Examples (PowerShell):

- For the current session: `$env:UTILITY_HUB_EDITOR = 'code --wait'`
- Persist for future shells: `setx UTILITY_HUB_EDITOR "code --wait"`
- Use Vim: `$env:UTILITY_HUB_EDITOR = 'vim'`

## Layout

- `pipelines/`: end-to-end flows for CVERK processing and distribution.
- `scripts/`: focused helpers that pipelines can compose.
