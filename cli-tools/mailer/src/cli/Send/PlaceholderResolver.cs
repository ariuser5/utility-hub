using System.Text.RegularExpressions;
using DCiuve.UtilityHub.Mailer.Model;

namespace DCiuve.UtilityHub.Mailer.Send;

internal static partial class PlaceholderResolver
{
    // Supports {{tokenName}} and ${tokenName} placeholders.
    [GeneratedRegex(@"\{\{\s*(?<name>[A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}|\$\{(?<name>[A-Za-z_][A-Za-z0-9_.-]*)\}", RegexOptions.Compiled)]
    private static partial Regex TokenRegex();

    public static void ResolveSubjectAndRecipients(SendParams sendParams)
    {
        sendParams.Subject = ResolveText(sendParams.Subject, sendParams.Tokens);

        if (sendParams.To is not null)
        {
            for (var i = 0; i < sendParams.To.Count; i++)
                sendParams.To[i] = ResolveText(sendParams.To[i], sendParams.Tokens);
        }

        if (sendParams.Cc is not null)
        {
            for (var i = 0; i < sendParams.Cc.Count; i++)
                sendParams.Cc[i] = ResolveText(sendParams.Cc[i], sendParams.Tokens);
        }

        if (sendParams.Bcc is not null)
        {
            for (var i = 0; i < sendParams.Bcc.Count; i++)
                sendParams.Bcc[i] = ResolveText(sendParams.Bcc[i], sendParams.Tokens);
        }
    }

    public static string ResolveText(string? value, IReadOnlyDictionary<string, string>? tokens)
    {
        if (string.IsNullOrEmpty(value))
            return value ?? string.Empty;

        var tokenMap = tokens is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(tokens, StringComparer.OrdinalIgnoreCase);

        return TokenRegex().Replace(value, match =>
        {
            var tokenName = match.Groups["name"].Value;

            if (tokenMap.TryGetValue(tokenName, out var fromParamFile))
                return fromParamFile;

            var fromEnv = Environment.GetEnvironmentVariable(tokenName);
            if (!string.IsNullOrEmpty(fromEnv))
                return fromEnv;

            return match.Value;
        });
    }
}