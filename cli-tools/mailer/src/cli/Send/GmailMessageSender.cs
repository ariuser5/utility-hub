using Google.Apis.Gmail.v1;
using Google.Apis.Gmail.v1.Data;
using MimeKit;
using DCiuve.UtilityHub.Mailer.Gmail;
using DCiuve.UtilityHub.Mailer.Model;

namespace DCiuve.UtilityHub.Mailer.Send;

internal static class GmailMessageSender
{
    public static async Task<string> SendAsync(GmailService service, SendParams sendParams, bool createDraft, CancellationToken cancellationToken)
    {
        var fromEmail = await GmailBroker.GetAuthenticatedEmailAsync(service, cancellationToken).ConfigureAwait(false);
        var (body, isHtml) = SendParamsValidator.ResolveBodyOrThrow(sendParams);

        var message = new MimeMessage();
        message.From.Add(MailboxAddress.Parse(fromEmail));
        foreach (var to in sendParams.To ?? []) message.To.Add(MailboxAddress.Parse(to));
        foreach (var cc in sendParams.Cc ?? []) message.Cc.Add(MailboxAddress.Parse(cc));
        foreach (var bcc in sendParams.Bcc ?? []) message.Bcc.Add(MailboxAddress.Parse(bcc));
        message.Subject = sendParams.Subject ?? string.Empty;

        var builder = new BodyBuilder();
        if (isHtml) builder.HtmlBody = body; else builder.TextBody = body;

        if (sendParams.Attachments is not null)
        {
            foreach (var attachment in sendParams.Attachments)
                builder.Attachments.Add(attachment);
        }

        message.Body = builder.ToMessageBody();

        using var mimeStream = new MemoryStream();
        await message.WriteToAsync(mimeStream, cancellationToken).ConfigureAwait(false);
        var raw = Base64UrlEncode(mimeStream.ToArray());

        var gmailMessage = new Message { Raw = raw };
        if (createDraft)
        {
            var draft = new Draft { Message = gmailMessage };
            var response = await service.Users.Drafts.Create(draft, "me").ExecuteAsync(cancellationToken).ConfigureAwait(false);
            return response.Id ?? response.Message?.Id ?? string.Empty;
        }

        var sendResponse = await service.Users.Messages.Send(gmailMessage, "me").ExecuteAsync(cancellationToken).ConfigureAwait(false);
        return sendResponse.Id ?? string.Empty;
    }

    private static string Base64UrlEncode(byte[] bytes)
    {
        var base64 = Convert.ToBase64String(bytes);
        return base64.Replace("+", "-").Replace("/", "_").TrimEnd('=');
    }
}
