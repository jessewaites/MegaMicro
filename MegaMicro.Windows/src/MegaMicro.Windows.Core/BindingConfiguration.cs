using System.Text.Json;
using System.Text.Json.Serialization;

namespace MegaMicro.Windows.Core;

public enum BindingActionKind
{
    None,
    FocusCodex,
    SendShortcut,
    FocusCodexThenShortcut,
}

public sealed record KeyboardGestureSpec
{
    public int VirtualKey { get; init; }
    public bool Control { get; init; }
    public bool Alt { get; init; }
    public bool Shift { get; init; }
    public bool Windows { get; init; }

    [JsonIgnore]
    public bool IsEmpty => VirtualKey == 0;

    [JsonIgnore]
    public string DisplayName
    {
        get
        {
            if (IsEmpty) return "Not assigned";
            var parts = new List<string>();
            if (Control) parts.Add("Ctrl");
            if (Alt) parts.Add("Alt");
            if (Shift) parts.Add("Shift");
            if (Windows) parts.Add("Win");
            parts.Add(KeyName(VirtualKey));
            return string.Join(" + ", parts);
        }
    }

    private static string KeyName(int key) => key switch
    {
        >= 0x70 and <= 0x87 => $"F{key - 0x6F}",
        >= 0x30 and <= 0x39 => ((char)key).ToString(),
        >= 0x41 and <= 0x5A => ((char)key).ToString(),
        0x0D => "Enter",
        0x1B => "Escape",
        0x20 => "Space",
        0x08 => "Backspace",
        0x09 => "Tab",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        _ => $"Key 0x{key:X2}",
    };
}

public sealed class ControlBinding
{
    public int Position { get; set; }
    public string Label { get; set; } = "Unassigned";
    public KeyboardGestureSpec Trigger { get; set; } = new();
    public BindingActionKind Action { get; set; }
    public KeyboardGestureSpec Output { get; set; } = new();
}

public sealed class BindingLayer
{
    public int Number { get; set; }
    public string Name { get; set; } = "Layer";
    public List<ControlBinding> Bindings { get; set; } = [];
}

public sealed class BindingProfile
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Codex";
    public int ActiveLayer { get; set; } = 1;
    public List<BindingLayer> Layers { get; set; } = [];
}

public sealed class BindingConfiguration
{
    public int Version { get; set; } = 1;
    public string ActiveProfileId { get; set; } = "codex-default";
    public List<BindingProfile> Profiles { get; set; } = [];

    public BindingProfile ActiveProfile => Profiles.First(x => x.Id == ActiveProfileId);

    public static BindingConfiguration CreateDefault()
    {
        var labels = new[]
        {
            "New task", "Focus Codex", "Approve", "Reject",
            "Review changes", "Run tests", "Fix errors", "Explain",
            "Refactor", "Commit", "Push", "Documentation",
            "Voice", "Search", "Reasoning", "Custom",
        };
        var profile = new BindingProfile { Id = "codex-default", Name = "Codex", ActiveLayer = 1 };
        for (var layerNumber = 1; layerNumber <= 3; layerNumber++)
        {
            var layer = new BindingLayer { Number = layerNumber, Name = layerNumber == 1 ? "Codex" : $"Layer {layerNumber}" };
            for (var index = 0; index < 16; index++)
            {
                var trigger = index < 12
                    ? new KeyboardGestureSpec { VirtualKey = 0x7C + index } // F13-F24
                    : new KeyboardGestureSpec { VirtualKey = 0x7C + index - 12, Control = true, Alt = true, Shift = true };
                layer.Bindings.Add(new ControlBinding
                {
                    Position = index + 1,
                    Label = layerNumber == 1 ? labels[index] : $"Key {index + 1}",
                    Trigger = trigger,
                    Action = index == 1 && layerNumber == 1 ? BindingActionKind.FocusCodex : BindingActionKind.None,
                });
            }
            profile.Layers.Add(layer);
        }
        return new BindingConfiguration { Profiles = [profile] };
    }
}

public sealed class BindingConfigStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public string Path { get; }

    public BindingConfigStore(string? path = null)
    {
        Path = path ?? System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CreatorCommandCenter", "bindings.json");
    }

    public BindingConfiguration Load()
    {
        if (!File.Exists(Path)) return BindingConfiguration.CreateDefault();
        try
        {
            var value = JsonSerializer.Deserialize<BindingConfiguration>(File.ReadAllText(Path), Options);
            return IsValid(value) ? value! : BindingConfiguration.CreateDefault();
        }
        catch (JsonException) { return BindingConfiguration.CreateDefault(); }
    }

    public void Save(BindingConfiguration configuration)
    {
        var directory = System.IO.Path.GetDirectoryName(Path)!;
        Directory.CreateDirectory(directory);
        var temporary = Path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(configuration, Options));
        File.Move(temporary, Path, true);
    }

    private static bool IsValid(BindingConfiguration? value) => value is not null &&
        value.Profiles.Any(x => x.Id == value.ActiveProfileId) &&
        value.Profiles.All(x => x.Layers.Count > 0 && x.Layers.All(layer => layer.Bindings.Count == 16));
}
