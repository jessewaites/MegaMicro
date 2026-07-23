using System.Text;
using System.Text.Json;
using MegaMicro.Windows.Core;

var provider = ValueAfter("--provider") ?? "generic";
var eventName = ValueAfter("--event") ?? "";
var port = int.TryParse(ValueAfter("--port"), out var parsedPort) ? parsedPort : WebhookServer.DefaultPort;
var dryRun = args.Contains("--dry-run-report", StringComparer.Ordinal);
var input = await Console.In.ReadToEndAsync();
using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(input) ? "{}" : input);
var report = BridgeNormalizer.Normalize(document.RootElement, provider, eventName);

if (dryRun)
{
    Console.Write(JsonSerializer.Serialize(report, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    return;
}

try
{
    using var client = new HttpClient { Timeout = TimeSpan.FromMilliseconds(750) };
    var json = JsonSerializer.Serialize(report,
        new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
    using var content = new StringContent(json, Encoding.UTF8, "application/json");
    await client.PostAsync($"http://127.0.0.1:{port}/state", content);
}
catch { /* Provider hooks must remain fail-open. */ }
Console.WriteLine("{}");

string? ValueAfter(string name)
{
    var index = Array.IndexOf(args, name);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
}
