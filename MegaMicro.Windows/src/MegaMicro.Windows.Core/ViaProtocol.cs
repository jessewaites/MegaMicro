namespace MegaMicro.Windows.Core;

public static class ViaProtocol
{
    public const byte GetProtocolVersion = 0x01;
    public const int PayloadLength = 32;

    /// <summary>
    /// Windows HID buffers include report ID 0 before the 32-byte VIA payload.
    /// </summary>
    public static byte[] CreateProtocolVersionRequest(int outputReportLength)
    {
        if (outputReportLength < PayloadLength + 1)
            throw new ArgumentOutOfRangeException(nameof(outputReportLength),
                "The VIA raw interface must expose a report-ID byte plus a 32-byte payload.");
        var report = new byte[outputReportLength];
        report[0] = 0;
        report[1] = GetProtocolVersion;
        return report;
    }

    public static bool TryParseProtocolVersion(ReadOnlySpan<byte> report, out ushort version)
    {
        version = 0;
        var commandOffset = report.Length > 0 && report[0] == 0 ? 1 : 0;
        if (report.Length < commandOffset + 3 || report[commandOffset] != GetProtocolVersion)
            return false;
        version = (ushort)((report[commandOffset + 1] << 8) | report[commandOffset + 2]);
        return true;
    }

    public static bool TryParseProtocolVersion(byte[] report, int length, out ushort version)
    {
        if (length < 0 || length > report.Length) throw new ArgumentOutOfRangeException(nameof(length));
        version = 0;
        var commandOffset = length > 0 && report[0] == 0 ? 1 : 0;
        if (length < commandOffset + 3 || report[commandOffset] != GetProtocolVersion)
            return false;
        version = (ushort)((report[commandOffset + 1] << 8) | report[commandOffset + 2]);
        return true;
    }
}
