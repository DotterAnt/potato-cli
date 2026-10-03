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
    public double MeanError, MaxTileError, AspectError;
    public int ReferenceExifOrientation=1;
    public void Dispose() { if (Bitmap!=null) { Bitmap.Dispose(); Bitmap=null; } }
}

public static class PotatoVisualCapture {
    static int ApplyDisplayOrientation(Image image) {
        if (Array.IndexOf(image.PropertyIdList,0x0112)<0) return 1;
        var property=image.GetPropertyItem(0x0112);
        if (property.Type!=3 || property.Value.Length!=2) throw new ArgumentException("Invalid EXIF orientation metadata.");
        int orientation=property.Value[0]+256*property.Value[1];
        if (orientation<1 || orientation>8) orientation=256*property.Value[0]+property.Value[1];
        RotateFlipType transform;
        switch (orientation) {
            case 1: transform=RotateFlipType.RotateNoneFlipNone; break;
            case 2: transform=RotateFlipType.RotateNoneFlipX; break;
            case 3: transform=RotateFlipType.Rotate180FlipNone; break;
            case 4: transform=RotateFlipType.RotateNoneFlipY; break;
            case 5: transform=RotateFlipType.Rotate90FlipX; break;
            case 6: transform=RotateFlipType.Rotate90FlipNone; break;
            case 7: transform=RotateFlipType.Rotate270FlipX; break;
            case 8: transform=RotateFlipType.Rotate270FlipNone; break;
            default: throw new ArgumentException("Invalid EXIF orientation metadata.");
        }
        if (orientation!=1) image.RotateFlip(transform);
        return orientation;
    }
    static void Validate(Rectangle screen,Rectangle comparison,int timeoutMs,int stableMs) {
        if (screen.Width<1 || screen.Height<1 || (long)screen.Width*screen.Height>16777216)
            throw new ArgumentException("Visual wait capture must contain 1..16777216 pixels.");
        if (comparison.X<0 || comparison.Y<0 || comparison.Width<1 || comparison.Height<1 ||
            (long)comparison.X+comparison.Width>screen.Width || (long)comparison.Y+comparison.Height>screen.Height)
            throw new ArgumentException("Comparison region must be a nonempty rectangle inside the screenshot, in image pixels.");
        if (timeoutMs<0 || timeoutMs>60000 || stableMs<0 || stableMs>10000 || stableMs>timeoutMs)
            throw new ArgumentException("Visual wait needs TimeoutMs 0..60000 and StableMs 0..10000, not exceeding TimeoutMs.");
    }
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
        Validate(screen,comparison,timeoutMs,stableMs);
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

    // Normalize the complete image/observed region, with the same RGB/tile
    // metric as replay assertions. Do not infer a region from unrelated chrome.
    static byte[] Normalize(Image image,Rectangle region) {
        using (var bitmap=new Bitmap(128,128)) {
            using (var graphics=Graphics.FromImage(bitmap))
            using (var attributes=new System.Drawing.Imaging.ImageAttributes()) {
                graphics.Clear(Color.White);
                graphics.InterpolationMode=System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                attributes.SetWrapMode(System.Drawing.Drawing2D.WrapMode.TileFlipXY);
                graphics.DrawImage(image,new Rectangle(0,0,128,128),region.X,region.Y,region.Width,region.Height,GraphicsUnit.Pixel,attributes);
            }
            var bits=bitmap.LockBits(new Rectangle(0,0,128,128),System.Drawing.Imaging.ImageLockMode.ReadOnly,System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try {
                var pixels=new byte[128*128*4];
                for (int y=0;y<128;y++)
                    System.Runtime.InteropServices.Marshal.Copy(IntPtr.Add(bits.Scan0,y*bits.Stride),pixels,y*128*4,128*4);
                return pixels;
            } finally {bitmap.UnlockBits(bits);}
        }
    }
    public static PotatoVisualFrame WaitForMatch(string referencePath,int rotation,Rectangle screen,Rectangle comparison,
        int timeoutMs,int stableMs,double maxMeanError,double maxTileError,double aspectTolerance) {
        Validate(screen,comparison,timeoutMs,stableMs);
        if (rotation!=0 && rotation!=90 && rotation!=180 && rotation!=270) throw new ArgumentException("ReferenceRotation must be 0,90,180,270 clockwise.");
        if (double.IsNaN(maxMeanError) || maxMeanError<0 || maxMeanError>32 ||
            double.IsNaN(maxTileError) || maxTileError<0 || maxTileError>64 ||
            double.IsNaN(aspectTolerance) || aspectTolerance<0 || aspectTolerance>0.1)
            throw new ArgumentException("Image match limits: mean 0..32, tile 0..64, aspect 0..0.1. Fix region/readiness/orientation instead of weakening content checks.");
        byte[] expected; double aspectError; int orientation;
        using (var stream=File.Open(referencePath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
            if (stream.Length>16777216) throw new ArgumentException("Visual reference exceeds 16 MiB.");
            using (var reference=Image.FromStream(stream,false,false)) {
                if ((long)reference.Width*reference.Height>16777216) throw new ArgumentException("Decoded visual reference exceeds 16777216 pixels.");
                orientation=ApplyDisplayOrientation(reference);
                if (rotation!=0) reference.RotateFlip(rotation==90 ? RotateFlipType.Rotate90FlipNone : rotation==180 ? RotateFlipType.Rotate180FlipNone : RotateFlipType.Rotate270FlipNone);
                aspectError=Math.Abs((comparison.Width/(double)comparison.Height)/(reference.Width/(double)reference.Height)-1);
                expected=Normalize(reference,new Rectangle(0,0,reference.Width,reference.Height));
            }
        }
        var result=new PotatoVisualFrame {AspectError=aspectError,ReferenceExifOrientation=orientation}; var clock=Stopwatch.StartNew(); long matchingSince=-1;
        try {
            do {
                if (result.Bitmap!=null) result.Bitmap.Dispose(); result.Bitmap=null;
                result.Bitmap=Capture(screen); result.Samples++;
                byte[] actual;
                using (var crop=result.Bitmap.Clone(comparison,System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                    actual=Normalize(crop,new Rectangle(0,0,crop.Width,crop.Height));
                var tiles=new double[64]; double sum=0;
                for (int y=0;y<128;y++) for (int x=0;x<128;x++) {
                    int offset=(y*128+x)*4; double delta=0;
                    for (int channel=0;channel<3;channel++) delta+=Math.Abs(actual[offset+channel]-expected[offset+channel]);
                    delta/=3;sum+=delta;tiles[(y/16)*8+x/16]+=delta;
                }
                result.MeanError=sum/(128*128);result.MaxTileError=0;
                foreach (double tile in tiles) result.MaxTileError=Math.Max(result.MaxTileError,tile/256);
                bool matches=aspectError<=aspectTolerance && result.MeanError<=maxMeanError && result.MaxTileError<=maxTileError;
                result.ElapsedMs=clock.ElapsedMilliseconds;
                if (!matches) matchingSince=-1; else if (matchingSince<0) matchingSince=result.ElapsedMs;
                result.ConditionMet=matches && result.ElapsedMs-matchingSince>=stableMs;
                if (result.ConditionMet || result.ElapsedMs>=timeoutMs) return result;
                Thread.Sleep((int)Math.Max(1,Math.Min(50,timeoutMs-result.ElapsedMs)));
            } while (true);
        } catch {result.Dispose();throw;}
    }
}
