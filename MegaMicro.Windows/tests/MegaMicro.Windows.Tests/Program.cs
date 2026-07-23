using System.Text;
using System.Text.Json;
using MegaMicro.Windows.Core;

var tests = new List<(string Name, Func<Task> Run)>
{
    ("state parsing", () =>
    {
        Check(SessionStore.TryParseState("waiting", out var state) && state == AgentState.Waiting, "waiting state");
        Check(!SessionStore.TryParseState("unknown", out _), "unknown rejected");
        return Task.CompletedTask;
    }),
    ("session replacement", () =>
    {
        var store = new SessionStore();
        store.Apply(new("codex", "thinking", "one", "C:\\repo"));
        store.Apply(new("codex", "coding", "one", "C:\\repo"));
        Check(store.Snapshot().Count == 1 && store.Snapshot()[0].State == AgentState.Coding, "session updated");
        return Task.CompletedTask;
    }),
    ("bridge normalization", () =>
    {
        using var doc = JsonDocument.Parse("{\"session_id\":\"abc\",\"cwd\":\"C:\\\\repo\"}");
        var report = BridgeNormalizer.Normalize(doc.RootElement, "codex", "PreToolUse");
        Check(report.State == "coding" && report.Session == "abc", "pre-tool coding state");
        return Task.CompletedTask;
    }),
    ("loopback webhook", async () =>
    {
        var store = new SessionStore();
        await using var server = new WebhookServer(store, 48812);
        server.Start();
        using var client = new HttpClient();
        using var content = new StringContent(
            "{\"source\":\"test\",\"state\":\"success\",\"session\":\"one\",\"cwd\":\"C:\\\\repo\"}",
            Encoding.UTF8, "application/json");
        var response = await client.PostAsync("http://127.0.0.1:48812/state", content);
        Check(response.IsSuccessStatusCode, "POST accepted");
        Check(store.Snapshot().Single().State == AgentState.Success, "stored success");
    }),
};

var failures = 0;
foreach (var test in tests)
{
    try { await test.Run(); Console.WriteLine($"PASS {test.Name}"); }
    catch (Exception ex) { failures++; Console.Error.WriteLine($"FAIL {test.Name}: {ex.Message}"); }
}
Console.WriteLine($"{tests.Count - failures}/{tests.Count} tests passed");
return failures == 0 ? 0 : 1;

static void Check(bool value, string message)
{
    if (!value) throw new InvalidOperationException(message);
}
