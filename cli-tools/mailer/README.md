
Mailer is a small console CLI to authenticate with Gmail (OAuth2) and send emails.

Install (Windows)
- Run (publishes automatically and adds to PATH by default):
	- `./scripts/Install-Mailer.ps1`
- Or install from an existing publish folder:
	- `./scripts/Install-Mailer.ps1 -SourcePath <publish-folder>`
- Installs to `%LOCALAPPDATA%\utility-hub\mailer\bin` and creates `%LOCALAPPDATA%\utility-hub\mailer\auth`.

Credentials resolution (strict)
- If `--credentials <path>` is present: it must point to an existing file or auth fails.
- Else if `UTILITY_HUB_MAILER_CREDENTIALS` env var is set: it must point to an existing file or auth fails.
- Else: it requires `auth/credentials.json` next to the installed app (inside the install root).

Auth
- `mailer auth [--credentials <path>]`
- OAuth attempt times out after 5 minutes.

Send
- `mailer send [--credentials <path>] [--param-file <path>] --to <email> [--to <email> ...] --subject <text> (--body <text> | --body-file <path>) [--cc <email> ...] [--bcc <email> ...] [--attach <path> ...] [--is-html]`
- If not authenticated yet, `send` triggers the same OAuth flow.

Param file
- `--param-file` is a JSON object; CLI flags override values from the file.

Example
```json
{
	"to": ["a@example.com"],
	"subject": "Something important",
	"bodyFile": "C:/temp/message.txt",
	"attachments": ["C:/temp/report.pdf"],
	"isHtml": false
}
```
