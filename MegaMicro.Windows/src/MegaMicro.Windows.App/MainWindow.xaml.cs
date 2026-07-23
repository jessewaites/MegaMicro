using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MegaMicro.Windows.Core;

namespace MegaMicro.Windows.App;

public partial class MainWindow : Window
{
    private enum CaptureTarget { None, Trigger, Output }

    private readonly BindingConfigStore configStore = new();
    private readonly KeyboardHookService keyboardHook = new();
    private readonly List<Button> keyButtons = [];
    private BindingConfiguration configuration;
    private ControlBinding? selectedBinding;
    private CaptureTarget captureTarget;
    private bool loadingEditor;

    public MainWindow()
    {
        InitializeComponent();
        configuration = configStore.Load();
        ActionCombo.ItemsSource = Enum.GetValues<BindingActionKind>();
        BuildKeyGrid();
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

    private void BuildKeyGrid()
    {
        KeyGrid.Children.Clear();
        keyButtons.Clear();
        for (var index = 0; index < 16; index++)
        {
            var button = new Button
            {
                Tag = index,
                Margin = new Thickness(5),
                Background = new SolidColorBrush(Color.FromRgb(0x25, 0x2B, 0x36)),
                Foreground = Brushes.White,
                BorderBrush = new SolidColorBrush(Color.FromRgb(0x3A, 0x43, 0x51)),
                BorderThickness = new Thickness(1),
            };
            button.Click += KeyButton_Click;
            keyButtons.Add(button);
            KeyGrid.Children.Add(button);
        }
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
            var label = new StackPanel();
            label.Children.Add(new TextBlock { Text = binding.Label, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontWeight = FontWeights.SemiBold });
            label.Children.Add(new TextBlock { Text = binding.Trigger.DisplayName, Foreground = new SolidColorBrush(Color.FromRgb(0x9B, 0xA6, 0xB5)), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 5, 0, 0) });
            keyButtons[binding.Position - 1].Content = label;
            keyButtons[binding.Position - 1].BorderBrush = selectedBinding?.Position == binding.Position
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
        selectedBinding = binding;
        loadingEditor = true;
        SelectedTitle.Text = $"Key {binding.Position}";
        LabelText.Text = binding.Label;
        TriggerText.Text = binding.Trigger.DisplayName;
        ActionCombo.SelectedItem = binding.Action;
        OutputText.Text = binding.Output.DisplayName;
        loadingEditor = false;
        RefreshLayer();
        UpdateActionHelp();
    }

    private void KeyButton_Click(object sender, RoutedEventArgs e)
    {
        var position = (int)((Button)sender).Tag + 1;
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
        captureTarget = CaptureTarget.Trigger;
        LearnTriggerButton.Content = "Press the Creator Micro key now…";
        EditorStatus.Text = "Waiting for the next physical key or shortcut.";
    }

    private void RecordOutput_Click(object sender, RoutedEventArgs e)
    {
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

    private void ActionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loadingEditor && selectedBinding is not null && ActionCombo.SelectedItem is BindingActionKind kind)
            selectedBinding.Action = kind;
        UpdateActionHelp();
    }

    private void UpdateActionHelp()
    {
        var kind = ActionCombo.SelectedItem is BindingActionKind selected ? selected : BindingActionKind.None;
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
        if (ActionCombo.SelectedItem is BindingActionKind action) selectedBinding.Action = action;
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
