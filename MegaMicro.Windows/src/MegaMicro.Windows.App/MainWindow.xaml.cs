using System.Windows;
using System.Windows.Media;
using MegaMicro.Windows.Core;

namespace MegaMicro.Windows.App;

public partial class MainWindow : Window
{
    private readonly SessionStore store = new();
    private WebhookServer? server;
    private HidInterface? viaInterface;

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
            viaInterface = report.Interfaces.FirstOrDefault(x => x.IsCreatorMicroV1 && x.IsViaRaw);
            ViaHandshakeButton.IsEnabled = viaInterface is not null;
            HardwareDetails.Text = string.Join(Environment.NewLine, report.Interfaces.Select(x =>
                $"VID {x.VendorId:X4} PID {x.ProductId:X4} · usage {x.UsagePage:X4}/{x.Usage:X2} · reports {x.InputReportLength}/{x.OutputReportLength}"));
        }
        catch (Exception ex)
        {
            HardwareStatus.Text = $"Probe failed safely: {ex.Message}";
        }
    }

    private async void ViaHandshake_Click(object sender, RoutedEventArgs e)
    {
        if (viaInterface is null) return;
        ViaHandshakeButton.IsEnabled = false;
        HardwareStatus.Text = "Requesting the VIA protocol version (no device settings will change)…";
        try
        {
            await using var transport = new WindowsHidTransport(viaInterface);
            transport.OpenShared();
            var version = await transport.ReadViaProtocolVersionAsync(TimeSpan.FromMilliseconds(750));
            HardwareStatus.Text = version is null
                ? "Creator Micro is present, but it did not answer the VIA handshake. Close Work Louder Input or VIA and retry."
                : $"Creator Micro VIA protocol handshake passed (version {version}). No settings were changed.";
        }
        catch (Exception ex)
        {
            HardwareStatus.Text = $"VIA handshake failed safely: {ex.Message}";
        }
        finally
        {
            ViaHandshakeButton.IsEnabled = viaInterface is not null;
        }
    }

    private void RefreshSessions() => SessionsList.ItemsSource = store.Snapshot();
}
