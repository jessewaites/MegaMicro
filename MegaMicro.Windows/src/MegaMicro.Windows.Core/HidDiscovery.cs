using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace MegaMicro.Windows.Core;

public sealed record HidInterface(string Path, ushort VendorId, ushort ProductId,
    ushort UsagePage, ushort Usage, string Product,
    ushort InputReportLength, ushort OutputReportLength, ushort FeatureReportLength)
{
    public bool IsCreatorMicroV1 => VendorId == 0x574C;
    public bool IsModernMicro => VendorId == 0x303A && ProductId is 0x8360 or 0x8297 or 0x8298;
    public bool IsViaRaw => UsagePage == 0xFF60 && Usage == 0x61;
}

public static class HidDiscovery
{
    private const uint DigcfPresent = 0x2;
    private const uint DigcfDeviceInterface = 0x10;
    private const uint FileShareRead = 1;
    private const uint FileShareWrite = 2;
    private const uint OpenExisting = 3;

    public static IReadOnlyList<HidInterface> Enumerate()
    {
        HidD_GetHidGuid(out var hidGuid);
        var set = SetupDiGetClassDevs(ref hidGuid, null, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
        if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var result = new List<HidInterface>();
        try
        {
            for (uint index = 0; ; index++)
            {
                var data = new SP_DEVICE_INTERFACE_DATA { cbSize = Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>() };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, index, ref data))
                {
                    if (Marshal.GetLastWin32Error() == 259) break;
                    continue;
                }
                SetupDiGetDeviceInterfaceDetail(set, ref data, IntPtr.Zero, 0, out var needed, IntPtr.Zero);
                var detail = Marshal.AllocHGlobal((int)needed);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref data, detail, needed, out _, IntPtr.Zero)) continue;
                    var path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                    if (string.IsNullOrEmpty(path)) continue;
                    var item = ReadInfo(path);
                    if (item is not null) result.Add(item);
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return result.OrderBy(x => x.VendorId).ThenBy(x => x.ProductId).ThenBy(x => x.UsagePage).ToArray();
    }

    private static HidInterface? ReadInfo(string path)
    {
        using var handle = CreateFile(path, 0, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        var attributes = new HIDD_ATTRIBUTES { Size = Marshal.SizeOf<HIDD_ATTRIBUTES>() };
        if (!HidD_GetAttributes(handle, ref attributes)) return null;
        ushort usagePage = 0, usage = 0, inputLength = 0, outputLength = 0, featureLength = 0;
        if (HidD_GetPreparsedData(handle, out var preparsed))
        {
            try
            {
                if (HidP_GetCaps(preparsed, out var caps) >= 0)
                {
                    usagePage = caps.UsagePage;
                    usage = caps.Usage;
                    inputLength = caps.InputReportByteLength;
                    outputLength = caps.OutputReportByteLength;
                    featureLength = caps.FeatureReportByteLength;
                }
            }
            finally { HidD_FreePreparsedData(preparsed); }
        }
        var productBuffer = Marshal.AllocHGlobal(256);
        string product = "";
        try
        {
            if (HidD_GetProductString(handle, productBuffer, 256))
                product = Marshal.PtrToStringUni(productBuffer) ?? "";
        }
        finally { Marshal.FreeHGlobal(productBuffer); }
        return new HidInterface(path, attributes.VendorID, attributes.ProductID, usagePage, usage,
            product, inputLength, outputLength, featureLength);
    }

    [StructLayout(LayoutKind.Sequential)] private struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public UIntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] private struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
    [StructLayout(LayoutKind.Sequential)] private struct HIDP_CAPS { public ushort Usage; public ushort UsagePage; public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved; public ushort NumberLinkCollectionNodes; public ushort NumberInputButtonCaps; public ushort NumberInputValueCaps; public ushort NumberInputDataIndices; public ushort NumberOutputButtonCaps; public ushort NumberOutputValueCaps; public ushort NumberOutputDataIndices; public ushort NumberFeatureButtonCaps; public ushort NumberFeatureValueCaps; public ushort NumberFeatureDataIndices; }

    [DllImport("hid.dll")] private static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll", SetLastError = true)] private static extern bool HidD_GetAttributes(SafeFileHandle device, ref HIDD_ATTRIBUTES attributes);
    [DllImport("hid.dll", SetLastError = true)] private static extern bool HidD_GetProductString(SafeFileHandle device, IntPtr buffer, int length);
    [DllImport("hid.dll", SetLastError = true)] private static extern bool HidD_GetPreparsedData(SafeFileHandle device, out IntPtr data);
    [DllImport("hid.dll")] private static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] private static extern int HidP_GetCaps(IntPtr data, out HIDP_CAPS caps);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string? enumerator, IntPtr hwnd, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, uint index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, uint detailSize, out uint needed, IntPtr deviceInfo);
    [DllImport("setupapi.dll")] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}

public sealed record HardwareProbeResult(string Summary, IReadOnlyList<HidInterface> Interfaces)
{
    public bool DeviceFound => Interfaces.Any(x => x.IsCreatorMicroV1 || x.IsModernMicro);
    public bool ViaRawInterfaceFound => Interfaces.Any(x => x.IsCreatorMicroV1 && x.IsViaRaw);
}

public static class HardwareProbe
{
    public static HardwareProbeResult RunReadOnly()
    {
        var matches = HidDiscovery.Enumerate().Where(x => x.IsCreatorMicroV1 || x.IsModernMicro).ToArray();
        if (matches.Length == 0)
            return new("No supported Work Louder keyboard was found.", matches);
        var modern = matches.FirstOrDefault(x => x.IsModernMicro);
        if (modern is not null)
            return new($"Found {(modern.Product.Length == 0 ? "Codex/Creator Micro 2" : modern.Product)} (VID {modern.VendorId:X4}, PID {modern.ProductId:X4}).", matches);
        var raw = matches.FirstOrDefault(x => x.IsViaRaw);
        var detail = raw is null ? "The VIA raw interface was not exposed." : "The VIA raw interface is available.";
        return new($"Found Creator Micro v1 (VID 574C). {detail}", matches);
    }
}
