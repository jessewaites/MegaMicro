using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using MegaMicro.Windows.Core;

namespace MegaMicro.Windows.App;

public partial class MainWindow : Window
{
    private enum CaptureTarget { None, Trigger, Output }
    private sealed record ActionOption(BindingActionKind Kind, string Label);

    private readonly BindingConfigStore configStore = new();
    private readonly KeyboardHookService keyboardHook = new();
    private readonly Dictionary<int, Button> keyButtons = [];
    private BindingConfiguration configuration;
    private ControlBinding? selectedBinding;
    private CaptureTarget captureTarget;
    private bool loadingEditor;
    private readonly ActionOption[] actionOptions =
    [
        new(BindingActionKind.None, "Disabled"),
        new(BindingActionKind.FocusCodex, "Focus Codex"),
        new(BindingActionKind.SendShortcut, "Send shortcut"),
        new(BindingActionKind.FocusCodexThenShortcut, "Focus Codex, then send shortcut"),
    ];

    public MainWindow()
    {
        InitializeComponent();
        configuration = configStore.Load();
        ActionCombo.ItemsSource = actionOptions;
        BuildDeviceLayout();
        LoadProfiles();
        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    private BindingProfile ActiveProfile => configuration.ActiveProfile;
    private BindingLayer ActiveLayer => ActiveProfile.Layers.First(x => x.Number == ActiveProfile.ActiveLayer);

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            keyboardHook.KeyPressed = OnGlobalKeyPressed;
            keyboardHook.Start();
            HookStatus.Text = "Global key listener: ready";
            HookStatus.Foreground = new SolidColorBrush(Color.FromRgb(0x63, 0xE6, 0xA8));
        }
        catch (Exception ex)
        {
            HookStatus.Text = $"Global key listener failed: {ex.Message}";
        }
        RunProbe();
        SelectBinding(ActiveLayer.Bindings[0]);
    }

    private void OnClosed(object? sender, EventArgs e) => keyboardHook.Dispose();

    private void BuildDeviceLayout()
    {
        DeviceGrid.Children.Clear();
        keyButtons.Clear();

        AddEncoderCell(0, 0, 1, 17, 18);
        AddControlButton(2, 0, 1);
        AddControlButton(3, 0, 2);
        AddEncoderCell(0, 3, 4, 19, 20);

        for (var column = 0; column < 4; column++)
        {
            AddControlButton(5 + column, 1, column);
            AddControlButton(9 + column, 2, column);
            AddControlButton(13 + column, 3, column);
        }
    }

    private void AddEncoderCell(int row, int column, int pressPosition, int counterClockwisePosition, int clockwisePosition)
    {
        var cell = new Grid { Margin = new Thickness(5) };
        cell.RowDefinitions.Add(new RowDefinition());
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(27) });
        Grid.SetRow(cell, row);
        Grid.SetColumn(cell, column);
        DeviceGrid.Children.Add(cell);

        var press = CreateControlButton(pressPosition, new Thickness(0, 0, 0, 4));
        Grid.SetRow(press, 0);
        cell.Children.Add(press);

        var directions = new UniformGrid { Columns = 2 };
        Grid.SetRow(directions, 1);
        directions.Children.Add(CreateControlButton(counterClockwisePosition, new Thickness(0, 0, 2, 0)));
        directions.Children.Add(CreateControlButton(clockwisePosition, new Thickness(2, 0, 0, 0)));
        cell.Children.Add(directions);
    }

    private void AddControlButton(int position, int row, int column)
    {
        var button = CreateControlButton(position, new Thickness(5));
        Grid.SetRow(button, row);
        Grid.SetColumn(button, column);
        DeviceGrid.Children.Add(button);
    }

    private Button CreateControlButton(int position, Thickness margin)
    {
        var descriptor = CreatorMicroV1Layout.Controls[position - 1];
        var round = descriptor.Kind is CreatorControlKind.DialPress or CreatorControlKind.SpecialButton;
        var button = new Button
        {
            Tag = position,
            Margin = margin,
            Background = new SolidColorBrush(Color.FromRgb(0x25, 0x2B, 0x36)),
            Foreground = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x3A, 0x43, 0x51)),
            BorderThickness = new Thickness(1),
            Style = (Style)FindResource(round ? "RoundKeyButtonStyle" : "KeyButtonStyle"),
        };
        if (round)
        {
            button.Width = descriptor.Kind == CreatorControlKind.DialPress ? 78 : 76;
            button.Height = descriptor.Kind == CreatorControlKind.DialPress ? 78 : 76;
            button.HorizontalAlignment = HorizontalAlignment.Center;
            button.VerticalAlignment = VerticalAlignment.Center;
        }
        else if (descriptor.Kind == CreatorControlKind.RollerPress)
        {
            button.Width = 82;
            button.Height = 68;
            button.HorizontalAlignment = HorizontalAlignment.Center;
            button.VerticalAlignment = VerticalAlignment.Center;
        }
        button.Click += KeyButton_Click;
        keyButtons[position] = button;
        return button;
    }

    private void LoadProfiles()
    {
        ProfileCombo.ItemsSource = configuration.Profiles;
        ProfileCombo.DisplayMemberPath = nameof(BindingProfile.Name);
        ProfileCombo.SelectedItem = configuration.ActiveProfile;
        RefreshLayer();
    }

    private void RefreshLayer()
    {
        LayerTitle.Text = $"Layer {ActiveLayer.Number} · {ActiveLayer.Name}";
        foreach (var binding in ActiveLayer.Bindings)
        {
            var compact = binding.Kind is CreatorControlKind.RollerTurn or CreatorControlKind.DialTurn;
            var label = new StackPanel();
            label.Children.Add(new TextBlock
            {
                Text = compact ? DirectionGlyph(binding.Position) : binding.Label,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                FontWeight = FontWeights.SemiBold,
                FontSize = compact ? 13 : binding.Label.Length > 11 ? 10 : 12,
            });
            if (!compact) label.Children.Add(new TextBlock
            {
                Text = FormatKeyTrigger(binding.Trigger),
                Foreground = new SolidColorBrush(Color.FromRgb(0x9B, 0xA6, 0xB5)),
                FontSize = 10,
                HorizontalAlignment = HorizontalAlignment.Center,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 5, 0, 0),
            });
            keyButtons[binding.Position].Content = label;
            keyButtons[binding.Position].ToolTip = $"{binding.ControlName}: {binding.Label} · {binding.Trigger.DisplayName}";
            keyButtons[binding.Position].BorderBrush = selectedBinding?.Position == binding.Position
                ? new SolidColorBrush(Color.FromRgb(0x63, 0xE6, 0xA8))
                : new SolidColorBrush(Color.FromRgb(0x3A, 0x43, 0x51));
        }
        Layer1Button.Background = ActiveProfile.ActiveLayer == 1 ? new SolidColorBrush(Color.FromRgb(0x63, 0xE6, 0xA8)) : new SolidColorBrush(Color.FromRgb(0x25, 0x2B, 0x36));
        Layer1Button.Foreground = ActiveProfile.ActiveLayer == 1 ? Brushes.Black : Brushes.White;
        Layer2Button.Background = ActiveProfile.ActiveLayer == 2 ? new SolidColorBrush(Color.FromRgb(0x63, 0xE6, 0xA8)) : new SolidColorBrush(Color.FromRgb(0x25, 0x2B, 0x36));
        Layer2Button.Foreground = ActiveProfile.ActiveLayer == 2 ? Brushes.Black : Brushes.White;
        Layer3Button.Background = ActiveProfile.ActiveLayer == 3 ? new SolidColorBrush(Color.FromRgb(0x63, 0xE6, 0xA8)) : new SolidColorBrush(Color.FromRgb(0x25, 0x2B, 0x36));
        Layer3Button.Foreground = ActiveProfile.ActiveLayer == 3 ? Brushes.Black : Brushes.White;
    }

    private void SelectBinding(ControlBinding binding)
    {
        CancelCapture();
        selectedBinding = binding;
        loadingEditor = true;
        SelectedTitle.Text = binding.ControlName;
        LabelText.Text = binding.Label;
        TriggerText.Text = binding.Trigger.DisplayName;
        ActionCombo.SelectedItem = actionOptions.First(x => x.Kind == binding.Action);
        OutputText.Text = binding.Output.DisplayName;
        loadingEditor = false;
        RefreshLayer();
        UpdateActionHelp();
    }

    private void KeyButton_Click(object sender, RoutedEventArgs e)
    {
        var position = (int)((Button)sender).Tag;
        SelectBinding(ActiveLayer.Bindings.First(x => x.Position == position));
    }

    private void Layer_Click(object sender, RoutedEventArgs e)
    {
        ActiveProfile.ActiveLayer = int.Parse((string)((Button)sender).Tag);
        SelectBinding(ActiveLayer.Bindings[0]);
        SaveConfiguration("Layer changed");
    }

    private void ProfileCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileCombo.SelectedItem is not BindingProfile profile) return;
        configuration.ActiveProfileId = profile.Id;
        SelectBinding(profile.Layers.First(x => x.Number == profile.ActiveLayer).Bindings[0]);
    }

    private void LearnTrigger_Click(object sender, RoutedEventArgs e)
    {
        if (captureTarget == CaptureTarget.Trigger)
        {
            CancelCapture("Physical-key capture cancelled.");
            return;
        }
        captureTarget = CaptureTarget.Trigger;
        LearnTriggerButton.Content = "Press the Creator Micro key now…";
        EditorStatus.Text = "Waiting for the next physical key or shortcut.";
    }

    private void RecordOutput_Click(object sender, RoutedEventArgs e)
    {
        if (captureTarget == CaptureTarget.Output)
        {
            CancelCapture("Shortcut capture cancelled.");
            return;
        }
        captureTarget = CaptureTarget.Output;
        RecordOutputButton.Content = "Press the desired Codex shortcut…";
        EditorStatus.Text = "Waiting for the output shortcut.";
    }

    private bool OnGlobalKeyPressed(KeyboardGestureSpec gesture)
    {
        if (captureTarget != CaptureTarget.None)
        {
            Dispatcher.Invoke(() => FinishCapture(gesture));
            return true;
        }
        var binding = ActiveLayer.Bindings.FirstOrDefault(x => x.Trigger == gesture && x.Action != BindingActionKind.None);
        if (binding is null) return false;
        _ = Task.Run(() =>
        {
            var worked = BindingExecutor.Execute(binding);
            Dispatcher.Invoke(() => FooterStatus.Text = worked ? $"Ran: {binding.Label}" : $"Could not run: {binding.Label}");
        });
        return true;
    }

    private void FinishCapture(KeyboardGestureSpec gesture)
    {
        if (selectedBinding is null) return;
        if (captureTarget == CaptureTarget.Trigger)
        {
            selectedBinding.Trigger = gesture;
            TriggerText.Text = gesture.DisplayName;
        }
        else
        {
            selectedBinding.Output = gesture;
            OutputText.Text = gesture.DisplayName;
        }
        captureTarget = CaptureTarget.None;
        LearnTriggerButton.Content = "Learn physical key";
        RecordOutputButton.Content = "Record output shortcut";
        EditorStatus.Text = $"Captured {gesture.DisplayName}. Click Save binding.";
        RefreshLayer();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape || captureTarget == CaptureTarget.None) return;
        CancelCapture("Capture cancelled.");
        e.Handled = true;
    }

    private void CancelCapture(string? message = null)
    {
        if (captureTarget == CaptureTarget.None) return;
        captureTarget = CaptureTarget.None;
        LearnTriggerButton.Content = "Learn physical key";
        RecordOutputButton.Content = "Record output shortcut";
        if (message is not null) EditorStatus.Text = message;
    }

    private static string FormatKeyTrigger(KeyboardGestureSpec trigger)
    {
        const string longPrefix = "Ctrl + Alt + Shift + ";
        return trigger.DisplayName.StartsWith(longPrefix, StringComparison.Ordinal)
            ? $"Ctrl · Alt · Shift\n{trigger.DisplayName[longPrefix.Length..]}"
            : trigger.DisplayName;
    }

    private static string DirectionGlyph(int position) => position switch
    {
        17 or 19 => "↶",
        18 or 20 => "↷",
        _ => "•",
    };

    private void ActionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loadingEditor && selectedBinding is not null && ActionCombo.SelectedItem is ActionOption option)
            selectedBinding.Action = option.Kind;
        UpdateActionHelp();
    }

    private void UpdateActionHelp()
    {
        var kind = ActionCombo.SelectedItem is ActionOption option ? option.Kind : BindingActionKind.None;
        EditorHelp.Text = kind switch
        {
            BindingActionKind.FocusCodex => "Brings the running Codex window to the foreground.",
            BindingActionKind.SendShortcut => "Sends the recorded shortcut to whichever app is currently focused.",
            BindingActionKind.FocusCodexThenShortcut => "Focuses Codex, waits briefly, then sends the recorded shortcut.",
            _ => "This key is disabled until an action is selected.",
        };
    }

    private void SaveBinding_Click(object sender, RoutedEventArgs e)
    {
        if (selectedBinding is null) return;
        selectedBinding.Label = string.IsNullOrWhiteSpace(LabelText.Text) ? $"Key {selectedBinding.Position}" : LabelText.Text.Trim();
        if (ActionCombo.SelectedItem is ActionOption option) selectedBinding.Action = option.Kind;
        if (selectedBinding.Trigger.IsEmpty)
        {
            EditorStatus.Text = "Learn a physical key before saving this binding.";
            return;
        }
        if (selectedBinding.Action is BindingActionKind.SendShortcut or BindingActionKind.FocusCodexThenShortcut && selectedBinding.Output.IsEmpty)
        {
            EditorStatus.Text = "Record an output shortcut for the selected action.";
            return;
        }
        var duplicate = ActiveLayer.Bindings.FirstOrDefault(x => x.Position != selectedBinding.Position && x.Trigger == selectedBinding.Trigger);
        if (duplicate is not null)
        {
            EditorStatus.Text = $"{selectedBinding.Trigger.DisplayName} is already assigned to Key {duplicate.Position}. Learn a different physical key.";
            return;
        }
        SaveConfiguration("Binding saved");
        RefreshLayer();
    }

    private void TestAction_Click(object sender, RoutedEventArgs e)
    {
        if (selectedBinding is null) return;
        var worked = BindingExecutor.Execute(selectedBinding);
        EditorStatus.Text = worked ? "Action sent." : "Action is incomplete or Codex is not running.";
    }

    private void SaveConfiguration(string message)
    {
        configStore.Save(configuration);
        FooterStatus.Text = message;
        EditorStatus.Text = message;
    }

    private void Probe_Click(object sender, RoutedEventArgs e) => RunProbe();

    private void RunProbe()
    {
        try
        {
            var report = HardwareProbe.RunReadOnly();
            ConnectionStatus.Text = report.Summary;
            ConnectionDot.Fill = new SolidColorBrush(report.DeviceFound
                ? Color.FromRgb(0x63, 0xE6, 0xA8)
                : Color.FromRgb(0xF2, 0xBA, 0x4B));
        }
        catch (Exception ex)
        {
            ConnectionStatus.Text = $"Probe failed: {ex.Message}";
            ConnectionDot.Fill = new SolidColorBrush(Color.FromRgb(0xFF, 0x72, 0x5E));
        }
    }
}
