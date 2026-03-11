
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
- `mailer send [--param-file <path>] --to <email> [--to <email> ...] --subject <text> (--body <text> | --body-file <path>) [--cc <email> ...] [--bcc <email> ...] [--attach <path> ...] [--is-html] [--draft] [--credentials <path>]`
- If not authenticated yet, `send` triggers the same OAuth flow.

Draft
- `mailer draft [--param-file <path>] --to <email> [--to <email> ...] --subject <text> (--body <text> | --body-file <path>) [--cc <email> ...] [--bcc <email> ...] [--attach <path> ...] [--is-html] [--credentials <path>]`
- Creates a draft in your Gmail account; it does not send the email.
- Success output includes the draft id and a hint to review it in Gmail Drafts.

Param file
- `--param-file` is a JSON object with send parameters at top level plus `context`.
- Top-level send parameters: `to`, `cc`, `bcc`, `subject`, `body`/`bodyFile`, `attachments`, `isHtml`; CLI flags override file values when explicitly provided.
- `context.variables` contains placeholder values.
- Placeholder substitution applies to `subject`, `to`, `cc`, `bcc`, and body content (`body` or `bodyFile`).
- Supported placeholder syntax: `{{tokenName}}` and `${tokenName}`.
- Placeholder values are resolved in this order:
	1. `context.variables` from `--param-file`
	2. Environment variables

Example
```json
{
	"to": ["a@example.com"],
	"subject": "Something important",
	"bodyFile": "C:/temp/message.txt",
	"attachments": ["C:/temp/report.pdf"],
	"isHtml": false,
	"context": {
		"variables": {
			"customerName": "Ari",
			"orderId": "12345"
		}
	}
}
```

If the subject/body/recipient fields contain placeholders like `Hello {{customerName}}` or `${envEmail}`, values are resolved using `context.variables` first, then environment variables when a token is not present in the file.
