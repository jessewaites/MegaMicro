using System.Windows;
using System.Windows.Media;
using MegaMicro.Windows.Core;

namespace MegaMicro.Windows.App;

public partial class MainWindow : Window
{
    private readonly SessionStore store = new();
    private WebhookServer? server;

    public MainWindow()
    {
        InitializeComponent();
        store.Changed += () => Dispatcher.Invoke(RefreshSessions);
        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            server = new WebhookServer(store);
            server.Start();
            ServiceStatus.Text = "Local agent service is ready";
            ServiceDot.Fill = new SolidColorBrush(Color.FromRgb(0x62, 0xE6, 0xA7));
        }
        catch (Exception ex)
        {
            ServiceStatus.Text = $"Could not start local service: {ex.Message}";
            ServiceDot.Fill = Brushes.OrangeRed;
        }
    }

    private async void OnClosed(object? sender, EventArgs e)
    {
        if (server is not null) await server.DisposeAsync();
    }

    private void Probe_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var report = HardwareProbe.RunReadOnly();
            HardwareStatus.Text = report.Summary;
        }
        catch (Exception ex)
        {
            HardwareStatus.Text = $"Probe failed safely: {ex.Message}";
        }
    }

    private void RefreshSessions() => SessionsList.ItemsSource = store.Snapshot();
}
