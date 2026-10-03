using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;

public static class PotatoWindowIdentity {
    delegate bool EnumWindowProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback, IntPtr param);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    public static long[] WindowHandles() {
        var handles=new List<long>();
        if (!EnumWindows((window,param)=>{handles.Add(window.ToInt64());return true;},IntPtr.Zero))
            throw new InvalidOperationException("Cannot snapshot desktop windows.");
        return handles.ToArray();
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetPropW(IntPtr window,string name,IntPtr value);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetPropW(IntPtr window,string name);
    public static void TagWindow(IntPtr window,string token) {
        if (!SetPropW(window,"PoTATo.Window."+token,new IntPtr(1)))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Cannot mark the new GUI window for scoped cleanup.");
    }
    public static bool HasWindowTag(IntPtr window,string token) {
        // Windows discards properties on destruction, including when the numeric
        // HWND is reused later by the same process and class.
        return !String.IsNullOrEmpty(token) && GetPropW(window,"PoTATo.Window."+token)==new IntPtr(1);
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, StringBuilder text, int length);
    public static string ClassName(IntPtr window) {
        var text=new StringBuilder(256); GetClassNameW(window,text,text.Capacity); return text.ToString();
    }
    public static string Title(IntPtr window) {
        var text=new StringBuilder(4096); GetWindowTextW(window,text,text.Capacity); return text.ToString();
    }
    [DllImport("user32.dll")] static extern int GetWindowLongW(IntPtr window, int index);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr window,uint message,IntPtr wParam,StringBuilder text,uint flags,uint timeout,out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr window,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
    public static bool IsStandardEdit(IntPtr window, int processId, bool writable) {
        if (window==IntPtr.Zero || ProcessId(window)!=processId) return false;
        var name=new StringBuilder(256); GetClassNameW(window,name,name.Capacity);
        // Read actual field text, never a generic window caption. Exclude passwords.
        return String.Equals(name.ToString(),"Edit",StringComparison.OrdinalIgnoreCase) &&
            (GetWindowLongW(window,-16) & (0x20 | (writable ? 0x800 : 0)))==0;
    }
    public static string ReadEdit(IntPtr window,int processId) {
        if (!IsStandardEdit(window,processId,false)) throw new InvalidOperationException("Not a readable standard Edit control.");
        IntPtr length;
        if (SendMessageTimeoutW(window,0x000E,IntPtr.Zero,IntPtr.Zero,2,1000,out length)==IntPtr.Zero)
            throw new InvalidOperationException("Edit readback timed out.");
        if (length.ToInt64()<0 || length.ToInt64()>1048576) throw new InvalidOperationException("Edit text exceeds the readback limit.");
        var text=new StringBuilder((int)length+1); IntPtr read;
        if (SendMessageTimeoutW(window,0x000D,new IntPtr(text.Capacity),text,2,1000,out read)==IntPtr.Zero)
            throw new InvalidOperationException("Edit readback timed out.");
        return text.ToString();
    }
    public static bool IsMultilineEdit(IntPtr window) {return (GetWindowLongW(window,-16) & 0x4)!=0;}
    public static void SelectEditText(IntPtr window,int processId) {
        if (!IsStandardEdit(window,processId,true)) throw new InvalidOperationException("Not a writable standard Edit control.");
        IntPtr result;
        if (SendMessageTimeoutW(window,0x00B1,IntPtr.Zero,new IntPtr(-1),2,1000,out result)==IntPtr.Zero)
            throw new InvalidOperationException("Edit selection timed out.");
    }
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
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window,int command);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    public static bool Activate(IntPtr window,bool maximize) {
        if (!IsWindow(window) || !IsWindowEnabled(window)) return false;
        if (maximize) ShowWindowAsync(window,3); // SW_MAXIMIZE
        else if (IsIconic(window)) ShowWindowAsync(window,9); // SW_RESTORE
        // Read back activation, regardless of the API's return value.
        if (ForegroundRoot()!=Root(window)) SetForegroundWindow(window);
        // No synthetic keystroke/control click. Confirm the real foreground.
        return ForegroundRoot()==Root(window);
    }
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
