using System.CommandLine;
using DCiuve.UtilityHub.Mailer.Commands;

var root = new RootCommand("utility-hub mailer (Gmail)");

var credentialsOption = new Option<string?>(
    name: "--credentials",
    description: "Path to Google OAuth credentials JSON (Desktop app).");

var authCommand = AuthCommandBuilder.Build(credentialsOption);
var sendCommand = SendCommandBuilder.Build(credentialsOption);
var draftCommand = DraftCommandBuilder.Build(credentialsOption);

root.AddCommand(authCommand);
root.AddCommand(sendCommand);
root.AddCommand(draftCommand);

return await root.InvokeAsync(args).ConfigureAwait(false);
