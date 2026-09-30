using System;
using System.Runtime.InteropServices;

public static class PotatoWindowIdentity {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    public static int ProcessId(IntPtr window) {
        uint processId;
        return GetWindowThreadProcessId(window, out processId) == 0 ? 0 : (int)processId;
    }
    public static IntPtr ForegroundRoot() { return GetAncestor(GetForegroundWindow(), 2); }
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
