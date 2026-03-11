using System.Text;
using System.Text.Json;
using DCiuve.UtilityHub.Mailer.Model;

namespace DCiuve.UtilityHub.Mailer.Send;

internal static class SendParamsJson
{
    public static SendParams LoadParamFile(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"--param-file does not exist: {path}");

        var json = File.ReadAllText(path, Encoding.UTF8);

        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Disallow,
            AllowTrailingCommas = false,
        };

        try
        {
            var parsed = JsonSerializer.Deserialize<ParamFileRoot>(json, options);
            if (parsed is null)
                throw new InvalidOperationException("--param-file JSON is empty or invalid.");

            return new SendParams
            {
                To = parsed.To,
                Cc = parsed.Cc,
                Bcc = parsed.Bcc,
                Subject = parsed.Subject,
                Body = parsed.Body,
                BodyFile = parsed.BodyFile,
                Attachments = parsed.Attachments,
                IsHtml = parsed.IsHtml,
                Tokens = parsed.Context?.Variables,
            };
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException($"Failed to parse --param-file JSON: {ex.Message}");
        }
    }

    private sealed class ParamFileRoot
    {
        public List<string>? To { get; set; }
        public List<string>? Cc { get; set; }
        public List<string>? Bcc { get; set; }
        public string? Subject { get; set; }
        public string? Body { get; set; }
        public string? BodyFile { get; set; }
        public List<string>? Attachments { get; set; }
        public bool? IsHtml { get; set; }
        public ParamFileContext? Context { get; set; }
    }

    private sealed class ParamFileContext
    {
        public Dictionary<string, string>? Variables { get; set; }
    }
}
