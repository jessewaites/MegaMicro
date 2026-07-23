using System.Runtime.InteropServices;

namespace MegaMicro.Windows.Core;

public sealed class KeyboardHookService : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const int LlkhfInjected = 0x10;
    private readonly HookProc callback;
    private IntPtr hook;

    public Func<KeyboardGestureSpec, bool>? KeyPressed { get; set; }

    public KeyboardHookService() => callback = HookCallback;

    public void Start()
    {
        if (hook != IntPtr.Zero) return;
        hook = SetWindowsHookEx(WhKeyboardLl, callback, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    private IntPtr HookCallback(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && (message == (IntPtr)WmKeyDown || message == (IntPtr)WmSysKeyDown))
        {
            var value = Marshal.PtrToStructure<KbdLlHookStruct>(data);
            if ((value.flags & LlkhfInjected) == 0 && !IsModifier((int)value.vkCode))
            {
                var gesture = new KeyboardGestureSpec
                {
                    VirtualKey = (int)value.vkCode,
                    Control = Down(0x11),
                    Alt = Down(0x12),
                    Shift = Down(0x10),
                    Windows = Down(0x5B) || Down(0x5C),
                };
                if (KeyPressed?.Invoke(gesture) == true) return (IntPtr)1;
            }
        }
        return CallNextHookEx(hook, code, message, data);
    }

    private static bool Down(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;
    private static bool IsModifier(int key) => key is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;

    public void Dispose()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    private delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] private struct KbdLlHookStruct { public uint vkCode; public uint scanCode; public int flags; public uint time; public UIntPtr extraInfo; }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int id, HookProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
}
