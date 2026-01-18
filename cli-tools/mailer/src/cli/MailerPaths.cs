namespace DCiuve.UtilityHub.Mailer;

internal static class MailerPaths
{
    public static string GetInstallBaseDirectory()
    {
        // When installed by our script, binaries live under <InstallRoot>\bin.
        // Treat the parent as the install root so <InstallRoot>\auth is discoverable.
        var baseDir = new DirectoryInfo(AppContext.BaseDirectory);
        if (string.Equals(baseDir.Name, "bin", StringComparison.OrdinalIgnoreCase) && baseDir.Parent is not null)
            return baseDir.Parent.FullName;

        return baseDir.FullName;
    }

    public static string GetDefaultInstalledCredentialsPath()
        => Path.Combine(GetInstallBaseDirectory(), "auth", "credentials.json");

    public static string GetTokenStoreDirectory()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        // Keep tokens outside the install root so uninstall doesn't remove them by default.
        return Path.Combine(localAppData, "utility-hub", "mailer-data", "token-store");
    }
}
