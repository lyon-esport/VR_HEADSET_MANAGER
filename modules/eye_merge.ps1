#################
# EYE MERGE - both lenses of a headset stitched into one wider, level picture
#################
#
# A headset's scrcpy frame holds both eyes side by side. Their two pictures differ by a pure rigid
# transform: the panels are mounted with opposite roll (the 22 / -21 deg angles of the Quest 3
# views) plus a shift. Both lenses share the same distortion, so far content lands on the same
# pixels once the transform is applied - no undistortion needed (ADR-0025).
#
# Geometry ("world" = the level merged picture, q in pixels, origin at the left-eye centre c):
#   left  eye pixel  pL = c     + R(-level) q
#   right eye pixel  pR = c + t + R(rel - level) q
# rel = relative_angle, t = (shift_x, shift_y), level = level_angle, R(a) = standard rotation with
# y pointing down. The calibration measures rel and t on a real frame:
#   right(c + R(rel)(pL - c) + t) == left(pL)   for far content.
#
# Everything a headset model needs is the small eye_merge block under
# scrcpy.parameters.<Model>.eye_merge in config.json (params only, shareable as a JSON snippet).
# The per-view crop of the merged picture is views.<view>.merged.crop ("w:h:x:y" on the merged
# canvas), drawn with the visual view editor. The lookup tables ffmpeg needs are a CACHE derived
# from those params (data\eye_merge\), rebuilt whenever the params or the crop change.

$script:EyeMergeCsharp = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public static class VrhmEyeMerge {

    // ---------------------------------------------------------------- image I/O (BGR, 3 bytes/px)
    public static byte[] LoadBgr(string path, out int w, out int h) {
        using (var src = new Bitmap(path)) {
            w = src.Width; h = src.Height;
            var rect = new Rectangle(0, 0, w, h);
            using (var bmp = src.Clone(rect, PixelFormat.Format24bppRgb)) {
                var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try {
                    var o = new byte[w * h * 3];
                    for (int y = 0; y < h; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), o, y * w * 3, w * 3);
                    return o;
                } finally { bmp.UnlockBits(data); }
            }
        }
    }

    public static void SaveBgrPng(byte[] bgr, int w, int h, string path) {
        using (var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
            var rect = new Rectangle(0, 0, w, h);
            var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            try { for (int y = 0; y < h; y++) Marshal.Copy(bgr, y * w * 3, IntPtr.Add(data.Scan0, y * data.Stride), w * 3); }
            finally { bmp.UnlockBits(data); }
            bmp.Save(path, ImageFormat.Png);
        }
    }

    static byte[] EyeLuma(byte[] bgr, int fw, int fh, int x0, int ew) {
        var g = new byte[ew * fh];
        for (int y = 0; y < fh; y++) for (int x = 0; x < ew; x++) {
            int i = (y * fw + x0 + x) * 3;
            g[y * ew + x] = (byte)((bgr[i] * 29 + bgr[i + 1] * 150 + bgr[i + 2] * 77) >> 8);
        }
        return g;
    }

    // ---------------------------------------------------------------- lens area
    // 255 inside the lens picture, 0 outside. Outside = dark pixels CONNECTED TO THE BORDER, so a
    // dark detail of the scene (shadow, black panel) inside the lens is never mistaken for it.
    public static byte[] LensMask(byte[] bgr, int fw, int fh, int x0, int ew, int thr) {
        var g = EyeLuma(bgr, fw, fh, x0, ew);
        int n = ew * fh; var outside = new bool[n]; var st = new Stack<int>();
        for (int x = 0; x < ew; x++) { st.Push(x); st.Push((fh - 1) * ew + x); }
        for (int y = 0; y < fh; y++) { st.Push(y * ew); st.Push(y * ew + ew - 1); }
        while (st.Count > 0) {
            int i = st.Pop();
            if (i < 0 || i >= n || outside[i] || g[i] > thr) continue;
            outside[i] = true; int x = i % ew;
            if (x > 0) st.Push(i - 1);
            if (x < ew - 1) st.Push(i + 1);
            st.Push(i - ew); st.Push(i + ew);
        }
        var m = new byte[n];
        for (int i = 0; i < n; i++) m[i] = outside[i] ? (byte)0 : (byte)255;
        return m;
    }

    // Lens outline as a polygon of n points (flat x,y list, eye-local pixels): radial march from the
    // centroid, last inside pixel before leaving the lens, then a MIN over 5 neighbours and a small
    // inward margin. Never a median or a mean: a vertex pushed OUTSIDE the real edge makes the
    // chord to its neighbour include black pixels, which showed as a straight dark line in the
    // blend band.
    public static int[] MaskPolygon(byte[] m, int ew, int eh, int n) { return MaskPolygon(m, ew, eh, n, 4); }
    public static int[] MaskPolygon(byte[] m, int ew, int eh, int n, int margin) {
        double sx = 0, sy = 0; long c = 0;
        for (int y = 0; y < eh; y += 2) for (int x = 0; x < ew; x += 2) if (m[y * ew + x] > 0) { sx += x; sy += y; c++; }
        if (c == 0) return new int[0];
        double cx = sx / c, cy = sy / c, rmax = Math.Sqrt((double)ew * ew + (double)eh * eh);
        var r = new double[n];
        for (int k = 0; k < n; k++) {
            double a = 2 * Math.PI * k / n, dx = Math.Cos(a), dy = Math.Sin(a), last = 0;
            for (double t = 0; t < rmax; t += 1) {
                int x = (int)(cx + dx * t), y = (int)(cy + dy * t);
                if (x < 0 || y < 0 || x >= ew || y >= eh) break;
                if (m[y * ew + x] > 0) last = t; else break;
            }
            r[k] = last;
        }
        var p = new int[n * 2];
        for (int k = 0; k < n; k++) {
            double rr = r[k];
            for (int j = -2; j <= 2; j++) rr = Math.Min(rr, r[(k + j + n) % n]);
            rr = Math.Max(0, rr - margin);
            double a = 2 * Math.PI * k / n;
            p[k * 2]     = Math.Max(0, Math.Min(ew - 1, (int)Math.Floor(cx + Math.Cos(a) * rr)));
            p[k * 2 + 1] = Math.Max(0, Math.Min(eh - 1, (int)Math.Floor(cy + Math.Sin(a) * rr)));
        }
        return p;
    }

    public static byte[] FillPolygon(int[] p, int ew, int eh) {
        var m = new byte[ew * eh]; int n = p.Length / 2; var xs = new List<double>();
        if (n < 3) return m;
        for (int y = 0; y < eh; y++) {
            double yc = y + 0.5; xs.Clear();
            for (int i = 0; i < n; i++) {
                int j = (i + 1) % n; double x1 = p[i * 2], y1 = p[i * 2 + 1], x2 = p[j * 2], y2 = p[j * 2 + 1];
                if ((y1 <= yc && y2 > yc) || (y2 <= yc && y1 > yc)) xs.Add(x1 + (yc - y1) * (x2 - x1) / (y2 - y1));
            }
            xs.Sort();
            for (int k = 0; k + 1 < xs.Count; k += 2) {
                int a = Math.Max(0, (int)Math.Ceiling(xs[k] - 0.5)), b = Math.Min(ew - 1, (int)Math.Floor(xs[k + 1] - 0.5));
                for (int x = a; x <= b; x++) m[y * ew + x] = 255;
            }
        }
        return m;
    }

    // Distance (px) from each inside pixel to the nearest outside pixel - 2-pass chamfer.
    static float[] Distance(byte[] m, int w, int h) {
        var d = new float[w * h];
        for (int i = 0; i < w * h; i++) d[i] = m[i] > 0 ? 1e6f : 0;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int i = y * w + x; if (d[i] == 0) continue; float v = d[i];
            v = Math.Min(v, x > 0 ? d[i - 1] + 1 : 1); v = Math.Min(v, y > 0 ? d[i - w] + 1 : 1);
            if (x > 0 && y > 0) v = Math.Min(v, d[i - w - 1] + 1.414f);
            if (x < w - 1 && y > 0) v = Math.Min(v, d[i - w + 1] + 1.414f);
            d[i] = v;
        }
        for (int y = h - 1; y >= 0; y--) for (int x = w - 1; x >= 0; x--) {
            int i = y * w + x; if (d[i] == 0) continue; float v = d[i];
            v = Math.Min(v, x < w - 1 ? d[i + 1] + 1 : 1); v = Math.Min(v, y < h - 1 ? d[i + w] + 1 : 1);
            if (x < w - 1 && y < h - 1) v = Math.Min(v, d[i + w + 1] + 1.414f);
            if (x > 0 && y < h - 1) v = Math.Min(v, d[i + w - 1] + 1.414f);
            d[i] = v;
        }
        return d;
    }

    // ---------------------------------------------------------------- registration
    static byte[] Down(byte[] g, int w, int h, int f, bool min) {
        int W = w / f, H = h / f; var o = new byte[W * H];
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int s = 0, mn = 255;
            for (int j = 0; j < f; j++) for (int i = 0; i < f; i++) { int v = g[(y * f + j) * w + x * f + i]; s += v; if (v < mn) mn = v; }
            o[y * W + x] = min ? (byte)mn : (byte)(s / (f * f));
        }
        return o;
    }

    static float[] Grad(byte[] g, byte[] m, int W, int H) {
        var o = new float[W * H];
        for (int i = 0; i < W * H; i++) o[i] = -1;
        for (int y = 2; y < H - 2; y++) for (int x = 2; x < W - 2; x++) {
            bool bad = false;
            for (int oy = -2; oy <= 2 && !bad; oy += 2) for (int ox = -2; ox <= 2; ox += 2) if (m[(y + oy) * W + x + ox] == 0) { bad = true; break; }
            if (bad) continue;
            float gx = g[y * W + x + 1] - g[y * W + x - 1], gy = g[(y + 1) * W + x] - g[(y - 1) * W + x];
            o[y * W + x] = (float)Math.Sqrt(gx * gx + gy * gy);
        }
        return o;
    }

    // Normalised cross-correlation of A against B sampled at c + R(deg)(p - c) + (dx,dy).
    static double Score(float[] A, float[] B, int W, int H, double deg, double dx, double dy, int step) {
        double c = Math.Cos(deg * Math.PI / 180), s = Math.Sin(deg * Math.PI / 180), cx = W / 2.0, cy = H / 2.0;
        double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0; int n = 0;
        for (int y = 0; y < H; y += step) for (int x = 0; x < W; x += step) {
            float a = A[y * W + x]; if (a < 0) continue;
            double u = x - cx, w = y - cy;
            int sx = (int)(cx + c * u - s * w + dx + 0.5), sy = (int)(cy + s * u + c * w + dy + 0.5);
            if (sx < 0 || sy < 0 || sx >= W || sy >= H) continue;
            float b = B[sy * W + sx]; if (b < 0) continue;
            sa += a; sb += b; saa += a * a; sbb += b * b; sab += a * b; n++;
        }
        if (n < (W * H) / (step * step) / 8) return -1;
        double ma = sa / n, mb = sb / n, va = saa / n - ma * ma, vb = sbb / n - mb * mb;
        if (va <= 0 || vb <= 0) return -1;
        return (sab / n - ma * mb) / Math.Sqrt(va * vb);
    }

    static double[] Search(float[] A, float[] B, int W, int H, double a0, double a1, double astep,
                           double cx0, double cy0, int range, int tstep, int step) {
        object lk = new object(); double best = -2, bd = 0, bx = 0, by = 0;
        int na = (int)Math.Round((a1 - a0) / astep) + 1;
        Parallel.For(0, na, i => {
            double d = a0 + i * astep, lb = -2, lx = 0, ly = 0;
            for (int ty = -range; ty <= range; ty += tstep) for (int tx = -range; tx <= range; tx += tstep) {
                double sc = Score(A, B, W, H, d, cx0 + tx, cy0 + ty, step);
                if (sc > lb) { lb = sc; lx = cx0 + tx; ly = cy0 + ty; }
            }
            lock (lk) { if (lb > best) { best = lb; bd = d; bx = lx; by = ly; } }
        });
        return new double[] { bd, bx, by, best };
    }

    // Measures the rigid transform between the eyes of one side-by-side frame.
    // Returns { relative_angle, shift_x, shift_y, score } in full-resolution pixels.
    public static double[] Register(byte[] bgr, int fw, int fh, byte[] mL, byte[] mR, double a0, double a1) {
        int ew = fw / 2;
        var gL = EyeLuma(bgr, fw, fh, 0, ew); var gR = EyeLuma(bgr, fw, fh, ew, ew);
        Func<int, float[][]> level = f => {
            int W = ew / f, H = fh / f;
            return new float[][] { Grad(Down(gL, ew, fh, f, false), Down(mL, ew, fh, f, true), W, H),
                                   Grad(Down(gR, ew, fh, f, false), Down(mR, ew, fh, f, true), W, H) };
        };
        var l8 = level(8); int W8 = ew / 8, H8 = fh / 8;
        var r = Search(l8[0], l8[1], W8, H8, a0, a1, 1, 0, 0, Math.Max(20, W8 * 3 / 10), 2, 2);
        var l4 = level(4); int W4 = ew / 4, H4 = fh / 4;
        r = Search(l4[0], l4[1], W4, H4, r[0] - 1.5, r[0] + 1.5, 0.5, Math.Round(r[1] * 2), Math.Round(r[2] * 2), 6, 1, 2);
        var l2 = level(2); int W2 = ew / 2, H2 = fh / 2;
        r = Search(l2[0], l2[1], W2, H2, r[0] - 0.5, r[0] + 0.5, 0.25, Math.Round(r[1] * 2), Math.Round(r[2] * 2), 3, 1, 2);
        // Half-resolution shift -> full resolution, correcting the half-pixel offset of the box downscale.
        double c = Math.Cos(r[0] * Math.PI / 180), s = Math.Sin(r[0] * Math.PI / 180), k = 0.5;
        double fx = 2 * r[1] - ((c - 1) * k - s * k), fy = 2 * r[2] - (s * k + (c - 1) * k);
        return new double[] { r[0], Math.Round(fx), Math.Round(fy), r[3] };
    }

    // ---------------------------------------------------------------- merged canvas geometry
    // P = { ew, eh, rel, tx, ty, level }
    static void ToLeft(double[] P, double qx, double qy, out double x, out double y) {
        double a = -P[5] * Math.PI / 180, c = Math.Cos(a), s = Math.Sin(a);
        x = P[0] / 2.0 + c * qx - s * qy; y = P[1] / 2.0 + s * qx + c * qy;
    }
    static void ToRight(double[] P, double qx, double qy, out double x, out double y) {
        double a = (P[2] - P[5]) * Math.PI / 180, c = Math.Cos(a), s = Math.Sin(a);
        x = P[0] / 2.0 + P[3] + c * qx - s * qy; y = P[1] / 2.0 + P[4] + s * qx + c * qy;
    }

    // Bounding box of the union of both lens areas in world coordinates: { ox, oy, w, h } (even w/h).
    public static int[] CanvasBox(double[] P, int[] polyL, int[] polyR) {
        double minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
        Action<int[], double, bool> add = (poly, ang, right) => {
            double a = ang * Math.PI / 180, c = Math.Cos(a), s = Math.Sin(a);
            for (int i = 0; i + 1 < poly.Length; i += 2) {
                double px = poly[i] - P[0] / 2.0 - (right ? P[3] : 0), py = poly[i + 1] - P[1] / 2.0 - (right ? P[4] : 0);
                double qx = c * px - s * py, qy = s * px + c * py;
                minx = Math.Min(minx, qx); maxx = Math.Max(maxx, qx); miny = Math.Min(miny, qy); maxy = Math.Max(maxy, qy);
            }
        };
        add(polyL, P[5], false);         // q = R(level) (pL - c)
        add(polyR, P[5] - P[2], true);   // q = R(level - rel) (pR - c - t)
        int ox = (int)Math.Floor(minx), oy = (int)Math.Floor(miny);
        int w = (int)Math.Ceiling(maxx) - ox, h = (int)Math.Ceiling(maxy) - oy;
        w += w % 2; h += h % 2;
        return new int[] { ox, oy, w, h };
    }

    // Shared sampler: for canvas pixel (u,v) returns base/other FRAME coordinates (or -1) and the
    // weight of the base eye (0..255).
    sealed class Ctx {
        public double[] P; public byte[] mL, mR, featherL, featherR; public float[] dL, dR;
        public bool baseRight; public int ew, eh, ox, oy;
    }
    static Ctx MakeCtx(double[] P, int[] polyL, int[] polyR, int[] box, bool baseRight, int inset, int feather) {
        var x = new Ctx(); x.P = P; x.ew = (int)P[0]; x.eh = (int)P[1]; x.ox = box[0]; x.oy = box[1]; x.baseRight = baseRight;
        x.mL = FillPolygon(polyL, x.ew, x.eh); x.mR = FillPolygon(polyR, x.ew, x.eh);
        // Both eyes get a feather ramp now: each picture darkens towards its own lens edge, so the
        // OTHER eye must not be used right up to its rim either.
        x.dL = Distance(x.mL, x.ew, x.eh); x.dR = Distance(x.mR, x.ew, x.eh);
        x.featherL = Ramp(x.dL, inset, feather); x.featherR = Ramp(x.dR, inset, feather);
        return x;
    }
    static byte[] Ramp(float[] d, int inset, int feather) {
        var o = new byte[d.Length];
        for (int i = 0; i < d.Length; i++) {
            double t = (d[i] - inset) / Math.Max(1, feather); t = Math.Max(0, Math.Min(1, t)); t = t * t * (3 - 2 * t);
            o[i] = (byte)Math.Round(t * 255);
        }
        return o;
    }
    static void Sample(Ctx k, double u, double v, out double bx, out double by, out double ox, out double oy, out int w) {
        double qx = k.ox + u, qy = k.oy + v, lx, ly, rx, ry;
        ToLeft(k.P, qx, qy, out lx, out ly); ToRight(k.P, qx, qy, out rx, out ry);
        int ilx = (int)Math.Round(lx), ily = (int)Math.Round(ly), irx = (int)Math.Round(rx), iry = (int)Math.Round(ry);
        bool inL = ilx >= 0 && ily >= 0 && ilx < k.ew && ily < k.eh && k.mL[ily * k.ew + ilx] > 0;
        bool inR = irx >= 0 && iry >= 0 && irx < k.ew && iry < k.eh && k.mR[iry * k.ew + irx] > 0;
        bool inB = k.baseRight ? inR : inL, inO = k.baseRight ? inL : inR;
        // Frame coordinates: the right eye sits ew pixels to the right in the side-by-side frame.
        bx = !inB ? -1 : (k.baseRight ? rx + k.ew : lx); by = !inB ? -1 : (k.baseRight ? ry : ly);
        ox = !inO ? -1 : (k.baseRight ? lx : rx + k.ew); oy = !inO ? -1 : (k.baseRight ? ly : ry);
        if (!inB) { w = 0; return; }
        if (!inO) { w = 255; return; }
        // Two-sided weight. sb / so = how usable each eye is here (0 at its dark lens rim, 1 inside).
        // The base keeps 100 % wherever it is fully usable (centre: no parallax ghosting); near the
        // base rim the other eye takes over only as far as IT is usable; where both rims overlap
        // the eye further from its own edge wins instead of blending two dark pixels.
        int iL = ily * k.ew + ilx, iR = iry * k.ew + irx;
        double sL = k.featherL[iL] / 255.0, sR = k.featherR[iR] / 255.0;
        double sb = k.baseRight ? sR : sL, so = k.baseRight ? sL : sR;
        double den = sb + (1 - sb) * so;
        if (den < 1e-3) {
            float db = k.baseRight ? k.dR[iR] : k.dL[iL], dO = k.baseRight ? k.dL[iL] : k.dR[iR];
            w = db >= dO ? 255 : 0;
        } else {
            w = (int)Math.Round(255 * sb / den);
        }
    }

    // Width of the darkened rim (vignette) of the lens pictures, in eye pixels: each eye's
    // brightness is compared with the other eye's aligned pixel (taken well inside the other lens)
    // as a function of the distance to its own edge; the rim ends where the median ratio reaches
    // 'ratio' for good. Returns the larger of the two eyes, or -1 when the overlap is too small.
    public static int MeasureFalloff(byte[] bgr, int fw, int fh, double[] P, int[] polyL, int[] polyR, int[] box, double ratio) {
        int ew = fw / 2;
        var gL = EyeLuma(bgr, fw, fh, 0, ew); var gR = EyeLuma(bgr, fw, fh, ew, ew);
        var mL = FillPolygon(polyL, ew, fh); var mR = FillPolygon(polyR, ew, fh);
        var dL = Distance(mL, ew, fh); var dR = Distance(mR, ew, fh);
        const int BIN = 10, NB = 40;                       // 0..400 px from the edge
        var binsL = new List<double>[NB]; var binsR = new List<double>[NB];
        for (int i = 0; i < NB; i++) { binsL[i] = new List<double>(); binsR[i] = new List<double>(); }
        for (int v = 0; v < box[3]; v += 3) for (int u = 0; u < box[2]; u += 3) {
            double lx, ly, rx, ry;
            ToLeft(P, box[0] + u, box[1] + v, out lx, out ly); ToRight(P, box[0] + u, box[1] + v, out rx, out ry);
            int ilx = (int)Math.Round(lx), ily = (int)Math.Round(ly), irx = (int)Math.Round(rx), iry = (int)Math.Round(ry);
            if (ilx < 0 || ily < 0 || ilx >= ew || ily >= fh || irx < 0 || iry < 0 || irx >= ew || iry >= fh) continue;
            int iL = ily * ew + ilx, iR = iry * ew + irx;
            if (mL[iL] == 0 || mR[iR] == 0) continue;
            // Left eye near its rim, measured against the right eye deep inside its lens.
            if (dR[iR] > 300 && gR[iR] >= 40 && gR[iR] <= 230 && dL[iL] < BIN * NB) binsL[(int)(dL[iL] / BIN)].Add(gL[iL] / (double)gR[iR]);
            if (dL[iL] > 300 && gL[iL] >= 40 && gL[iL] <= 230 && dR[iR] < BIN * NB) binsR[(int)(dR[iR] / BIN)].Add(gR[iR] / (double)gL[iL]);
        }
        int a = RimWidth(binsL, BIN, ratio), b = RimWidth(binsR, BIN, ratio);
        if (a < 0 && b < 0) return -1;
        return Math.Max(a, b);
    }
    static int RimWidth(List<double>[] bins, int binPx, double ratio) {
        int nb = bins.Length; var med = new double[nb]; var ok = new bool[nb]; int filled = 0;
        for (int i = 0; i < nb; i++) {
            if (bins[i].Count < 40) continue;
            bins[i].Sort(); med[i] = bins[i][bins[i].Count / 2]; ok[i] = true; filled++;
        }
        if (filled < 6) return -1;
        // The rim ends at the first bin from which every later measured bin reaches the ratio.
        for (int i = 0; i < nb; i++) {
            if (!ok[i]) continue;
            bool all = true;
            for (int j = i; j < nb; j++) if (ok[j] && med[j] < ratio) { all = false; break; }
            if (all) return i * binPx;
        }
        return nb * binPx;
    }

    // The flat merged canvas (what the operator crops in the view editor), bilinear, black outside.
    public static void RenderCanvas(byte[] bgr, int fw, int fh, double[] P, int[] polyL, int[] polyR, int[] box,
                                    bool baseRight, int inset, int feather, string outPng) {
        var k = MakeCtx(P, polyL, polyR, box, baseRight, inset, feather);
        int W = box[2], H = box[3]; var o = new byte[W * H * 3];
        Parallel.For(0, H, v => {
            var pb = new double[3]; var po = new double[3];
            for (int u = 0; u < W; u++) {
                double bx, by, ox, oy; int w;
                Sample(k, u, v, out bx, out by, out ox, out oy, out w);
                bool hb = Bilinear(bgr, fw, fh, bx, by, pb), ho = Bilinear(bgr, fw, fh, ox, oy, po);
                int i = (v * W + u) * 3;
                for (int c = 0; c < 3; c++) {
                    double val = (hb ? pb[c] * w : 0) + (ho ? po[c] * (255 - w) : 0);
                    if (!ho && hb) val = pb[c] * 255; if (!hb && ho) val = po[c] * 255;
                    o[i + c] = (byte)Math.Max(0, Math.Min(255, Math.Round(val / 255)));
                }
            }
        });
        SaveBgrPng(o, W, H, outPng);
    }

    static bool Bilinear(byte[] bgr, int fw, int fh, double x, double y, double[] px) {
        if (x < 0 || y < 0) return false;
        int ix = (int)Math.Floor(x), iy = (int)Math.Floor(y);
        if (ix >= fw - 1 || iy >= fh - 1) return false;
        double fx = x - ix, fy = y - iy;
        for (int c = 0; c < 3; c++) {
            px[c] = bgr[(iy * fw + ix) * 3 + c] * (1 - fx) * (1 - fy) + bgr[(iy * fw + ix + 1) * 3 + c] * fx * (1 - fy)
                  + bgr[((iy + 1) * fw + ix) * 3 + c] * (1 - fx) * fy + bgr[((iy + 1) * fw + ix + 1) * 3 + c] * fx * fy;
        }
        return true;
    }

    // ffmpeg remap tables for one crop of the canvas: base/other x,y (gray16le, 65535 = outside)
    // and the base weight (gray8). Files: <prefix>.bx.raw .by.raw .ox.raw .oy.raw .w.raw
    // The output may be smaller than the crop (model max_size): the downscale is baked into the
    // tables, so it costs nothing at runtime.
    public static void BuildMaps(string prefix, double[] P, int[] polyL, int[] polyR, int[] box, bool baseRight,
                                 int inset, int feather, int cx, int cy, int cw, int ch, int ow, int oh) {
        var k = MakeCtx(P, polyL, polyR, box, baseRight, inset, feather);
        double sx = (double)cw / ow, sy = (double)ch / oh;
        int n = ow * oh; var bxm = new byte[n * 2]; var bym = new byte[n * 2]; var oxm = new byte[n * 2]; var oym = new byte[n * 2]; var wm = new byte[n];
        Parallel.For(0, oh, v => {
            for (int u = 0; u < ow; u++) {
                double bx, by, ox, oy; int w;
                Sample(k, cx + (u + 0.5) * sx - 0.5, cy + (v + 0.5) * sy - 0.5, out bx, out by, out ox, out oy, out w);
                int i = v * ow + u;
                Put16(bxm, i, bx); Put16(bym, i, by); Put16(oxm, i, ox); Put16(oym, i, oy);
                wm[i] = (byte)w;
            }
        });
        File.WriteAllBytes(prefix + ".bx.raw", bxm); File.WriteAllBytes(prefix + ".by.raw", bym);
        File.WriteAllBytes(prefix + ".ox.raw", oxm); File.WriteAllBytes(prefix + ".oy.raw", oym);
        File.WriteAllBytes(prefix + ".w.raw", wm);
    }
    static void Put16(byte[] a, int i, double v) {
        int x = v < 0 ? 65535 : (int)Math.Round(v); if (x > 65535) x = 65535;
        a[i * 2] = (byte)(x & 255); a[i * 2 + 1] = (byte)(x >> 8);
    }

    // ---------------------------------------------------------------- stream transparency masks
    // White PNG whose ALPHA is 0 outside the lens picture and ramps to 255 from 'inset' to
    // 'inset + feather' px inside it. Applied by the browser pages with CSS mask-image: an H.264 /
    // HEVC stream has no alpha channel, so the transparency cannot travel in the video itself.
    static void SaveAlphaMask(bool[] valid, int w, int h, int inset, int feather, string outPng) {
        // The picture border is NOT a lens edge: only a lens outline fades, never the crop edges.
        var d = new float[w * h];
        for (int i = 0; i < w * h; i++) d[i] = valid[i] ? 1e6f : 0;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int i = y * w + x; if (d[i] == 0) continue; float v = d[i];
            if (x > 0) v = Math.Min(v, d[i - 1] + 1); if (y > 0) v = Math.Min(v, d[i - w] + 1);
            if (x > 0 && y > 0) v = Math.Min(v, d[i - w - 1] + 1.414f); if (x < w - 1 && y > 0) v = Math.Min(v, d[i - w + 1] + 1.414f); d[i] = v; }
        for (int y = h - 1; y >= 0; y--) for (int x = w - 1; x >= 0; x--) { int i = y * w + x; if (d[i] == 0) continue; float v = d[i];
            if (x < w - 1) v = Math.Min(v, d[i + 1] + 1); if (y < h - 1) v = Math.Min(v, d[i + w] + 1);
            if (x < w - 1 && y < h - 1) v = Math.Min(v, d[i + w + 1] + 1.414f); if (x > 0 && y < h - 1) v = Math.Min(v, d[i + w - 1] + 1.414f); d[i] = v; }
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            var rect = new Rectangle(0, 0, w, h);
            var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            var row = new byte[w * 4];
            try {
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        double t = (d[y * w + x] - inset) / Math.Max(1, feather); t = Math.Max(0, Math.Min(1, t)); t = t * t * (3 - 2 * t);
                        row[x * 4] = 255; row[x * 4 + 1] = 255; row[x * 4 + 2] = 255; row[x * 4 + 3] = (byte)Math.Round(t * 255);
                    }
                    Marshal.Copy(row, 0, IntPtr.Add(data.Scan0, y * data.Stride), w * 4);
                }
            } finally { bmp.UnlockBits(data); }
            bmp.Save(outPng, ImageFormat.Png);
        }
    }

    // Mask of a MERGED stream, read from its remap tables: an output pixel is picture when at least
    // one eye is sampled there (table value != 65535), so the mask can never drift from the merge.
    public static void StreamMaskFromMaps(string prefix, int w, int h, int inset, int feather, string outPng) {
        var bx = File.ReadAllBytes(prefix + ".bx.raw"); var ox = File.ReadAllBytes(prefix + ".ox.raw");
        var valid = new bool[w * h];
        for (int i = 0; i < w * h; i++)
            valid[i] = !(bx[i * 2] == 255 && bx[i * 2 + 1] == 255) || !(ox[i * 2] == 255 && ox[i * 2 + 1] == 255);
        SaveAlphaMask(valid, w, h, inset, feather, outPng);
    }

    // Mask of a single-eye stream: scrcpy --crop + --angle keeps the crop size and rotates the
    // picture around the CROP CENTRE, sampling the full frame (measured on a Quest 3:
    // output(p) = frame(cropCentre + R(-angle)(p - outCentre)), 44 dB against the real output).
    // An output pixel is picture when it lands inside the frame and inside the lens outline of the
    // eye it falls in (polyL / polyR in eye-local pixels, the right eye starting at fw / 2).
    public static void StreamMaskFromCrop(int fw, int fh, int cx, int cy, int cw, int ch, double angle,
                                          int[] polyL, int[] polyR, int inset, int feather, string outPng) {
        int ew = fw / 2;
        var mL = FillPolygon(polyL, ew, fh); var mR = FillPolygon(polyR, ew, fh);
        double a = -angle * Math.PI / 180, c = Math.Cos(a), s = Math.Sin(a);
        double ccx = cx + cw / 2.0, ccy = cy + ch / 2.0;
        var valid = new bool[cw * ch];
        for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) {
            double u = x + 0.5 - cw / 2.0, v = y + 0.5 - ch / 2.0;
            int sx = (int)Math.Floor(ccx + c * u - s * v), sy = (int)Math.Floor(ccy + s * u + c * v);
            bool ok = false;
            if (sx >= 0 && sy >= 0 && sx < fw && sy < fh) ok = sx < ew ? mL[sy * ew + sx] > 0 : mR[sy * ew + sx - ew] > 0;
            valid[y * cw + x] = ok;
        }
        SaveAlphaMask(valid, cw, ch, inset, feather, outPng);
    }

    // Largest rectangle of the given aspect fully inside the merged lens area: { w, h, x, y } (even).
    public static int[] DefaultCrop(double[] P, int[] polyL, int[] polyR, int[] box, double aspect) {
        const int F = 4;
        var k = MakeCtx(P, polyL, polyR, box, true, 0, 1);
        int W = box[2] / F, H = box[3] / F; var bad = new int[(W + 1) * (H + 1)];
        var valid = new bool[W * H];
        Parallel.For(0, H, v => {
            for (int u = 0; u < W; u++) {
                bool all = true;
                for (int j = 0; j < 2 && all; j++) for (int i = 0; i < 2; i++) {
                    double bx, by, ox, oy; int w;
                    Sample(k, u * F + i * (F - 1), v * F + j * (F - 1), out bx, out by, out ox, out oy, out w);
                    if (bx < 0 && ox < 0) { all = false; break; }
                }
                valid[v * W + u] = all;
            }
        });
        for (int y = 0; y < H; y++) { int row = 0; for (int x = 0; x < W; x++) { row += valid[y * W + x] ? 0 : 1; bad[(y + 1) * (W + 1) + x + 1] = bad[y * (W + 1) + x + 1] + row; } }
        for (int w = W; w >= 4; w--) {
            int h = (int)Math.Round(w / aspect); if (h > H || h < 2) continue;
            int bestX = -1, bestY = -1; double bestD = 1e18;
            for (int y = 0; y + h <= H; y++) for (int x = 0; x + w <= W; x++) {
                int b = bad[(y + h) * (W + 1) + x + w] - bad[y * (W + 1) + x + w] - bad[(y + h) * (W + 1) + x] + bad[y * (W + 1) + x];
                if (b != 0) continue;
                double d = Math.Pow(x + w / 2.0 - W / 2.0, 2) + Math.Pow(y + h / 2.0 - H / 2.0, 2);
                if (d < bestD) { bestD = d; bestX = x; bestY = y; }
            }
            if (bestX >= 0) {
                int cw = (w * F) & ~1, chh = (h * F) & ~1;
                return new int[] { cw, chh, bestX * F, bestY * F };
            }
        }
        return new int[] { box[2], box[3], 0, 0 };
    }
}
'@

function Initialize-EyeMergeType {
    if ('VrhmEyeMerge' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition $script:EyeMergeCsharp -ReferencedAssemblies System.Drawing -ErrorAction Stop
        return $true
    } catch {
        Write-Log ("Eye merge: could not compile the image helper: {0}" -f $_.Exception.Message) -Level ERROR
        return $false
    }
}


# Lens outline <-> compact text "x,y x,y ..." (eye-local pixels). Text keeps config.json readable:
# as a JSON array, ConvertTo-Json would write one line per number (~256 lines per model).
# Example: ConvertFrom-EyeMergePolygon -Text '10,20 30,40 50,60'   -> int[] 10,20,30,40,50,60
function ConvertFrom-EyeMergePolygon {
    param([string]$Text)
    $out = [System.Collections.Generic.List[int]]::new()
    if (-not $Text) { return ,[int[]]@() }
    foreach ($pair in ($Text.Trim() -split '\s+')) {
        if ($pair -notmatch '^(\d{1,5}),(\d{1,5})$') { return ,[int[]]@() }
        $out.Add([int]$Matches[1]); $out.Add([int]$Matches[2])
    }
    return ,$out.ToArray()
}

function ConvertTo-EyeMergePolygon {
    param([int[]]$Points)
    $pairs = for ($i = 0; $i + 1 -lt $Points.Count; $i += 2) { '{0},{1}' -f $Points[$i], $Points[$i + 1] }
    return ($pairs -join ' ')
}


# Validates an eye_merge block (PSCustomObject or hashtable from JSON). Returns @{Ok;Errors}.
# Example: (Test-EyeMergeProfile -MergeProfile $global:scrcpyParameters.'Quest 3'.eye_merge).Ok
function Test-EyeMergeProfile {
    param([Parameter(Mandatory)] $MergeProfile)
    $errors = [System.Collections.Generic.List[string]]::new()
    $num = {
        param($name, $min, $max)
        $v = $MergeProfile.$name
        $d = 0.0
        if ($null -eq $v -or -not [double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
            $errors.Add("$name is missing or not a number"); return
        }
        if ($d -lt $min -or $d -gt $max) { $errors.Add("$name must be between $min and $max") }
    }
    if ([string]$MergeProfile.schema -ne '1') { $errors.Add('schema must be 1') }
    & $num 'frame_width'    100 16384
    & $num 'frame_height'   100 16384
    & $num 'relative_angle' -90 90
    & $num 'shift_x'        -4000 4000
    & $num 'shift_y'        -4000 4000
    & $num 'level_angle'    -90 90
    & $num 'feather_px'     0 2000
    & $num 'inset_px'       0 1000
    if ($MergeProfile.frame_width -and ([int]$MergeProfile.frame_width % 2) -ne 0) { $errors.Add('frame_width must be even (two eyes side by side)') }
    if ([string]$MergeProfile.base_eye -notin @('L','R')) { $errors.Add('base_eye must be L or R') }
    foreach ($m in 'mask_left','mask_right') {
        $pts = ConvertFrom-EyeMergePolygon -Text ([string]$MergeProfile.$m)
        if ($pts.Count -lt 16 -or $pts.Count -gt 2048) { $errors.Add("$m must be 8 to 1024 'x,y' points separated by spaces"); continue }
        $ew = [int]$MergeProfile.frame_width / 2
        for ($i = 0; $i -lt $pts.Count; $i++) {
            $lim = if ($i % 2 -eq 0) { $ew } else { [int]$MergeProfile.frame_height }
            if ($pts[$i] -ge $lim) { $errors.Add("$m has a point outside the eye image"); break }
        }
    }
    return @{ Ok = ($errors.Count -eq 0); Errors = @($errors) }
}


# Re-reads scrcpy.parameters from config.json when the file changed since this process last read it.
# Needed because a calibration, an import or a crop can be written by ANOTHER process (console menu,
# VRMonitor, web server) while each one keeps its own $global:scrcpyParameters: the web server only
# reloads config on /api/config/save, so the view editor's merged picture kept the OLD lens outlines
# (straight black line in the seam) after a recalibration. One file timestamp read when unchanged.
# Example: Update-EyeMergeParameters
function Update-EyeMergeParameters {
    try {
        $cfgPath = Join-Path $global:ScriptPath 'config\config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) { return }
        $stamp = [System.IO.File]::GetLastWriteTimeUtc($cfgPath)
        if ($script:EyeMergeConfigStamp -and $script:EyeMergeConfigStamp -eq $stamp) { return }
        $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
        if ($cfg -and $cfg.scrcpy -and $cfg.scrcpy.parameters) {
            # Same shape config_files_loader.ps1 gives it.
            $global:scrcpyParameters = @($cfg.scrcpy.parameters)
            $script:EyeMergeConfigStamp = $stamp
        }
    } catch {
        Write-Log ("Eye merge: could not refresh the calibration from config.json: {0}" -f $_.Exception.Message) -Level DEBUG
    }
}


# The eye_merge block of a model when it is present, enabled and valid; $null otherwise.
# Example: $p = Get-EyeMergeProfile -Model 'Quest 3'
function Get-EyeMergeProfile {
    param([string]$Model, [switch]$IncludeDisabled)
    Update-EyeMergeParameters
    if (-not $Model -or -not $global:scrcpyParameters) { return $null }
    $tpl = $global:scrcpyParameters.$Model
    if (-not $tpl -or $tpl -is [string] -or -not $tpl.eye_merge) { return $null }
    $p = $tpl.eye_merge
    if (-not $IncludeDisabled -and $p.enabled -eq $false) { return $null }
    # Validation (two 256-point outlines) costs ~6 ms and this runs in the scrcpy watchdog for every
    # headset: remember the result for this exact object - a config reload creates a new one.
    if (-not $script:EyeMergeValidated) { $script:EyeMergeValidated = @{} }
    $memo = $script:EyeMergeValidated[$Model]
    if ($memo -and [object]::ReferenceEquals($memo.Obj, $p)) { if ($memo.Ok) { return $p } else { return $null } }
    $t = Test-EyeMergeProfile -MergeProfile $p
    $script:EyeMergeValidated[$Model] = @{ Obj = $p; Ok = $t.Ok }
    if (-not $t.Ok) {
        Write-Log ("Eye merge profile of '{0}' is invalid: {1}" -f $Model, ($t.Errors -join '; ')) -Level WARNING
        return $null
    }
    return $p
}


# $true when the model has an enabled, valid eye_merge calibration (the "supported" flag).
# Example: if (Test-EyeMergeSupported -Model 'Quest 2') { ... }
function Test-EyeMergeSupported {
    param([string]$Model)
    return ($null -ne (Get-EyeMergeProfile -Model $Model))
}


# Internal: profile -> parameter arrays for the C# helper, plus the canvas box.
function Get-EyeMergeGeometry {
    param([Parameter(Mandatory)] $MergeProfile)
    # PowerShell casts are culture-invariant; never go through a formatted string here (fr-FR
    # would turn 43.5 into "43,5").
    # Each element in its own parentheses: the comma binds tighter than '/'.
    $P = [double[]]@((([double]$MergeProfile.frame_width) / 2), ([double]$MergeProfile.frame_height),
                     ([double]$MergeProfile.relative_angle), ([double]$MergeProfile.shift_x),
                     ([double]$MergeProfile.shift_y), ([double]$MergeProfile.level_angle))
    $polyL = ConvertFrom-EyeMergePolygon -Text ([string]$MergeProfile.mask_left)
    $polyR = ConvertFrom-EyeMergePolygon -Text ([string]$MergeProfile.mask_right)
    $box = [VrhmEyeMerge]::CanvasBox($P, $polyL, $polyR)
    return @{
        P = $P; PolyL = $polyL; PolyR = $polyR; Box = $box
        BaseRight = ([string]$MergeProfile.base_eye -ne 'L')
        Inset = [int]$MergeProfile.inset_px; Feather = [int]$MergeProfile.feather_px
        CanvasWidth = $box[2]; CanvasHeight = $box[3]
    }
}


# Crop of the merged canvas used by one view: views.<view>.merged.crop when set (clamped to the
# canvas), otherwise the largest clean rectangle with the aspect ratio of the view's eye crop
# ('fullscreen' / 0:0:0:0 = the whole canvas). Returns @{W;H;X;Y;Auto} or $null.
# Example: Get-EyeMergeViewCrop -Model 'Quest 3' -View 'square'
function Get-EyeMergeViewCrop {
    param([Parameter(Mandatory)][string]$Model, [string]$View, $MergeProfile = $null)
    if (-not $MergeProfile) { $MergeProfile = Get-EyeMergeProfile -Model $Model }
    if (-not $MergeProfile -or -not (Initialize-EyeMergeType)) { return $null }
    $g = Get-EyeMergeGeometry -MergeProfile $MergeProfile
    $cw = $g.CanvasWidth; $ch = $g.CanvasHeight
    $viewObj = $null
    $tpl = $global:scrcpyParameters.$Model
    if ($View -and $tpl -and $tpl.views) { $viewObj = $tpl.views.$View }

    $crop = if ($viewObj -and $viewObj.merged) { [string]$viewObj.merged.crop } else { '' }
    if ($crop -match '^(\d+):(\d+):(\d+):(\d+)$' -and [int]$Matches[1] -gt 0 -and [int]$Matches[2] -gt 0) {
        $w = [int]$Matches[1]; $h = [int]$Matches[2]; $x = [int]$Matches[3]; $y = [int]$Matches[4]
        $x = [Math]::Min([Math]::Max(0, $x), $cw - 2); $y = [Math]::Min([Math]::Max(0, $y), $ch - 2)
        $w = [Math]::Min($w, $cw - $x); $h = [Math]::Min($h, $ch - $y)
        $w -= $w % 2; $h -= $h % 2
        return @{ W = $w; H = $h; X = $x; Y = $y; Auto = $false }
    }

    # Automatic default from the view's eye crop aspect.
    $eyeCrop = ''
    if ($viewObj) {
        $eyeCrop = if ($viewObj.right_eye) { [string]$viewObj.right_eye.crop } elseif ($viewObj.left_eye) { [string]$viewObj.left_eye.crop } else { '' }
    }
    if (-not $eyeCrop -or $eyeCrop -eq '0:0:0:0' -or $eyeCrop -notmatch '^(\d+):(\d+):') {
        if ($View -eq 'fullscreen' -or $eyeCrop -eq '0:0:0:0') { return @{ W = $cw; H = $ch; X = 0; Y = 0; Auto = $true } }
        $aspect = 16.0 / 9
    } else {
        $aspect = [double]$Matches[1] / [double]$Matches[2]
    }
    $r = [VrhmEyeMerge]::DefaultCrop($g.P, $g.PolyL, $g.PolyR, $g.Box, $aspect)
    return @{ W = $r[0]; H = $r[1]; X = $r[2]; Y = $r[3]; Auto = $true }
}


# Identity of the merge a stream of this model/view would run: changes whenever the calibration or
# the view crop changes. Cheap enough for the scrcpy watchdog. '' when merge is not usable.
# Example: Get-EyeMergeViewKey -Model 'Quest 3' -View 'square'
function Get-EyeMergeViewKey {
    param([Parameter(Mandatory)][string]$Model, [string]$View)
    $p = Get-EyeMergeProfile -Model $Model
    if (-not $p) { return '' }
    $viewObj = $null
    $tpl = $global:scrcpyParameters.$Model
    if ($View -and $tpl.views) { $viewObj = $tpl.views.$View }
    $viewPart = if ($viewObj) { ($viewObj | ConvertTo-Json -Depth 6 -Compress) } else { $View }
    # The model max_size caps the merged output too (Get-EyeMergeMaps), so it is part of the identity.
    $maxSize = if ($tpl -and $tpl.max_size) { [int]$tpl.max_size } else { 0 }
    $text = ($p | ConvertTo-Json -Depth 6 -Compress) + '|' + $viewPart + '|max' + $maxSize + '|v3'
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return (($bytes | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}


# Single decision point for a scrcpy profile: does it run as an eye merge? Used alike by
# ConvertTo-ScrcpyArguments, start-screenCopy and the scrcpy watchdog, so they can never disagree.
# Returns @{Use;View;Key;Reason}: Use=$false with Reason '' (not an M profile), 'localwindow'
# (no ffmpeg in that capture mode) or 'unsupported' (no enabled calibration for the model).
# In every Use=$false case with an M profile the stream falls back to the RIGHT eye.
# Example: (Resolve-EyeMergeUse -Model 'Quest 3' -ScrcpyProfile 'square-M-N-45-20').Use
function Resolve-EyeMergeUse {
    param([string]$Model, [string]$ScrcpyProfile)
    $r = @{ Use = $false; View = ''; Key = ''; Reason = '' }
    $parsed = ConvertFrom-ScrcpyProfile -Profile $ScrcpyProfile
    if (-not $parsed -or $parsed.Eye -ne 'M') { return $r }
    $r.View = $parsed.View
    $mode = if ($global:CaptureMode) { [string]$global:CaptureMode } else { 'StreamOnly' }
    if ($mode -eq 'LocalWindow') { $r.Reason = 'localwindow'; return $r }
    if (-not (Test-EyeMergeSupported -Model $Model)) { $r.Reason = 'unsupported'; return $r }
    $r.Key = Get-EyeMergeViewKey -Model $Model -View $parsed.View
    $r.Use = [bool]$r.Key
    if (-not $r.Use) { $r.Reason = 'unsupported'; return $r }
    # start-screenCopy refused this exact calibration/view for this process (display size mismatch,
    # tables could not be built): keep falling back so the watchdog does not restart in a loop.
    # A recalibration or a crop change produces a new key and is tried again.
    if ($global:EyeMergeRejected -and $global:EyeMergeRejected.ContainsKey("$Model|$($r.Key)")) {
        $r.Use = $false; $r.Reason = 'rejected'
    }
    return $r
}


# Marks one model/view merge as unusable for this process (see Resolve-EyeMergeUse).
function Set-EyeMergeRejected {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][string]$Key, [string]$Reason)
    if (-not $global:EyeMergeRejected) { $global:EyeMergeRejected = @{} }
    $global:EyeMergeRejected["$Model|$Key"] = $Reason
    Write-Log ("Merged view disabled for {0} until the next calibration or crop change: {1} - using the right eye." -f $Model, $Reason) -Level WARNING
}


# Builds (or reuses from the cache) the ffmpeg remap tables of one model/view.
# Returns @{Ok;Key;Prefix;Width;Height;Crop;Error}. Files: <Prefix>.bx.raw/.by.raw/.ox.raw/.oy.raw
# (gray16le) and .w.raw (gray8), Width x Height.
# Example: $maps = Get-EyeMergeMaps -Model 'Quest 3' -View 'square'
function Get-EyeMergeMaps {
    param([Parameter(Mandatory)][string]$Model, [string]$View)
    $res = @{ Ok = $false; Key = ''; Prefix = ''; Width = 0; Height = 0; Crop = $null; Error = $null }
    try {
        $p = Get-EyeMergeProfile -Model $Model
        if (-not $p) { $res.Error = "Model '$Model' has no enabled eye merge calibration."; return $res }
        if (-not (Initialize-EyeMergeType)) { $res.Error = 'Image helper unavailable.'; return $res }
        $key = Get-EyeMergeViewKey -Model $Model -View $View
        $dir = Join-Path $global:ScriptPath 'data\eye_merge'
        if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $safeModel = ($Model -replace '[^A-Za-z0-9]+', '_')
        $prefix = Join-Path $dir ("{0}_{1}" -f $safeModel, $key)
        $metaPath = "$prefix.json"
        $res.Key = $key; $res.Prefix = $prefix

        if (Test-Path -LiteralPath $metaPath) {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $allThere = @('bx','by','ox','oy','w' | Where-Object { -not (Test-Path -LiteralPath "$prefix.$_.raw") }).Count -eq 0
            if ($allThere) {
                $res.Width = [int]$meta.Width; $res.Height = [int]$meta.Height; $res.Crop = $meta.Crop; $res.Ok = $true
                return $res
            }
        }

        $crop = Get-EyeMergeViewCrop -Model $Model -View $View -MergeProfile $p
        if (-not $crop) { $res.Error = 'Could not resolve the merged crop.'; return $res }
        $g = Get-EyeMergeGeometry -MergeProfile $p
        # scrcpy cannot apply the model max_size to a merged view (it needs the native frame), so the
        # cap is applied here: the long edge of the merged output never exceeds it.
        $outW = $crop.W; $outH = $crop.H
        $maxSize = if ($global:scrcpyParameters.$Model.max_size) { [int]$global:scrcpyParameters.$Model.max_size } else { 0 }
        if ($maxSize -gt 0 -and [Math]::Max($outW, $outH) -gt $maxSize) {
            $scale = $maxSize / [double][Math]::Max($outW, $outH)
            $outW = [int][Math]::Floor($outW * $scale); $outH = [int][Math]::Floor($outH * $scale)
            $outW -= $outW % 2; $outH -= $outH % 2
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [VrhmEyeMerge]::BuildMaps($prefix, $g.P, $g.PolyL, $g.PolyR, $g.Box, $g.BaseRight, $g.Inset, $g.Feather,
                                  $crop.X, $crop.Y, $crop.W, $crop.H, $outW, $outH)
        $meta = [ordered]@{ Model = $Model; View = $View; Width = $outW; Height = $outH; Crop = ("{0}:{1}:{2}:{3}" -f $crop.W, $crop.H, $crop.X, $crop.Y); Built = (Get-Date).ToString('s') }
        Write-FileWithoutBom -Path $metaPath -Content ($meta | ConvertTo-Json -Compress)
        Write-Log ("Eye merge: lookup tables for {0}/{1} built in {2} ms (crop {3}x{4}, output {5}x{6})" -f $Model, $View, $sw.ElapsedMilliseconds, $crop.W, $crop.H, $outW, $outH) -Level INFO

        # Keep the cache small: the 12 most recent table sets.
        $metas = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        foreach ($old in ($metas | Select-Object -Skip 12)) {
            $oldPrefix = $old.FullName.Substring(0, $old.FullName.Length - 5)
            foreach ($ext in 'bx','by','ox','oy','w') { Remove-Item -LiteralPath "$oldPrefix.$ext.raw" -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
        $res.Width = $outW; $res.Height = $outH; $res.Crop = $meta.Crop; $res.Ok = $true
    } catch {
        $res.Error = $_.Exception.Message
        Write-Log ("Get-EyeMergeMaps failed for {0}/{1}: {2}" -f $Model, $View, $_.Exception.Message) -Level ERROR
    }
    return $res
}


# ffmpeg arguments for the merge: the extra -i inputs (indexes 1..5, after the pipe input 0) and
# the -filter_complex graph whose output label is [vout].
# Example: $fx = Get-EyeMergeFfmpegArgs -Maps (Get-EyeMergeMaps -Model 'Quest 3' -View 'square')
function Get-EyeMergeFfmpegArgs {
    param([Parameter(Mandatory)] $Maps)
    $size = "{0}x{1}" -f $Maps.Width, $Maps.Height
    $inputs = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(@('bx','gray16le'), @('by','gray16le'), @('ox','gray16le'), @('oy','gray16le'), @('w','gray'))) {
        $inputs.AddRange([string[]]@('-f','rawvideo','-pix_fmt',$p[1],'-video_size',$size,'-i',("{0}.{1}.raw" -f $Maps.Prefix, $p[0])))
    }
    # The tables are single frames repeated by loop=-1. The blend is an OVERLAY (base eye, with the
    # feather weight as alpha, over the other eye) and not maskedmerge on purpose: overlay takes its
    # timing from its main input - the live video - and shortest=1 ends the graph with it.
    # maskedmerge syncs on all inputs alike: it emitted frames at the looped tables' 25 fps and
    # never ended once scrcpy stopped (measured: 18000 frames from 3 s of input), which would
    # leave a recording unfinalised. gbrp keeps colour and brightness blended alike.
    $graph = '[0:v]setpts=PTS-STARTPTS,format=gbrp,split=2[s1][s2];' +
             '[1:v]loop=-1:1:0[bx];[2:v]loop=-1:1:0[by];[3:v]loop=-1:1:0[ox];[4:v]loop=-1:1:0[oy];' +
             '[5:v]loop=-1:1:0,format=gray[w];' +
             '[s1][bx][by]remap=fill=black,format=gbrap[B];[s2][ox][oy]remap=fill=black[O];' +
             '[B][w]alphamerge[Bw];' +
             '[O][Bw]overlay=format=gbrp:shortest=1:eof_action=endall,format=yuv420p[vout]'
    return @{ Inputs = $inputs.ToArray(); Graph = $graph }
}


# The display size of a headset (adb "wm size"), @{Width;Height} or $null. Used to refuse a merge
# calibrated for another resolution (firmware change, other model reporting the same name).
function Get-HeadsetDisplaySize {
    param([Parameter(Mandatory)] $Device)
    try {
        $out = Invoke-AdbCmd -Device $Device -Command 'shell wm size' -TimeoutSeconds 5 -SilentOnFail
        if (-not $out) { return $null }
        $line = @($out | Where-Object { $_ -match 'Override size' }) | Select-Object -First 1
        if (-not $line) { $line = @($out | Where-Object { $_ -match 'Physical size' }) | Select-Object -First 1 }
        if ($line -match '(\d+)x(\d+)') { return @{ Width = [int]$Matches[1]; Height = [int]$Matches[2] } }
    } catch {}
    return $null
}


# Writes the merged canvas of a raw side-by-side frame (PNG) - the picture the operator crops in the
# view editor. Returns @{Ok;Path;Width;Height;Error}.
# Example: New-EyeMergeCanvas -Model 'Quest 3' -FramePath $frame.Path -OutFile 'C:\tmp\merged.png'
function New-EyeMergeCanvas {
    param([string]$Model, [Parameter(Mandatory)][string]$FramePath, [Parameter(Mandatory)][string]$OutFile, $MergeProfile = $null)
    $res = @{ Ok = $false; Path = $null; Width = 0; Height = 0; Error = $null }
    try {
        if (-not $MergeProfile) { $MergeProfile = Get-EyeMergeProfile -Model $Model -IncludeDisabled }
        if (-not $MergeProfile) { $res.Error = "Model '$Model' has no eye merge calibration."; return $res }
        if (-not (Initialize-EyeMergeType)) { $res.Error = 'Image helper unavailable.'; return $res }
        $fw = 0; $fh = 0
        $bgr = [VrhmEyeMerge]::LoadBgr($FramePath, [ref]$fw, [ref]$fh)
        if ($fw -ne [int]$MergeProfile.frame_width -or $fh -ne [int]$MergeProfile.frame_height) {
            $res.Error = ("Frame is {0}x{1} but the calibration expects {2}x{3}." -f $fw, $fh, $MergeProfile.frame_width, $MergeProfile.frame_height)
            return $res
        }
        $g = Get-EyeMergeGeometry -MergeProfile $MergeProfile
        $dir = Split-Path -Path $OutFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        [VrhmEyeMerge]::RenderCanvas($bgr, $fw, $fh, $g.P, $g.PolyL, $g.PolyR, $g.Box, $g.BaseRight, $g.Inset, $g.Feather, $OutFile)
        $res.Path = $OutFile; $res.Width = $g.CanvasWidth; $res.Height = $g.CanvasHeight; $res.Ok = $true
    } catch {
        $res.Error = $_.Exception.Message
        Write-Log ("New-EyeMergeCanvas failed: {0}" -f $_.Exception.Message) -Level ERROR
    }
    return $res
}


# Measures the eye merge calibration of a headset model from one frame: relative angle + shift
# between the eyes, lens outlines, symmetric leveling angle. -FramePath calibrates from an existing
# raw frame instead of capturing one. -Save writes the result into config.json (enabled).
# Returns @{Ok;Score;Profile;Model;PreviewPath;PreviewWidth;PreviewHeight;Saved;Error}.
# Example: Invoke-EyeMergeCalibration -Headset (Get-HeadsetDiagTarget -Id 3) -Save
function Invoke-EyeMergeCalibration {
    param(
        $Headset = $null,
        [string]$Model,
        [string]$FramePath,
        [ValidateSet('Auto','USB','WiFi')] [string]$Transport = 'Auto',
        [switch]$Save,
        [string]$CalibratedBy = $env:COMPUTERNAME,
        [double]$MinScore = 0.35
    )
    $res = @{ Ok = $false; Score = 0; Profile = $null; Model = $Model; PreviewPath = $null; PreviewWidth = 0; PreviewHeight = 0; Saved = $false; Error = $null }
    try {
        if (-not $Model -and $Headset) { $Model = [string]$Headset.Model }
        if (-not $Model) { $res.Error = 'Headset model unknown - connect the headset once so its model is detected.'; return $res }
        $res.Model = $Model
        if (-not (Initialize-EyeMergeType)) { $res.Error = 'Image helper unavailable.'; return $res }

        if (-not $FramePath) {
            if (-not $Headset) { $res.Error = 'A headset or a frame is required.'; return $res }
            $frame = Get-HeadsetScreenFrame -Headset $Headset -Transport $Transport
            if (-not $frame.Ok) { $res.Error = $frame.Error; return $res }
            $FramePath = $frame.Path
        }
        $fw = 0; $fh = 0
        $bgr = [VrhmEyeMerge]::LoadBgr($FramePath, [ref]$fw, [ref]$fh)
        if ($fw % 2 -ne 0 -or $fw -lt $fh) { $res.Error = ("Frame {0}x{1} does not look like two eyes side by side." -f $fw, $fh); return $res }
        $ew = $fw / 2
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $mL = [VrhmEyeMerge]::LensMask($bgr, $fw, $fh, 0, $ew, 14)
        $mR = [VrhmEyeMerge]::LensMask($bgr, $fw, $fh, $ew, $ew, 14)
        $polyL = [VrhmEyeMerge]::MaskPolygon($mL, $ew, $fh, 256)
        $polyR = [VrhmEyeMerge]::MaskPolygon($mR, $ew, $fh, 256)
        if ($polyL.Count -lt 16 -or $polyR.Count -lt 16) { $res.Error = 'No lens picture found in the frame (is the headset display on?).'; return $res }

        # Search around the relative angle the model's eye views already encode (left angle - right
        # angle, 43 for a Quest 3), then everywhere if that finds nothing convincing.
        $hint = $null
        $tpl = $global:scrcpyParameters.$Model
        if ($tpl -and $tpl.views) {
            foreach ($v in $tpl.views.PSObject.Properties) {
                if ($v.Value.left_eye -and $v.Value.right_eye -and [string]$v.Value.left_eye.crop -ne '0:0:0:0') {
                    $hint = [double]$v.Value.left_eye.angle - [double]$v.Value.right_eye.angle; break
                }
            }
        }
        $r = $null
        if ($null -ne $hint) { $r = [VrhmEyeMerge]::Register($bgr, $fw, $fh, $mL, $mR, $hint - 12, $hint + 12) }
        if (-not $r -or $r[3] -lt $MinScore) { $r = [VrhmEyeMerge]::Register($bgr, $fw, $fh, $mL, $mR, -60, 60) }
        $res.Score = [Math]::Round($r[3], 3)
        Write-Log ("Eye merge calibration of {0}: angle {1:N2} deg, shift {2},{3}, score {4:N3} ({5} ms)" -f $Model, $r[0], $r[1], $r[2], $r[3], $sw.ElapsedMilliseconds) -Level INFO
        if ($r[3] -lt $MinScore) {
            $res.Error = ("The two eyes could not be matched (score {0:N2}, needs {1:N2}). Use a scene with far, detailed content (Home environment), the headset level and steady, no window close to the eyes." -f $r[3], $MinScore)
            return $res
        }

        $ic = [System.Globalization.CultureInfo]::InvariantCulture
        $existing = Get-EyeMergeProfile -Model $Model -IncludeDisabled
        $cal = [ordered]@{
            schema         = 1
            enabled        = $true
            model          = $Model
            frame_width    = $fw
            frame_height   = $fh
            relative_angle = [Math]::Round($r[0], 2)
            shift_x        = [int]$r[1]
            shift_y        = [int]$r[2]
            level_angle    = [Math]::Round($r[0] / 2, 2)
            base_eye       = if ($existing -and $existing.base_eye) { [string]$existing.base_eye } else { 'R' }
            canvas_width   = 0
            canvas_height  = 0
            feather_px     = if ($existing -and $null -ne $existing.feather_px) { [int]$existing.feather_px } else { 240 }
            inset_px       = if ($existing -and $null -ne $existing.inset_px) { [int]$existing.inset_px } else { 40 }
            mask_left      = (ConvertTo-EyeMergePolygon -Points $polyL)
            mask_right     = (ConvertTo-EyeMergePolygon -Points $polyR)
            score          = $res.Score
            calibrated_at  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $ic)
            calibrated_by  = [string]$CalibratedBy
            notes          = ''
        }
        $pObj = [PSCustomObject]$cal
        $g = Get-EyeMergeGeometry -MergeProfile $pObj
        $pObj.canvas_width = $g.CanvasWidth; $pObj.canvas_height = $g.CanvasHeight

        # Width of the darkened lens rim, measured on this frame: the blend must not use a pixel
        # inside it (soft dark band and dark blob in the seam otherwise). +10 px of margin, clamped.
        $rim = [VrhmEyeMerge]::MeasureFalloff($bgr, $fw, $fh, $g.P, $g.PolyL, $g.PolyR, $g.Box, 0.92)
        if ($rim -ge 0) {
            $pObj.inset_px = [int][Math]::Min(300, [Math]::Max(20, $rim + 10))
            Write-Log ("Eye merge calibration of {0}: darkened lens rim ~{1} px -> inset {2} px" -f $Model, $rim, $pObj.inset_px) -Level INFO
        } else {
            Write-Log ("Eye merge calibration of {0}: lens rim not measurable on this frame, inset kept at {1} px" -f $Model, $pObj.inset_px) -Level INFO
        }

        $previewDir = Join-Path $global:ScriptPath 'website\generated\eye_merge'
        $safeModel = ($Model -replace '[^A-Za-z0-9]+', '_')
        $preview = Join-Path $previewDir ("calibration_{0}.png" -f $safeModel)
        $canvas = New-EyeMergeCanvas -FramePath $FramePath -OutFile $preview -MergeProfile $pObj
        if ($canvas.Ok) { $res.PreviewPath = $canvas.Path; $res.PreviewWidth = $canvas.Width; $res.PreviewHeight = $canvas.Height }

        $res.Profile = $pObj
        $res.Ok = $true
        if ($Save) { $res.Saved = Save-EyeMergeProfile -Model $Model -MergeProfile $pObj }
    } catch {
        $res.Error = $_.Exception.Message
        Write-Log ("Invoke-EyeMergeCalibration failed: {0}" -f $_.Exception.Message) -Level ERROR
        Write-Log ("Invoke-EyeMergeCalibration stack: {0}" -f $_.ScriptStackTrace) -Level DEBUG
    }
    return $res
}


# Internal: read config.json, let -Mutate change scrcpy.parameters.<Model>, write it back (UTF-8, no
# BOM, depth 20), reload globals. Returns $true/$false.
function Update-EyeMergeConfig {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][scriptblock]$Mutate, [switch]$CreateModel)
    $cfgPath = Join-Path $global:ScriptPath 'config\config.json'
    try {
        $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
        if (-not $cfg -or -not $cfg.scrcpy -or -not $cfg.scrcpy.parameters) {
            Write-Log 'Eye merge: config.json could not be read.' -Level ERROR
            return $false
        }
        $modelObj = $cfg.scrcpy.parameters.$Model
        if (-not $modelObj) {
            if (-not $CreateModel) { Write-Log ("Eye merge: model '{0}' not found in config.json." -f $Model) -Level ERROR; return $false }
            $modelObj = [PSCustomObject]@{ views = [PSCustomObject]@{}; max_size = 0; video_codec = 'h264'; video_encoder = ''; video_buffer = 50; stay_awake = $true }
            $cfg.scrcpy.parameters | Add-Member -NotePropertyName $Model -NotePropertyValue $modelObj
        }
        & $Mutate $modelObj
        Write-FileWithoutBom -Path $cfgPath -Content ($cfg | ConvertTo-Json -Depth 20)
    } catch {
        Write-Log ("Eye merge: config update for '{0}' failed: {1}" -f $Model, $_.Exception.Message) -Level ERROR
        return $false
    }
    Get-Config
    return $true
}


# Saves an eye_merge block for a model into config.json. Returns $true/$false.
# Example: Save-EyeMergeProfile -Model 'Quest 3' -MergeProfile $cal.Profile
function Save-EyeMergeProfile {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)] $MergeProfile, [switch]$CreateModel)
    $t = Test-EyeMergeProfile -MergeProfile $MergeProfile
    if (-not $t.Ok) { Write-Log ("Save-EyeMergeProfile: invalid profile: {0}" -f ($t.Errors -join '; ')) -Level ERROR; return $false }
    $ok = Update-EyeMergeConfig -Model $Model -CreateModel:$CreateModel -Mutate {
        param($m)
        if ($m.PSObject.Properties.Name -contains 'eye_merge') { $m.eye_merge = $MergeProfile }
        else { $m | Add-Member -NotePropertyName 'eye_merge' -NotePropertyValue $MergeProfile }
    }
    if ($ok) { Write-Log ("Eye merge calibration saved for model '{0}'." -f $Model) -Level SUCCESS }
    return $ok
}


# Turns the merge of a model on or off without losing its calibration. Returns $true/$false.
# Example: Set-EyeMergeEnabled -Model 'Quest 3' -Enabled $false
function Set-EyeMergeEnabled {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][bool]$Enabled)
    if (-not (Get-EyeMergeProfile -Model $Model -IncludeDisabled)) { Write-Log ("Eye merge: model '{0}' has no calibration." -f $Model) -Level WARNING; return $false }
    $ok = Update-EyeMergeConfig -Model $Model -Mutate {
        param($m)
        if ($m.eye_merge.PSObject.Properties.Name -contains 'enabled') { $m.eye_merge.enabled = $Enabled }
        else { $m.eye_merge | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $Enabled }
    }
    if ($ok) { Write-Log ("Eye merge for model '{0}' is now {1}." -f $Model, $(if ($Enabled) { 'enabled' } else { 'disabled' })) -Level INFO }
    return $ok
}


# Sets (w:h:x:y on the merged canvas) or clears (-Reset = automatic) the merged crop of one view.
# Example: Set-EyeMergeViewCrop -Model 'Quest 3' -View 'square' -Crop '1720:1720:640:420'
function Set-EyeMergeViewCrop {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][string]$View, [string]$Crop, [switch]$Reset)
    if (-not $Reset -and $Crop -notmatch '^\d+:\d+:\d+:\d+$') { Write-Log ("Set-EyeMergeViewCrop: '{0}' is not w:h:x:y." -f $Crop) -Level ERROR; return $false }
    return (Update-EyeMergeConfig -Model $Model -Mutate {
        param($m)
        $v = $m.views.$View
        if (-not $v) { throw "View '$View' not found for model '$Model'." }
        if ($Reset) {
            if ($v.PSObject.Properties.Name -contains 'merged') { $v.PSObject.Properties.Remove('merged') }
        } elseif ($v.PSObject.Properties.Name -contains 'merged') {
            $v.merged = [PSCustomObject]@{ crop = $Crop }
        } else {
            $v | Add-Member -NotePropertyName 'merged' -NotePropertyValue ([PSCustomObject]@{ crop = $Crop })
        }
    })
}


# Shareable JSON snippet of a model calibration: the eye_merge block plus the merged crop of every
# view that has one. Paste it into Import-EyeMergeProfile (or the web Import box) elsewhere.
# Example: Export-EyeMergeProfile -Model 'Quest 3' | Set-Clipboard
function Export-EyeMergeProfile {
    param([Parameter(Mandatory)][string]$Model)
    $p = Get-EyeMergeProfile -Model $Model -IncludeDisabled
    if (-not $p) { return $null }
    $crops = [ordered]@{}
    $tpl = $global:scrcpyParameters.$Model
    if ($tpl.views) {
        foreach ($v in $tpl.views.PSObject.Properties) {
            if ($v.Value.merged -and $v.Value.merged.crop) { $crops[$v.Name] = [string]$v.Value.merged.crop }
        }
    }
    $snippet = [ordered]@{ vrhm_eye_merge = 1; model = $Model; eye_merge = $p; view_crops = $crops }
    return ($snippet | ConvertTo-Json -Depth 8)
}


# Imports a snippet produced by Export-EyeMergeProfile. -Model overrides the target model (default:
# the one named in the snippet). -IncludeViewCrops also applies the shared views' merged crops
# (only to views that exist locally). Returns @{Ok;Model;Error;CropsApplied}.
# Example: Import-EyeMergeProfile -Json (Get-Content -LiteralPath $f -Raw -Encoding UTF8) -IncludeViewCrops
function Import-EyeMergeProfile {
    param([Parameter(Mandatory)][string]$Json, [string]$Model, [switch]$IncludeViewCrops)
    $res = @{ Ok = $false; Model = $null; Error = $null; CropsApplied = 0 }
    try {
        if ($Json.Length -gt 200000) { $res.Error = 'Snippet too large.'; return $res }
        $o = $Json | ConvertFrom-Json -ErrorAction Stop
        $block = if ($o.vrhm_eye_merge) { $o.eye_merge } elseif ($o.schema) { $o } else { $null }
        if (-not $block) { $res.Error = 'This is not an eye merge snippet (vrhm_eye_merge missing).'; return $res }
        if (-not $Model) { $Model = if ($o.model) { [string]$o.model } else { [string]$block.model } }
        if (-not $Model) { $res.Error = 'The snippet names no headset model - choose one.'; return $res }
        $res.Model = $Model
        $t = Test-EyeMergeProfile -MergeProfile $block
        if (-not $t.Ok) { $res.Error = 'Invalid calibration: ' + ($t.Errors -join '; '); return $res }
        if ($block.PSObject.Properties.Name -contains 'model') { $block.model = $Model }
        if (-not (Save-EyeMergeProfile -Model $Model -MergeProfile $block -CreateModel)) { $res.Error = 'Could not write config.json.'; return $res }
        if ($IncludeViewCrops -and $o.view_crops) {
            foreach ($c in $o.view_crops.PSObject.Properties) {
                if ($global:scrcpyParameters.$Model.views.($c.Name) -and [string]$c.Value -match '^\d+:\d+:\d+:\d+$') {
                    if (Set-EyeMergeViewCrop -Model $Model -View $c.Name -Crop ([string]$c.Value)) { $res.CropsApplied++ }
                }
            }
        }
        $res.Ok = $true
    } catch {
        $res.Error = 'Not valid JSON: ' + $_.Exception.Message
    }
    return $res
}


# Captures a headset frame and renders its merged canvas for the view editor.
# Returns the same shape as /api/headset-screen-frame: @{Ok;Path;Width;Height;Transport;Error}.
# Example: Get-HeadsetMergedFrame -Headset (Get-HeadsetDiagTarget -Id 3)
function Get-HeadsetMergedFrame {
    param([Parameter(Mandatory)] $Headset, [ValidateSet('Auto','USB','WiFi')] [string]$Transport = 'Auto')
    $res = @{ Ok = $false; Path = $null; Width = 0; Height = 0; Transport = '-'; Error = $null }
    $p = Get-EyeMergeProfile -Model ([string]$Headset.Model) -IncludeDisabled
    if (-not $p) { $res.Error = ("Model '{0}' has no eye merge calibration - calibrate it first." -f $Headset.Model); return $res }
    $frame = Get-HeadsetScreenFrame -Headset $Headset -Transport $Transport
    $res.Transport = $frame.Transport
    if (-not $frame.Ok) { $res.Error = $frame.Error; return $res }
    $out = Join-Path $global:ScriptPath ("website\generated\view_editor\headset_{0}_merged.png" -f $Headset.ID)
    $c = New-EyeMergeCanvas -FramePath $frame.Path -OutFile $out -MergeProfile $p
    if (-not $c.Ok) { $res.Error = $c.Error; return $res }
    $res.Path = $c.Path; $res.Width = $c.Width; $res.Height = $c.Height; $res.Ok = $true
    return $res
}


# Transparency mask of a headset's CURRENT stream, when its view has "transparent_corners": true.
# Works for every eye: M from the merge tables, L/R from the crop + angle + the model's lens
# outlines (the eye_merge calibration, enabled or not - it is the only source of the lens shape).
# The PNG is cached in website\generated\stream_mask\<key>.png (served as /stream_mask/<key>.png),
# the key being a hash of everything that shapes it. The [video].html pages apply it with CSS
# mask-image, so the corners are transparent in browsers and OBS Browser Sources (an RTSP/HLS player
# still shows them black: H.264/HEVC carry no alpha).
# Returns @{Ok;Mask;Url;Path;Width;Height;Key;Reason;Error}; Mask=$false with a Reason when the
# option is off or the mask cannot be computed.
# Example: Get-StreamMask -Headset (Get-HeadsetDiagTarget -Id 10)
function Get-StreamMask {
    param([Parameter(Mandatory)] $Headset, [int]$Feather = 24)
    $res = @{ Ok = $true; Mask = $false; Url = $null; Path = $null; Width = 0; Height = 0; Key = ''; Reason = ''; Error = $null }
    try {
        Update-EyeMergeParameters
        $model = [string]$Headset.Model
        $parsed = ConvertFrom-ScrcpyProfile -Profile ([string]$Headset.ScrcpyProfile)
        $tpl = if ($model) { $global:scrcpyParameters.$model } else { $null }
        if (-not $parsed -or -not $tpl -or $tpl -is [string] -or -not $tpl.views) { $res.Reason = 'no view'; return $res }
        $view = $tpl.views.($parsed.View)
        if (-not $view -or $view.transparent_corners -ne $true) { $res.Reason = 'option off'; return $res }
        if (-not (Initialize-EyeMergeType)) { $res.Ok = $false; $res.Error = 'Image helper unavailable.'; return $res }

        $cal = Get-EyeMergeProfile -Model $model -IncludeDisabled
        $inset = if ($cal -and $cal.inset_px) { [Math]::Min(40, [int]$cal.inset_px) } else { 8 }
        $dir = Join-Path $global:ScriptPath 'website\generated\stream_mask'
        if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }

        $merge = Resolve-EyeMergeUse -Model $model -ScrcpyProfile ([string]$Headset.ScrcpyProfile)
        if ($merge.Use) {
            $maps = Get-EyeMergeMaps -Model $model -View $merge.View
            if (-not $maps.Ok) { $res.Reason = $maps.Error; return $res }
            $key = Get-StreamMaskHash -Text ("M|{0}|{1}|{2}|{3}|v2" -f $maps.Key, $maps.Width, $maps.Height, $Feather)
            $out = Join-Path $dir "$key.png"
            if (-not (Test-Path -LiteralPath $out)) { [VrhmEyeMerge]::StreamMaskFromMaps($maps.Prefix, $maps.Width, $maps.Height, 8, $Feather, $out) }
            $res.Width = $maps.Width; $res.Height = $maps.Height
        } else {
            # L, R, or an M profile falling back to the right eye.
            if (-not $cal) { $res.Reason = "model '$model' has no lens outline (calibrate the eye merge once)"; return $res }
            $eye = if ($parsed.Eye -eq 'L') { 'L' } else { 'R' }
            $eyeObj = if ($eye -eq 'L') { $view.left_eye } else { $view.right_eye }
            $fw = [int]$cal.frame_width; $fh = [int]$cal.frame_height
            $crop = if ($eyeObj) { [string]$eyeObj.crop } else { '' }
            $angle = if ($eyeObj -and $null -ne $eyeObj.angle) { [double]$eyeObj.angle } else { 0.0 }
            if ($crop -match '^(\d+):(\d+):(\d+):(\d+)$' -and [int]$Matches[1] -gt 0) {
                $cw = [int]$Matches[1]; $ch = [int]$Matches[2]; $cx = [int]$Matches[3]; $cy = [int]$Matches[4]
            } else {
                $cw = $fw; $ch = $fh; $cx = 0; $cy = 0; $angle = 0.0      # fullscreen: both eyes, no rotation
            }
            $pL = ConvertFrom-EyeMergePolygon -Text ([string]$cal.mask_left)
            $pR = ConvertFrom-EyeMergePolygon -Text ([string]$cal.mask_right)
            $key = Get-StreamMaskHash -Text ("LR|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|v2" -f $fw, $fh, $cx, $cy, $cw, $ch, $angle, $cal.mask_left, $cal.mask_right, $inset, $Feather)
            $out = Join-Path $dir "$key.png"
            if (-not (Test-Path -LiteralPath $out)) { [VrhmEyeMerge]::StreamMaskFromCrop($fw, $fh, $cx, $cy, $cw, $ch, $angle, $pL, $pR, $inset, $Feather, $out) }
            $res.Width = $cw; $res.Height = $ch
        }
        Limit-StreamMaskCache -Folder $dir -Keep 30
        $res.Key = $key; $res.Path = $out; $res.Url = "/stream_mask/$key.png"; $res.Mask = $true
    } catch {
        $res.Ok = $false; $res.Error = $_.Exception.Message
        Write-Log ("Get-StreamMask failed for {0}: {1}" -f $Headset.Name, $_.Exception.Message) -Level WARNING
    }
    return $res
}

# Internal: 16-hex-char SHA1 of a text, for cache keys.
function Get-StreamMaskHash {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

# Internal: keeps the newest -Keep PNG masks of the cache folder.
function Limit-StreamMaskCache {
    param([Parameter(Mandatory)][string]$Folder, [int]$Keep = 30)
    foreach ($old in @(Get-ChildItem -LiteralPath $Folder -Filter '*.png' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)) {
        try { [System.IO.File]::Delete($old.FullName) } catch {}
    }
}


# Turns "transparent outside the lenses" on or off for one view (views.<view>.transparent_corners),
# for every eye mode of that view. Console counterpart of the checkbox in the visual view editor.
# Example: Set-ViewTransparentCorners -Model 'Quest 3' -View 'square' -Enabled $true
function Set-ViewTransparentCorners {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][string]$View, [Parameter(Mandatory)][bool]$Enabled)
    return (Update-EyeMergeConfig -Model $Model -Mutate {
        param($m)
        $v = $m.views.$View
        if (-not $v) { throw "View '$View' not found for model '$Model'." }
        if ($Enabled) {
            if ($v.PSObject.Properties.Name -contains 'transparent_corners') { $v.transparent_corners = $true }
            else { $v | Add-Member -NotePropertyName 'transparent_corners' -NotePropertyValue $true }
        } elseif ($v.PSObject.Properties.Name -contains 'transparent_corners') {
            $v.PSObject.Properties.Remove('transparent_corners')
        }
    })
}
