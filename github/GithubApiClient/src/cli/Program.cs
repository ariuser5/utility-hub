using System.Net.Http.Headers;
using System.Text.Json;

using var client = new HttpClient();
client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("DotNetApp", "1.0"));

Console.Write("Enter GitHub username: ");
var username = Console.ReadLine();
Console.Write("Enter repository (owner/repo): ");
var repo = Console.ReadLine();

// Fetch commits by user
var commitsUrl = $"https://api.github.com/repos/{repo}/commits?author={username}";
var commitsResponse = await client.GetAsync(commitsUrl);
if (commitsResponse.IsSuccessStatusCode)
{
    var commitsContent = await commitsResponse.Content.ReadAsStringAsync();
    var commits = JsonDocument.Parse(commitsContent).RootElement;
    Console.WriteLine($"\nCommits by {username} in {repo}:");
    foreach (var commit in commits.EnumerateArray())
    {
        var sha = commit.GetProperty("sha").GetString();
        var message = commit.GetProperty("commit").GetProperty("message").GetString();
        Console.WriteLine($"- {sha}: {message}");
    }
}
else
{
    Console.WriteLine($"Error fetching commits: {commitsResponse.StatusCode}");
}

// Fetch PRs opened by user
var prsUrl = $"https://api.github.com/search/issues?q=type:pr+repo:{repo}+author:{username}";
var prsResponse = await client.GetAsync(prsUrl);
if (prsResponse.IsSuccessStatusCode)
{
    var prsContent = await prsResponse.Content.ReadAsStringAsync();
    var prs = JsonDocument.Parse(prsContent).RootElement;
    Console.WriteLine($"\nPull Requests opened by {username} in {repo}:");
    foreach (var pr in prs.GetProperty("items").EnumerateArray())
    {
        var title = pr.GetProperty("title").GetString();
        var urlPr = pr.GetProperty("html_url").GetString();
        Console.WriteLine($"- {title}: {urlPr}");
    }
}
else
{
    Console.WriteLine($"Error fetching PRs: {prsResponse.StatusCode}");
}

// Note: Fetching reviews by a user is more complex and requires iterating PRs and checking each one's reviews.
