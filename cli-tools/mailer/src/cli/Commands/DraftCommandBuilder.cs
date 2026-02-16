using System.CommandLine;

namespace DCiuve.UtilityHub.Mailer.Commands;

internal static class DraftCommandBuilder
{
    public static Command Build(Option<string?> credentialsOption)
    {
        return SendDraftCommandShared.Build(
            commandName: "draft",
            description: "Create an email draft in Gmail.",
            credentialsOption,
            includeDraftOption: false,
            defaultDraftMode: true);
    }
}
