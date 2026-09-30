using System;
using System.Runtime.InteropServices;

public static class PotatoWindowIdentity {
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    public static IntPtr EnterPhysicalCoordinates() {
        // Thread-scoped: never change the embedding host's process-wide setting.
        IntPtr previous=SetThreadDpiAwarenessContext(new IntPtr(-4)); // PER_MONITOR_AWARE_V2
        if (previous==IntPtr.Zero) previous=SetThreadDpiAwarenessContext(new IntPtr(-3)); // Windows 10 1607
        if (previous==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cannot establish physical screen coordinates.");
        return previous;
    }
    // Read under EnterPhysicalCoordinates, without WinForms Screen's cached bounds.
    public static int PrimaryWidth() { return GetSystemMetrics(0); }
    public static int PrimaryHeight() { return GetSystemMetrics(1); }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo {
        public uint size, flags;
        public IntPtr active, focus, capture, menuOwner, moveSize, caret;
        public Rect caretRect;
    }
    public sealed class FocusInfo {
        public long foregroundHandle, focusHandle, caretHandle;
        public int foregroundProcessId, focusProcessId;
        public bool stable, enabled, withinForeground, menuActive;
    }
    public static FocusInfo ReadFocus() {
        IntPtr foreground=GetForegroundWindow();
        uint processId;
        uint thread=GetWindowThreadProcessId(foreground, out processId);
        var result=new FocusInfo { foregroundHandle=foreground.ToInt64(), foregroundProcessId=(int)processId };
        var info=new GuiThreadInfo { size=(uint)Marshal.SizeOf(typeof(GuiThreadInfo)) };
        if (foreground==IntPtr.Zero || thread==0 || !GetGUIThreadInfo(thread, ref info)) return result;
        result.focusHandle=info.focus.ToInt64();
        result.focusProcessId=ProcessId(info.focus);
        result.caretHandle=info.caret.ToInt64();
        result.enabled=info.focus!=IntPtr.Zero && IsWindowEnabled(info.focus);
        result.withinForeground=info.focus!=IntPtr.Zero && GetAncestor(info.focus,2)==GetAncestor(foreground,2);
        result.menuActive=(info.flags & 0x1c)!=0;
        result.stable=GetForegroundWindow()==foreground && info.active!=IntPtr.Zero;
        return result;
    }
    public static int ProcessId(IntPtr window) {
        uint processId;
        return GetWindowThreadProcessId(window, out processId) == 0 ? 0 : (int)processId;
    }
    public static IntPtr ForegroundRoot() { return GetAncestor(GetForegroundWindow(), 2); }
    public static IntPtr Root(IntPtr window) { return GetAncestor(window, 2); }
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    public static void RequestClose(IntPtr window, int expectedProcessId) {
        if (window==IntPtr.Zero || ProcessId(window)!=expectedProcessId)
            throw new InvalidOperationException("Close target disappeared or changed process; no close was requested.");
        if (!PostMessageW(window,0x0010,IntPtr.Zero,IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Window close request failed.");
    }
    public static bool IsOwnedBy(IntPtr window, IntPtr owner) {
        if (window == IntPtr.Zero || owner == IntPtr.Zero) return false;
        IntPtr root = GetAncestor(window, 2); // GA_ROOT
        for (int i=0; i<32 && root!=IntPtr.Zero; i++) {
            if (root==owner) return true;
            root=GetWindow(root, 4); // GW_OWNER, including cross-process dialogs
        }
        return false;
    }
}
