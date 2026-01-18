namespace DCiuve.UtilityHub.Mailer.Model;

internal sealed class SendParams
{
    public List<string>? To { get; set; }
    public List<string>? Cc { get; set; }
    public List<string>? Bcc { get; set; }
    public string? Subject { get; set; }
    public string? Body { get; set; }
    public string? BodyFile { get; set; }
    public List<string>? Attachments { get; set; }
    public bool? IsHtml { get; set; }
}
