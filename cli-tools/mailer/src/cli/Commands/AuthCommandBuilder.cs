using System.CommandLine;
using System.CommandLine.Invocation;
using DCiuve.UtilityHub.Mailer.Gmail;

namespace DCiuve.UtilityHub.Mailer.Commands;

internal static class AuthCommandBuilder
{
    public static Command Build(Option<string?> credentialsOption)
    {
        var authCommand = new Command("auth", "Authenticate (OAuth) and cache tokens locally.")
        {
            credentialsOption,
        };

        authCommand.SetHandler(async (InvocationContext ctx) =>
        {
            var parse = ctx.ParseResult;
            var credentialsSpecified = parse.FindResultFor(credentialsOption) is not null;
            var credentialsPath = parse.GetValueForOption(credentialsOption);
            ctx.ExitCode = await RunAuthAsync(credentialsPath, credentialsSpecified).ConfigureAwait(false);
        });

        return authCommand;
    }

    private static async Task<int> RunAuthAsync(string? credentialsPath, bool credentialsSpecified)
    {
        using var cts = new CancellationTokenSource(MailerConstants.AuthTimeout);

        try
        {
            var credential = await GmailBroker.AuthenticateAsync(credentialsPath, credentialsSpecified, cts.Token).ConfigureAwait(false);
            var gmail = GmailBroker.CreateGmailService(credential);
            var email = await GmailBroker.GetAuthenticatedEmailAsync(gmail, cts.Token).ConfigureAwait(false);

            Console.WriteLine($"Authenticated as: {email}");
            Console.WriteLine($"Token cache: {MailerPaths.GetTokenStoreDirectory()}");
            return 0;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Authentication timed out after 5 minutes.");
            return 3;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }
}
