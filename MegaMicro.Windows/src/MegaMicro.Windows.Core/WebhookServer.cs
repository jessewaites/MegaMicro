using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace MegaMicro.Windows.Core;

public sealed class WebhookServer : IAsyncDisposable
{
    public const int DefaultPort = 48802;
    private const int MaximumRequestBytes = 64 * 1024;
    private readonly SessionStore store;
    private readonly int port;
    private TcpListener? listener;
    private CancellationTokenSource? shutdown;

    public WebhookServer(SessionStore store, int port = DefaultPort)
    {
        this.store = store;
        this.port = port;
    }

    public bool IsRunning => listener is not null;

    public void Start()
    {
        if (listener is not null) return;
        shutdown = new CancellationTokenSource();
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start(32);
        _ = AcceptLoopAsync(listener, shutdown.Token);
    }

    private async Task AcceptLoopAsync(TcpListener active, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var client = await active.AcceptTcpClientAsync(token).ConfigureAwait(false);
                _ = HandleAsync(client, token);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    private async Task HandleAsync(TcpClient client, CancellationToken token)
    {
        using (client)
        {
            client.ReceiveTimeout = 5000;
            client.SendTimeout = 5000;
            var stream = client.GetStream();
            var buffer = new byte[4096];
            using var request = new MemoryStream();
            int headerEnd = -1;
            int contentLength = 0;
            while (request.Length < MaximumRequestBytes)
            {
                var read = await stream.ReadAsync(buffer, token).ConfigureAwait(false);
                if (read == 0) break;
                request.Write(buffer, 0, read);
                var bytes = request.ToArray();
                if (headerEnd < 0)
                {
                    headerEnd = FindHeaderEnd(bytes);
                    if (headerEnd >= 0)
                    {
                        var headers = Encoding.ASCII.GetString(bytes, 0, headerEnd);
                        contentLength = ParseContentLength(headers);
                        if (contentLength < 0 || contentLength > MaximumRequestBytes - headerEnd - 4)
                        {
                            await RespondAsync(stream, "413 Payload Too Large", "{\"ok\":false}", token);
                            return;
                        }
                    }
                }
                if (headerEnd >= 0 && request.Length >= headerEnd + 4 + contentLength) break;
            }

            if (headerEnd < 0)
            {
                await RespondAsync(stream, "400 Bad Request", "{\"ok\":false}", token);
                return;
            }
            var all = request.ToArray();
            var head = Encoding.ASCII.GetString(all, 0, headerEnd);
            if (!IsAllowedBrowserOrigin(ReadHeader(head, "Origin")))
            {
                await RespondAsync(stream, "403 Forbidden", "{\"ok\":false,\"error\":\"browser origin rejected\"}", token);
                return;
            }
            var first = head.Split("\r\n", 2)[0].Split(' ');
            var method = first.ElementAtOrDefault(0) ?? "";
            var path = first.ElementAtOrDefault(1) ?? "";
            if (method == "GET" && path == "/health")
            {
                await RespondAsync(stream, "200 OK", "{\"ok\":true}", token);
                return;
            }
            if (method == "GET" && path == "/sessions")
            {
                await RespondAsync(stream, "200 OK", JsonSerializer.Serialize(store.Snapshot()), token);
                return;
            }
            if (method == "POST" && path == "/state")
            {
                try
                {
                    var body = all.Skip(headerEnd + 4).Take(contentLength).ToArray();
                    var report = JsonSerializer.Deserialize<StateReport>(body,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (report is null) throw new JsonException();
                    store.Apply(report);
                    await RespondAsync(stream, "200 OK", "{\"ok\":true}", token);
                }
                catch (Exception ex) when (ex is JsonException or ArgumentException)
                {
                    var message = ex is JsonException
                        ? "Request body must be valid JSON with source, state, and session fields."
                        : ex.Message;
                    await RespondAsync(stream, "400 Bad Request",
                        JsonSerializer.Serialize(new { ok = false, error = message }), token);
                }
                return;
            }
            await RespondAsync(stream, "404 Not Found", "{\"ok\":false}", token);
        }
    }

    private static int FindHeaderEnd(byte[] bytes)
    {
        for (var i = 0; i <= bytes.Length - 4; i++)
            if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10)
                return i;
        return -1;
    }

    private static int ParseContentLength(string headers)
    {
        foreach (var line in headers.Split("\r\n"))
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                return int.TryParse(line[15..].Trim(), out var value) ? value : -1;
        return 0;
    }

    private static string? ReadHeader(string headers, string name)
    {
        foreach (var line in headers.Split("\r\n"))
            if (line.StartsWith(name + ":", StringComparison.OrdinalIgnoreCase))
                return line[(name.Length + 1)..].Trim();
        return null;
    }

    public static bool IsAllowedBrowserOrigin(string? origin)
    {
        if (string.IsNullOrWhiteSpace(origin)) return true;
        if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri)) return false;
        return uri.Scheme is "http" or "https" &&
               (uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
                IPAddress.TryParse(uri.Host, out var address) && IPAddress.IsLoopback(address));
    }

    private static async Task RespondAsync(NetworkStream stream, string status, string json, CancellationToken token)
    {
        var body = Encoding.UTF8.GetBytes(json);
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, token).ConfigureAwait(false);
        await stream.WriteAsync(body, token).ConfigureAwait(false);
    }

    public ValueTask DisposeAsync()
    {
        shutdown?.Cancel();
        listener?.Stop();
        listener = null;
        shutdown?.Dispose();
        shutdown = null;
        return ValueTask.CompletedTask;
    }
}
