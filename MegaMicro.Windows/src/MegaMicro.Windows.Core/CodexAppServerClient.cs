using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;

namespace MegaMicro.Windows.Core;

public sealed record CodexTaskResult(string ThreadId, string TurnId);
public sealed record CodexStatusEvent(string Method, string Message);

public sealed class CodexAppServerClient : IAsyncDisposable
{
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly SemaphoreSlim startGate = new(1, 1);
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private Process? process;
    private Task? readerTask;
    private long nextRequestId;

    public event EventHandler<CodexStatusEvent>? StatusChanged;
    public bool IsReady { get; private set; }

    public async Task EnsureStartedAsync(CancellationToken cancellationToken = default)
    {
        if (IsReady && process is { HasExited: false }) return;
        await startGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (IsReady && process is { HasExited: false }) return;
            await StopProcessAsync().ConfigureAwait(false);

            var startInfo = new ProcessStartInfo
            {
                FileName = FindCodexExecutable(),
                Arguments = "app-server --stdio",
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start Codex app-server.");
            readerTask = ReadMessagesAsync(process, cancellationToken);
            _ = DrainErrorsAsync(process);

            await RequestAsync("initialize", new
            {
                clientInfo = new { name = "creator_command_center", title = "Creator Command Center", version = "0.2.0" },
            }, cancellationToken).ConfigureAwait(false);
            await NotifyAsync("initialized", new { }, cancellationToken).ConfigureAwait(false);
            IsReady = true;
            RaiseStatus("initialized", "Direct Codex connection ready");
        }
        catch
        {
            await StopProcessAsync().ConfigureAwait(false);
            throw;
        }
        finally
        {
            startGate.Release();
        }
    }

    public async Task<CodexTaskResult> StartTaskAsync(string instruction, string workingDirectory, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(instruction)) throw new ArgumentException("A Codex instruction is required.", nameof(instruction));
        if (!Directory.Exists(workingDirectory)) throw new DirectoryNotFoundException($"Working directory not found: {workingDirectory}");

        await EnsureStartedAsync(cancellationToken).ConfigureAwait(false);
        var threadResponse = await RequestAsync("thread/start", new
        {
            cwd = Path.GetFullPath(workingDirectory),
            approvalPolicy = "never",
            sandbox = "workspace-write",
            ephemeral = false,
        }, cancellationToken).ConfigureAwait(false);
        var threadId = threadResponse.GetProperty("thread").GetProperty("id").GetString()
            ?? throw new InvalidDataException("Codex did not return a thread id.");

        var turnResponse = await RequestAsync("turn/start", new
        {
            threadId,
            input = new[] { new { type = "text", text = instruction.Trim() } },
        }, cancellationToken).ConfigureAwait(false);
        var turnId = turnResponse.GetProperty("turn").GetProperty("id").GetString()
            ?? throw new InvalidDataException("Codex did not return a turn id.");
        RaiseStatus("turn/started", $"Codex task started ({threadId})");
        return new CodexTaskResult(threadId, turnId);
    }

    private async Task<JsonElement> RequestAsync(string method, object parameters, CancellationToken cancellationToken)
    {
        var id = Interlocked.Increment(ref nextRequestId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        try
        {
            await WriteAsync(new { method, id, @params = parameters }, cancellationToken).ConfigureAwait(false);
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            pending.TryRemove(id, out _);
        }
    }

    private Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken) =>
        WriteAsync(new { method, @params = parameters }, cancellationToken);

    private async Task WriteAsync(object message, CancellationToken cancellationToken)
    {
        var target = process is { HasExited: false } ? process : throw new InvalidOperationException("Codex app-server is not running.");
        var json = JsonSerializer.Serialize(message);
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await target.StandardInput.WriteLineAsync(json.AsMemory(), cancellationToken).ConfigureAwait(false);
            await target.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            writeGate.Release();
        }
    }

    private async Task ReadMessagesAsync(Process target, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested && await target.StandardOutput.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.TryGetProperty("id", out var idElement) && idElement.TryGetInt64(out var id))
                {
                    if (root.TryGetProperty("result", out var result) && pending.TryGetValue(id, out var success))
                        success.TrySetResult(result.Clone());
                    else if (root.TryGetProperty("error", out var error) && pending.TryGetValue(id, out var failure))
                        failure.TrySetException(new InvalidOperationException(error.TryGetProperty("message", out var message) ? message.GetString() : "Codex request failed."));
                    else if (root.TryGetProperty("method", out _))
                        await WriteAsync(new { id, error = new { code = -32601, message = "Client request is unsupported." } }, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                if (root.TryGetProperty("method", out var methodElement))
                {
                    var method = methodElement.GetString() ?? "event";
                    RaiseStatus(method, FriendlyStatus(method, root));
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            foreach (var completion in pending.Values) completion.TrySetException(ex);
            IsReady = false;
            RaiseStatus("disconnected", $"Codex connection stopped: {ex.Message}");
        }
    }

    private async Task DrainErrorsAsync(Process target)
    {
        while (await target.StandardError.ReadLineAsync().ConfigureAwait(false) is not null) { }
    }

    private static string FriendlyStatus(string method, JsonElement message) => method switch
    {
        "turn/started" => "Codex is working",
        "turn/completed" => CompletionMessage(message),
        "turn/aborted" => "Codex task was stopped",
        "item/agentMessage/delta" => "Codex is responding",
        _ when method.StartsWith("item/", StringComparison.Ordinal) => "Codex task in progress",
        _ => method,
    };

    private static string CompletionMessage(JsonElement message)
    {
        if (message.TryGetProperty("params", out var parameters) &&
            parameters.TryGetProperty("turn", out var turn) &&
            turn.TryGetProperty("status", out var status))
            return $"Codex task {status.GetString()}";
        return "Codex task completed";
    }

    private void RaiseStatus(string method, string message) => StatusChanged?.Invoke(this, new CodexStatusEvent(method, message));

    private static string FindCodexExecutable()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var bundled = Path.Combine(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe");
        return File.Exists(bundled) ? bundled : "codex";
    }

    private async Task StopProcessAsync()
    {
        IsReady = false;
        var target = process;
        process = null;
        if (target is null) return;
        try
        {
            target.StandardInput.Close();
            if (!target.HasExited && !await Task.Run(() => target.WaitForExit(1500)).ConfigureAwait(false)) target.Kill();
        }
        catch { }
        target.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        await StopProcessAsync().ConfigureAwait(false);
        if (readerTask is not null)
        {
            try { await readerTask.ConfigureAwait(false); } catch { }
        }
        startGate.Dispose();
        writeGate.Dispose();
    }
}
