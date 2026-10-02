using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

// Mouse motion and buttons share the checked input stream. No cursor warping,
// application APIs or synthetic document/canvas output.
public static class PotatoMouseNative {
    [StructLayout(LayoutKind.Sequential)]
    struct MouseInput { public int x,y; public uint data,flags,time; public IntPtr extra; }
    // MOUSEINPUT is the largest INPUT union member on both x86 and x64.
    [StructLayout(LayoutKind.Sequential)]
    struct Input { public uint type; public MouseInput mouse; }
    [DllImport("user32.dll",SetLastError=true)]
    static extern uint SendInput(uint count,Input[] input,int size);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

    public static int NormalizeCoordinate(int coordinate,int origin,int size) {
        if (size<=0 || (long)coordinate<origin || (long)coordinate>=(long)origin+size)
            throw new ArgumentOutOfRangeException("coordinate","Mouse point is outside the virtual desktop.");
        return (int)Math.Min(65535,Math.Floor(((long)coordinate-origin+0.5)*65536.0/size));
    }
    static void Send(MouseInput mouse) {
        var inputs=new[]{new Input {type=0,mouse=mouse}};
        if (SendInput(1,inputs,Marshal.SizeOf(typeof(Input)))!=1) {
            var failure=new Win32Exception(Marshal.GetLastWin32Error(),"Mouse input was not inserted; inspect the desktop before retrying.");
            failure.Data["PotatoErrorType"]="MouseInputRejected";
            failure.Data["NoInputSent"]=true;
            throw failure;
        }
    }
    public static void MoveTo(int x,int y) {
        Send(new MouseInput {
            x=NormalizeCoordinate(x,GetSystemMetrics(76),GetSystemMetrics(78)),
            y=NormalizeCoordinate(y,GetSystemMetrics(77),GetSystemMetrics(79)),
            flags=0x8000|0x4000|0x2000|0x0001
        });
    }
    public static void MouseEvent(int flags,int x,int y,int data,int extra) {
        Send(new MouseInput {x=x,y=y,data=(uint)data,flags=(uint)flags,extra=new IntPtr(extra)});
    }
    public static void Click(bool right,int count) {
        if (count<1 || count>2) throw new ArgumentOutOfRangeException("count");
        var inputs=new Input[count*2];
        for (int i=0;i<count;i++) {
            inputs[i*2]=new Input {type=0,mouse=new MouseInput {flags=right ? 0x0008u : 0x0002u}};
            inputs[i*2+1]=new Input {type=0,mouse=new MouseInput {flags=right ? 0x0010u : 0x0004u}};
        }
        // Insert the entire click/double-click without shell/UIA gaps between
        // presses. Queue insertion is not application transition verification.
        uint sent=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)));
        if (sent!=inputs.Length) {
            int error=Marshal.GetLastWin32Error();
            if (sent>0) SendInput(1,new[]{inputs[1]},Marshal.SizeOf(typeof(Input)));
            var failure=new Win32Exception(error,"Mouse click was incomplete; inspect the desktop before retrying.");
            failure.Data["PotatoErrorType"]="MouseInputRejected";
            failure.Data["NoInputSent"]=sent==0;
            throw failure;
        }
    }
    public static void MoveSmooth(int startX,int startY,int endX,int endY,int durationMs) {
        if (durationMs<50 || durationMs>10000) throw new ArgumentOutOfRangeException("durationMs");
        var clock=Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds<durationMs) {
            double fraction=(double)clock.ElapsedMilliseconds/durationMs;
            MoveTo((int)Math.Round(startX+((long)endX-startX)*fraction),
                   (int)Math.Round(startY+((long)endY-startY)*fraction));
            // Interpolate by elapsed time instead of accumulating per-step PS
            // overhead and timer rounding. Late samples never create a burst.
            Thread.Sleep((int)Math.Max(1,Math.Min(10,durationMs-clock.ElapsedMilliseconds)));
        }
        MoveTo(endX,endY);
    }
}
