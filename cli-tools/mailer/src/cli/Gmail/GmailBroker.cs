using Google.Apis.Auth.OAuth2;
using Google.Apis.Gmail.v1;
using Google.Apis.Services;
using Google.Apis.Util.Store;
using DCiuve.UtilityHub.Mailer.Credentials;
using DCiuve.Gcp.Auth;

namespace DCiuve.UtilityHub.Mailer.Gmail;

internal static class GmailBroker
{
    public static async Task<UserCredential> AuthenticateAsync(
        string? credentialsOptionValue,
        bool credentialsOptionSpecified,
        CancellationToken cancellationToken)
    {
        var credentialsPath = CredentialsResolver.ResolveCredentialsPathStrict(credentialsOptionValue, credentialsOptionSpecified);
        using var stream = File.OpenRead(credentialsPath);
        var secrets = GoogleClientSecrets.FromStream(stream).Secrets;
        
        if (string.IsNullOrWhiteSpace(secrets.ClientId) || string.IsNullOrWhiteSpace(secrets.ClientSecret))
            throw new InvalidOperationException("Invalid credentials JSON: missing client_id/client_secret.");

        var tokenStore = new FileDataStore(MailerPaths.GetTokenStoreDirectory(), true);
        string[] scopes = [
            GmailService.Scope.GmailCompose,
            GmailService.Scope.GmailSend,
            GmailService.Scope.GmailMetadata
        ];

        return await Authenticator.Authenticate(
            secrets,
            scopes,
            user: "user",
            dataStore: tokenStore,
            cancellationToken: cancellationToken
        ).ConfigureAwait(false);
    }

    public static GmailService CreateGmailService(UserCredential credential)
    {
        return new(new BaseClientService.Initializer
        {
            HttpClientInitializer = credential,
            ApplicationName = MailerConstants.AppName,
        });
    }

    public static async Task<string> GetAuthenticatedEmailAsync(GmailService gmailService, CancellationToken cancellationToken)
    {
        var profile = await gmailService.Users.GetProfile("me").ExecuteAsync(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(profile.EmailAddress))
            throw new InvalidOperationException("Could not determine authenticated Gmail address.");
        return profile.EmailAddress;
    }
}
