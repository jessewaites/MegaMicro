namespace MegaMicro.Windows.Core;

public enum AgentState
{
    Idle = 0,
    Success = 1,
    Thinking = 2,
    Coding = 3,
    Waiting = 4,
    Error = 5,
}

public sealed record StateReport(
    string Source,
    string State,
    string Session,
    string? Cwd = null,
    string? Agent = null,
    string? ParentSession = null,
    string? Model = null,
    string? Task = null);

public sealed record AgentSession(
    string Source,
    string Session,
    string? Cwd,
    AgentState State,
    DateTimeOffset UpdatedAt,
    string? Agent,
    string? Model,
    string? Task)
{
    public string Key => $"{Source}:{Session}";
}

public sealed class SessionStore
{
    private readonly object gate = new();
    private readonly Dictionary<string, AgentSession> sessions = new(StringComparer.Ordinal);

    public event Action? Changed;

    public IReadOnlyList<AgentSession> Snapshot()
    {
        lock (gate)
            return sessions.Values.OrderByDescending(x => x.UpdatedAt).ToArray();
    }

    public void Apply(StateReport report)
    {
        if (!TryParseState(report.State, out var state))
            throw new ArgumentException($"Unsupported state '{report.State}'.", nameof(report));
        if (string.IsNullOrWhiteSpace(report.Source) || string.IsNullOrWhiteSpace(report.Session))
            throw new ArgumentException("source and session are required", nameof(report));

        var value = new AgentSession(report.Source, report.Session, report.Cwd, state,
            DateTimeOffset.UtcNow, report.Agent, report.Model, report.Task);
        lock (gate)
        {
            sessions[value.Key] = value;
            if (sessions.Count > 256)
            {
                var oldest = sessions.Values.OrderBy(x => x.UpdatedAt).First();
                sessions.Remove(oldest.Key);
            }
        }
        Changed?.Invoke();
    }

    public static bool TryParseState(string value, out AgentState state)
    {
        state = value.Trim().ToLowerInvariant() switch
        {
            "idle" => AgentState.Idle,
            "success" or "complete" or "completed" or "done" => AgentState.Success,
            "thinking" => AgentState.Thinking,
            "coding" or "working" or "running" or "active" => AgentState.Coding,
            "waiting" or "needs_input" or "needs-input" or "attention" or "blocked" => AgentState.Waiting,
            "error" => AgentState.Error,
            _ => (AgentState)(-1),
        };
        return (int)state >= 0;
    }
}
