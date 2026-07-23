using System.Text;
using System.Text.Json;
using MegaMicro.Windows.Core;

var tests = new List<(string Name, Func<Task> Run)>
{
    ("state parsing", () =>
    {
        Check(SessionStore.TryParseState("waiting", out var state) && state == AgentState.Waiting, "waiting state");
        Check(SessionStore.TryParseState("working", out state) && state == AgentState.Coding, "working alias");
        Check(SessionStore.TryParseState("complete", out state) && state == AgentState.Success, "complete alias");
        Check(SessionStore.TryParseState("needs_input", out state) && state == AgentState.Waiting, "needs-input alias");
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
    ("VIA report framing", () =>
    {
        var request = ViaProtocol.CreateProtocolVersionRequest(33);
        Check(request.Length == 33 && request[0] == 0 && request[1] == ViaProtocol.GetProtocolVersion,
            "Windows report ID precedes VIA command");
        Check(request.Skip(2).All(x => x == 0), "request is zero padded");
        return Task.CompletedTask;
    }),
    ("VIA version parsing", () =>
    {
        var numbered = new byte[] { 0, ViaProtocol.GetProtocolVersion, 0, 12 };
        Check(ViaProtocol.TryParseProtocolVersion(numbered, numbered.Length, out var version) && version == 12,
            "report-ID response parsed");
        var payload = new byte[] { ViaProtocol.GetProtocolVersion, 1, 2 };
        Check(ViaProtocol.TryParseProtocolVersion(payload, out version) && version == 258,
            "payload-only response parsed");
        return Task.CompletedTask;
    }),
    ("browser origin policy", () =>
    {
        Check(WebhookServer.IsAllowedBrowserOrigin(null), "non-browser callers allowed");
        Check(WebhookServer.IsAllowedBrowserOrigin("http://localhost:3000"), "localhost allowed");
        Check(WebhookServer.IsAllowedBrowserOrigin("https://127.0.0.1:5173"), "loopback allowed");
        Check(!WebhookServer.IsAllowedBrowserOrigin("https://example.com"), "remote browser rejected");
        Check(!WebhookServer.IsAllowedBrowserOrigin("not a uri"), "malformed origin rejected");
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
    ("friendly webhook aliases", async () =>
    {
        var store = new SessionStore();
        await using var server = new WebhookServer(store, 48813);
        server.Start();
        using var client = new HttpClient();
        using var content = new StringContent(
            "{\"source\":\"codex\",\"state\":\"working\",\"session\":\"friendly\"}",
            Encoding.UTF8, "application/json");
        var response = await client.PostAsync("http://127.0.0.1:48813/state", content);
        Check(response.IsSuccessStatusCode, "working alias accepted");
        Check(store.Snapshot().Single().State == AgentState.Coding, "working normalized to coding");
    }),
    ("default keymap", () =>
    {
        var configuration = BindingConfiguration.CreateDefault();
        Check(configuration.Profiles.Count == 1, "one starter profile");
        Check(configuration.ActiveProfile.Layers.Count == 3, "three layers");
        Check(configuration.ActiveProfile.Layers.All(x => x.Bindings.Count == CreatorMicroV1Layout.ControlCount), "twenty inputs per layer");
        Check(configuration.ActiveProfile.Layers[0].Bindings.Select(x => x.Position).SequenceEqual(Enumerable.Range(1, CreatorMicroV1Layout.ControlCount)),
            "physical positions are stable");
        Check(configuration.ActiveProfile.Layers[0].Bindings.Count(x => x.Kind == CreatorControlKind.Key) == 12,
            "twelve RGB mechanical keys");
        Check(configuration.ActiveProfile.Layers[0].Bindings.Count(x => x.Kind is CreatorControlKind.RollerTurn or CreatorControlKind.DialTurn) == 4,
            "four encoder directions");
        Check(configuration.ActiveProfile.Layers[0].Bindings[0].ControlName == "Roller press", "top-left control is roller press");
        Check(configuration.ActiveProfile.Layers[0].Bindings[3].ControlName == "Dial press", "top-right control is dial press");
        Check(configuration.ActiveProfile.Layers[0].Bindings[0].Trigger.DisplayName == "F13", "first default trigger");
        Check(configuration.ActiveProfile.Layers[0].Bindings[15].Trigger.DisplayName == "Ctrl + Alt + Shift + F16",
            "extended default trigger");
        return Task.CompletedTask;
    }),
    ("keymap persistence", () =>
    {
        var directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"MegaMicro-tests-{Guid.NewGuid():N}");
        var path = System.IO.Path.Combine(directory, "bindings.json");
        try
        {
            var store = new BindingConfigStore(path);
            var configuration = BindingConfiguration.CreateDefault();
            var binding = configuration.ActiveProfile.Layers[0].Bindings[0];
            binding.Label = "Open Codex";
            binding.Action = BindingActionKind.FocusCodexThenShortcut;
            binding.Output = new KeyboardGestureSpec { VirtualKey = 0x4E, Control = true };
            store.Save(configuration);
            var loaded = store.Load().ActiveProfile.Layers[0].Bindings[0];
            Check(loaded.Label == "Open Codex", "label persisted");
            Check(loaded.Action == BindingActionKind.FocusCodexThenShortcut, "action persisted");
            Check(loaded.Output.DisplayName == "Ctrl + N", "shortcut persisted");
            Check(!File.ReadAllText(path).Contains("DisplayName", StringComparison.Ordinal), "computed labels omitted from JSON");
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
        return Task.CompletedTask;
    }),
    ("v1 keymap migration", () =>
    {
        var directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"MegaMicro-migration-{Guid.NewGuid():N}");
        var path = System.IO.Path.Combine(directory, "bindings.json");
        try
        {
            var store = new BindingConfigStore(path);
            var oldConfiguration = BindingConfiguration.CreateDefault();
            oldConfiguration.Version = 1;
            foreach (var layer in oldConfiguration.Profiles.SelectMany(profile => profile.Layers))
                layer.Bindings.RemoveAll(binding => binding.Position > 16);
            store.Save(oldConfiguration);

            var migrated = store.Load();
            Check(migrated.Version == 2, "configuration version migrated");
            Check(migrated.ActiveProfile.Layers.All(layer => layer.Bindings.Count == CreatorMicroV1Layout.ControlCount),
                "encoder directions added");
            Check(migrated.ActiveProfile.Layers[0].Bindings.Single(binding => binding.Position == 20).ControlName == "Dial clockwise",
                "new physical control metadata added");
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
        return Task.CompletedTask;
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
