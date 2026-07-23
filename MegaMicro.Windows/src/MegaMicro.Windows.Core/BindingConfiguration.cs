using System.Text.Json;
using System.Text.Json.Serialization;

namespace MegaMicro.Windows.Core;

public enum BindingActionKind
{
    None,
    FocusCodex,
    SendShortcut,
    FocusCodexThenShortcut,
    StartCodexTask,
}

public enum CreatorControlKind
{
    Key,
    RollerPress,
    DialPress,
    SpecialButton,
    RollerTurn,
    DialTurn,
}

public sealed record CreatorControlDescriptor(int Position, string Name, CreatorControlKind Kind);

public static class CreatorMicroV1Layout
{
    public const int ControlCount = 20;

    public static IReadOnlyList<CreatorControlDescriptor> Controls { get; } =
    [
        new(1, "Roller press", CreatorControlKind.RollerPress),
        new(2, "Top key 1", CreatorControlKind.Key),
        new(3, "Top key 2", CreatorControlKind.Key),
        new(4, "Dial press", CreatorControlKind.DialPress),
        new(5, "Key 1", CreatorControlKind.Key),
        new(6, "Key 2", CreatorControlKind.Key),
        new(7, "Key 3", CreatorControlKind.Key),
        new(8, "Key 4", CreatorControlKind.Key),
        new(9, "Key 5", CreatorControlKind.Key),
        new(10, "Key 6", CreatorControlKind.Key),
        new(11, "Key 7", CreatorControlKind.Key),
        new(12, "Key 8", CreatorControlKind.Key),
        new(13, "Bottom-left button", CreatorControlKind.SpecialButton),
        new(14, "Bottom key 1", CreatorControlKind.Key),
        new(15, "Bottom key 2", CreatorControlKind.Key),
        new(16, "Bottom-right button", CreatorControlKind.SpecialButton),
        new(17, "Roller left", CreatorControlKind.RollerTurn),
        new(18, "Roller right", CreatorControlKind.RollerTurn),
        new(19, "Dial counter-clockwise", CreatorControlKind.DialTurn),
        new(20, "Dial clockwise", CreatorControlKind.DialTurn),
    ];
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
    public string ControlName { get; set; } = "Control";
    public CreatorControlKind Kind { get; set; }
    public string Label { get; set; } = "Unassigned";
    public KeyboardGestureSpec Trigger { get; set; } = new();
    public BindingActionKind Action { get; set; }
    public KeyboardGestureSpec Output { get; set; } = new();
    public string CodexInstruction { get; set; } = "";
    public string WorkingDirectory { get; set; } = "";
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
    public int Version { get; set; } = 2;
    public string ActiveProfileId { get; set; } = "codex-default";
    public List<BindingProfile> Profiles { get; set; } = [];

    public BindingProfile ActiveProfile => Profiles.First(x => x.Id == ActiveProfileId);

    public static BindingConfiguration CreateDefault()
    {
        var labels = new[]
        {
            "Roller press", "New task", "Focus Codex", "Dial press",
            "Approve", "Reject", "Review changes", "Run tests",
            "Fix errors", "Explain", "Refactor", "Commit",
            "Layer", "Push", "Documentation", "Lighting",
            "Previous", "Next", "Reasoning down", "Reasoning up",
        };
        var profile = new BindingProfile { Id = "codex-default", Name = "Codex", ActiveLayer = 1 };
        for (var layerNumber = 1; layerNumber <= 3; layerNumber++)
        {
            var layer = new BindingLayer { Number = layerNumber, Name = layerNumber == 1 ? "Codex" : $"Layer {layerNumber}" };
            for (var index = 0; index < CreatorMicroV1Layout.ControlCount; index++)
            {
                var trigger = index < 12
                    ? new KeyboardGestureSpec { VirtualKey = 0x7C + index } // F13-F24
                    : new KeyboardGestureSpec { VirtualKey = 0x7C + index - 12, Control = true, Alt = true, Shift = true };
                var control = CreatorMicroV1Layout.Controls[index];
                layer.Bindings.Add(new ControlBinding
                {
                    Position = index + 1,
                    ControlName = control.Name,
                    Kind = control.Kind,
                    Label = layerNumber == 1 ? labels[index] : control.Name,
                    Trigger = trigger,
                    Action = index == 2 && layerNumber == 1 ? BindingActionKind.FocusCodex : BindingActionKind.None,
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
            if (value is null) return BindingConfiguration.CreateDefault();
            Migrate(value);
            return IsValid(value) ? value : BindingConfiguration.CreateDefault();
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

    private static void Migrate(BindingConfiguration value)
    {
        foreach (var layer in value.Profiles.SelectMany(profile => profile.Layers))
        {
            foreach (var binding in layer.Bindings.Where(binding => binding.Position <= 16))
            {
                var descriptor = CreatorMicroV1Layout.Controls[binding.Position - 1];
                binding.ControlName = descriptor.Name;
                binding.Kind = descriptor.Kind;
            }
            if (layer.Bindings.Count == 16)
            {
                foreach (var descriptor in CreatorMicroV1Layout.Controls.Skip(16))
                {
                    layer.Bindings.Add(new ControlBinding
                    {
                        Position = descriptor.Position,
                        ControlName = descriptor.Name,
                        Kind = descriptor.Kind,
                        Label = descriptor.Name,
                        Trigger = new KeyboardGestureSpec
                        {
                            VirtualKey = 0x7C + descriptor.Position - 13,
                            Control = true,
                            Alt = true,
                            Shift = true,
                        },
                    });
                }
            }
        }
        value.Version = 2;
    }

    private static bool IsValid(BindingConfiguration? value) => value is not null &&
        value.Profiles.Any(x => x.Id == value.ActiveProfileId) &&
        value.Profiles.All(x => x.Layers.Count > 0 && x.Layers.All(layer =>
            layer.Bindings.Count == CreatorMicroV1Layout.ControlCount &&
            layer.Bindings.Select(binding => binding.Position).Order().SequenceEqual(Enumerable.Range(1, CreatorMicroV1Layout.ControlCount))));
}
