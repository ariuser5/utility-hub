using System.CommandLine;
using System.CommandLine.Invocation;
using DCiuve.UtilityHub.Mailer.Gmail;
using DCiuve.UtilityHub.Mailer.Model;
using DCiuve.UtilityHub.Mailer.Send;

namespace DCiuve.UtilityHub.Mailer.Commands;

internal static class SendDraftCommandShared
{
    public static Command Build(
        string commandName,
        string description,
        Option<string?> credentialsOption,
        bool includeDraftOption,
        bool defaultDraftMode)
    {
        var command = new Command(commandName, description)
        {
            credentialsOption,
        };

        var paramFileOption = new Option<string?>(
            name: "--param-file",
            description: "Path to JSON file containing send parameters. CLI flags override file values when explicitly provided.");

        var toOption = new Option<string[]>(
            name: "--to",
            description: "Recipient email(s). Repeatable.")
        {
            AllowMultipleArgumentsPerToken = true,
        };

        var ccOption = new Option<string[]>(
            name: "--cc",
            description: "CC email(s). Repeatable.")
        {
            AllowMultipleArgumentsPerToken = true,
        };

        var bccOption = new Option<string[]>(
            name: "--bcc",
            description: "BCC email(s). Repeatable.")
        {
            AllowMultipleArgumentsPerToken = true,
        };

        var subjectOption = new Option<string?>(
            name: "--subject",
            description: "Email subject.");

        var bodyOption = new Option<string?>(
            name: "--body",
            description: "Email body (inline).");

        var bodyFileOption = new Option<string?>(
            name: "--body-file",
            description: "Path to a file containing the email body.");

        var attachOption = new Option<string[]>(
            name: "--attach",
            description: "Attachment file path(s). Repeatable.")
        {
            AllowMultipleArgumentsPerToken = true,
        };

        var isHtmlOption = new Option<bool>(
            name: "--is-html",
            description: "Treat body as HTML.");

        Option<bool>? draftOption = null;
        if (includeDraftOption)
        {
            draftOption = new Option<bool>(
                name: "--draft",
                description: "Create a draft in Gmail instead of sending immediately.");
        }

        command.AddOption(paramFileOption);
        command.AddOption(toOption);
        command.AddOption(ccOption);
        command.AddOption(bccOption);
        command.AddOption(subjectOption);
        command.AddOption(bodyOption);
        command.AddOption(bodyFileOption);
        command.AddOption(attachOption);
        command.AddOption(isHtmlOption);
        if (draftOption is not null)
            command.AddOption(draftOption);

        command.SetHandler(async (InvocationContext ctx) =>
        {
            var parse = ctx.ParseResult;

            var credentialsSpecified = parse.FindResultFor(credentialsOption) is not null;
            var credentialsPath = parse.GetValueForOption(credentialsOption);

            var paramFileSpecified = parse.FindResultFor(paramFileOption) is not null;
            var paramFilePath = parse.GetValueForOption(paramFileOption);

            if (paramFileSpecified && string.IsNullOrWhiteSpace(paramFilePath))
            {
                Console.Error.WriteLine("--param-file was provided but no path value was given.");
                ctx.ExitCode = 2;
                return;
            }

            SendParams fileParams = new();
            if (paramFileSpecified)
            {
                try
                {
                    fileParams = SendParamsJson.LoadParamFile(paramFilePath!);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(ex.Message);
                    ctx.ExitCode = 2;
                    return;
                }
            }

            var merged = SendParamsMerger.MergeParams(
                fileParams,
                subject: parse.GetValueForOption(subjectOption),
                subjectSpecified: parse.FindResultFor(subjectOption) is not null,
                body: parse.GetValueForOption(bodyOption),
                bodySpecified: parse.FindResultFor(bodyOption) is not null,
                bodyFile: parse.GetValueForOption(bodyFileOption),
                bodyFileSpecified: parse.FindResultFor(bodyFileOption) is not null,
                isHtml: parse.GetValueForOption(isHtmlOption),
                isHtmlSpecified: parse.FindResultFor(isHtmlOption) is not null,
                to: parse.GetValueForOption(toOption) ?? [],
                toSpecified: parse.FindResultFor(toOption) is not null,
                cc: parse.GetValueForOption(ccOption) ?? [],
                ccSpecified: parse.FindResultFor(ccOption) is not null,
                bcc: parse.GetValueForOption(bccOption) ?? [],
                bccSpecified: parse.FindResultFor(bccOption) is not null,
                attach: parse.GetValueForOption(attachOption) ?? [],
                attachSpecified: parse.FindResultFor(attachOption) is not null);

            var draftMode = defaultDraftMode || (draftOption is not null && parse.GetValueForOption(draftOption));

            ctx.ExitCode = await RunSendAsync(credentialsPath, credentialsSpecified, merged, draftMode).ConfigureAwait(false);
        });

        return command;
    }

    private static async Task<int> RunSendAsync(string? credentialsPath, bool credentialsSpecified, SendParams sendParams, bool createDraft)
    {
        try
        {
            SendParamsValidator.ValidateSendParamsOrThrow(sendParams);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }

        using var cts = new CancellationTokenSource(MailerConstants.AuthTimeout);

        try
        {
            var credential = await GmailBroker.AuthenticateAsync(credentialsPath, credentialsSpecified, cts.Token).ConfigureAwait(false);
            var service = GmailBroker.CreateGmailService(credential);

            var messageId = await GmailMessageSender.SendAsync(service, sendParams, createDraft, CancellationToken.None).ConfigureAwait(false);
            if (createDraft)
                Console.WriteLine($"Draft created: {messageId}. Review in Gmail Drafts.");
            else
                Console.WriteLine($"Sent message id: {messageId}");
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
