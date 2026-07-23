using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MegaMicro.Windows.Core;

public sealed class WindowsHidTransport : IAsyncDisposable
{
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 1;
    private const uint FileShareWrite = 2;
    private const uint OpenExisting = 3;
    private const uint FileFlagOverlapped = 0x40000000;
    private FileStream? stream;

    public HidInterface Interface { get; }
    public bool IsOpen => stream is not null;

    public WindowsHidTransport(HidInterface device) => Interface = device;

    public void OpenShared()
    {
        if (stream is not null) return;
        if (!Interface.IsViaRaw)
            throw new InvalidOperationException("Only a qualified VIA raw interface can be opened.");
        var handle = CreateFile(Interface.Path, GenericRead | GenericWrite,
            FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, FileFlagOverlapped, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Could not open the VIA interface in shared mode. Close other keyboard configurators and retry.");
        }
        var bufferSize = Math.Max(64, Math.Max((int)Interface.InputReportLength, Interface.OutputReportLength));
        stream = new FileStream(handle, FileAccess.ReadWrite, bufferSize, isAsync: true);
    }

    /// <summary>
    /// Sends VIA's read-only protocol-version request. This does not change LEDs,
    /// keymaps, firmware, or persistent device state.
    /// </summary>
    public async Task<ushort?> ReadViaProtocolVersionAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        if (stream is null) throw new InvalidOperationException("The HID interface is not open.");
        var request = ViaProtocol.CreateProtocolVersionRequest(Interface.OutputReportLength);
        await stream.WriteAsync(request, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        var response = new byte[Math.Max(ViaProtocol.PayloadLength + 1, (int)Interface.InputReportLength)];
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(response, deadline.Token).ConfigureAwait(false);
                if (read == 0) return null;
                if (ViaProtocol.TryParseProtocolVersion(response, read, out var version))
                    return version;
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (stream is not null) await stream.DisposeAsync().ConfigureAwait(false);
        stream = null;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
}
