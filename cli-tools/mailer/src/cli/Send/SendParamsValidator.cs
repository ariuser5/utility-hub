using System.Net.Mail;
using System.Text;
using DCiuve.UtilityHub.Mailer.Model;

namespace DCiuve.UtilityHub.Mailer.Send;

internal static class SendParamsValidator
{
    public static (string body, bool isHtml) ResolveBodyOrThrow(SendParams p)
    {
        var hasBody = !string.IsNullOrWhiteSpace(p.Body);
        var hasBodyFile = !string.IsNullOrWhiteSpace(p.BodyFile);

        if (hasBody && hasBodyFile)
            throw new InvalidOperationException("Both 'body' and 'bodyFile' are set. Choose only one (use --body OR --body-file, and remove the other from the param file).");

        if (!hasBody && !hasBodyFile)
            throw new InvalidOperationException("Missing body. Provide --body or --body-file, or set 'body'/'bodyFile' in --param-file.");

        var isHtml = p.IsHtml ?? false;

        if (hasBody)
            return (p.Body!, isHtml);

        var path = p.BodyFile!;
        if (!File.Exists(path))
            throw new FileNotFoundException($"bodyFile does not exist: {path}");

        var body = File.ReadAllText(path, Encoding.UTF8);
        return (body, isHtml);
    }

    public static void ValidateSendParamsOrThrow(SendParams p)
    {
        if (p.To is null || p.To.Count == 0)
            throw new InvalidOperationException("Missing recipients. Provide --to or set 'to' in --param-file.");

        ValidateEmailList("to", p.To);

        if (p.Cc is not null) ValidateEmailList("cc", p.Cc);
        if (p.Bcc is not null) ValidateEmailList("bcc", p.Bcc);

        if (string.IsNullOrWhiteSpace(p.Subject))
            throw new InvalidOperationException("Missing subject. Provide --subject or set 'subject' in --param-file.");

        _ = ResolveBodyOrThrow(p);

        if (p.Attachments is not null)
        {
            for (var i = 0; i < p.Attachments.Count; i++)
            {
                var file = p.Attachments[i];
                if (string.IsNullOrWhiteSpace(file))
                    throw new InvalidOperationException($"attachments[{i}] is empty.");
                if (!File.Exists(file))
                    throw new FileNotFoundException($"Attachment does not exist: {file}");
            }
        }
    }

    private static void ValidateEmailList(string fieldName, IReadOnlyList<string> values)
    {
        for (var i = 0; i < values.Count; i++)
        {
            var value = values[i];
            try
            {
                _ = new MailAddress(value);
            }
            catch
            {
                throw new InvalidOperationException($"Invalid email in '{fieldName}[{i}]': {value}");
            }
        }
    }
}
