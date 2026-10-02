using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;

// Read-only rendering wait for opaque controls. Never repeats GUI input.
public sealed class PotatoVisualFrame : IDisposable {
    public Bitmap Bitmap;
    public bool ConditionMet, Changed;
    public int Samples;
    public long ElapsedMs;
    public void Dispose() { if (Bitmap!=null) { Bitmap.Dispose(); Bitmap=null; } }
}

public static class PotatoVisualCapture {
    static Bitmap Capture(Rectangle screen) {
        var bitmap=new Bitmap(screen.Width,screen.Height);
        try {
            using (var graphics=Graphics.FromImage(bitmap))
                graphics.CopyFromScreen(screen.Location,Point.Empty,screen.Size);
            return bitmap;
        } catch { bitmap.Dispose(); throw; }
    }
    // A bounded 64x64 RGB sample grid avoids full desktop pixel copies and
    // PowerShell per-pixel loops. This detects visual change, not its meaning.
    static byte[] Sample(Bitmap bitmap,Rectangle region) {
        int width=Math.Min(64,region.Width),height=Math.Min(64,region.Height);
        var pixels=new byte[width*height*3]; int offset=0;
        for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
            int px=region.X+(int)(((long)x*2+1)*region.Width/(width*2));
            int py=region.Y+(int)(((long)y*2+1)*region.Height/(height*2));
            var color=bitmap.GetPixel(px,py);
            pixels[offset++]=color.R;pixels[offset++]=color.G;pixels[offset++]=color.B;
        }
        return pixels;
    }
    static bool Equal(byte[] left,byte[] right) {
        if (left==null || right==null || left.Length!=right.Length) return false;
        for (int i=0;i<left.Length;i++) if (left[i]!=right[i]) return false;
        return true;
    }
    public static PotatoVisualFrame Wait(string referencePath,Rectangle screen,Rectangle comparison,int timeoutMs,int stableMs) {
        if (screen.Width<1 || screen.Height<1 || (long)screen.Width*screen.Height>16777216)
            throw new ArgumentException("Visual wait capture must contain 1..16777216 pixels.");
        if (comparison.X<0 || comparison.Y<0 || comparison.Width<1 || comparison.Height<1 ||
            (long)comparison.X+comparison.Width>screen.Width || (long)comparison.Y+comparison.Height>screen.Height)
            throw new ArgumentException("ChangeRegionJson must be a nonempty rectangle inside the screenshot, in image pixels.");
        if (timeoutMs<0 || timeoutMs>60000 || stableMs<0 || stableMs>10000 || stableMs>timeoutMs)
            throw new ArgumentException("Visual wait needs TimeoutMs 0..60000 and StableMs 0..10000, not exceeding TimeoutMs.");
        byte[] baseline;
        using (var stream=File.Open(referencePath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
            if (stream.Length>16777216) throw new ArgumentException("Visual reference exceeds 16 MiB.");
            using (var image=Image.FromStream(stream,false,false)) {
                // Lossy reference artifacts can differ from identical screen
                // pixels and falsely signal a transition before any GUI update.
                if (image.RawFormat.Guid!=System.Drawing.Imaging.ImageFormat.Png.Guid)
                    throw new ArgumentException("Visual wait reference must be an original lossless PNG capture, not a JPEG/resized preview.");
                if (image.Width!=screen.Width || image.Height!=screen.Height)
                    throw new ArgumentException("Visual reference dimensions must match the capture region. Preserve the original physical pixel dimensions and origin.");
                using (var bitmap=new Bitmap(image)) baseline=Sample(bitmap,comparison);
            }
        }
        var result=new PotatoVisualFrame(); var clock=Stopwatch.StartNew();
        byte[] previous=null; long stableSince=0;
        try {
            do {
                if (result.Bitmap!=null) result.Bitmap.Dispose();
                result.Bitmap=null;
                result.Bitmap=Capture(screen);result.Samples++;
                var pixels=Sample(result.Bitmap,comparison);
                result.Changed=!Equal(baseline,pixels);
                if (!Equal(previous,pixels)) stableSince=clock.ElapsedMilliseconds;
                previous=pixels;
                result.ElapsedMs=clock.ElapsedMilliseconds;
                result.ConditionMet=result.Changed && result.ElapsedMs-stableSince>=stableMs;
                if (result.ConditionMet || result.ElapsedMs>=timeoutMs) return result;
                Thread.Sleep((int)Math.Max(1,Math.Min(50,timeoutMs-result.ElapsedMs)));
            } while (true);
        } catch {result.Dispose();throw;}
    }
}
