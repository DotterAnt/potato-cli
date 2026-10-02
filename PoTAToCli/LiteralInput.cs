using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text;
using System.Diagnostics;

// Unicode keyboard events, never clipboard or application object-model writes.
public static class PotatoLiteralInput {
    [StructLayout(LayoutKind.Sequential)]
    struct KeyboardInput { public ushort key, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct MouseInput { public int x, y; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion {
        [FieldOffset(0)] public KeyboardInput keyboard;
        [FieldOffset(0)] public MouseInput mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Input { public uint type; public InputUnion value; }
    [DllImport("user32.dll", SetLastError=true)]
    static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo {
        public uint size, flags;
        public IntPtr active, focus, capture, menuOwner, moveSize, caret;
        public Rect caretRect;
    }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window,StringBuilder text,int capacity);
    [DllImport("user32.dll")] static extern int GetWindowLongW(IntPtr window,int index);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeoutW(IntPtr window,uint message,IntPtr wParam,StringBuilder text,uint flags,uint timeout,out IntPtr result);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageTimeoutW")] static extern IntPtr ReadEditLength(IntPtr window,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageTimeoutW")] static extern IntPtr ReadEditSelection(IntPtr window,uint message,out uint start,out uint end,uint flags,uint timeout,out IntPtr result);
    static bool PrefixConsumed(long handle,string expected,string actual) {
        if (String.Equals(expected,actual,StringComparison.Ordinal)) return true;
        // Shell/edit autocomplete can append a selected suggestion. The next
        // character replaces that selection; an unselected extra suffix is not
        // accepted as consumption. Final full-field verification stays exact.
        if (!actual.StartsWith(expected,StringComparison.Ordinal)) return false;
        uint start,end;IntPtr result;
        return ReadEditSelection(new IntPtr(handle),0xB0,out start,out end,2,500,out result)!=IntPtr.Zero &&
            start==expected.Length && end==actual.Length;
    }
    static string ReadEmptyEditTarget(long handle,int process) {
        var window=new IntPtr(handle); uint actualProcess;
        GetWindowThreadProcessId(window,out actualProcess);
        var name=new StringBuilder(256);GetClassNameW(window,name,name.Capacity);
        if (actualProcess!=(uint)process || !String.Equals(name.ToString(),"Edit",StringComparison.OrdinalIgnoreCase) ||
            (GetWindowLongW(window,-16) & (0x20|0x800|0x4))!=0)
            throw new InvalidOperationException("Acknowledged typing requires a readable single-line standard Edit.");
        IntPtr length;
        if (ReadEditLength(window,0xE,IntPtr.Zero,IntPtr.Zero,2,500,out length)==IntPtr.Zero || length.ToInt64()<0 || length.ToInt64()>65536)
            throw new InvalidOperationException("Edit acknowledgement length is unavailable or exceeds its bound.");
        var text=new StringBuilder((int)length+1);IntPtr read;
        if (SendMessageTimeoutW(window,0x000D,new IntPtr(text.Capacity),text,2,500,out read)==IntPtr.Zero)
            throw new InvalidOperationException("Edit acknowledgement timed out.");
        return text.ToString();
    }

    static Input Key(char value, bool up) {
        bool control = value == '\n' || value == '\t';
        return new Input { type=1, value=new InputUnion { keyboard=new KeyboardInput {
            key=(ushort)(control ? (value == '\n' ? 13 : 9) : 0),
            scan=(ushort)(control ? 0 : value), flags=(control ? 0u : 4u) | (up ? 2u : 0u)
        } } };
    }
    static Input VirtualKey(ushort key, bool up) {
        return new Input { type=1, value=new InputUnion { keyboard=new KeyboardInput {
            key=key, flags=(key>=0x25 && key<=0x28 ? 1u : 0u) | (up ? 2u : 0u)
        } } };
    }
    public static void SendNavigation(string name, long foregroundHandle, long focusHandle) {
        ushort key;
        switch ((name ?? "").ToLowerInvariant()) {
            case "tab": case "shifttab": key=9; break;
            case "enter": key=13; break;
            case "escape": key=27; break;
            case "left": key=0x25; break;
            case "up": key=0x26; break;
            case "right": key=0x27; break;
            case "down": key=0x28; break;
            default: throw new ArgumentException("Unsupported navigation key.");
        }
        var info=new GuiThreadInfo {size=(uint)Marshal.SizeOf(typeof(GuiThreadInfo))};
        if (foregroundHandle==0 || focusHandle==0 || GetForegroundWindow().ToInt64()!=foregroundHandle ||
            !GetGUIThreadInfo(0,ref info) || info.focus.ToInt64()!=focusHandle || !IsWindowEnabled(info.focus)) {
            var failure=new InvalidOperationException("Keyboard target changed before navigation. No input was sent.");
            failure.Data["PotatoErrorType"]="InputFocusChanged"; failure.Data["NoInputSent"]=true;
            throw failure;
        }
        bool shift=String.Equals(name,"ShiftTab",StringComparison.OrdinalIgnoreCase);
        var inputs=shift ? new[]{VirtualKey(0x10,false),VirtualKey(key,false),VirtualKey(key,true),VirtualKey(0x10,true)} :
            new[]{VirtualKey(key,false),VirtualKey(key,true)};
        uint sent=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)));
        if (sent!=inputs.Length) {
            int error=Marshal.GetLastWin32Error();
            // Best-effort release after partial insertion, never repeat the action.
            if (sent>0) {
                var releases=shift ? new[]{VirtualKey(key,true),VirtualKey(0x10,true)} : new[]{VirtualKey(key,true)};
                SendInput((uint)releases.Length,releases,Marshal.SizeOf(typeof(Input)));
            }
            var failure=new Win32Exception(error,"Navigation input was incomplete; observe before retrying.");
            failure.Data["NoInputSent"]=sent==0; throw failure;
        }
    }
    public static void SendText(string text) {
        var info=new GuiThreadInfo {size=(uint)Marshal.SizeOf(typeof(GuiThreadInfo))};
        if (!GetGUIThreadInfo(0,ref info)) throw new InvalidOperationException("Cannot confirm keyboard focus before typing.");
        SendText(text,5,GetForegroundWindow().ToInt64(),info.focus.ToInt64());
    }
    public static void SendText(string text, int delayMs, long foregroundHandle, long focusHandle) {
        SendCore(text,delayMs,foregroundHandle,focusHandle,0,0,3000);
    }
    public static void SendTextAcknowledged(string text,int delayMs,long foregroundHandle,long focusHandle,int process) {
        SendTextAcknowledged(text,delayMs,foregroundHandle,focusHandle,process,3000);
    }
    public static void SendTextAcknowledged(string text,int delayMs,long foregroundHandle,long focusHandle,int process,int timeoutMs) {
        if (timeoutMs<0 || timeoutMs>60000) throw new ArgumentOutOfRangeException("timeoutMs");
        // Only empty replacement fields have an unambiguous expected prefix.
        // Wait for queued Backspace to be consumed; never repeat clearing/input.
        var timer=Stopwatch.StartNew();
        while (ReadEmptyEditTarget(focusHandle,process).Length!=0) {
            if (timer.ElapsedMilliseconds>=timeoutMs) {
                var failure=new InvalidOperationException("Replacement field did not become empty; no text was sent. Inspect it before retrying.");
                failure.Data["PotatoErrorType"]="TextClearNotReady";failure.Data["NoInputSent"]=true;
                throw failure;
            }
            Thread.Sleep(2);
        }
        SendCore(text,delayMs,foregroundHandle,focusHandle,focusHandle,process,timeoutMs);
    }
    static void SendCore(string text,int delayMs,long foregroundHandle,long focusHandle,long acknowledgedEdit,int process,int timeoutMs) {
        if (delayMs<0 || delayMs>100) throw new ArgumentOutOfRangeException("delayMs");
        for (int i=0;i<text.Length;i++) {
            if (char.IsHighSurrogate(text[i]) && i+1<text.Length && char.IsLowSurrogate(text[i+1])) {i++;continue;}
            if (char.IsSurrogate(text[i])) {
                var failure=new ArgumentException("Text contains an unpaired UTF-16 surrogate. No input was sent.");
                failure.Data["PotatoErrorType"]="InvalidText"; failure.Data["NoInputSent"]=true;
                throw failure;
            }
        }
        text = text.Replace("\r\n", "\n").Replace("\r", "\n");
        for (int offset=0; offset<text.Length;) {
            var info=new GuiThreadInfo {size=(uint)Marshal.SizeOf(typeof(GuiThreadInfo))};
            if (foregroundHandle==0 || focusHandle==0 || GetForegroundWindow().ToInt64()!=foregroundHandle ||
                !GetGUIThreadInfo(0,ref info) || info.focus.ToInt64()!=focusHandle || !IsWindowEnabled(info.focus)) {
                var failure=new InvalidOperationException("Keyboard target changed during typing. Input was stopped; inspect content before retrying.");
                failure.Data["PotatoErrorType"]="InputFocusChanged";
                failure.Data["NoInputSent"]=offset==0;
                throw failure;
            }
            // Deliver one Unicode scalar per paced call. A successful SendInput
            // reports queue insertion, not that the editor consumed the text.
            int length=delayMs==0 && acknowledgedEdit==0 ? Math.Min(128,text.Length-offset) :
                (char.IsHighSurrogate(text[offset]) && offset+1<text.Length && char.IsLowSurrogate(text[offset+1]) ? 2 : 1);
            if (length>1 && offset+length<text.Length && char.IsHighSurrogate(text[offset+length-1])) length--;
            var inputs=new Input[length*2];
            for (int i=0;i<length;i++) {
                inputs[i*2]=Key(text[offset+i],false);
                inputs[i*2+1]=Key(text[offset+i],true);
            }
            uint sent=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)));
            if (sent!=inputs.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Text input was incomplete; observe the field before retrying.");
            offset+=length;
            if (delayMs>0) Thread.Sleep(delayMs);
            if (acknowledgedEdit!=0) {
                string expected=text.Substring(0,offset),actual="";
                var timer=Stopwatch.StartNew();
                do {
                    if (GetForegroundWindow().ToInt64()!=foregroundHandle || !GetGUIThreadInfo(0,ref info) || info.focus.ToInt64()!=focusHandle) {
                        var changed=new InvalidOperationException("Keyboard target changed while acknowledging text. Inspect content before retrying.");
                        changed.Data["PotatoErrorType"]="InputFocusChanged";changed.Data["NoInputSent"]=false;throw changed;
                    }
                    actual=ReadEmptyEditTarget(acknowledgedEdit,process);
                    if (PrefixConsumed(acknowledgedEdit,expected,actual)) break;
                    if (timer.ElapsedMilliseconds>=timeoutMs) {
                        var failure=new InvalidOperationException("Edit did not consume the typed prefix exactly. Remaining text was stopped; input was not repeated. Inspect actual text rather than assuming path/extension normalization.");
                        failure.Data["PotatoErrorType"]="TextConsumptionFailed";failure.Data["NoInputSent"]=false;
                        failure.Data["observedText"]=actual.Substring(0,Math.Min(192,actual.Length));
                        failure.Data["expectedLength"]=offset;failure.Data["observedLength"]=actual.Length;
                        failure.Data["acknowledgementMs"]=timer.ElapsedMilliseconds;failure.Data["timeoutMs"]=timeoutMs;
                        throw failure;
                    }
                    // Fast controls usually consume the packet immediately.
                    // Yield briefly before falling back to a scheduler sleep;
                    // a blind 1..5 ms sleep can round to an entire Windows tick.
                    if (delayMs==0 && timer.ElapsedMilliseconds<2) Thread.Yield();
                    else Thread.Sleep(1);
                } while (true);
            }
        }
    }
}
