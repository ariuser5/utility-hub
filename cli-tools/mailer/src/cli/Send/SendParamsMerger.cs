using DCiuve.UtilityHub.Mailer.Model;

namespace DCiuve.UtilityHub.Mailer.Send;

internal static class SendParamsMerger
{
    public static SendParams MergeParams(
        SendParams fileParams,
        string? subject, bool subjectSpecified,
        string? body, bool bodySpecified,
        string? bodyFile, bool bodyFileSpecified,
        bool isHtml, bool isHtmlSpecified,
        string[] to, bool toSpecified,
        string[] cc, bool ccSpecified,
        string[] bcc, bool bccSpecified,
        string[] attach, bool attachSpecified)
    {
        var merged = new SendParams
        {
            To = fileParams.To,
            Cc = fileParams.Cc,
            Bcc = fileParams.Bcc,
            Subject = fileParams.Subject,
            Body = fileParams.Body,
            BodyFile = fileParams.BodyFile,
            Attachments = fileParams.Attachments,
            IsHtml = fileParams.IsHtml,
        };

        if (subjectSpecified) merged.Subject = subject;
        if (bodySpecified) merged.Body = body;
        if (bodyFileSpecified) merged.BodyFile = bodyFile;
        if (isHtmlSpecified) merged.IsHtml = isHtml;

        if (toSpecified) merged.To = to.ToList();
        if (ccSpecified) merged.Cc = cc.ToList();
        if (bccSpecified) merged.Bcc = bcc.ToList();
        if (attachSpecified) merged.Attachments = attach.ToList();

        return merged;
    }
}
