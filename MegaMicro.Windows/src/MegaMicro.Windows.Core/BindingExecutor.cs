using System.Diagnostics;
using System.Runtime.InteropServices;

namespace MegaMicro.Windows.Core;

public static class BindingExecutor
{
    private const uint KeyEventKeyUp = 0x0002;

    public static bool Execute(ControlBinding binding)
    {
        return binding.Action switch
        {
            BindingActionKind.None => false,
            BindingActionKind.FocusCodex => FocusCodex(),
            BindingActionKind.SendShortcut => SendShortcut(binding.Output),
            BindingActionKind.FocusCodexThenShortcut => FocusCodex() && DelayedShortcut(binding.Output),
            _ => false,
        };
    }

    public static bool FocusCodex()
    {
        var process = Process.GetProcesses()
            .Where(x => x.ProcessName.Contains("codex", StringComparison.OrdinalIgnoreCase) && x.MainWindowHandle != IntPtr.Zero)
            .OrderByDescending(x => x.MainWindowHandle)
            .FirstOrDefault();
        return process is not null && SetForegroundWindow(process.MainWindowHandle);
    }

    public static bool SendShortcut(KeyboardGestureSpec gesture)
    {
        if (gesture.IsEmpty) return false;
        var modifiers = new List<byte>();
        if (gesture.Control) modifiers.Add(0x11);
        if (gesture.Alt) modifiers.Add(0x12);
        if (gesture.Shift) modifiers.Add(0x10);
        if (gesture.Windows) modifiers.Add(0x5B);
        foreach (var key in modifiers) keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event((byte)gesture.VirtualKey, 0, 0, UIntPtr.Zero);
        keybd_event((byte)gesture.VirtualKey, 0, KeyEventKeyUp, UIntPtr.Zero);
        for (var index = modifiers.Count - 1; index >= 0; index--)
            keybd_event(modifiers[index], 0, KeyEventKeyUp, UIntPtr.Zero);
        return true;
    }

    private static bool DelayedShortcut(KeyboardGestureSpec gesture)
    {
        Thread.Sleep(80);
        return SendShortcut(gesture);
    }

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
}
