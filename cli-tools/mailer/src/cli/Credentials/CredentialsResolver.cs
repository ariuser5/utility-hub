namespace DCiuve.UtilityHub.Mailer.Credentials;

internal static class CredentialsResolver
{
	public const string EnvVarName = "UTILITY_HUB_MAILER_CREDENTIALS";
	
    public static string ResolveCredentialsPathStrict(string? credentialsOptionValue, bool credentialsOptionSpecified)
    {
        // Strict selection rules (not fallbacks when a choice is made):
        // 1) If --credentials exists in args, it MUST be valid or fail.
        // 2) Else, if UTILITY_HUB_MAILER_CREDENTIALS env var is present, it MUST be valid or fail.
        // 3) Else, use installed auth/credentials.json, which MUST exist or fail.

        if (credentialsOptionSpecified)
        {
            if (string.IsNullOrWhiteSpace(credentialsOptionValue))
                throw new InvalidOperationException("--credentials was provided but no path value was given.");

            if (!File.Exists(credentialsOptionValue))
                throw new FileNotFoundException($"--credentials path does not exist: {credentialsOptionValue}");

            return credentialsOptionValue;
        }

        var envValue = Environment.GetEnvironmentVariable("EnvVarName");
        if (envValue is not null)
        {
            if (string.IsNullOrWhiteSpace(envValue))
                throw new InvalidOperationException($"Environment variable {EnvVarName} is set but empty.");

            if (!File.Exists(envValue))
                throw new FileNotFoundException($"{EnvVarName} points to a missing file: {envValue}");

            return envValue;
        }

        var installedPath = MailerPaths.GetDefaultInstalledCredentialsPath();
        if (!File.Exists(installedPath))
            throw new FileNotFoundException($"No credentials source found. Expected installed credentials at: {installedPath}");

        return installedPath;
    }
}
