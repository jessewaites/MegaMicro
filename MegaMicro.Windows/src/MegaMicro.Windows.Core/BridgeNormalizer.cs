using System.Text.Json;

namespace MegaMicro.Windows.Core;

public static class BridgeNormalizer
{
    public static StateReport Normalize(JsonElement root, string provider, string eventName)
    {
        var eventValue = string.IsNullOrWhiteSpace(eventName) ? Read(root, "hook_event_name", "event", "type") ?? "" : eventName;
        var lower = eventValue.ToLowerInvariant();
        var tool = (Read(root, "tool_name", "toolName") ?? "").ToLowerInvariant();
        var state = lower.Contains("failure") || lower.Contains("error") || Read(root, "error", "error_message") is not null ? "error"
            : lower.Contains("permission") || lower.Contains("elicitation") || tool is "ask_question" or "askuserquestion" or "ask_user" ? "waiting"
            : lower.Contains("pretool") || lower.Contains("beforetool") || lower.Contains("afterfileedit") ? "coding"
            : lower.Contains("stop") || lower.Contains("taskcompleted") ? "success"
            : lower.Contains("sessionend") || lower == "session.idle" ? "idle"
            : "thinking";
        var normalizedProvider = provider.ToLowerInvariant() switch { "claude" => "claude-code", _ => provider.ToLowerInvariant() };
        var session = Read(root, "session_id", "sessionId", "conversationId") ?? $"{normalizedProvider}-{Environment.ProcessId}";
        return new StateReport(normalizedProvider, state, session,
            Read(root, "cwd", "working_dir", "working_directory"),
            Read(root, "agent_type", "agentType", "agent_name"),
            Read(root, "parent_session_id", "parentSessionId"),
            Read(root, "model", "model_id", "modelId"),
            Read(root, "task_name", "taskName", "task_title"));
    }

    private static string? Read(JsonElement root, params string[] names)
    {
        foreach (var name in names)
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(value.GetString()))
                return value.GetString();
        return null;
    }
}
