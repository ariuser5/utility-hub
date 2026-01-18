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
            var parsed = JsonSerializer.Deserialize<SendParams>(json, options);
            if (parsed is null)
                throw new InvalidOperationException("--param-file JSON is empty or invalid.");
            return parsed;
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException($"Failed to parse --param-file JSON: {ex.Message}");
        }
    }
}
